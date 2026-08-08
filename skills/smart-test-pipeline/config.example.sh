#!/usr/bin/env bash
# config.sh - Smart Test Pipeline configuration
# Copy to ~/.config/greploop/config.sh and edit for your project
set -euo pipefail

# ── Loop control ──────────────────────────────────────────────
MAX_ITERATIONS="${MAX_ITERATIONS:-10}"
TARGET_SCORE="${TARGET_SCORE:-5}"        # Greptile confidence (1-5)

# ── Fix agent ─────────────────────────────────────────────────
# Which AI tool to spawn for fixes: pi, claude, codex, opencode
FIX_AGENT="${FIX_AGENT:-pi}"

# ── CI gating ─────────────────────────────────────────────────
WAIT_CI="${WAIT_CI:-true}"
CI_TIMEOUT="${CI_TIMEOUT:-3600}"         # seconds to wait for CI

# ── Review bots ───────────────────────────────────────────────
# Space-separated list of bots to trigger: coderabbit greptile
REVIEW_BOTS="${REVIEW_BOTS:-coderabbit greptile}"

# ── Local validation ──────────────────────────────────────────
TEST_CMD="${TEST_CMD:-python -m pytest --tb=short -q}"
LINT_CMD="${LINT_CMD:-}"                # empty = skip lint

# ── Timing ────────────────────────────────────────────────────
PRE_REVIEW_WAIT="${PRE_REVIEW_WAIT:-30}"    # wait before first poll
REVIEW_TIMEOUT="${REVIEW_TIMEOUT:-600}"     # max wait for review comments
POLL_INTERVAL="${POLL_INTERVAL:-30}"        # seconds between polls

# ── Safety ────────────────────────────────────────────────────
DRY_RUN="${DRY_RUN:-false}"
FORCE_PUSH="${FORCE_PUSH:-false}"

# ── Working directory ─────────────────────────────────────────
# Auto-set by run.sh from the PR branch
DATA_DIR="${DATA_DIR:-}"
BRIEF_FILE="${BRIEF_FILE:-}"
ITERATION="${ITERATION:-0}"
