#!/usr/bin/env bash
# lib/validate.sh — credential-free disposable validation and CI checks
set -euo pipefail

VALIDATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$VALIDATE_LIB_DIR/colors.sh"
source "$VALIDATE_LIB_DIR/sandbox.sh"

run_tests() {
  local worktree_dir="$1" test_cmd="$2" data_dir="$3" iteration="$4"
  local output_file="$data_dir/iterations/$iteration/test-output.txt"
  local failure_file="$data_dir/iterations/$iteration/test-failures.txt"
  echo -e "${CYAN}  ${PLAY} Running tests in a credential-free disposable sandbox${NC}"
  local rc=0
  local saved_agent_env="${AGENT_ENV_ALLOWLIST-}"
  AGENT_ENV_ALLOWLIST=""
  export AGENT_ENV_ALLOWLIST
  run_sandboxed "${VALIDATION_SANDBOX:-auto}" "$worktree_dir" "$data_dir/sandbox-home" "$data_dir/sandbox-tmp" false \
    bash -c "$test_cmd" >"$output_file" 2>&1 || rc=$?
  AGENT_ENV_ALLOWLIST="$saved_agent_env"
  export AGENT_ENV_ALLOWLIST
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
  AGENT_ENV_ALLOWLIST=""
  export AGENT_ENV_ALLOWLIST
  run_sandboxed "${VALIDATION_SANDBOX:-auto}" "$worktree_dir" "$data_dir/sandbox-home" "$data_dir/sandbox-tmp" false \
    bash -c "$lint_cmd" >"$output_file" 2>&1 || rc=$?
  AGENT_ENV_ALLOWLIST="$saved_agent_env"
  export AGENT_ENV_ALLOWLIST
  if [[ $rc -ne 0 ]]; then
    cp "$output_file" "$failure_file"
    echo -e "${RED}  ${CROSS} Lint failed (exit $rc)${NC}"
    return 1
  fi
  rm -f "$failure_file"
  echo -e "${GREEN}  ${CHECK} Lint passed${NC}"
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
  while (( SECONDS - start < timeout )); do
    local check_runs
    check_runs=$(gh api --paginate --slurp "/repos/$owner/$repo/commits/$sha/check-runs" 2>/dev/null) || {
      echo "ERROR: unable to read CI checks" >&2
      return 1
    }
    local total pending
    total=$(jq '[.[].check_runs[]] | length' <<<"$check_runs")
    pending=$(jq '[.[].check_runs[] | select(.status != "completed")] | length' <<<"$check_runs")
    if [[ "$total" -eq 0 ]]; then sleep 30; continue; fi
    if [[ "$pending" -gt 0 ]]; then sleep 30; continue; fi
    jq '[.[].check_runs[] | {name, conclusion, details_url: .html_url}]' <<<"$check_runs" > "$conclusions_file"
    local failed
    failed=$(jq '[.[] | select(.conclusion != "success" and .conclusion != "neutral" and .conclusion != "skipped")] | length' "$conclusions_file")
    if [[ "$failed" -eq 0 ]]; then
      rm -f "$failures_file"
      return 0
    fi
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
