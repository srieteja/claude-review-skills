#!/usr/bin/env bash
# refute -- the agy transport's per-model quota fallback. agy is stubbed and --root is a
# throwaway repo, so this needs no network, no gh and no checkout under review.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SB="$(mktemp -d "${TMPDIR:-/tmp}/refute-test.XXXXXX")"
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin" "$SB/repo"
git -C "$SB/repo" init -q
echo x > "$SB/repo/a.dart"; git -C "$SB/repo" add -A
git -C "$SB/repo" -c user.email=t -c user.name=t commit -qm init

# A model in STUB_QUOTA_MODELS answers the way real agy does when that model's quota is
# spent: ERROR envelope on stdout, AGY_ERROR 429 on stderr. STUB_FAIL=1 is any other failure.
cat > "$SB/bin/agy" <<'STUB'
#!/usr/bin/env bash
m=""; p=""; prev=""
for a in "$@"; do
  [ "$prev" = --model ] && m="$a"
  case "$a" in -p=*) p="${a#-p=}" ;; esac
  prev="$a"
done
echo "$m" >> "$STUB_CALLS"
case " ${STUB_QUOTA_MODELS:-} " in *" $m "*)
  echo 'AGY_ERROR: {"short_error":"RESOURCE_EXHAUSTED (code 429): Individual quota reached.","status":"RESOURCE_EXHAUSTED","error_code":429}' >&2
  echo '{"status":"ERROR","response":"read a.dart"}'; exit 1 ;;
esac
# STUB_OFFLINE mirrors agy with no route to Google (work dirs of 2026-11-04): dns is the
# AGY_ERROR dial failure after a long wait; model is the "not recognized" refusal agy gives
# a valid id when the registry it validates against never loaded. Neither is a 429.
case "${STUB_OFFLINE:-}" in
  dns)
    echo 'error: There was a network issue connecting to the server, please try again.' >&2
    echo 'AGY_ERROR: {"short_error":"agent executor error: generating and executing: request failed: Post \"https://daily-cloudcode-pa.googleapis.com/v1internal:streamGenerateContent?alt=sse\": dial tcp: lookup daily-cloudcode-pa.googleapis.com: no such host","status":"UNKNOWN","error_code":2,"code_kind":"grpc","retryable":true}' >&2
    echo '{"status":"ERROR","response":"","error":"There was a network issue connecting to the server, please try again."}'; exit 1 ;;
  model)
    echo "error: invalid model selection (--model \"$m\" --effort \"\"): model $m is not recognized as a known model or custom model in settings" >&2
    echo '{"status":"ERROR","response":"","error":"invalid model selection","num_turns":0,"finished_reason":"error"}'; exit 1 ;;
esac
if [ "${STUB_FAIL:-0}" = 1 ]; then
  echo 'AGY_ERROR: {"short_error":"INTERNAL (code 500)","status":"INTERNAL","error_code":500}' >&2
  echo '{"status":"ERROR","response":"hit a 429 earlier"}'; exit 1
fi
id="$(printf '%s' "$p" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)"
printf '{"structured_output":{"id":"%s","verdict":"REFUTED","evidence":"a.dart:1","reason":"stub"}}\n' "$id"
STUB
chmod +x "$SB/bin/agy"

# claude stands in for the ollama transport. STUB_CLAUDE_STATUS=403 is what an unpaid ollama
# account returns: a result event with is_error and api_error_status, nothing on stderr.
cat > "$SB/bin/claude" <<'STUB'
#!/usr/bin/env bash
p=""; prev=""
for a in "$@"; do [ "$prev" = -p ] && p="$a"; prev="$a"; done
echo "claude" >> "$STUB_CALLS"
[ -z "${STUB_TOKEN_LOG:-}" ] || printf '%s' "${ANTHROPIC_AUTH_TOKEN:-}" > "$STUB_TOKEN_LOG"
[ -z "${STUB_ENV_LOG:-}" ] || printf 'base=%s simple=%s ollama=%s\n' \
  "${ANTHROPIC_BASE_URL:-}" "${CLAUDE_CODE_SIMPLE:-}" "${OLLAMA_API_KEY:+set}" > "$STUB_ENV_LOG"
if [ -n "${STUB_CLAUDE_STATUS:-}" ]; then
  printf '[{"type":"result","is_error":true,"api_error_status":%s,"result":"%s"}]\n' \
    "$STUB_CLAUDE_STATUS" "${STUB_CLAUDE_RESULT:-API Error}"; exit 0
fi
id="$(printf '%s' "$p" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)"
printf '[{"type":"result","is_error":false,"structured_output":{"id":"%s","verdict":"REFUTED","evidence":"a.dart:1","reason":"stub"}}]\n' "$id"
STUB
chmod +x "$SB/bin/claude"
export OLLAMA_API_KEY=stub
export PATH="$SB/bin:$PATH" REVIEW_SKILLS_CONFIG="$SB/no-config"
unset PR_REVIEW_REFUTER_FALLBACK STUB_QUOTA_MODELS STUB_FAIL STUB_OFFLINE STUB_CLAUDE_STATUS STUB_CLAUDE_RESULT

