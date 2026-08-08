#!/usr/bin/env bash
# run.sh — guarded PR review → fix → validate → repeat loop
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/report.sh"

# Operator configuration is loaded before built-in defaults. CLI flags are
# parsed afterwards and therefore always take precedence over both.
CONFIG_FILE="${SMART_TEST_CONFIG:-$SCRIPT_DIR/config.sh}"
if [[ -f "$CONFIG_FILE" ]]; then
  # This file is operator-owned and must never come from the PR worktree.
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

: "${MAX_ITERATIONS:=10}"
: "${FIX_AGENT:=pi}"
: "${WAIT_CI:=true}"
: "${DRY_RUN:=false}"
: "${FORCE_PUSH:=false}"
: "${CI_TIMEOUT:=3600}"
: "${REVIEW_BOTS:=coderabbit greptile}"
: "${TEST_CMD:=python -m pytest --tb=short -q}"
: "${LINT_CMD:=}"
: "${PRE_REVIEW_WAIT:=30}"
: "${REVIEW_TIMEOUT:=600}"
: "${POLL_INTERVAL:=30}"
: "${CACHE_ROOT:=${HOME:-/tmp}/.greploop/cache}"
: "${DATA_ROOT:=${TMPDIR:-/tmp}/greploop-data}"
: "${VALIDATION_SANDBOX:=auto}"
: "${AGENT_SANDBOX:=auto}"
: "${ALLOWED_SUPPORT_GLOBS:=tests/** test/** **/test_*.py **/*_test.*}"

PR_URL=""
EXTRA_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-iterations) MAX_ITERATIONS="$2"; shift 2 ;;
    --fix-agent) FIX_AGENT="$2"; shift 2 ;;
    --wait-ci) WAIT_CI="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --force) FORCE_PUSH=true; shift ;;
    --) shift; EXTRA_ARGS+=("$@"); break ;;
    -*) echo "ERROR: unknown flag $1" >&2; exit 2 ;;
    *)
      if [[ -z "$PR_URL" ]]; then PR_URL="$1"; else EXTRA_ARGS+=("$1"); fi
      shift
      ;;
  esac
done

if [[ -z "$PR_URL" ]]; then
  echo "Usage: $0 <PR_URL> [--max-iterations N] [--fix-agent AGENT] [--wait-ci true|false] [--dry-run]" >&2
  exit 2
fi

