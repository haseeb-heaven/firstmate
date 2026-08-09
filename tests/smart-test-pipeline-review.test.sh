#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_DIR="$ROOT/skills/smart-test-pipeline"
source "$SKILL_DIR/lib/sandbox.sh"
source "$SKILL_DIR/lib/agent.sh"
source "$SKILL_DIR/lib/validate.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/smart-pipeline-review-tests.XXXXXX")"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT
fail() { echo "not ok - $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

CODEX_PROVIDER_ENV=OPENAI_API_KEY
OPENAI_API_KEY=provider-secret
GH_TOKEN=github-secret
AWS_SECRET_ACCESS_KEY=cloud-secret
export CODEX_PROVIDER_ENV OPENAI_API_KEY GH_TOKEN AWS_SECRET_ACCESS_KEY
[[ "$(agent_provider_env codex)" == OPENAI_API_KEY ]] || fail "configured provider env is selected"
copied=$(copy_allowed_env "$(agent_provider_env codex)" | tr '\0' '\n')
grep -Fq 'OPENAI_API_KEY=provider-secret' <<<"$copied" || fail "provider credential reaches the clean agent environment"
! grep -Fq 'GH_TOKEN=' <<<"$copied" || fail "GitHub credentials stay excluded"
! grep -Fq 'AWS_SECRET_ACCESS_KEY=' <<<"$copied" || fail "unrelated cloud credentials stay excluded"
pass "provider credential allowlist is honored without broad credential leakage"

mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/work" "$TMP_ROOT/home" "$TMP_ROOT/tmp"
cat > "$TMP_ROOT/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$DOCKER_ARGS"
DOCKER
chmod +x "$TMP_ROOT/bin/docker"
DOCKER_ARGS="$TMP_ROOT/docker.args"
SANDBOX_IMAGE=test-image
export DOCKER_ARGS SANDBOX_IMAGE
PATH="$TMP_ROOT/bin:$PATH"
export PATH
_run_sandboxed_impl docker "$TMP_ROOT/work" "$TMP_ROOT/home" "$TMP_ROOT/tmp" false true
grep -Fq "HOME=$TMP_ROOT/home" "$DOCKER_ARGS" || fail "Docker HOME points at the mounted writable home"
grep -Fq "TMPDIR=$TMP_ROOT/tmp" "$DOCKER_ARGS" || fail "Docker TMPDIR points at the mounted writable temp"
pass "Docker sandbox uses its writable mounted home and temp directories"

mkdir -p "$TMP_ROOT/prefix/bin" "$TMP_ROOT/prefix/lib/node_modules/pkg/bin"
printf '#!/usr/bin/env node\n' > "$TMP_ROOT/prefix/lib/node_modules/pkg/bin/cli.js"
ln -s ../lib/node_modules/pkg/bin/cli.js "$TMP_ROOT/prefix/bin/codex"
write_macos_profile "$TMP_ROOT/profile.sb" "$TMP_ROOT/work" "$TMP_ROOT/home" "$TMP_ROOT/tmp" true api.openai.com "$TMP_ROOT/prefix/bin/codex"
grep -Fq "(subpath \"$TMP_ROOT/prefix\")" "$TMP_ROOT/profile.sb" || fail "macOS sandbox exposes the selected CLI install/runtime prefix read-only"
pass "macOS sandbox permits the selected CLI runtime tree"

git -C "$TMP_ROOT" init -q repo
git -C "$TMP_ROOT/repo" config user.email test@example.invalid
git -C "$TMP_ROOT/repo" config user.name test
printf 'base\n' > "$TMP_ROOT/repo/app.txt"
mkdir -p "$TMP_ROOT/repo/tests"
printf 'base\n' > "$TMP_ROOT/repo/tests/test_app.txt"
git -C "$TMP_ROOT/repo" add .
git -C "$TMP_ROOT/repo" commit -qm base
BASE_SHA="$(git -C "$TMP_ROOT/repo" rev-parse HEAD)"
printf '[{"id":"ci","path":"unknown","line":null,"severity":"high","body":"failed","source":"github-ci"}]\n' > "$TMP_ROOT/findings.json"
ALLOWED_SUPPORT_GLOBS='tests/**'
export ALLOWED_SUPPORT_GLOBS
printf 'change\n' >> "$TMP_ROOT/repo/app.txt"
if validate_scope "$TMP_ROOT/repo" "$BASE_SHA" "$TMP_ROOT/findings.json" "$TMP_ROOT/allowed" 2>/dev/null; then
  fail "unknown CI findings must not authorize arbitrary production paths"
fi
git -C "$TMP_ROOT/repo" checkout -- app.txt
printf 'change\n' >> "$TMP_ROOT/repo/tests/test_app.txt"
validate_scope "$TMP_ROOT/repo" "$BASE_SHA" "$TMP_ROOT/findings.json" "$TMP_ROOT/allowed" || fail "approved support paths remain available for CI-only findings"
pass "unknown CI findings cannot widen production scope"

mkdir -p "$TMP_ROOT/repo/service"
printf 'TOP_SECRET=value\n' > "$TMP_ROOT/repo/service/.env.production"
git -C "$TMP_ROOT/repo" add service/.env.production
if prepare_validation_snapshot "$TMP_ROOT/repo" "$TMP_ROOT/snapshot" 2>"$TMP_ROOT/snapshot.err"; then
  fail "nested production environment file entered validation snapshot"
fi
grep -Fq 'secret-like path refused' "$TMP_ROOT/snapshot.err" || fail "nested secret refusal was not reported"
pass "validation snapshot rejects nested environment secrets behaviorally"

echo "all final-review behavioral regression tests passed"
