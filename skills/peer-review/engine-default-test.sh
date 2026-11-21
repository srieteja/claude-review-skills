#!/usr/bin/env bash
# peer-review.sh engine choice: regular by default, intense only when asked (--intense or
# PEER_REVIEW_ENGINE=intense), and an asked-for intense that isn't ready fails instead of
# falling back. gh, curl and both engines are stubbed; nothing is spent.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SB="$(mktemp -d "${TMPDIR:-/tmp}/peer-engine-test.XXXXXX")"; trap 'rm -rf "$SB"' EXIT
fail=0; n=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=1; }
check() { desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }

SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
mkdir -p "$SB/bin"
cat > "$SB/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view")  printf '{"url":"https://github.com/acme/widgets/pull/7","author":{"login":"alice","is_bot":false},"headRefOid":"%s","state":"OPEN","isCrossRepository":false}' "$STUB_SHA" ;;
  "api user") echo me ;;
  *) echo "gh stub: unhandled: $*" >&2; exit 64 ;;
esac
STUB
cat > "$SB/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG/curl"; cat > /dev/null
printf '200'
STUB
cat > "$SB/bin/engine" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG/$(basename "$0")"
case "$(basename "$0")" in intense-review.sh) store="$PR_REVIEW_INTENSE_DIR" ;; *) store="$PR_REVIEW_DIR" ;; esac
d="$store/alice/widgets/$1"; mkdir -p "$d"
printf '# PR #%s\n\nu · reviewed at head `%s`\n\n**No findings.** opus reviewed the diff.\n' "$1" "$STUB_SHA" > "$d/pr$1-review.md"
STUB
cp "$SB/bin/engine" "$SB/bin/intense-review.sh"; cp "$SB/bin/engine" "$SB/bin/pr-review.sh"
cat > "$SB/bin/autofix.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$SB/bin/"*
export PATH="$SB/bin:$PATH" PEER_REVIEW_INTENSE="$SB/bin/intense-review.sh" \
       PEER_REVIEW_REGULAR="$SB/bin/pr-review.sh" PEER_REVIEW_AUTOFIX="$SB/bin/autofix.sh" \
       PR_REVIEW_LEARN=off STUB_SHA="$SHA"
unset PEER_REVIEW_ENGINE PEER_REVIEW_FIX_AUTHORS PR_REVIEW_INTENSE_REFUTER PR_REVIEW_FINDERS PR_REVIEW_PRESET PEER_REVIEW_SHIPPER
export REVIEW_SKILLS_CONFIG="$SB/no-config" PR_REVIEW_FIX_AUTHORS=carol REVIEW_SKILLS_LOCK_DIR="$SB/locks"
export REVIEW_SKILLS_MODELS=manual REVIEW_SKILLS_CACHE="$SB/models-cache"

setup() {
  n=$((n + 1)); C="$SB/case$n"; mkdir -p "$C/log" "$C/intense" "$C/regular"; git init -q "$C/repo"
  export STUB_LOG="$C/log" PR_REVIEW_INTENSE_DIR="$C/intense" PR_REVIEW_DIR="$C/regular" \
         OLLAMA_API_KEY=k-secret-123 PR_REVIEW_LEARN_DIR="$C/learn"
  unset PEER_REVIEW_ENGINE
}
run() { rc=0; ( cd "$C/repo" && "$HERE/peer-review.sh" "$@" ) >"$C/stdout" 2>"$C/stderr" || rc=$?; }
calls()  { if [ -f "$C/log/$1" ]; then wc -l < "$C/log/$1" | tr -d ' '; else echo 0; fi; }
said()   { grep -qxF -- "$1" "$C/stdout"; }
logged() { [ -f "$C/log/$1" ] && grep -qF -- "$2" "$C/log/$1"; }
not()    { ! "$@"; }
rc_is()  { [ "$rc" = "$1" ]; }

echo "engine: regular unless asked"
setup; run 7
check "no flag, key set: regular"                  said "ENGINE=regular"
check "  runs pr-review once"                      [ "$(calls pr-review.sh)" = 1 ]
check "  never runs intense"                       [ "$(calls intense-review.sh)" = 0 ]
check "  no ollama probe"                          [ "$(calls curl)" = 0 ]

setup; run 7 --intense
check "--intense: intense"                         said "ENGINE=intense"
check "  runs intense once"                        [ "$(calls intense-review.sh)" = 1 ]
check "  never runs the regular review"            [ "$(calls pr-review.sh)" = 0 ]
check "  --intense is not passed to the engine"    not logged intense-review.sh "--intense"
check "  --no-fix still is"                        logged intense-review.sh "7 --no-fix"

setup; PEER_REVIEW_ENGINE=intense run 7
check "PEER_REVIEW_ENGINE=intense: intense"        said "ENGINE=intense"

setup; PEER_REVIEW_ENGINE=regular run 7 --intense
check "--intense beats PEER_REVIEW_ENGINE=regular" said "ENGINE=intense"

setup; unset OLLAMA_API_KEY; run 7 --intense
check "--intense, not ready: exits 1"              not rc_is 0
check "  says why"                                 grep -qi "intense" "$C/stderr"
check "  runs no engine"                           [ "$(calls intense-review.sh)$(calls pr-review.sh)" = 00 ]
check "  no ENGINE= line"                          not said "ENGINE=regular"

setup; run 7 --ship --intense
check "--intense with --ship is refused"           not rc_is 0

setup; PEER_REVIEW_ENGINE=bogus run 7
check "unknown PEER_REVIEW_ENGINE is refused"      not rc_is 0

[ "$fail" = 0 ] || { echo "FAILED"; exit 1; }
echo "ok"
