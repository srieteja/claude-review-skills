#!/usr/bin/env bash
# Unit checks for lib/models.sh: which finders and refuter a preset resolves to, from the
# backends this machine can reach. claude, agy and curl are stubbed; nothing leaves the box.
set -euo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SB="$(mktemp -d "${TMPDIR:-/tmp}/models-test.XXXXXX")"; trap 'rm -rf "$SB"' EXIT
fail=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=1; }
check() { desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }

mkdir -p "$SB/bin" "$SB/log"
cat > "$SB/bin/claude" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG/claude"
[ "$1 $2" = "auth status" ] || exit 64
if [ "${STUB_CLAUDE:-}" = in ]; then echo '{"loggedIn":true,"authMethod":"claude.ai"}'
else echo '{"loggedIn":false}'; exit 1; fi
STUB
cat > "$SB/bin/agy" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG/agy"
[ "$1" = models ] || exit 64
[ "${STUB_AGY:-}" = in ] || { echo "not signed in" >&2; exit 1; }
printf 'Fetching models...\n'
printf 'gemini-3.8-flash-high\tGemini 3.8 Flash (high)\ngemini-3.8-pro\tGemini 3.8 Pro\n'
STUB
# ollama.com lists its models to anyone; only a call with the key proves the key.
cat > "$SB/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG/curl"
case "$*" in
  */v1/models*) printf '{"data":[%s]}' "$(printf '%s' "${STUB_OLLAMA_IDS-glm-5.3 glm-5.3-flash kimi-k3}" \
                  | tr ' ' '\n' | sed 's/.*/{"id":"&"}/' | paste -sd, -)" ;;
  */v1/messages*) cat > /dev/null; printf '%s' "${STUB_OLLAMA_CODE:-200}" ;;
  *) exit 64 ;;
esac
STUB
chmod +x "$SB/bin/"*

# res <preset> [VAR=val...]: resolves in a clean shell; prints "finders | refuter | same | claude".
CACHE="$SB/cache"
res() { local p="$1"; shift
  env -i HOME="$SB/home" PATH="$SB/bin:$PATH" STUB_LOG="$SB/log" REVIEW_SKILLS_CONFIG=/nonexistent \
    REVIEW_SKILLS_CACHE="$CACHE" "$@" \
    bash -c '. "$1"; resolve_models "$2" || exit $?; echo "$RESOLVED_FINDERS | $RESOLVED_REFUTER | $SAME_FAMILY | $CLAUDE_OK"' \
    _ "$HERE/common.sh" "$p"; }
is() { local want="$1"; shift; test "$(res "$@" 2>/dev/null)" = "$want"; }
fresh() { rm -rf "$CACHE" "$SB/log"; mkdir -p "$SB/log"; }
calls() { if [ -f "$SB/log/$1" ]; then wc -l < "$SB/log/$1" | tr -d ' '; else echo 0; fi; }
ALL=(STUB_CLAUDE=in STUB_AGY=in OLLAMA_API_KEY=k-oll)
REG_DEFAULT="anthropic:claude-opus-5-5@xhigh | agy:gemini-3.8-flash-high | 0 | 1"
INT_DEFAULT="anthropic:claude-opus-5-5@max agy:gemini-3.8-flash-high | ollama:glm-5.3-flash | 0 | 1"

echo "manual"
fresh
check "regular: the rank-1 rows, today's defaults" is "$REG_DEFAULT" regular REVIEW_SKILLS_MODELS=manual
check "intense: the rank-1 rows, today's defaults" is "$INT_DEFAULT" intense REVIEW_SKILLS_MODELS=manual
check "  no backend is probed" test "$(calls claude)$(calls agy)$(calls curl)" = 000

echo "auto, every backend reachable"
fresh
check "regular resolves to today's defaults" is "$REG_DEFAULT" regular "${ALL[@]}"
fresh
check "intense resolves to today's defaults" is "$INT_DEFAULT" intense "${ALL[@]}"
check "  the ollama key is proven with a call to the model, not the open list" \
  grep -q 'v1/messages' "$SB/log/curl"
