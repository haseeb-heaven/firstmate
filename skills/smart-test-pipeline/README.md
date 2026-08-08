# Smart Test Pipeline - Guarded PR Review and Fix Loop

## What it does

1. Captures a baseline and triggers the configured review bots on the PR.
2. Waits for each configured bot to publish a completion signal.
3. Collects unresolved, non-outdated review threads through GitHub GraphQL.
4. Spawns a fix agent with a structured brief containing review and CI findings.
5. Runs the configured tests and optional lint before committing or pushing changes.
6. Optionally waits for at least one completed, successful CI check.
7. Repeats until no unresolved findings remain or the maximum iteration count is reached.

## Quick start

```bash
# Basic - point at a PR URL
./run.sh "https://github.com/owner/repo/pull/123"

# With options
./run.sh "https://github.com/owner/repo/pull/123" \
  --max-iterations 10 \
  --fix-agent pi \
  --wait-ci true
```

## Configuration

Copy `config.example.sh` to `~/.config/greploop/config.sh` and edit, or set `GREPOLOOP_CONFIG` to a trusted config path. Key settings:

| Variable | Default | Description |
|----------|---------|-------------|
| `MAX_ITERATIONS` | 10 | Max loop cycles |
| `FIX_AGENT` | pi | Agent to spawn for fixes (pi, claude, codex, opencode) |
| `WAIT_CI` | true | Wait for CI green before next iteration |
| `CI_TIMEOUT` | 3600 | Seconds to wait for CI |
| `REVIEW_BOTS` | coderabbit greptile | Bots to trigger |
| `TEST_CMD` | `python -m pytest --tb=short -q` | Local test command |
| `LINT_CMD` | (empty) | Local lint command |

## Safety

The pipeline does not merge pull requests, and its complete safety contract is documented in [SKILL.md](SKILL.md).
Use `--force` only when a force-with-lease push is explicitly intended.
The pipeline stops at the configured iteration limit and writes a full report.
Use `--dry-run` to preview the run without review triggers, agent execution, commits, pushes, or CI polling.

## Output

By default, the pipeline writes iteration reports under `${TMPDIR:-/tmp}/greploop-data/<owner>/<repo>/<pr>/iterations/<N>/` and the final report at the corresponding `report.md` path.
