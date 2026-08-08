#!/usr/bin/env bash
# Operator-owned configuration. Loaded before built-in defaults; CLI flags win.

MAX_ITERATIONS=10
FIX_AGENT=pi
WAIT_CI=true
CI_TIMEOUT=3600
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

# Supporting files may be changed only when a finding exists and the path is
# in one of these narrowly scoped test patterns.
ALLOWED_SUPPORT_GLOBS="tests/** test/** **/test_*.py **/*_test.*"

# These are names only. Values are copied from the operator environment into
# the model process; GitHub, SSH, cloud, and generic secret variables are not.
PI_PROVIDER_ENV="ANTHROPIC_API_KEY OPENAI_API_KEY GOOGLE_API_KEY"
CLAUDE_PROVIDER_ENV="ANTHROPIC_API_KEY CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEXAI"
CODEX_PROVIDER_ENV="OPENAI_API_KEY OPENAI_BASE_URL"
OPENCODE_PROVIDER_ENV="OPENAI_API_KEY ANTHROPIC_API_KEY GOOGLE_GENERATIVE_AI_API_KEY"