if [[ ! "$MAX_ITERATIONS" =~ ^[1-9][0-9]*$ || ! "$CI_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: iteration and timeout values must be positive integers" >&2
  exit 2
fi

if [[ "$PR_URL" =~ ^https://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)$ ]]; then
  OWNER="${BASH_REMATCH[1]}"
  REPO="${BASH_REMATCH[2]}"
  PR_NUM="${BASH_REMATCH[3]}"
else
  echo "ERROR: not a valid GitHub PR URL: $PR_URL" >&2
  exit 2
fi

REPO_FULL="$OWNER/$REPO"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM}"
REPO_ROOT="$CACHE_ROOT/$OWNER/$REPO"
REPOSITORY_DIR="$REPO_ROOT/repository"
WORKTREE_DIR="$REPO_ROOT/worktrees/$RUN_ID"
RUN_ROOT="$DATA_ROOT/$OWNER/$REPO/pr-$PR_NUM/$RUN_ID"
LOCK_DIR="$REPO_ROOT/locks/pr-$PR_NUM.lock"
DATA_DIR="$RUN_ROOT"

cleanup() {
  local rc=$?
  if [[ -n "${WORKTREE_DIR:-}" && -d "$WORKTREE_DIR" && -d "${REPOSITORY_DIR:-}/.git" ]]; then
    git -C "$REPOSITORY_DIR" worktree remove --force "$WORKTREE_DIR" >/dev/null 2>&1 || true
  fi
  if [[ -n "${LOCK_DIR:-}" && -d "$LOCK_DIR" ]]; then
    rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
  fi
  if [[ "${DRY_RUN:-false}" == true ]]; then
    :
  elif [[ -n "${DATA_DIR:-}" && -f "$DATA_DIR/report.md" ]]; then
    :
  elif [[ -n "${DATA_DIR:-}" && -d "$DATA_DIR" ]]; then
    write_final_report "$DATA_DIR" "${ITERATION:-0}" "${PIPELINE_RESULT:-failed}" 2>/dev/null || true
  fi
  exit "$rc"
}
trap cleanup EXIT

mkdir -p "$DATA_DIR/iterations"

echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}  ${YELLOW}Smart Test Pipeline — Guarded PR Review${NC}       ${CYAN}║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  PR:       ${BOLD}$PR_URL${NC}"
echo -e "  Agent:    ${BOLD}$FIX_AGENT${NC}"
echo -e "  Max iter: ${BOLD}$MAX_ITERATIONS${NC}"
echo -e "  Wait CI:  ${BOLD}$WAIT_CI${NC}"
echo -e "  Dry run:  ${BOLD}$DRY_RUN${NC}"

if [[ "$DRY_RUN" == "true" ]]; then
  PIPELINE_RESULT="dry_run"
  echo -e "  ${YELLOW}${INFO} Dry run — no authentication, PR mutation, checkout, agent, commit, push, or CI activity${NC}"
  exit 0
fi

if ! gh auth status >/dev/null 2>&1; then
  echo -e "${RED}ERROR: GitHub CLI is not authenticated${NC}" >&2
  exit 1
fi

mkdir -p "$REPO_ROOT/locks" "$RUN_ROOT"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo -e "${RED}ERROR: another pipeline is already operating on $REPO_FULL PR #$PR_NUM${NC}" >&2
  exit 1
fi

PR_METADATA="$(gh pr view "$PR_NUM" --repo "$REPO_FULL" --json state,headRefName,headRepositoryOwner,headRepository,baseRefName,baseRefOid,headRefOid 2>/dev/null)" || {
  echo -e "${RED}ERROR: unable to read PR metadata${NC}" >&2
  exit 1
}
PR_STATE="$(jq -r '.state // empty' <<<"$PR_METADATA")"
if [[ "$PR_STATE" != "OPEN" ]]; then
  echo -e "${RED}ERROR: refusing mutation because PR #$PR_NUM is $PR_STATE, not OPEN${NC}" >&2
  exit 1
fi

PR_BRANCH="$(jq -r '.headRefName // empty' <<<"$PR_METADATA")"
HEAD_OWNER="$(jq -r '.headRepositoryOwner.login // empty' <<<"$PR_METADATA")"
HEAD_REPO="$(jq -r '.headRepository.name // empty' <<<"$PR_METADATA")"
BASE_BRANCH="$(jq -r '.baseRefName // empty' <<<"$PR_METADATA")"
BASE_SHA="$(jq -r '.baseRefOid // empty' <<<"$PR_METADATA")"
HEAD_SHA="$(jq -r '.headRefOid // empty' <<<"$PR_METADATA")"
if [[ -z "$PR_BRANCH" || -z "$HEAD_OWNER" || -z "$HEAD_REPO" || -z "$BASE_BRANCH" || -z "$BASE_SHA" || -z "$HEAD_SHA" ]]; then
  echo -e "${RED}ERROR: incomplete PR metadata; refusing mutation${NC}" >&2
  exit 1
fi

mkdir -p "$REPOSITORY_DIR" "$REPO_ROOT/worktrees"
if [[ ! -d "$REPOSITORY_DIR/.git" ]]; then
  rmdir "$REPOSITORY_DIR" 2>/dev/null || true
  git clone "https://github.com/$REPO_FULL.git" "$REPOSITORY_DIR" >/dev/null
fi

git -C "$REPOSITORY_DIR" fetch --no-tags origin "$BASE_BRANCH" >/dev/null
if [[ "$HEAD_OWNER/$HEAD_REPO" != "$REPO_FULL" ]]; then
  if git -C "$REPOSITORY_DIR" remote get-url pr-head >/dev/null 2>&1; then
    git -C "$REPOSITORY_DIR" remote set-url pr-head "https://github.com/$HEAD_OWNER/$HEAD_REPO.git"
  else
    git -C "$REPOSITORY_DIR" remote add pr-head "https://github.com/$HEAD_OWNER/$HEAD_REPO.git"
  fi
  git -C "$REPOSITORY_DIR" fetch --no-tags pr-head "$PR_BRANCH" >/dev/null
  PUSH_REMOTE="pr-head"
else
  PUSH_REMOTE="origin"
  git -C "$REPOSITORY_DIR" fetch --no-tags origin "$PR_BRANCH" >/dev/null
fi

REMOTE_HEAD="$(git -C "$REPOSITORY_DIR" rev-parse "$PUSH_REMOTE/$PR_BRANCH")"
if [[ "$REMOTE_HEAD" != "$HEAD_SHA" ]]; then
  echo -e "${RED}ERROR: PR head changed during setup; refusing to overwrite unexpected history${NC}" >&2
  exit 1
fi
if ! git -C "$REPOSITORY_DIR" merge-base --is-ancestor "$BASE_SHA" "$HEAD_SHA"; then
  echo -e "${RED}ERROR: PR head is not based on the current PR base; refusing to operate${NC}" >&2
  exit 1
fi

git -C "$REPOSITORY_DIR" worktree add --detach "$WORKTREE_DIR" "$HEAD_SHA" >/dev/null
BRANCH="$PR_BRANCH"
LOCAL_BRANCH="detached-pr-$PR_NUM-$RUN_ID"

export PR_URL OWNER REPO PR_NUM REPO_FULL BRANCH LOCAL_BRANCH WORKTREE_DIR DATA_DIR PUSH_REMOTE
export BASE_BRANCH BASE_SHA HEAD_SHA REPOSITORY_DIR RUN_ROOT RUN_ID
export MAX_ITERATIONS FIX_AGENT WAIT_CI DRY_RUN FORCE_PUSH CI_TIMEOUT REVIEW_BOTS TEST_CMD LINT_CMD
export PRE_REVIEW_WAIT REVIEW_TIMEOUT POLL_INTERVAL ALLOWED_SUPPORT_GLOBS VALIDATION_SANDBOX AGENT_SANDBOX

source "$SCRIPT_DIR/lib/loop.sh"

echo ""
echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
case "$PIPELINE_RESULT" in
  clean) echo -e "${GREEN}  PR is clean — ready for owner review${NC}" ;;
  max_iterations) echo -e "${YELLOW}  Maximum iterations reached — review report${NC}" ;;
  ci_blocked) echo -e "${RED}  CI remains failing — review report${NC}" ;;
  *) echo -e "${YELLOW}  Pipeline stopped: $PIPELINE_RESULT${NC}" ;;
esac
echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
echo -e "  Final report: ${BOLD}$DATA_DIR/report.md${NC}"