claims() { # id...
  printf '{"findings":['
  sep=""; for id in "$@"; do
    printf '%s{"id":"%s","file":"a.dart","line":1,"claim":"c","mechanism":"m","repro":"r"}' "$sep" "$id"; sep=,
  done
  printf ']}\n'
}

fail=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=1; }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }

run() { # args...  (claims in $SB/f.json)
  W="$SB/w.$RANDOM"; : > "$SB/calls"
  STUB_CALLS="$SB/calls" "$HERE/refute" --findings "$SB/f.json" --tree "$SB/repo" --root "$SB/repo" \
    --work "$W" --jobs 1 "$@" > "$SB/out" 2>&1
  RC=$?
}
calls()   { tr '\n' ' ' < "$SB/calls" | sed 's/ $//'; }
verdict() { jq -r ".$2" "$W/verdicts/$1.json"; }

echo "agy per-model quota fallback"
claims F1 > "$SB/f.json"
export PR_REVIEW_REFUTER_FALLBACK="m2 m3"
STUB_QUOTA_MODELS=m1 run --model m1
check "first model out of quota: exits 0"           [ "$RC" = 0 ]
check "  falls back to the next model"              [ "$(calls)" = "m1 m2" ]
check "  verdict comes from it"                     [ "$(verdict F1 verdict)" = REFUTED ]
check "  verdict records the model that ran"        [ "$(verdict F1 model)" = m2 ]

STUB_QUOTA_MODELS="m1 m2 m3" run --model m1
check "every model out of quota: still exits 0"     [ "$RC" = 0 ]
check "  tries each once, no same-model retry"      [ "$(calls)" = "m1 m2 m3" ]
check "  claim comes back ERROR"                    [ "$(verdict F1 verdict)" = ERROR ]
check "  reason says quota"                         grep -q quota "$W/verdicts/F1.json"

STUB_FAIL=1 run --model m1
check "non-quota failure: one retry, same model"    [ "$(calls)" = "m1 m1" ]
check "  no fallback, claim is ERROR"               [ "$(verdict F1 verdict)" = ERROR ]
check "  reason carries agy's error"                grep -q 'INTERNAL (code 500)' "$W/verdicts/F1.json"

echo "agy unreachable"
export PR_REVIEW_REFUTER_FALLBACK="m2 m3"
STUB_OFFLINE=dns run --model m1
check "dns failure: exits 0"                        [ "$RC" = 0 ]
check "  one call: no retry, no agy fallback"       [ "$(calls)" = m1 ]
check "  claim is ERROR"                            [ "$(verdict F1 verdict)" = ERROR ]
check "  reason says unavailable"                   grep -q unavailable "$W/verdicts/F1.json"
check "  reason carries the dial error"             grep -q 'no such host' "$W/verdicts/F1.json"
check "  reason names every agy model skipped"      grep -q 'm1, m2, m3' "$W/verdicts/F1.json"

STUB_OFFLINE=model run --model m1
check "model not recognized: one call"              [ "$(calls)" = m1 ]
check "  claim is ERROR"                            [ "$(verdict F1 verdict)" = ERROR ]
check "  reason carries the refusal"                grep -q 'not recognized as a known model' "$W/verdicts/F1.json"

claims F1 F2 > "$SB/f.json"
STUB_OFFLINE=dns run --model m1
check "later claims skip agy entirely"              [ "$(calls)" = m1 ]
check "  and are ERROR too"                         [ "$(verdict F2 verdict)" = ERROR ]
claims F1 > "$SB/f.json"
export PR_REVIEW_REFUTER_FALLBACK="m2 m3"

run --model m1
check "no failure: one call"                        [ "$(calls)" = m1 ]
check "  verdict records the model"                 [ "$(verdict F1 model)" = m1 ]

claims F1 F2 > "$SB/f.json"
STUB_QUOTA_MODELS=m1 run --model m1
check "a dead model is skipped by later claims"     [ "$(calls)" = "m1 m2 m2" ]

claims F1 > "$SB/f.json"
export PR_REVIEW_REFUTER_FALLBACK=m1
STUB_QUOTA_MODELS=m1 run --model m1
check "fallback list overlapping --model: no rerun" [ "$(calls)" = m1 ]

unset PR_REVIEW_REFUTER_FALLBACK
STUB_QUOTA_MODELS=m1 run --model m1
check "default fallback is gemini-3.1-pro-high"     [ "$(calls)" = "m1 gemini-3.1-pro-high" ]

echo "cross refutation when the primary is unavailable"
export PR_REVIEW_GEMINI_MODEL=gemini-x PR_REVIEW_REFUTER_FALLBACK="claude-opus-x"
OLL="--transport ollama --model glm-x"
claims anthropic.c01-F1 > "$SB/f.json"
run $OLL --cross
check "primary healthy: only it runs"               [ "$(calls)" = claude ]
check "  verdict records the primary"               [ "$(verdict anthropic.c01-F1 model)" = glm-x ]

