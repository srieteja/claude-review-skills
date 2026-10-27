#!/usr/bin/env bash
# Checks for bin/review-skills: install, models, doctor, test --list. Everything runs against
# a scratch HOME and stubbed backends; nothing is installed for real.
set -euo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$HERE/.." && pwd)"
CLI="$HERE/review-skills"
SB="$(mktemp -d "${TMPDIR:-/tmp}/cli-test.XXXXXX")"; trap 'rm -rf "$SB"' EXIT
fail=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=1; }
check() { desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }

mkdir -p "$SB/home" "$SB/stub"
cat > "$SB/stub/claude" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2" = "auth status" ] && { echo '{"loggedIn":true}'; exit 0; }
exit 64
STUB
cat > "$SB/stub/agy" <<'STUB'
#!/usr/bin/env bash
echo "not signed in" >&2; exit 1
STUB
# npm: logs its arguments, so install's mermaid step is seen without touching the repo.
cat > "$SB/stub/npm" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$SB/npm.log"; exit \${STUB_NPM_RC:-0}
STUB
chmod +x "$SB/stub/"*
# cli [VAR=val...] -- <args>: the CLI in a clean env with a scratch HOME, config and cache.
cat > "$SB/cli" <<EOF
#!/usr/bin/env bash
vars=()
while [ "\$1" != -- ]; do vars+=("\$1"); shift; done; shift
exec env -i HOME="$SB/home" PATH="$SB/stub:$PATH" TMPDIR="${TMPDIR:-/tmp}" \\
  REVIEW_SKILLS_CONFIG="$SB/cfg/config.env" REVIEW_SKILLS_CACHE="$SB/cache" \\
  CLAUDE_SKILLS_DIR="$SB/skills" \${vars[@]+"\${vars[@]}"} bash "$CLI" "\$@"
EOF
chmod +x "$SB/cli"; cli="$SB/cli"
cli() { "$cli" "$@"; }
SKILLS="delegate intense-review ollama-agents peer-review pr-review"

echo "install"
out="$(cli -- install 2>&1)" && rc=0 || rc=$?
check "exits 0 on a clean machine" test "$rc" = 0
for s in $SKILLS; do
  check "  links $s to the repo" test "$(readlink "$SB/skills/$s")" = "$REPO/skills/$s"
done
check "  seeds config.env from the template" cmp -s "$SB/cfg/config.env" "$REPO/config.example.env"
check "  readable by its owner only" sh -c 'test -f "$1" && test -z "$(find "$1" \( -perm -040 -o -perm -004 \) -print)"' _ "$SB/cfg/config.env"
check "  an installed entry point finds lib/" \
  sh -c '"$1" --help 2>&1 | grep -q "usage: pr-review.sh"' _ "$SB/skills/pr-review/pr-review.sh"
echo 'OLLAMA_API_KEY=mine' > "$SB/cfg/config.env"
check "  installs mermaid for the diagram check" grep -qx "ci --prefix $REPO/skills/pr-review/mermaid --no-audit --no-fund" "$SB/npm.log"
check "a second install exits 0" cli -- install
check "a failed npm ci still installs" cli STUB_NPM_RC=1 -- install
check "  and says diagrams are off" sh -c '"$@" -- install 2>&1 | grep -q "diagrams off"' _ "$cli" STUB_NPM_RC=1
check "  and keeps the user's config" grep -qx 'OLLAMA_API_KEY=mine' "$SB/cfg/config.env"
rm "$SB/skills/delegate"; mkdir "$SB/skills/delegate"; : > "$SB/skills/delegate/mine"
out="$(cli -- install 2>&1)" && rc=0 || rc=$?
check "a directory already in the way fails the install" test "$rc" -ne 0
check "  is named" sh -c 'printf "%s" "$1" | grep -q "skills/delegate"' _ "$out"
check "  and left as it was" test -f "$SB/skills/delegate/mine"
check "  the other skills still link" test -L "$SB/skills/pr-review"
rm -rf "$SB/skills" "$SB/cfg"
mkdir -p "$SB/bin"; ln -s "$CLI" "$SB/bin/review-skills"
env -i HOME="$SB/home" PATH="$SB/stub:$PATH" REVIEW_SKILLS_CONFIG="$SB/cfg/config.env" \
  CLAUDE_SKILLS_DIR="$SB/skills" bash "$SB/bin/review-skills" install >/dev/null 2>&1 || true
