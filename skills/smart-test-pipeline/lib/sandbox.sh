#!/usr/bin/env bash
# lib/sandbox.sh — disposable boundaries for agents and validation commands
set -euo pipefail

SANDBOX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

copy_allowed_env() {
  local names="$1" name value
  for name in $names; do
    if [[ "$name" =~ ^[A-Z][A-Z0-9_]*$ && -n "${!name+x}" ]]; then
      value="${!name}"
      printf '%s=%s\0' "$name" "$value"
    fi
  done
}

# Networked fix agents must authenticate through an operator-owned broker that
# does not expose reusable provider credentials in the agent environment. The
# pipeline deliberately refuses raw API-key forwarding because every agent
# child process would inherit those variables.
agent_provider_env() {
  case "$1" in
    pi|claude|codex|opencode) ;;
    *) return 1 ;;
  esac
  local broker="${AGENT_CREDENTIAL_BROKER:-}"
  [[ "$broker" == /* && -x "$broker" ]] || return 1
  printf '%s' 'AGENT_CREDENTIAL_BROKER'
}

agent_provider_hosts() {
  case "$1" in
    pi) printf '%s' "${PI_PROVIDER_HOSTS:-api.anthropic.com}" ;;
    claude) printf '%s' "${CLAUDE_PROVIDER_HOSTS:-api.anthropic.com}" ;;
    codex) printf '%s' "${CODEX_PROVIDER_HOSTS:-api.openai.com}" ;;
    opencode) printf '%s' "${OPENCODE_PROVIDER_HOSTS:-api.openai.com}" ;;
    *) return 1 ;;
  esac
}

sandbox_exec_works() {
  command -v sandbox-exec >/dev/null 2>&1 || return 1
  sandbox-exec -p '(version 1) (deny default) (allow process*)' true >/dev/null 2>&1
}

resolve_runtime_path() {
  local path="$1" target dir hops=0
  [[ -n "$path" ]] || return 0
  while [[ -L "$path" ]]; do
    hops=$((hops + 1))
    (( hops <= 40 )) || { echo "ERROR: executable symlink chain is too deep: $1" >&2; return 1; }
    target=$(readlink "$path") || return 1
    if [[ "$target" == /* ]]; then
      path="$target"
    else
      dir=$(cd "$(dirname "$path")" && pwd -P)
      path="$dir/$target"
    fi
  done
  if [[ -e "$path" ]]; then
    dir=$(cd "$(dirname "$path")" && pwd -P)
    printf '%s/%s\n' "$dir" "$(basename "$path")"
  else
    printf '%s\n' "$path"
  fi
}

agent_runtime_roots() {
  local path="$1" prefix rest scope package cellar_base formula version
  [[ -n "$path" ]] || return 0

  case "$path" in
    */node_modules/@*/*/*)
      prefix="${path%%/node_modules/*}/node_modules"
      rest="${path#*/node_modules/}"
      scope="${rest%%/*}"
      rest="${rest#*/}"
      package="${rest%%/*}"
      [[ "$scope" == @* && -n "$package" ]] && printf '%s/%s/%s\n' "$prefix" "$scope" "$package"
      ;;
    */node_modules/*/*)
      prefix="${path%%/node_modules/*}/node_modules"
      rest="${path#*/node_modules/}"
      package="${rest%%/*}"
      [[ -n "$package" ]] && printf '%s/%s\n' "$prefix" "$package"
      ;;
  esac

  case "$path" in
    /opt/homebrew/Cellar/*/*/*)
      cellar_base="/opt/homebrew/Cellar"
      rest="${path#$cellar_base/}"
      formula="${rest%%/*}"
      rest="${rest#*/}"
      version="${rest%%/*}"
      [[ -n "$formula" && -n "$version" ]] && printf '%s/%s/%s\n' "$cellar_base" "$formula" "$version"
      ;;
    /usr/local/Cellar/*/*/*)
      cellar_base="/usr/local/Cellar"
      rest="${path#$cellar_base/}"
      formula="${rest%%/*}"
      rest="${rest#*/}"
      version="${rest%%/*}"
      [[ -n "$formula" && -n "$version" ]] && printf '%s/%s/%s\n' "$cellar_base" "$formula" "$version"
      ;;
  esac
}

