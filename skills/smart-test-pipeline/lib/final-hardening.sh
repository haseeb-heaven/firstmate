#!/usr/bin/env bash
# lib/final-hardening.sh — reviewed trust-boundary hardening loaded last.
set -euo pipefail

# Preserve the already-hardened implementations so the final wrappers can add
# narrow checks without duplicating unrelated orchestration behavior.
if ! declare -F _smart_prior_spawn_fix_agent >/dev/null 2>&1; then
  eval "$(declare -f spawn_fix_agent | sed '1s/spawn_fix_agent/_smart_prior_spawn_fix_agent/')"
fi
if ! declare -F _smart_prior_run_sandboxed_impl >/dev/null 2>&1; then
  eval "$(declare -f _run_sandboxed_impl | sed '1s/_run_sandboxed_impl/_smart_prior_run_sandboxed_impl/')"
fi

trusted_command_path() {
  local input="${1:-}" worktree="${2:-}" part output=""
  local old_ifs="$IFS"
  IFS=:
  for part in $input; do
    [[ "$part" == /* && -d "$part" ]] || continue
    if [[ -n "$worktree" ]]; then
      case "$part" in
        "$worktree"|"$worktree"/*) continue ;;
      esac
    fi
    case ":$output:" in
      *":$part:"*) ;;
      *) output="${output:+$output:}$part" ;;
    esac
  done
  IFS="$old_ifs"
  [[ -n "$output" ]] || output="/usr/bin:/bin:/usr/sbin:/sbin"
  printf '%s\n' "$output"
}

# Establish a trusted absolute-only PATH before entering untrusted code. This
# also excludes absolute PATH entries that point into the PR worktree.
run_sandboxed() {
  local worktree="$2" original_path="${PATH:-/usr/bin:/bin}" safe_path
  safe_path=$(trusted_command_path "$original_path" "$worktree")
  ( export PATH="$safe_path"; cd "$worktree" && _run_sandboxed_impl "$@" )
}

validation_runtime_mount_paths() {
  local executable resolved interpreter runtime_root
  while IFS= read -r executable; do
    [[ -n "$executable" ]] || continue
    resolved=$(resolve_runtime_path "$executable") || return 1
    interpreter=$(runtime_interpreter_path "$executable") || return 1
    printf '%s\n' "$executable"
    [[ -n "$resolved" ]] && printf '%s\n' "$resolved"
    [[ -n "$interpreter" ]] && printf '%s\n' "$interpreter"
    while IFS= read -r runtime_root; do
      [[ -n "$runtime_root" ]] && printf '%s\n' "$runtime_root"
    done < <(
      {
        agent_runtime_roots "$resolved"
        agent_runtime_roots "$interpreter"
      } | awk '!seen[$0]++'
    )
  done < <(validation_runtime_executables)
}

bwrap_parent_dirs_for_path() {
  local path="$1" dir parents="" next
  dir=$(dirname "$path")
  while [[ "$dir" != / && -n "$dir" ]]; do
    case "$dir" in
      /usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*|/lib64|/lib64/*|/proc|/proc/*|/dev|/dev/*|/tmp|/tmp/*)
        break
        ;;
    esac
    parents="$dir${parents:+$'\n'$parents}"
    next=$(dirname "$dir")
    [[ "$next" != "$dir" ]] || break
    dir="$next"
  done
  printf '%s\n' "$parents" | sed '/^$/d'
}

# Intercept credential-free bwrap validation so user-installed configured
# runtimes are mounted read-only at their exact absolute locations. Other
# sandbox modes retain the implementation from sandbox.sh/review-hardening.sh.
_run_sandboxed_impl() {
  local mode="$1" worktree="$2" home_dir="$3" temp_dir="$4" allow_network="$5"
  shift 5
  local command=("$@")

  local use_bwrap=false
  if [[ "$allow_network" != true ]]; then
    if [[ "$mode" == bwrap ]]; then
      use_bwrap=true
    elif [[ "$mode" == auto ]] && ! sandbox_exec_works && command -v bwrap >/dev/null 2>&1; then
      use_bwrap=true
    fi
  fi
  [[ "$use_bwrap" == true ]] || {
    _smart_prior_run_sandboxed_impl "$mode" "$worktree" "$home_dir" "$temp_dir" "$allow_network" "${command[@]}"
    return $?
  }

  local path_value="${PATH:-/usr/bin:/bin}" item runtime_path parent
  local -a clean_env=(env -i "PATH=$path_value" "HOME=$home_dir" "PWD=$worktree" "TMPDIR=$temp_dir"
    "GIT_CONFIG_NOSYSTEM=1" "GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_SYSTEM=/dev/null"
    "GIT_TERMINAL_PROMPT=0" "GIT_SSH_COMMAND=ssh -oIdentityAgent=none -oIdentitiesOnly=yes")
  while IFS= read -r -d '' item; do clean_env+=("$item"); done < <(copy_allowed_env "${AGENT_ENV_ALLOWLIST:-}")

  local -a args=(--die-with-parent --new-session --unshare-pid --unshare-ipc --unshare-uts
    --ro-bind /usr /usr --ro-bind /bin /bin --ro-bind /sbin /sbin
    --ro-bind /lib /lib --proc /proc --dev /dev --tmpfs /tmp
    --bind "$worktree" "$worktree" --bind "$home_dir" "$home_dir" --bind "$temp_dir" "$temp_dir"
    --chdir "$worktree" --unshare-net)
  [[ -d /lib64 ]] && args+=(--ro-bind /lib64 /lib64)
  [[ -f /etc/resolv.conf ]] && args+=(--ro-bind /etc/resolv.conf /etc/resolv.conf)
  [[ -e "$worktree/.git" ]] && args+=(--ro-bind "$worktree/.git" "$worktree/.git")

  local runtime_file="$temp_dir/validation-runtime-paths.txt"
  validation_runtime_mount_paths | awk '!seen[$0]++' > "$runtime_file"
  local parent_file="$temp_dir/validation-runtime-parents.txt"
  : > "$parent_file"
  while IFS= read -r runtime_path; do
    [[ "$runtime_path" == /* && -e "$runtime_path" ]] || continue
    bwrap_parent_dirs_for_path "$runtime_path" >> "$parent_file"
  done < "$runtime_file"
  awk 'NF && !seen[$0]++ { print length($0), $0 }' "$parent_file" | sort -n | cut -d' ' -f2- | while IFS= read -r parent; do
    printf '%s\n' "$parent"
  done > "$parent_file.sorted"
  while IFS= read -r parent; do
    [[ -n "$parent" ]] || continue
    [[ -e "$parent" ]] || args+=(--dir "$parent")
  done < "$parent_file.sorted"
  while IFS= read -r runtime_path; do
    [[ "$runtime_path" == /* && -e "$runtime_path" ]] || continue
    case "$runtime_path" in
      /usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*|/lib64|/lib64/*) continue ;;
    esac
    args+=(--ro-bind "$runtime_path" "$runtime_path")
  done < "$runtime_file"

  "${clean_env[@]}" bwrap "${args[@]}" -- "${command[@]}"
}

validate_provider_hosts() {
  local hosts="$1" host count=0
  for host in $hosts; do
    count=$((count + 1))
    [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || {
      echo "ERROR: invalid provider host: $host" >&2
      return 1
    }
    case "$host" in
      *..*|.*|*.) echo "ERROR: invalid provider host: $host" >&2; return 1 ;;
    esac
  done
  [[ "$count" -gt 0 ]] || {
    echo "ERROR: provider host list must not be empty" >&2
    return 1
  }
}

# Validate the complete network/authentication boundary before any review bot is
# triggered. This uses the broker contract rather than raw provider keys.
preflight_agent() {
  case "$FIX_AGENT" in
    pi|claude|codex|opencode) ;;
    *) echo "ERROR: unsupported fix agent '$FIX_AGENT'; refusing to trigger review bots" >&2; return 1 ;;
  esac

  AGENT_EXECUTABLE=$(resolve_agent_executable "$FIX_AGENT") || {
    echo "ERROR: fix agent '$FIX_AGENT' is not installed" >&2
    return 1
  }
  export AGENT_EXECUTABLE

  local broker="${AGENT_CREDENTIAL_BROKER:-}" hosts
  [[ "$broker" == /* && -x "$broker" ]] || {
    echo "ERROR: AGENT_CREDENTIAL_BROKER must be an absolute trusted executable" >&2
    return 1
  }
  hosts=$(agent_provider_hosts "$FIX_AGENT") || return 1
  validate_provider_hosts "$hosts" || return 1
  AGENT_PROVIDER_HOSTS="$hosts"
  export AGENT_PROVIDER_HOSTS

  GH_EXECUTABLE=$(command -v gh 2>/dev/null || true)
  case "$GH_EXECUTABLE" in
    /*) ;;
    '') echo "ERROR: gh is not installed" >&2; return 1 ;;
    *) GH_EXECUTABLE="$(cd "$(dirname "$GH_EXECUTABLE")" && pwd -P)/$(basename "$GH_EXECUTABLE")" ;;
  esac
  [[ -x "$GH_EXECUTABLE" ]] || { echo "ERROR: gh executable is not usable" >&2; return 1; }
  export GH_EXECUTABLE

  case "${AGENT_SANDBOX:-auto}" in
    macos) sandbox_exec_works || { echo "ERROR: macOS agent sandbox unavailable" >&2; return 1; } ;;
    bwrap|docker) echo "ERROR: $AGENT_SANDBOX cannot provide provider-restricted agent networking" >&2; return 1 ;;
    auto) sandbox_exec_works || { echo "ERROR: no provider-aware disposable agent sandbox backend is available" >&2; return 1; } ;;
    *) echo "ERROR: unsupported agent sandbox mode: $AGENT_SANDBOX" >&2; return 1 ;;
  esac
}

# Never spend an agent run on stale code after another contributor moves the PR
# head while reviewers are publishing findings.
spawn_fix_agent() {
  if declare -F pr_head_matches_worktree >/dev/null 2>&1 && ! pr_head_matches_worktree; then
    echo "ERROR: PR head changed before fixer launch; refusing to run against stale code" >&2
    return 42
  fi
  _smart_prior_spawn_fix_agent "$@"
}

# Pin the credential helper to the trusted absolute gh executable captured by
# preflight, so a PR-controlled `gh` cannot be resolved from the worktree.
push_changes() {
  local remote="$1" worktree_dir="$2" remote_branch="$3" force="$4" helper
  [[ "${GH_EXECUTABLE:-}" == /* && -x "$GH_EXECUTABLE" ]] || {
    echo "ERROR: trusted gh executable was not preflighted" >&2
    return 1
  }
  printf -v helper '!%q auth git-credential' "$GH_EXECUTABLE"
  local -a args=(push "$remote" "HEAD:$remote_branch")
  [[ "$force" == true ]] && args+=(--force-with-lease)
  if ! git -C "$worktree_dir" -c "credential.helper=$helper" "${args[@]}"; then
    echo "ERROR: git push failed" >&2
    return 1
  fi
  echo -e "${GREEN}  ${CHECK} Pushed${NC}"
}

# Strict CI contract: every completed reported check/status must be success.
wait_for_ci() {
  local owner="$1" repo="$2" sha="$3" timeout="$4" data_dir="$5" iteration="$6"
  local start=$SECONDS conclusions_file="$data_dir/iterations/$iteration/ci-conclusions.json"
  local failures_file="$data_dir/iterations/$iteration/ci-failures.md"
  local stability_polls="${CI_STABILITY_POLLS:-2}" stable_polls=0 stable_fingerprint="" fingerprint
  [[ "$stability_polls" =~ ^[1-9][0-9]*$ ]] || return 2

  while (( SECONDS - start < timeout )); do
    local check_runs statuses latest_statuses total pending status_total status_pending failed
    check_runs=$(gh api --paginate --slurp "/repos/$owner/$repo/commits/$sha/check-runs" 2>/dev/null) || return 1
    statuses=$(gh api --paginate --slurp "/repos/$owner/$repo/commits/$sha/statuses" 2>/dev/null) || return 1
    total=$(jq '[.[].check_runs[]] | length' <<<"$check_runs")
    pending=$(jq '[.[].check_runs[] | select(.status != "completed")] | length' <<<"$check_runs")
    latest_statuses=$(jq '[.[][]] | sort_by(.context, .created_at) | group_by(.context) | map(last)' <<<"$statuses")
    status_total=$(jq 'length' <<<"$latest_statuses")
    status_pending=$(jq '[.[] | select(.state == "pending")] | length' <<<"$latest_statuses")
    total=$((total + status_total)); pending=$((pending + status_pending))
    if [[ "$total" -eq 0 || "$pending" -gt 0 ]]; then
      stable_polls=0; stable_fingerprint=""
      sleep "${POLL_INTERVAL:-30}"
      continue
    fi

    jq '[.[].check_runs[] | {name, conclusion, details_url: .html_url}]' <<<"$check_runs" > "$conclusions_file"
    jq --argjson latest "$latest_statuses" '[ $latest[] | {name: .context, conclusion: .state, details_url: .target_url} ]' <<<"{}" > "$conclusions_file.statuses"
    jq -s '.[0] + .[1]' "$conclusions_file" "$conclusions_file.statuses" > "$conclusions_file.tmp"
    mv "$conclusions_file.tmp" "$conclusions_file"; rm -f "$conclusions_file.statuses"

    failed=$(jq '[.[] | select(.conclusion != "success")] | length' "$conclusions_file")
    if [[ "$failed" -eq 0 ]]; then
      fingerprint=$(jq -r 'sort_by(.name) | map("\(.name)=\(.conclusion)") | join("\n")' "$conclusions_file")
      if [[ "$fingerprint" == "$stable_fingerprint" ]]; then stable_polls=$((stable_polls + 1)); else stable_fingerprint="$fingerprint"; stable_polls=1; fi
      if [[ "$stable_polls" -ge "$stability_polls" ]]; then rm -f "$failures_file"; return 0; fi
      sleep "${POLL_INTERVAL:-30}"
      continue
    fi

    stable_polls=0; stable_fingerprint=""
    {
      echo "## CI Failures"
      jq -r '.[] | select(.conclusion != "success") | "- **\(.name)**: \(.conclusion) (\(.details_url))"' "$conclusions_file"
    } > "$failures_file"
    return 1
  done
  printf '## CI Failures\n\n- CI wait timed out after %ss\n' "$timeout" > "$failures_file"
  return 1
}

# Generated/dependency directories are forbidden at any nesting depth, not only
# when they occur at the repository root.
path_is_forbidden() {
  local path="$1" lower basename wrapped
  lower=$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')
  basename="${lower##*/}"
  wrapped="/$lower/"
  [[ "$lower" == .git || "$lower" == .git/* || "$lower" == */.git || "$lower" == */.git/* || "$lower" == .greploop-data/* ]] && return 0
  case "$basename" in
    .env|.env.*|*.pem|*.key|*.p12|*.pfx)
      case "$basename" in
        .env.example|.env.*.example) ;;
        *) return 0 ;;
      esac
      ;;
  esac
  case "$wrapped" in
    */node_modules/*|*/.venv/*|*/vendor/*|*/dist/*|*/build/*) return 0 ;;
  esac
  return 1
}

# Preflight every gitlink before the core copier descends. A checked-out
# submodule must resolve to a repository rooted at that exact path and remain
# physically beneath its parent validation source; symlink escapes are refused.
if ! declare -F _smart_prior_copy_snapshot_repo >/dev/null 2>&1; then
  eval "$(declare -f copy_snapshot_repo | sed '1s/copy_snapshot_repo/_smart_prior_copy_snapshot_repo/')"
fi
copy_snapshot_repo() {
  local source_dir="$1" snapshot_dir="$2" include_untracked="$3"
  local source_root path mode submodule_dir submodule_root
  source_root=$(cd "$source_dir" && pwd -P) || return 1
  while IFS= read -r -d '' path; do
    mode=$(git -C "$source_dir" ls-files --stage -- "$path" | awk 'NR == 1 { print $1 }')
    [[ "$mode" == 160000 ]] || continue
    [[ -d "$source_dir/$path" ]] || {
      echo "ERROR: checked-out submodule missing from validation snapshot: $path" >&2
      return 1
    }
    submodule_dir=$(cd "$source_dir/$path" 2>/dev/null && pwd -P) || return 1
    case "$submodule_dir" in
      "$source_root"/*) ;;
      *) echo "ERROR: submodule escapes validation source: $path" >&2; return 1 ;;
    esac
    submodule_root=$(git -C "$source_dir/$path" rev-parse --show-toplevel 2>/dev/null || true)
    [[ -n "$submodule_root" ]] || {
      echo "ERROR: submodule is not initialized in validation source: $path" >&2
      return 1
    }
    submodule_root=$(cd "$submodule_root" 2>/dev/null && pwd -P) || submodule_root=""
    [[ "$submodule_root" == "$submodule_dir" ]] || {
      echo "ERROR: submodule is not initialized in validation source: $path" >&2
      return 1
    }
  done < <(git -C "$source_dir" ls-files --cached -z)
  _smart_prior_copy_snapshot_repo "$source_dir" "$snapshot_dir" "$include_untracked"
}

# Snapshot construction itself runs outside the validation sandbox, so every
# Git command that can consult configuration or invoke filters is isolated from
# host/system config. The new snapshot repository has no filter commands of its
# own, so repository-controlled .gitattributes cannot activate host filters.
prepare_validation_snapshot() {
  local source_dir="$1" snapshot_dir="$2"
  rm -rf "$snapshot_dir"
  mkdir -p "$snapshot_dir"
  copy_snapshot_repo "$source_dir" "$snapshot_dir" true || return 1
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    git -C "$snapshot_dir" init -q
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    git -C "$snapshot_dir" -c core.hooksPath=/dev/null add -A
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    GIT_AUTHOR_NAME=validation GIT_AUTHOR_EMAIL=validation@localhost \
    GIT_COMMITTER_NAME=validation GIT_COMMITTER_EMAIL=validation@localhost \
    git -c core.hooksPath=/dev/null -c commit.gpgSign=false \
      -C "$snapshot_dir" commit --no-verify -qm "credential-free validation snapshot"
}
