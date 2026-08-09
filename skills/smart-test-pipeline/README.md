# Smart Test Pipeline - Guarded PR Review and Fix Loop

## What it does

1. Captures a baseline and triggers the configured review bots on the PR.
2. Waits for each configured bot to publish a completion signal.
3. Collects unresolved, non-outdated review threads through GitHub GraphQL with bounded retained payloads.
4. Spawns a fix agent through a trusted credential-isolating broker with a structured brief containing review and CI findings.
5. Runs the configured tests and optional lint in a credential-free disposable sandbox before committing or pushing changes.
6. Optionally waits for a successful CI set to remain stable across multiple polls before declaring it green.
7. Repeats until no unresolved findings remain or the maximum iteration count is reached.

## Quick start

```bash
# Configure a trusted credential broker first.
export AGENT_CREDENTIAL_BROKER=/absolute/path/to/agent-credential-broker

# Basic - point at a PR URL
./run.sh "https://github.com/owner/repo/pull/123"

# With options
./run.sh "https://github.com/owner/repo/pull/123" \
  --max-iterations 10 \
  --fix-agent pi \
  --wait-ci true
```

> **Agent authentication note:** raw provider API keys are intentionally **not** copied into the agent sandbox. Networked fixing requires an operator-owned `AGENT_CREDENTIAL_BROKER` that authenticates the selected CLI without exposing reusable provider credentials in the agent environment or its project subprocesses. The pipeline fails preflight before posting review triggers when that broker is absent or invalid.

> **Agent platform note:** automatic fix-agent execution currently requires macOS with a working `sandbox-exec` provider-aware network boundary. Linux validation can use bubblewrap or Docker, but networked fix agents are intentionally refused there because those backends do not currently enforce provider-only egress. On Linux, use the pipeline only for dry-run/validation workflows until a provider-aware agent boundary is available.

## Credential broker contract

The broker path must be absolute and executable. It is invoked inside the restricted agent boundary as:

```text
<broker> --agent <pi|claude|codex|opencode> \
  --brief <sandboxed-fix-brief> \
  --worktree <isolated-worktree> \
  -- <verified-agent-command-and-args>
```

The broker is trusted operator infrastructure. It must authenticate the agent without exporting reusable provider credentials to the agent or descendants. The smart-test-pipeline itself does not forward `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, GitHub credentials, SSH credentials, cloud credentials, or generic host secrets into the agent environment. Repository-controlled tests, builds, scripts, and executables are reserved for the later credential-free validation stage rather than the credentialed fixer stage.

## Configuration

Copy `config.example.sh` to `config.sh` beside `run.sh`, or set `SMART_TEST_CONFIG` to a trusted operator-owned config path. CLI flags override config, and config overrides built-in defaults. Key settings:

| Variable | Default | Description |
|----------|---------|-------------|
| `MAX_ITERATIONS` | 10 | Max loop cycles |
| `FIX_AGENT` | pi | Agent adapter selected for fixes (pi, claude, codex, opencode) |
| `WAIT_CI` | true | Wait for CI green before next iteration |
| `CI_TIMEOUT` | 3600 | Seconds to wait for CI |
| `CI_STABILITY_POLLS` | 3 | Identical completed CI polls required before success |
| `AGENT_TIMEOUT` | 1800 | Seconds before a stalled fix-agent process group is terminated |
| `VALIDATION_TIMEOUT` | 3600 | Seconds before the complete test/lint process group is terminated |
| `VALIDATION_OUTPUT_LIMIT` | 1048576 | Maximum captured bytes per test or lint stage |
| `REVIEW_THREAD_BODY_LIMIT` | 262144 | Maximum retained body characters for one review thread |
| `REVIEW_FINDINGS_TOTAL_LIMIT` | 4194304 | Maximum aggregate retained unresolved-review payload bytes |
| `REVIEW_BOTS` | coderabbit greptile | Bots to trigger |
| `PRE_REVIEW_WAIT` | 30 | Non-negative seconds to wait after review triggers |
| `TEST_CMD` | `python -m pytest --tb=short -q` | Local test command |
| `LINT_CMD` | (empty) | Local lint command |
| `AGENT_CREDENTIAL_BROKER` | (empty; required for fixes) | Absolute trusted broker executable; raw provider-key forwarding is unsupported |
| `VALIDATION_SANDBOX` | auto | Disposable validation backend: `macos` (`sandbox-exec`), `bwrap`, or Docker |
| `AGENT_SANDBOX` | auto | Disposable fix-agent backend; currently `auto`/`macos` require macOS `sandbox-exec` for provider-restricted networking |
| `ALLOWED_SUPPORT_GLOBS` | test patterns | Narrow patterns for reviewed supporting files |

## Safety

The pipeline does not merge pull requests, refuses closed/merged PRs, isolates concurrent PR runs, validates PR URL path segments before constructing local paths, and protects Git control data. Linked-worktree Git metadata is exposed read-only to the macOS agent boundary while write access remains denied. Agent runtime reads are limited to exact executable/interpreter files and narrowly derived package/formula roots rather than executable parent directories.

The pipeline stops at the configured iteration limit and writes a full report. `PRE_REVIEW_WAIT` and other timing/size settings are validated before any review-trigger mutation. Review pagination is retained through files/stdin with explicit per-thread and aggregate limits rather than expanding large bodies into command-line arguments.

Use `--force` only when a force-with-lease push is explicitly intended. Use `--dry-run` to preview the run without review triggers, agent execution, commits, pushes, or CI polling.

## Output

By default, the pipeline writes each run under `${TMPDIR:-/tmp}/greploop-data/<owner>/<repo>/pr-<pr>/<run-id>/`, so stale iteration artifacts cannot be reused.