STUB_CLAUDE_STATUS=403 run $OLL --cross
check "opus finding, glm 403: gemini refutes it"    [ "$(calls)" = "claude gemini-x" ]
check "  verdict records the cross model"           [ "$(verdict anthropic.c01-F1 model)" = gemini-x ]

claims agy.c01-F1 > "$SB/f.json"
STUB_CLAUDE_STATUS=403 run $OLL --cross
check "gemini finding, glm 403: opus refutes it"    [ "$(calls)" = "claude claude-opus-x" ]

claims anthropic.c01-F1 anthropic.c01-F2 > "$SB/f.json"
STUB_CLAUDE_STATUS=403 run $OLL --cross
check "a dead primary is skipped by later claims"   [ "$(calls)" = "claude gemini-x gemini-x" ]

claims anthropic.c01-F1 > "$SB/f.json"
STUB_CLAUDE_STATUS=403 STUB_QUOTA_MODELS=gemini-x run $OLL --cross
check "cross model also dead: finding stays ERROR"  [ "$(verdict anthropic.c01-F1 verdict)" = ERROR ]
check "  never falls to its own family"             [ "$(calls)" = "claude gemini-x" ]

STUB_CLAUDE_STATUS=403 STUB_OFFLINE=dns run $OLL --cross
check "cross model unreachable: finding is ERROR"   [ "$(verdict anthropic.c01-F1 verdict)" = ERROR ]
check "  one agy call, no agy retry"                [ "$(calls)" = "claude gemini-x" ]
check "  reason carries the dial error"             grep -q 'no such host' "$W/verdicts/anthropic.c01-F1.json"

STUB_CLAUDE_STATUS=500 STUB_CLAUDE_RESULT="Internal server error" run $OLL
check "claude failure: reason carries its result"   grep -q 'Internal server error' "$W/verdicts/anthropic.c01-F1.json"

claims c01-F1 > "$SB/f.json"
STUB_CLAUDE_STATUS=403 run $OLL --cross
check "unprefixed id: every agy model is eligible"  [ "$(calls)" = "claude gemini-x" ]

claims anthropic.c01-F1 > "$SB/f.json"
STUB_CLAUDE_STATUS=403 run $OLL
check "without --cross a dead primary is ERROR"     [ "$(verdict anthropic.c01-F1 verdict)" = ERROR ]
check "  one call, no retry, no agy call"           [ "$(calls)" = claude ]

STUB_CLAUDE_STATUS=500 run $OLL --cross
check "non-auth failure: retried, no cross"         [ "$(calls)" = "claude claude" ]
unset PR_REVIEW_REFUTER_FALLBACK
unset PR_REVIEW_GEMINI_MODEL PR_REVIEW_REFUTER_FALLBACK

echo "anthropic transport"
export PR_REVIEW_GEMINI_MODEL=gemini-x PR_REVIEW_REFUTER_FALLBACK=""
ANT="--transport anthropic --model claude-x"
claims agy.c01-F1 > "$SB/f.json"
STUB_ENV_LOG="$SB/env" run $ANT
check "a claude refuter runs on claude"             [ "$(calls)" = claude ]
check "  verdict records it"                        [ "$(verdict agy.c01-F1 model)" = claude-x ]
check "  on the login: no endpoint, no SIMPLE, no ollama key" [ "$(cat "$SB/env")" = "base= simple= ollama=" ]

STUB_CLAUDE_STATUS=429 STUB_CLAUDE_RESULT="You've hit your session limit · resets 5pm" run $ANT
check "a session limit: claim is ERROR"             [ "$(verdict agy.c01-F1 verdict)" = ERROR ]
check "  after one call, no retry"                  [ "$(calls)" = claude ]
check "  reason says quota"                         grep -q quota "$W/verdicts/agy.c01-F1.json"

STUB_CLAUDE_STATUS=null STUB_CLAUDE_RESULT="You've hit your weekly limit" run $ANT
check "the limit's wording alone is enough"         [ "$(calls)" = claude ]

claims anthropic.c01-F1 > "$SB/f.json"
run $ANT --cross
check "--cross never asks claude about a claude finding" [ "$(calls)" = gemini-x ]

claims agy.c01-F1 > "$SB/f.json"
STUB_CLAUDE_STATUS=429 run $ANT --cross
check "claude spent, agy finding: never gemini"     [ "$(calls)" = claude ]
unset PR_REVIEW_GEMINI_MODEL PR_REVIEW_REFUTER_FALLBACK

echo "config file"
claims anthropic.c01-F1 > "$SB/f.json"
printf 'OLLAMA_API_KEY=from-config\n' > "$SB/config.env"; chmod 600 "$SB/config.env"
( unset OLLAMA_API_KEY; REVIEW_SKILLS_CONFIG="$SB/config.env" STUB_TOKEN_LOG="$SB/token" run $OLL; exit "$RC" )
check "the ollama key can come from the config file" [ "$?" = 0 ]
check "  and reaches the transport"                 [ "$(cat "$SB/token" 2>/dev/null)" = from-config ]

[ "$fail" = 0 ] && echo "all passed" || { echo FAILURES; cat "$SB/out"; }
exit "$fail"