check "run through a symlink, it still links the repo's skills" \
  test "$(readlink "$SB/skills/pr-review")" = "$REPO/skills/pr-review"

echo "models"
check "manual: today's defaults for both presets" sh -c '
  out="$("$@" -- models)"
  printf "%s" "$out" | grep -q "regular.*anthropic:claude-opus-5-5@xhigh.*agy:gemini-3.8-flash-high" &&
  printf "%s" "$out" | grep -q "intense.*anthropic:claude-opus-5-5@max agy:gemini-3.8-flash-high.*ollama:glm-5.3-flash"
' _ "$cli" REVIEW_SKILLS_MODELS=manual
check "one preset when asked" sh -c '! "$@" -- models intense | grep -q "^regular"' _ "$cli" REVIEW_SKILLS_MODELS=manual
check "a same-family refuter is called out" sh -c '"$@" -- models regular | grep -q "same family"' _ "$cli"
mkdir -p "$SB/cache"; echo stale > "$SB/cache/agy.models"
cli -- models --refresh >/dev/null 2>&1 || true
check "--refresh drops the cached model lists" test ! -e "$SB/cache/agy.models"
check "an unknown preset is refused" sh -c '! "$@" -- models bogus' _ "$cli"

echo "doctor"
mkdir -p "$SB/cfg"; printf 'OLLAMA_API_KEY=sekrit-123\n' > "$SB/cfg/config.env"; chmod 600 "$SB/cfg/config.env"
out="$(cli -- doctor 2>&1)" || true
check "names the config file" sh -c 'printf "%s" "$1" | grep -qF "$2"' _ "$out" "$SB/cfg/config.env"
check "says a key is set" sh -c 'printf "%s" "$1" | grep -q "OLLAMA_API_KEY.*set"' _ "$out"
check "  never prints it" sh -c '! printf "%s" "$1" | grep -q sekrit' _ "$out"
check "reports claude signed in, agy not" \
  sh -c 'printf "%s" "$1" | grep -q "claude.*signed in" && printf "%s" "$1" | grep -q "agy.*not signed in"' _ "$out"
check "reports whether diagrams are checked" sh -c 'printf "%s" "$1" | grep -qE "diagrams( off)?:"' _ "$out"
check "shows what each preset resolves to" \
  sh -c 'printf "%s" "$1" | grep -q "^ *regular" && printf "%s" "$1" | grep -q "^ *intense"' _ "$out"
chmod 644 "$SB/cfg/config.env"
check "a config readable by others fails" sh -c '! "$@" -- doctor' _ "$cli"
chmod 600 "$SB/cfg/config.env"
mkdir -p "$SB/nojq"
for t in bash git gh curl python3 awk find claude agy; do
  p="$(PATH="$SB/stub:$PATH" command -v "$t" 2>/dev/null)" && ln -sf "$p" "$SB/nojq/$t"
done
out="$(env -i HOME="$SB/home" PATH="$SB/nojq:/usr/bin:/bin" REVIEW_SKILLS_CONFIG="$SB/cfg/config.env" \
  REVIEW_SKILLS_CACHE="$SB/cache" "$SB/nojq/bash" "$CLI" doctor 2>&1)" && rc=0 || rc=$?
if [ -x /usr/bin/jq ]; then ok "a missing tool fails (skipped: jq is in /usr/bin)"
else
  check "a missing tool fails" test "$rc" -ne 0
  check "  and is named" sh -c 'printf "%s" "$1" | grep -q "jq.*missing"' _ "$out"
fi

echo "test"
out="$(cli -- test --list)"
check "lists every suite" sh -c 'for t in lib/models-test.sh skills/pr-review/offline-test.sh skills/delegate/offline-test.sh bin/cli-test.sh; do printf "%s" "$1" | grep -qx "$t" || exit 1; done' _ "$out"
check "  but not the live selftests" sh -c '! printf "%s" "$1" | grep -q selftest' _ "$out"

echo "usage"
check "an unknown command fails" sh -c '! "$@" -- frobnicate' _ "$cli"
check "no command prints usage" sh -c '"$@" -- 2>&1 | grep -q "usage: review-skills"' _ "$cli"

[ "$fail" -eq 0 ] && printf '\n\033[32mall cli checks passed\033[0m\n' || printf '\n\033[31mcli checks FAILED\033[0m\n'
exit $fail
