# Greploop Pipeline — Autonomous PR Review & Fix Loop

## What it does

1. Triggers the configured review bots on the PR
2. Waits for reviews, collects all unresolved findings
3. Spawns a fix agent with structured brief
4. Validates locally (tests, lint), then pushes
5. Waits for CI to pass
6. Repeats until zero findings or max iterations hit

## Quick start

```bash
# Basic — point at a PR URL
./run.sh "https://github.com/owner/repo/pull/123"

# With options
./run.sh "https://github.com/owner/repo/pull/123" \
  --max-iterations 10 \
  --fix-agent pi \
  --wait-ci true
```

## Configuration

Copy `config.example.sh` to `config.sh` and edit. Key settings:

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

- Never merges the PR (captain approval required)
- Never forces pushes without `--force`
- Stops on max iterations with full report
- Dry-run mode: `--dry-run`
- Each iteration = separate commit (easy to revert)

## Output

After each iteration, the pipeline writes `.greploop-data/iterations/<N>/report.md` with findings, fixes, test results, and CI status.
The final report is `.greploop-data/report.md`.
