#!/usr/bin/env bash
# lib/validate.sh — credential-free disposable validation and CI checks
set -euo pipefail

VALIDATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$VALIDATE_LIB_DIR/colors.sh"
source "$VALIDATE_LIB_DIR/sandbox.sh"

cleanup_validation_stage() {
  rm -rf "$@"
}

bounded_output_drain() {
  local fifo="$1" output_file="$2" limit="$3"
  local size remainder truncated=false
  : > "$output_file"
  exec 7<"$fifo"
  head -c "$limit" <&7 > "$output_file" 2>/dev/null || true
  remainder=$(wc -c <&7 | tr -d ' ')
  exec 7<&-
  [[ "$remainder" =~ ^[0-9]+$ ]] || remainder=0
  [[ "$remainder" -eq 0 ]] || truncated=true
  size=$(wc -c < "$output_file" | tr -d ' ')
  [[ "$size" =~ ^[0-9]+$ ]] || size=0
  if [[ "$size" -gt "$limit" ]]; then
    echo "ERROR: bounded output drain exceeded configured limit" >&2
    return 1
  fi
  if [[ "$truncated" == true ]]; then
    printf '\n[output truncated at %s bytes]\n' "$limit" >> "$output_file"
  fi
}

run_validation_captured() {
  local limit="$1" output_file="$2"
  shift 2
  [[ "$limit" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: VALIDATION_OUTPUT_LIMIT must be a positive integer" >&2
    return 2
  }
  local fifo="${output_file}.pipe.$$" drain_pid rc=0 drain_stuck=false
  rm -f "$fifo"
  mkfifo "$fifo"
  bounded_output_drain "$fifo" "$output_file" "$limit" &
  drain_pid=$!
  "$@" > "$fifo" 2>&1 || rc=$?

  local _
  for _ in 1 2 3 4 5; do
    kill -0 "$drain_pid" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$drain_pid" 2>/dev/null; then
    drain_stuck=true
    kill -TERM "$drain_pid" 2>/dev/null || true
    sleep 1
    kill -KILL "$drain_pid" 2>/dev/null || true
  fi
  wait "$drain_pid" 2>/dev/null || true
  rm -f "$fifo"
  if [[ "$drain_stuck" == true ]]; then
    echo "ERROR: validation output drain remained open after process-group teardown" >&2
    [[ "$rc" -ne 0 ]] && return "$rc"
    return 124
  fi
  return "$rc"
}

run_tests() {
  local worktree_dir="$1" test_cmd="$2" data_dir="$3" iteration="$4"
  local output_file="$data_dir/iterations/$iteration/test-output.txt"
  local failure_file="$data_dir/iterations/$iteration/test-failures.txt"
  echo -e "${CYAN}  ${PLAY} Running tests in a credential-free disposable sandbox${NC}"
  local rc=0
  local saved_agent_env="${AGENT_ENV_ALLOWLIST-}"
  local snapshot_dir="$data_dir/iterations/$iteration/validation-worktree-tests"
  local sandbox_home="$data_dir/iterations/$iteration/sandbox-home-tests"
  local sandbox_tmp="$data_dir/iterations/$iteration/sandbox-tmp-tests"
  mkdir -p "$sandbox_home" "$sandbox_tmp"
  if ! prepare_validation_snapshot "$worktree_dir" "$snapshot_dir" 2>"$output_file"; then
    printf 'Tests could not prepare a disposable snapshot.\n' >> "$output_file"
    cp "$output_file" "$failure_file"
    cleanup_validation_stage "$snapshot_dir" "$sandbox_home" "$sandbox_tmp"
    return 1
  fi
  AGENT_ENV_ALLOWLIST=""
  export AGENT_ENV_ALLOWLIST
  run_validation_captured "${VALIDATION_OUTPUT_LIMIT:-1048576}" "$output_file" \
    run_validation_command "${VALIDATION_TIMEOUT:-3600}" \
      run_sandboxed "${VALIDATION_SANDBOX:-auto}" "$snapshot_dir" "$sandbox_home" "$sandbox_tmp" \
      false bash -c "$test_cmd" || rc=$?
  AGENT_ENV_ALLOWLIST="$saved_agent_env"
  export AGENT_ENV_ALLOWLIST
  cleanup_validation_stage "$snapshot_dir" "$sandbox_home" "$sandbox_tmp"
  if [[ $rc -ne 0 ]]; then
    cp "$output_file" "$failure_file"
    echo -e "${RED}  ${CROSS} Tests failed (exit $rc)${NC}"
    return 1
  fi
  rm -f "$failure_file"
  echo -e "${GREEN}  ${CHECK} Tests passed${NC}"
}

run_lint() {
  local worktree_dir="$1" lint_cmd="$2" data_dir="$3" iteration="$4"
  [[ -n "$lint_cmd" ]] || { echo -e "${DIM}  ${INFO} Lint command not set — skipping${NC}"; return 0; }
  local output_file="$data_dir/iterations/$iteration/lint-output.txt"
  local failure_file="$data_dir/iterations/$iteration/lint-failures.txt"
  echo -e "${CYAN}  ${PLAY} Running lint in a credential-free disposable sandbox${NC}"
  local rc=0
  local saved_agent_env="${AGENT_ENV_ALLOWLIST-}"
  local snapshot_dir="$data_dir/iterations/$iteration/validation-worktree-lint"
  local sandbox_home="$data_dir/iterations/$iteration/sandbox-home-lint"
  local sandbox_tmp="$data_dir/iterations/$iteration/sandbox-tmp-lint"
  mkdir -p "$sandbox_home" "$sandbox_tmp"
  if ! prepare_validation_snapshot "$worktree_dir" "$snapshot_dir" 2>"$output_file"; then
    printf 'Lint could not prepare a disposable snapshot.\n' >> "$output_file"
    cp "$output_file" "$failure_file"
    cleanup_validation_stage "$snapshot_dir" "$sandbox_home" "$sandbox_tmp"
    return 1
  fi
  AGENT_ENV_ALLOWLIST=""
  export AGENT_ENV_ALLOWLIST
  run_validation_captured "${VALIDATION_OUTPUT_LIMIT:-1048576}" "$output_file" \
    run_validation_command "${VALIDATION_TIMEOUT:-3600}" \
      run_sandboxed "${VALIDATION_SANDBOX:-auto}" "$snapshot_dir" "$sandbox_home" "$sandbox_tmp" \
      false bash -c "$lint_cmd" || rc=$?
  AGENT_ENV_ALLOWLIST="$saved_agent_env"
  export AGENT_ENV_ALLOWLIST
  cleanup_validation_stage "$snapshot_dir" "$sandbox_home" "$sandbox_tmp"
  if [[ $rc -ne 0 ]]; then
    cp "$output_file" "$failure_file"
    echo -e "${RED}  ${CROSS} Lint failed (exit $rc)${NC}"
    return 1
  fi
  rm -f "$failure_file"
  echo -e "${GREEN}  ${CHECK} Lint passed${NC}"
}

run_validation_command() (
  local seconds="$1"; shift
  local child watcher rc pgid shell_pgid
  [[ "$seconds" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: validation timeout must be a positive integer" >&2
    return 2
  }

  set -m
  "$@" &
  child=$!
  set +m

  # For a single job started with monitor mode, Bash uses the job leader PID as
  # its process-group ID. Capture it from $! immediately; the leader can exit
  # before ps observes it while descendants still keep the group/FIFO alive.
  pgid="$child"
  shell_pgid=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d '[:space:]')
  if [[ ! "$pgid" =~ ^[1-9][0-9]*$ || "$pgid" == "$shell_pgid" ]]; then
    echo "ERROR: unable to isolate validation process group safely" >&2
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    return 125
  fi

  terminate_validation_group() {
    local signal="$1"
    kill -"$signal" -- "-$pgid" 2>/dev/null || true
  }

  (
    trap 'exit 0' TERM INT
    sleep "$seconds"
    terminate_validation_group TERM
    sleep 1
    terminate_validation_group KILL
  ) &
  watcher=$!

  if wait "$child"; then rc=0; else rc=$?; fi
  kill -TERM "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true

  if kill -0 -- "-$pgid" 2>/dev/null; then
    terminate_validation_group TERM
    sleep 1
    if kill -0 -- "-$pgid" 2>/dev/null; then
      terminate_validation_group KILL
    fi
  fi
  return "$rc"
)

snapshot_path_is_forbidden() {
  local path="$1" lower_path basename_lower
  [[ "$path" != /* && "$path" != .git && "$path" != .git/* ]] || return 0
  lower_path=$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')
  basename_lower="${lower_path##*/}"
  case "$basename_lower" in
    .env|.env.*|*.key|*.pem|*.p12|*.pfx)
      case "$basename_lower" in
        .env.example|.env.*.example) ;;
        *) return 0 ;;
      esac
      ;;
  esac
  case "$lower_path" in
    *credentials*|*credential*)
      case "$lower_path" in
        docs/*.md) ;;
        *) return 0 ;;
      esac
      ;;
  esac
  return 1
}

copy_snapshot_repo() {
  local source_dir="$1" snapshot_dir="$2" include_untracked="$3"
  local path mode parent target submodule_root submodule_dir
  local -a ls_args=(--cached)
  if [[ "$include_untracked" == true ]]; then
    ls_args+=(--others --exclude-standard)
  fi
  while IFS= read -r -d '' path; do
    if snapshot_path_is_forbidden "$path"; then
      echo "ERROR: secret-like or control path refused in validation snapshot: $path" >&2
      return 1
    fi
    mode=$(git -C "$source_dir" ls-files --stage -- "$path" | awk 'NR == 1 { print $1 }')
    if [[ "$mode" == 160000 ]]; then
      [[ -d "$source_dir/$path" ]] || {
        echo "ERROR: checked-out submodule missing from validation snapshot: $path" >&2
        return 1
      }
      submodule_dir=$(cd "$source_dir/$path" && pwd -P) || return 1
      submodule_root=$(git -C "$source_dir/$path" rev-parse --show-toplevel 2>/dev/null || true)
      if [[ -z "$submodule_root" ]]; then
        echo "ERROR: submodule is not initialized in validation source: $path" >&2
        return 1
      fi
      submodule_root=$(cd "$submodule_root" 2>/dev/null && pwd -P) || submodule_root=""
      if [[ "$submodule_root" != "$submodule_dir" ]]; then
        echo "ERROR: submodule is not initialized in validation source: $path" >&2
        return 1
      fi
      parent="$snapshot_dir/$path"
      mkdir -p "$parent"
      if ! copy_snapshot_repo "$source_dir/$path" "$parent" false; then
        echo "ERROR: unsafe content refused from submodule validation snapshot: $path" >&2
        return 1
      fi
      continue
    fi
    if [[ -L "$source_dir/$path" ]]; then
      target=$(readlink "$source_dir/$path")
      [[ "$target" != /* && "$target" != ../* && "$target" != */../* ]] || {
        echo "ERROR: unsafe symlink in validation snapshot: $path" >&2
        return 1
      }
      parent="$snapshot_dir/$(dirname "$path")"
      mkdir -p "$parent"
      ln -s "$target" "$snapshot_dir/$path"
      continue
    fi
    [[ -e "$source_dir/$path" || -L "$source_dir/$path" ]] || continue
    [[ -f "$source_dir/$path" ]] || {
      echo "ERROR: unsupported file type in validation snapshot: $path" >&2
      return 1
    }
    parent="$snapshot_dir/$(dirname "$path")"
    mkdir -p "$parent"
    cp -p "$source_dir/$path" "$snapshot_dir/$path"
  done < <(git -C "$source_dir" ls-files "${ls_args[@]}" -z)
}

prepare_validation_snapshot() {
  local source_dir="$1" snapshot_dir="$2"
  rm -rf "$snapshot_dir"
  mkdir -p "$snapshot_dir"
  copy_snapshot_repo "$source_dir" "$snapshot_dir" true || return 1
  git -C "$snapshot_dir" init -q
  git -C "$snapshot_dir" add -A
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    GIT_AUTHOR_NAME=validation GIT_AUTHOR_EMAIL=validation@localhost \
    GIT_COMMITTER_NAME=validation GIT_COMMITTER_EMAIL=validation@localhost \
    git -c core.hooksPath=/dev/null -c commit.gpgSign=false \
      -C "$snapshot_dir" commit --no-verify -qm "credential-free validation snapshot"
}

push_changes() {
  local remote="$1" worktree_dir="$2" remote_branch="$3" force="$4"
  local expected_sha="${5:-}" current_sha
  current_sha=$(git -C "$worktree_dir" rev-parse HEAD)
  [[ -z "$expected_sha" || "$current_sha" == "$expected_sha" ]] || {
    echo "ERROR: local HEAD changed unexpectedly before push" >&2
    return 1
  }
  git -C "$worktree_dir" diff --quiet || { echo "ERROR: unstaged changes before push" >&2; return 1; }
  git -C "$worktree_dir" diff --cached --quiet || { echo "ERROR: staged changes before push" >&2; return 1; }
  local -a args=(push "$remote" "HEAD:$remote_branch")
  [[ "$force" == true ]] && args+=(--force-with-lease)
  if ! git -C "$worktree_dir" "${args[@]}"; then
    echo "ERROR: git push failed" >&2
    return 1
  fi
  echo -e "${GREEN}  ${CHECK} Pushed${NC}"
}

wait_for_ci() {
  local owner="$1" repo="$2" sha="$3" timeout="$4" data_dir="$5" iteration="$6"
  local start=$SECONDS
  local conclusions_file="$data_dir/iterations/$iteration/ci-conclusions.json"
  local failures_file="$data_dir/iterations/$iteration/ci-failures.md"
  local stability_polls="${CI_STABILITY_POLLS:-2}" stable_polls=0 stable_fingerprint="" fingerprint
  [[ "$stability_polls" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: CI_STABILITY_POLLS must be a positive integer" >&2
    return 2
  }
  while (( SECONDS - start < timeout )); do
    local check_runs statuses
    check_runs=$(gh api --paginate --slurp "/repos/$owner/$repo/commits/$sha/check-runs" 2>/dev/null) || {
      echo "ERROR: unable to read CI checks" >&2
      return 1
    }
    statuses=$(gh api --paginate --slurp "/repos/$owner/$repo/commits/$sha/statuses" 2>/dev/null) || {
      echo "ERROR: unable to read commit statuses" >&2
      return 1
    }
    local total pending
    total=$(jq '[.[].check_runs[]] | length' <<<"$check_runs")
    pending=$(jq '[.[].check_runs[] | select(.status != "completed")] | length' <<<"$check_runs")
    local latest_statuses status_total status_pending
    latest_statuses=$(jq '[.[][]] | sort_by(.context, .created_at) | group_by(.context) | map(last)' <<<"$statuses")
    status_total=$(jq 'length' <<<"$latest_statuses")
    status_pending=$(jq '[.[] | select(.state == "pending")] | length' <<<"$latest_statuses")
    total=$((total + status_total)); pending=$((pending + status_pending))
    if [[ "$total" -eq 0 ]]; then
      stable_polls=0; stable_fingerprint=""
      sleep "${POLL_INTERVAL:-5}"
      continue
    fi
    if [[ "$pending" -gt 0 ]]; then
      stable_polls=0; stable_fingerprint=""
      sleep "${POLL_INTERVAL:-30}"
      continue
    fi
    jq '[.[].check_runs[] | {name, conclusion, details_url: .html_url}]' <<<"$check_runs" > "$conclusions_file"
    jq --argjson latest "$latest_statuses" '[ $latest[] | {name: .context, conclusion: (if .state == "success" then "success" else .state end), details_url: .target_url} ]' <<<"{}" > "$conclusions_file.statuses"
    jq -s '.[0] + .[1]' "$conclusions_file" "$conclusions_file.statuses" > "$conclusions_file.tmp"
    mv "$conclusions_file.tmp" "$conclusions_file"
    rm -f "$conclusions_file.statuses"
    local failed successful
    failed=$(jq '[.[] | select(.conclusion != "success" and .conclusion != "neutral" and .conclusion != "skipped")] | length' "$conclusions_file")
    successful=$(jq '[.[] | select(.conclusion == "success")] | length' "$conclusions_file")
    if [[ "$failed" -eq 0 && "$successful" -gt 0 ]]; then
      fingerprint=$(jq -r 'sort_by(.name) | map("\(.name)=\(.conclusion)") | join("\n")' "$conclusions_file")
      if [[ "$fingerprint" == "$stable_fingerprint" ]]; then
        stable_polls=$((stable_polls + 1))
      else
        stable_fingerprint="$fingerprint"
        stable_polls=1
      fi
      if [[ "$stable_polls" -ge "$stability_polls" ]]; then
        rm -f "$failures_file"
        return 0
      fi
      sleep "${POLL_INTERVAL:-30}"
      continue
    fi
    stable_polls=0; stable_fingerprint=""
    {
      echo "## CI Failures"
      jq -r '.[] | select(.conclusion != "success" and .conclusion != "neutral" and .conclusion != "skipped") | "- **\(.name)**: \(.conclusion) (\(.details_url))"' "$conclusions_file"
    } > "$failures_file"
    return 1
  done
  echo "ERROR: CI timeout after ${timeout}s" >&2
  printf '## CI Failures\n\n- CI wait timed out after %ss\n' "$timeout" > "$failures_file"
  return 1
}

get_current_sha() { git -C "$WORKTREE_DIR" rev-parse HEAD; }