runtime_interpreter_path() {
  local executable="$1" resolved first_line shebang interpreter command_name
  resolved=$(resolve_runtime_path "$executable") || return 1
  [[ -f "$resolved" ]] || return 0
  IFS= read -r first_line < "$resolved" || true
  [[ "$first_line" == '#!'* ]] || return 0
  shebang="${first_line#\#!}"
  set -- $shebang
  interpreter="${1:-}"
  [[ -n "$interpreter" ]] || return 0
  if [[ "$(basename "$interpreter")" == env ]]; then
    shift
    if [[ "${1:-}" == -S ]]; then shift; fi
    command_name="${1:-}"
    [[ -n "$command_name" ]] || return 0
    interpreter=$(command -v "$command_name" 2>/dev/null || true)
  fi
  [[ -n "$interpreter" ]] || return 0
  resolve_runtime_path "$interpreter"
}

worktree_git_metadata_paths() {
  local worktree="$1" git_dir common_dir
  git_dir=$(git -C "$worktree" rev-parse --absolute-git-dir 2>/dev/null || true)
  common_dir=$(git -C "$worktree" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  if [[ -z "$common_dir" ]]; then
    common_dir=$(git -C "$worktree" rev-parse --git-common-dir 2>/dev/null || true)
    if [[ -n "$common_dir" && "$common_dir" != /* ]]; then
      common_dir=$(cd "$worktree/$common_dir" 2>/dev/null && pwd -P || true)
    fi
  fi
  [[ -n "$git_dir" && -d "$git_dir" ]] && printf '%s\n' "$git_dir"
  [[ -n "$common_dir" && -d "$common_dir" && "$common_dir" != "$git_dir" ]] && printf '%s\n' "$common_dir"
}

append_macos_executable_permissions() {
  local profile="$1" executable="$2" resolved="" interpreter="" runtime_root
  [[ -n "$executable" ]] || return 0
  [[ "$executable" == /* && -x "$executable" ]] || {
    echo "ERROR: sandbox executable must be an absolute executable path: $executable" >&2
    return 1
  }
  resolved=$(resolve_runtime_path "$executable") || return 1
  interpreter=$(runtime_interpreter_path "$executable") || return 1

  printf '(allow file-read* (literal "%s"))\n' "$executable" >> "$profile"
  if [[ -n "$resolved" && "$resolved" != "$executable" ]]; then
    printf '(allow file-read* (literal "%s"))\n' "$resolved" >> "$profile"
  fi
  if [[ -n "$interpreter" ]]; then
    printf '(allow file-read* (literal "%s"))\n' "$interpreter" >> "$profile"
  fi
  while IFS= read -r runtime_root; do
    [[ -n "$runtime_root" ]] || continue
    printf '(allow file-read* (subpath "%s"))\n' "$runtime_root" >> "$profile"
  done < <(
    {
      agent_runtime_roots "$resolved"
      agent_runtime_roots "$interpreter"
    } | awk '!seen[$0]++'
  )
}

write_macos_profile() {
  local profile="$1" worktree="$2" agent_home="$3" temp_dir="$4" allow_network="$5" provider_hosts="$6" executable="${7:-}"
  cat > "$profile" <<PROFILE
(version 1)
(deny default)
(allow process*)
(allow file-read* (subpath "/usr") (subpath "/bin") (subpath "/sbin") (subpath "/System") (subpath "/Library"))
(allow file-read* (subpath "$worktree"))
(allow file-read* (subpath "$agent_home"))
(allow file-read* (subpath "$temp_dir"))
(allow file-write* (subpath "$worktree"))
(allow file-write* (subpath "$agent_home"))
(allow file-write* (subpath "$temp_dir"))
(deny process-exec (subpath "$worktree"))
(deny file-write* (subpath "$worktree/.git"))
PROFILE

  append_macos_executable_permissions "$profile" "$executable" || return 1
  if [[ "$allow_network" == true && -n "${AGENT_TARGET_EXECUTABLE:-}" && "${AGENT_TARGET_EXECUTABLE}" != "$executable" ]]; then
    append_macos_executable_permissions "$profile" "$AGENT_TARGET_EXECUTABLE" || return 1
  fi

  local git_metadata
  while IFS= read -r git_metadata; do
    [[ -n "$git_metadata" ]] || continue
    printf '(allow file-read* (subpath "%s"))\n' "$git_metadata" >> "$profile"
    printf '(deny file-write* (subpath "%s"))\n' "$git_metadata" >> "$profile"
  done < <(worktree_git_metadata_paths "$worktree")

  if [[ "$allow_network" == "true" ]]; then
    local host
    for host in $provider_hosts; do
      [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "ERROR: invalid provider host: $host" >&2; return 1; }
      printf '(allow network-outbound (remote tcp "%s:443"))\n' "$host" >> "$profile"
    done
  fi
}

_run_sandboxed_impl() {
  local mode="$1" worktree="$2" home_dir="$3" temp_dir="$4" allow_network="$5"
  shift 5
  local command=("$@")
  local provider_hosts="${AGENT_PROVIDER_HOSTS:-}"
  local path_value="${PATH:-/usr/bin:/bin}"
  local -a clean_env=(env -i "PATH=$path_value" "HOME=$home_dir" "PWD=$worktree" "TMPDIR=$temp_dir"
    "GIT_CONFIG_NOSYSTEM=1" "GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_SYSTEM=/dev/null"
    "GIT_TERMINAL_PROMPT=0" "GIT_SSH_COMMAND=ssh -oIdentityAgent=none -oIdentitiesOnly=yes")
  while IFS= read -r -d '' item; do clean_env+=("$item"); done < <(copy_allowed_env "${AGENT_ENV_ALLOWLIST:-}")

  case "$mode" in
    auto)
      if [[ "$allow_network" == "true" ]]; then
        if sandbox_exec_works; then
          mode=macos
        else
          echo "ERROR: no provider-aware network sandbox is available for the agent" >&2
          mode=none
        fi
      elif sandbox_exec_works; then
        mode=macos
      elif command -v bwrap >/dev/null 2>&1; then
        mode=bwrap
      elif command -v docker >/dev/null 2>&1; then
        mode=docker
      else
        mode=none
      fi
      ;;
  esac

  case "$mode" in
    macos)
      local profile="$temp_dir/sandbox.sb" profile_executable=""
      if [[ "$allow_network" == true ]]; then
        profile_executable="${AGENT_BROKER_EXECUTABLE:-${AGENT_EXECUTABLE:-}}"
      fi
      write_macos_profile "$profile" "$worktree" "$home_dir" "$temp_dir" "$allow_network" "$provider_hosts" "$profile_executable"
      sandbox-exec -f "$profile" -- "${clean_env[@]}" "${command[@]}"
      ;;
    bwrap)
      [[ "$allow_network" != "true" ]] || { echo "ERROR: bwrap cannot enforce provider-only egress; refusing networked agent" >&2; return 125; }
      local -a args=(--die-with-parent --new-session --unshare-pid --unshare-ipc --unshare-uts
        --ro-bind /usr /usr --ro-bind /bin /bin --ro-bind /sbin /sbin
        --ro-bind /lib /lib --proc /proc --dev /dev --tmpfs /tmp
        --bind "$worktree" "$worktree" --bind "$home_dir" "$home_dir" --bind "$temp_dir" "$temp_dir"
        --chdir "$worktree")
      [[ -e "$worktree/.git" ]] && args+=(--ro-bind "$worktree/.git" "$worktree/.git")
      [[ "$allow_network" == "true" ]] || args+=(--unshare-net)
      [[ -d /lib64 ]] && args+=(--ro-bind /lib64 /lib64)
      [[ -f /etc/resolv.conf ]] && args+=(--ro-bind /etc/resolv.conf /etc/resolv.conf)
      "${clean_env[@]}" bwrap "${args[@]}" -- "${command[@]}"
      ;;
    docker)
      local image="${SANDBOX_IMAGE:-}"
      [[ -n "$image" ]] || { echo "ERROR: SANDBOX_IMAGE must name a compatible image containing bash and the requested command" >&2; return 125; }
      local network_arg=--network=none
      [[ "$allow_network" != "true" ]] || { echo "ERROR: Docker cannot enforce provider-only egress; refusing networked agent" >&2; return 125; }
      local -a docker_env=(--env "HOME=$home_dir" --env "TMPDIR=$temp_dir")
      while IFS= read -r -d '' item; do docker_env+=(--env "$item"); done < <(copy_allowed_env "${AGENT_ENV_ALLOWLIST:-}")
      local -a git_mount=()
      [[ -e "$worktree/.git" ]] && git_mount+=(--mount "type=bind,src=$worktree/.git,dst=$worktree/.git,readonly")
      docker run --rm --user "$(id -u):$(id -g)" "$network_arg" "${docker_env[@]}" \
        --read-only --tmpfs /tmp --mount "type=bind,src=$worktree,dst=$worktree" "${git_mount[@]}" \
        --mount "type=bind,src=$home_dir,dst=$home_dir" --mount "type=bind,src=$temp_dir,dst=$temp_dir" \
        -w "$worktree" "$image" bash -c 'exec "$@"' bash "${command[@]}"
      ;;
    none)
      echo "ERROR: no disposable sandbox backend is available" >&2
      return 125
      ;;
    *)
      echo "ERROR: unsupported sandbox mode: $mode" >&2
      return 125
      ;;
  esac
}

run_sandboxed() {
  local worktree="$2"
  (cd "$worktree" && _run_sandboxed_impl "$@")
}
