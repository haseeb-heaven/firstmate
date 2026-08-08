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

agent_provider_env() {
  case "$1" in
    pi) printf '%s' "${PI_PROVIDER_ENV:-ANTHROPIC_API_KEY OPENAI_API_KEY GOOGLE_API_KEY}" ;;
    claude) printf '%s' "${CLAUDE_PROVIDER_ENV:-ANTHROPIC_API_KEY CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEXAI}" ;;
    codex) printf '%s' "${CODEX_PROVIDER_ENV:-OPENAI_API_KEY OPENAI_BASE_URL}" ;;
    opencode) printf '%s' "${OPENCODE_PROVIDER_ENV:-OPENAI_API_KEY ANTHROPIC_API_KEY GOOGLE_GENERATIVE_AI_API_KEY}" ;;
    *) return 1 ;;
  esac
}

write_macos_profile() {
  local profile="$1" worktree="$2" agent_home="$3" temp_dir="$4" allow_network="$5"
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
(deny file-write* (subpath "$worktree/.git"))
(deny file-write* (subpath "$worktree/.git/config"))
(deny file-write* (subpath "$worktree/.git/refs"))
(deny file-write* (subpath "$worktree/.git/hooks"))
PROFILE
  if [[ "$allow_network" == "true" ]]; then
    printf '%s\n' '(allow network-outbound)' >> "$profile"
  fi
}

_run_sandboxed_impl() {
  local mode="$1" worktree="$2" home_dir="$3" temp_dir="$4" allow_network="$5"
  shift 5
  local command=("$@")
  local path_value="${PATH:-/usr/bin:/bin}"
  local -a clean_env=(env -i "PATH=$path_value" "HOME=$home_dir" "PWD=$worktree"
    "GIT_CONFIG_NOSYSTEM=1" "GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_SYSTEM=/dev/null"
    "GIT_TERMINAL_PROMPT=0" "GIT_SSH_COMMAND=ssh -oIdentityAgent=none -oIdentitiesOnly=yes")
  while IFS= read -r -d '' item; do clean_env+=("$item"); done < <(copy_allowed_env "${AGENT_ENV_ALLOWLIST:-}")

  if [[ "${PIPELINE_TEST_MODE:-false}" == "true" ]]; then
    "${clean_env[@]}" "${command[@]}"
    return $?
  fi

  case "$mode" in
    auto)
      if command -v sandbox-exec >/dev/null 2>&1; then mode=macos
      elif command -v bwrap >/dev/null 2>&1; then mode=bwrap
      elif command -v docker >/dev/null 2>&1; then mode=docker
      else mode=none
      fi
      ;;
  esac

  case "$mode" in
    macos)
      local profile="$temp_dir/sandbox.sb"
      write_macos_profile "$profile" "$worktree" "$home_dir" "$temp_dir" "$allow_network"
      sandbox-exec -f "$profile" -- "${clean_env[@]}" "${command[@]}"
      ;;
    bwrap)
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
      local image="${SANDBOX_IMAGE:-alpine:3.20}"
      local network_arg=--network=none
      [[ "$allow_network" == "true" ]] && network_arg="--network=host"
      local -a docker_env=()
      while IFS= read -r -d '' item; do docker_env+=(--env "$item"); done < <(copy_allowed_env "${AGENT_ENV_ALLOWLIST:-}")
      local -a git_mount=()
      [[ -e "$worktree/.git" ]] && git_mount+=(--mount "type=bind,src=$worktree/.git,dst=$worktree/.git,readonly")
      docker run --rm --user "$(id -u):$(id -g)" "$network_arg" "${docker_env[@]}" "${git_mount[@]}" \
        --read-only --tmpfs /tmp --mount "type=bind,src=$worktree,dst=$worktree" \
        --mount "type=bind,src=$home_dir,dst=$home_dir" --mount "type=bind,src=$temp_dir,dst=$temp_dir" \
        -w "$worktree" "$image" sh -c 'exec "$@"' sh "${command[@]}"
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

# Every backend starts in the disposable PR worktree. The subshell prevents a
# validation or agent invocation from changing the orchestrator's directory.
run_sandboxed() {
  local worktree="$2"
  (cd "$worktree" && _run_sandboxed_impl "$@")
}