check "  the key never on argv" sh -c '! grep -q k-oll "$1"' _ "$SB/log/curl"
fresh
check "auto is the default" is "$REG_DEFAULT" regular "${ALL[@]}" REVIEW_SKILLS_MODELS=

echo "auto, some backends"
fresh
check "claude only: a sonnet refuter, flagged same-family" \
  is "anthropic:claude-opus-5-5@xhigh | anthropic:claude-sonnet-5-5 | 1 | 1" regular STUB_CLAUDE=in
fresh
check "agy only: gemini finds, gemini refutes, flagged" \
  is "agy:gemini-3.8-flash-high | agy:gemini-3.8-flash-high | 1 | 0" regular STUB_AGY=in
fresh
check "ollama only: glm finds, glm-flash refutes, flagged" \
  is "ollama:glm-5.3 | ollama:glm-5.3-flash | 1 | 0" regular OLLAMA_API_KEY=k-oll
fresh
check "claude + ollama, intense: one finder, glm refutes" \
  is "anthropic:claude-opus-5-5@max | ollama:glm-5.3-flash | 0 | 1" intense STUB_CLAUDE=in OLLAMA_API_KEY=k-oll
fresh
check "claude + agy, intense: gemini refutes rather than finds -- no third family to refute two" \
  is "anthropic:claude-opus-5-5@max | agy:gemini-3.8-flash-high | 0 | 1" intense STUB_CLAUDE=in STUB_AGY=in
fresh
check "a model ollama does not list is skipped" \
  is "anthropic:claude-opus-5-5@max | agy:gemini-3.8-flash-high | 0 | 1" \
  intense "${ALL[@]}" STUB_OLLAMA_IDS="glm-5.3 kimi-k3"
fresh
check "a key ollama refuses counts as no ollama" \
  is "anthropic:claude-opus-5-5@xhigh | agy:gemini-3.8-flash-high | 0 | 1" regular STUB_CLAUDE=in STUB_AGY=in OLLAMA_API_KEY=bad STUB_OLLAMA_CODE=401
check "  and is not cached" test ! -e "$CACHE/ollama.models"
fresh
check "ANTHROPIC_USE_API_KEY=1 with a key: claude is ready without a login check" \
  is "anthropic:claude-opus-5-5@xhigh | anthropic:claude-sonnet-5-5 | 1 | 1" regular ANTHROPIC_USE_API_KEY=1 ANTHROPIC_API_KEY=k
check "  claude auth status is never asked" test "$(calls claude)" = 0

echo "no backend"
fresh
out="$(res regular 2>&1)" && rc=0 || rc=$?
check "fails" test "$rc" -ne 0
check "  naming every way in" sh -c 'printf "%s" "$1" | grep -q "claude" && printf "%s" "$1" | grep -q "agy" && printf "%s" "$1" | grep -q OLLAMA_API_KEY' _ "$out"
check "  and the config file" sh -c 'printf "%s" "$1" | grep -q "config.env\|/nonexistent"' _ "$out"

echo "cache"
fresh
res regular "${ALL[@]}" >/dev/null 2>&1 || true
check "a reachable backend's model list is cached" test -s "$CACHE/agy.models"
check "  so a second run asks agy nothing" \
  is "$REG_DEFAULT" regular STUB_CLAUDE=in STUB_AGY=out OLLAMA_API_KEY=k-oll
check "  (agy asked once)" test "$(calls agy)" = 1
touch -t 200001010000 "$CACHE/agy.models"
check "a day-old list is asked again" \
  is "anthropic:claude-opus-5-5@xhigh | ollama:glm-5.3-flash | 0 | 1" regular STUB_CLAUDE=in STUB_AGY=out OLLAMA_API_KEY=k-oll
