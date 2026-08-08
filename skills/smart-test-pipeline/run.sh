#!/usr/bin/env bash
# run.sh — Greploop Pipeline orchestrator
# Autonomous PR review → fix → validate → repeat loop
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"

# ── Parse args ────────────────────────────────────────────────
PR_URL=""
MAX_ITERATIONS=10
FIX_AGENT="pi"
WAIT_CI=true
DRY_RUN=false
FORCE=false
TARGET_SCORE=5
CI_TIMEOUT=3600
REVIEW_BOTS="coderabbit greptile"
TEST_CMD="python -m pytest --tb=short -q"
LINT_CMD=""
PRE_REVIEW_WAIT=30
REVIEW_TIMEOUT=600
POLL_INTERVAL=30
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-iterations) MAX_ITERATIONS="$2"; shift 2 ;;
    --fix-agent)      FIX_AGENT="$2"; shift 2 ;;
    --wait-ci)        WAIT_CI="$2"; shift 2 ;;
    --dry-run)        DRY_RUN=true; shift ;;
    --force)          FORCE=true; shift ;;
    --)               shift; EXTRA_ARGS+=("$@"); break ;;
    -*)               echo "ERROR: unknown flag $1"; exit 1 ;;
    *)
      if [[ -z "$PR_URL" ]]; then PR_URL="$1"; else EXTRA_ARGS+=("$1"); fi
      shift ;;
  esac
done

if [[ -z "$PR_URL" ]]; then
  echo "Usage: $0 <PR_URL> [--max-iterations N] [--fix-agent AGENT] [--wait-ci true|false] [--dry-run]"
  exit 1
fi

# ── Resolve repo + PR number ──────────────────────────────────
if [[ "$PR_URL" =~ ^https://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)$ ]]; then
  OWNER="${BASH_REMATCH[1]}"
  REPO="${BASH_REMATCH[2]}"
  PR_NUM="${BASH_REMATCH[3]}"
else
  echo "ERROR: not a valid GitHub PR URL: $PR_URL"
  exit 1
fi

REPO_FULL="$OWNER/$REPO"
echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}  ${YELLOW}Greploop Pipeline — Autonomous Review Loop${NC}     ${CYAN}║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  PR:      ${BOLD}$PR_URL${NC}"
echo -e "  Agent:   ${BOLD}$FIX_AGENT${NC}"
echo -e "  Max iter:${BOLD} $MAX_ITERATIONS${NC}"
echo -e "  Wait CI: ${BOLD}$WAIT_CI${NC}"
echo -e "  Dry run: ${BOLD}$DRY_RUN${NC}"
echo ""

# ── Verify gh auth ────────────────────────────────────────────
if ! gh auth status >/dev/null 2>&1; then
  echo -e "${RED}ERROR: not authenticated with gh. Run 'gh auth login'${NC}"
  exit 1
fi

# ── Clone / find local copy ───────────────────────────────────
CACHE_DIR="$HOME/.greploop/cache"
PROJECT_DIR="$CACHE_DIR/$OWNER/$REPO"
mkdir -p "$CACHE_DIR/$OWNER"

if [[ ! -d "$PROJECT_DIR/.git" ]]; then
  echo -e "${DIM}Cloning $REPO_FULL...${NC}"
  git clone "https://github.com/$REPO_FULL.git" "$PROJECT_DIR" 2>/dev/null
else
  echo -e "${DIM}Using cached clone at $PROJECT_DIR${NC}"
fi

cd "$PROJECT_DIR"

if [[ -n "$(git status --porcelain)" ]]; then
  echo -e "${RED}ERROR: cached checkout is dirty; refusing to operate on unknown changes${NC}"
  exit 1
fi

# ── Fetch + checkout PR branch ────────────────────────────────
echo -e "${DIM}Fetching latest...${NC}"
git fetch origin 2>/dev/null

PR_BRANCH="$(gh pr view "$PR_NUM" --json headRefName --jq '.headRefName' 2>/dev/null)"
if [[ -z "$PR_BRANCH" ]]; then
  echo -e "${RED}ERROR: could not read PR branch${NC}"
  exit 1
fi

echo -e "${DIM}Checking out branch ${YELLOW}$PR_BRANCH${NC}..."
git checkout "$PR_BRANCH" 2>/dev/null || git checkout -b "$PR_BRANCH" "origin/$PR_BRANCH" 2>/dev/null
git pull --ff-only origin "$PR_BRANCH" 2>/dev/null || {
  echo -e "${RED}ERROR: cached PR branch is not a fast-forward of origin; refresh the cache before retrying${NC}"
  exit 1
}

WORKTREE_DIR="$PROJECT_DIR"
BRANCH="$PR_BRANCH"

# ── Setup data dir ────────────────────────────────────────────
DATA_DIR="$WORKTREE_DIR/.greploop-data"
mkdir -p "$DATA_DIR"

# ── Source config (project-local overrides) ───────────────────
# Do not source configuration from the PR checkout: the PR is untrusted code
# and sourcing it would execute attacker-controlled shell commands.
if [[ -f "$SCRIPT_DIR/config.sh" ]]; then
  source "$SCRIPT_DIR/config.sh"
fi

export PR_URL OWNER REPO PR_NUM REPO_FULL BRANCH WORKTREE_DIR DATA_DIR
export MAX_ITERATIONS FIX_AGENT WAIT_CI DRY_RUN FORCE

# ── Main loop ─────────────────────────────────────────────────
source "$SCRIPT_DIR/lib/loop.sh"

echo ""
echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
if [[ "$PIPELINE_RESULT" == "clean" ]]; then
  echo -e "${GREEN}  PR is clean — ready for merge!${NC}"
elif [[ "$PIPELINE_RESULT" == "max_iterations" ]]; then
  echo -e "${YELLOW}  Max iterations reached — review report${NC}"
elif [[ "$PIPELINE_RESULT" == "ci_blocked" ]]; then
  echo -e "${RED}  CI blocked — check report${NC}"
else
  echo -e "${YELLOW}  Pipeline stopped: $PIPELINE_RESULT${NC}"
fi
echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Final report: ${BOLD}$DATA_DIR/report.md${NC}"
echo -e "  Iterations:   ${BOLD}$DATA_DIR/iterations/${NC}"
echo ""
