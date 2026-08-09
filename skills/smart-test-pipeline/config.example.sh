#!/usr/bin/env bash
# Operator-owned configuration. Loaded before built-in defaults; CLI flags win.

MAX_ITERATIONS=10
FIX_AGENT=pi
WAIT_CI=true
CI_TIMEOUT=3600
CI_STABILITY_POLLS=3
AGENT_TIMEOUT=1800
VALIDATION_TIMEOUT=3600
VALIDATION_OUTPUT_LIMIT=1048576
REVIEW_THREAD_BODY_LIMIT=262144
REVIEW_FINDINGS_TOTAL_LIMIT=4194304
REVIEW_BOTS="coderabbit greptile"
TEST_CMD="python -m pytest --tb=short -q"
LINT_CMD=""
PRE_REVIEW_WAIT=30
REVIEW_TIMEOUT=600
POLL_INTERVAL=30

# The pipeline refuses validation if auto/bwrap/sandbox-exec/docker cannot
# provide a disposable boundary.
VALIDATION_SANDBOX=auto
AGENT_SANDBOX=auto

# Required for networked fix agents. This must be an absolute path to a trusted
# operator-owned broker executable. The broker receives:
#   --agent <pi|claude|codex|opencode>
#   --brief <sandboxed-fix-brief>
#   --worktree <isolated-worktree>
#   -- <verified-agent-command-and-args>
# It is responsible for authenticating the agent without exposing reusable
# provider credentials in the agent environment or its project subprocesses.
# Raw ANTHROPIC_API_KEY / OPENAI_API_KEY forwarding is intentionally unsupported.
AGENT_CREDENTIAL_BROKER=""

# Supporting files may be changed only when a finding exists and the path is
# in one of these narrowly scoped test patterns.
ALLOWED_SUPPORT_GLOBS="tests/** test/** **/test_*.py **/*_test.*"

# Docker requires an image with bash and the selected agent/runtime installed.
SANDBOX_IMAGE=""