check "  and, unreachable now, dropped" test ! -e "$CACHE/agy.models"
fresh
res regular STUB_CLAUDE=in >/dev/null 2>&1 || true
check "an unreachable backend is not cached" test ! -e "$CACHE/agy.models"
check "  so it is asked again next run" is "$REG_DEFAULT" regular "${ALL[@]}"
check "the cache defaults under XDG_CACHE_HOME" \
  test "$(env -i HOME=/h PATH="$PATH" XDG_CACHE_HOME=/x bash -c '. "$1"; models_cache' _ "$HERE/common.sh")" = /x/review-skills

echo "pins"
fresh
check "PR_REVIEW_FINDERS pins regular's finders" \
  is "ollama:kimi-k3 | agy:gemini-3.8-flash-high | 0 | 1" regular "${ALL[@]}" PR_REVIEW_FINDERS=ollama:kimi-k3
check "PR_REVIEW_REFUTER pins regular's refuter" \
  is "anthropic:claude-opus-5-5@xhigh | ollama:kimi-k3 | 0 | 1" regular "${ALL[@]}" PR_REVIEW_REFUTER=ollama:kimi-k3
check "intense ignores the regular pins" \
  is "$INT_DEFAULT" intense "${ALL[@]}" PR_REVIEW_FINDERS=ollama:kimi-k3 PR_REVIEW_REFUTER=ollama:kimi-k3
check "PR_REVIEW_INTENSE_FINDERS / _REFUTER pin intense" \
  is "agy:gemini-x | anthropic:claude-y | 0 | 1" intense "${ALL[@]}" PR_REVIEW_INTENSE_FINDERS=agy:gemini-x PR_REVIEW_INTENSE_REFUTER=anthropic:claude-y
check "the old single-finder knobs still pin" \
  is "ollama:m@high | agy:gemini-3.8-flash-high | 0 | 1" regular "${ALL[@]}" PR_REVIEW_TRANSPORT=ollama PR_REVIEW_S1_MODEL=m PR_REVIEW_S1_EFFORT=high
check "PR_REVIEW_OPUS_MODEL is the old name for S1_MODEL" \
  is "anthropic:claude-o@xhigh | agy:gemini-3.8-flash-high | 0 | 1" regular "${ALL[@]}" PR_REVIEW_OPUS_MODEL=claude-o
check "PR_REVIEW_GEMINI_MODEL pins an agy refuter" \
  is "anthropic:claude-opus-5-5@xhigh | agy:gemini-g | 0 | 1" regular "${ALL[@]}" PR_REVIEW_GEMINI_MODEL=gemini-g
fresh
check "a pinned pair needs no probe" \
  is "ollama:a | agy:b | 0 | 1" regular PR_REVIEW_FINDERS=ollama:a PR_REVIEW_REFUTER=agy:b REVIEW_SKILLS_MODELS=manual
check "a pinned refuter of a finder's family is flagged" \
  is "anthropic:claude-opus-5-5@xhigh | anthropic:claude-z | 1 | 1" regular "${ALL[@]}" PR_REVIEW_REFUTER=anthropic:claude-z

echo "families"
fam() { test "$(env -i PATH="$PATH" HOME=/h bash -c '. "$1"; model_family "$2"' _ "$HERE/common.sh" "$1")" = "$2"; }
check "claude-* is anthropic" fam anthropic:claude-opus-5-5@max anthropic
check "gemini-* is google" fam agy:gemini-3.8-flash-high google
check "gemma over ollama is google too" fam ollama:gemma4:27b google
check "anything else is its name's first word" fam ollama:glm-5.3-flash glm
check "  with a tag dropped" fam ollama:gpt-oss:120b gpt

[ "$fail" -eq 0 ] && printf '\n\033[32mall models checks passed\033[0m\n' || printf '\n\033[31mmodels checks FAILED\033[0m\n'
exit $fail
