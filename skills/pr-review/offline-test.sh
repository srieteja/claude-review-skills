#!/usr/bin/env bash
# Exercises stage 1 slicing, id namespacing, gap reporting, caching, and the merge —
# with both models stubbed, so it costs nothing and can run on every edit.
#
# What it cannot test: whether the models are any good. That is selftest.sh (discrimination)
# and the T6 end-to-end run. This tests the plumbing those two depend on.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REVIEW_SKILLS_CONFIG=/nonexistent/review-skills-config
unset OLLAMA_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY ANTHROPIC_USE_API_KEY
# Templated on purpose: BSD mktemp -d with no template ignores TMPDIR and lands in the
# per-user /var/folders dir, which is unwritable under a Seatbelt sandbox.
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/pr-review-test.XXXXXX")"
. "$HERE/test-fixture.sh"
. "$HERE/test-lib.sh"
fixture_repo "$SANDBOX/fixture"
cd "$FIXTURE_ROOT"
PIN_PR=7; AUTHOR=alice
export TMPDIR="$SANDBOX"                           # keeps the slice cache out of the real one
# The review store is redirected into the sandbox, so the test never touches a real store.
export PR_REVIEW_DIR="$SANDBOX/reviews"
export PR_REVIEW_INTENSE_DIR="$SANDBOX/reviews-intense"
export PR_REVIEW_CHUNK_BYTES=1200
export STUB_LOG="$SANDBOX/log"
export REVIEW_SKILLS_LOCK_DIR="$SANDBOX/locks"
# Every preset takes its first models.tsv rows; lib/models-test.sh covers auto resolution.
export REVIEW_SKILLS_MODELS=manual REVIEW_SKILLS_CACHE="$SANDBOX/models-cache"
REPORT="$PR_REVIEW_DIR/$AUTHOR/widgets/$PIN_PR/pr${PIN_PR}-review.md"
BRIEF="$PR_REVIEW_DIR/$AUTHOR/widgets/$PIN_PR/pr${PIN_PR}-explainer.md"
INLINE="$PR_REVIEW_DIR/$AUTHOR/widgets/$PIN_PR/inline.json"
IREPORT="$PR_REVIEW_INTENSE_DIR/$AUTHOR/widgets/$PIN_PR/pr${PIN_PR}-review.md"
IMERGED="$PR_REVIEW_INTENSE_DIR/$AUTHOR/widgets/$PIN_PR/merged.json"
IBRIEF="$PR_REVIEW_INTENSE_DIR/$AUTHOR/widgets/$PIN_PR/pr${PIN_PR}-explainer.md"

fail=0
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=1; }
check() { desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }
# Stub logs are "$STUB_LOG/<kind>.<suffix>". logged/never: some/no log of a kind has a line
# matching the ERE. every: at least one log of that kind exists, and all of them match.
# Files, not cat | grep -q: under pipefail, grep quitting at its first match can SIGPIPE a
# cat that is still writing, and a check that found what it wanted fails anyway.
logged() { grep -qE -- "$2" "$STUB_LOG/$1".* 2>/dev/null; }
never()  { ! logged "$@"; }
# absent <file> <ere>: the pattern is nowhere in the file. Note grep -qv is NOT this -- it
# succeeds on the first line that does not match, so it passes even when the pattern is there.
absent() { ! grep -qE -- "$2" "$1" 2>/dev/null; }
nolog()  { ! ls "$STUB_LOG/$1".* >/dev/null 2>&1; }
every()  { ls "$STUB_LOG/$1".* >/dev/null 2>&1 || return 1
           for f in "$STUB_LOG/$1".*; do grep -qE -- "$2" "$f" || return 1; done; }

mkdir -p "$SANDBOX/stub" "$STUB_LOG"
cat > "$SANDBOX/stub/log.sh" <<'STUB'
# One log per call: cwd, the env that routes it, then every argv entry except the prompt.
stub_log() {
  f="$(mktemp "$STUB_LOG/$1.XXXXXX")"; shift
  { echo "cwd=$(pwd -P)"
    echo "CLAUDE_CODE_SIMPLE=${CLAUDE_CODE_SIMPLE:-}"
    echo "ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL:-}"
    echo "auth=${ANTHROPIC_AUTH_TOKEN:-}"
    env | grep -oE '^(ANTHROPIC_API_KEY|OLLAMA_API_KEY|GEMINI_API_KEY)=' | sed 's/^/key:/; s/=$//' || true
    for a in "$@"; do [ ${#a} -gt 200 ] || echo "arg=$a"; done
  } > "$f"
}
claim_id() { printf '%s\n' "$1" | sed -n 's/.*"id"[: ]*"\([^"]*\)".*/\1/p' | head -1; }
STUB
cat > "$SANDBOX/stub/claude" <<'STUB'
#!/usr/bin/env bash
. "$(dirname "$0")/log.sh"
if [ "$1 $2" = "auth status" ]; then
  [ -z "${STUB_CLAUDE_OUT:-}" ] || { echo '{"loggedIn":false}'; exit 1; }
  echo '{"loggedIn":true}'; exit 0
fi
prompt=""; schema=""; prev=""
for a in "$@"; do
  if [ "$prev" = --json-schema ]; then schema="$a"
  else case "$a" in -*) ;; *) [ ${#a} -gt 200 ] && prompt="$a" ;; esac; fi
  prev="$a"
done
if [ -n "$schema" ]; then
  stub_log claude-refute "$@"
  id="$(claim_id "$prompt")"
  printf '%s\n' "$prompt" > "$STUB_LOG/prompt.$id"
  printf '%s\n' "$schema" > "$STUB_LOG/schema.$id"
  case "$id" in agy.c01*) v=REFUTED ;; anthropic.*) v=CONFIRMED ;; *) v=UNVERIFIABLE ;; esac
  printf '[{"type":"system","subtype":"init"},{"type":"result","subtype":"success","structured_output":{"id":"%s","verdict":"%s","evidence":"stub.dart:1","reason":"stub"}},{"type":"system","subtype":"after"}]\n' "$id" "$v"
  exit 0
fi
# The brief is the one claude call with no schema and no findings target. Match it before
# the finder branch, which would otherwise write its stub findings to an empty path.
case "$prompt" in
  *"fails to parse in mermaid"*)
    # diagram.sh's one repair call: answers with the block quoted.
    stub_log claude-repair "$@"
    printf '[{"type":"result","is_error":false,"result":"```mermaid\\nflowchart LR\\n  subgraph S[\\"S §1\\"]\\n  end\\n```\\n"}]\n'
    exit 0 ;;
  *"plain-language brief"*)
    stub_log claude-brief "$@"
    body="### What this PR does"
    i=0
    while [ $i -lt 12 ]; do
      body="$body\\n- stub brief bullet $i, padding the result past the length guard"
      i=$((i + 1))
    done
    # The diagram: valid by default, an unquoted § subgraph title (mermaid can't lex it)
    # when STUB_DIAGRAM=bad.
    if [ "${STUB_DIAGRAM:-ok}" = bad ]; then diag='flowchart LR\n  subgraph S §1\n  end'
    else diag='flowchart LR\n  A --> B'; fi
    body="$body\\n\\n\`\`\`mermaid\\n$diag\\n\`\`\`"
    # --output-format json comes in both shapes: a transcript array by default, the bare
    # result object when STUB_BARE is set. The array has an event after its result, so a
    # read that takes the last element instead of the result event comes up empty.
    result="{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"$body\"}"
    if [ -n "${STUB_BARE:-}" ]; then printf '%s\n' "$result"
    else printf '[{"type":"system","subtype":"init"},%s,{"type":"system","subtype":"after"}]\n' "$result"; fi
    exit 0 ;;
esac
stub_log claude-find "$@"
out="$(printf '%s\n' "$prompt" | sed -n 's|^Write your findings to \([^ ]*\) as JSON.*|\1|p' | head -1)"
diff="$(printf '%s\n' "$prompt" | sed -n 's|.*The diff under review is at \([^ ]*\) and.*|\1|p' | head -1)"
key="$(basename "${out%.json}")"
# STUB_ORDER: one "key diff-bytes" line per slice, in the order slices start.
[ -z "${STUB_ORDER:-}" ] || echo "$key $(wc -c < "$diff" | tr -d ' ')" >> "$STUB_ORDER"
if [ -n "${STUB_QUOTA:-}" ]; then
  case "$key" in *c01)
    qtext="${STUB_QUOTA_TEXT:-}"; [ -n "$qtext" ] || qtext="You've hit your session limit · resets ${STUB_QUOTA_WHEN:-12:30am (Asia/Calcutta)}"
    ev="$(printf '{"type":"result","subtype":"success","is_error":true,"api_error_status":%s,"num_turns":1,"result":"%s"}' "${STUB_QUOTA_STATUS:-429}" "$qtext")"
    # STUB_QUOTA_RESETSAT: a transcript whose rejected window carries that resetsAt, as a login's CLI reports it.
    if [ -n "${STUB_QUOTA_RESETSAT:-}" ]; then
      printf '[{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":%s}},%s]\n' "$STUB_QUOTA_RESETSAT" "$ev"
    else printf '%s\n' "$ev"; fi
    exit 1 ;; esac
  sleep 4711; exit 1
fi
[ -z "${STUB_CLAUDE_FAIL:-}" ] || { echo '{"type":"result","subtype":"error_max_turns","num_turns":9}'; exit 1; }
if [ -n "${STUB_EMPTY:-}" ]; then
  chk="$(sed -n 's|^diff --git a/.* b/||p' "$diff" | jq -R '. + ": traced callers"' | jq -sc .)"
  [ -z "${STUB_NOCHECK:-}" ] || chk='[]'
  printf '{"findings":[],"read":["x"],"checked":%s}\n' "$chk" > "$out"; echo '{"type":"result","result":"0"}'; exit 0
fi
case "$key" in *c02)
  echo 'stub: simulated limit at /Users/someone/private/path' >&2
  echo '{"type":"result","subtype":"error_during_execution","num_turns":3,"total_cost_usd":0.42}'; exit 1 ;; esac
# A test slice records what context it was handed: how many feature findings the file it was
# pointed at holds, and whether the brief it was pointed at exists.
case "$key" in *t[0-9][0-9])
  ff="$(printf '%s\n' "$prompt" | sed -n 's|.*feature review.s findings are at \([^ ]*\) .*|\1|p' | head -1)"
  br="$(printf '%s\n' "$prompt" | sed -n 's|.*The brief is at \([^ ]*\) .*|\1|p' | head -1)"
  { echo "n=$(jq '.findings|length' "$ff" 2>/dev/null || echo missing)"
    if [ -s "$br" ]; then echo brief=yes; else echo brief=none; fi
  } > "$(mktemp "$STUB_LOG/tctx.XXXXXX")" ;;
esac
# STUB_HOLD: stay live for that long, recording how many slices are live at once.
if [ -n "${STUB_HOLD:-}" ]; then
  mkdir -p "$STUB_LOG/live"; : > "$STUB_LOG/live/$$"
  ls "$STUB_LOG/live" | wc -l | tr -d ' ' >> "$STUB_LOG/maxlive.n"
  sleep "$STUB_HOLD"; rm -f "$STUB_LOG/live/$$"
fi
case "$key" in
  *_cross) sleep "${STUB_SLOW_CROSS:-0}" ;;
  *c[0-9][0-9]) sleep "${STUB_SLOW_FEATURES:-0}" ;;
esac
sleep "${STUB_SLOW_CLAUDE:-0}"
first="$(sed -n 's|^+++ b/||p' "$diff" | head -1)"
printf '{"findings":[{"id":"%s","file":"%s","line":42,"severity":"medium","claim":"stub %s","mechanism":"stub","repro":"stub"}]}\n' \
  "${STUB_ID:-F1}" "$first" "$key" > "$out"
echo '{"type":"result","result":"1"}'
STUB
cat > "$SANDBOX/stub/agy" <<'STUB'
#!/usr/bin/env bash
. "$(dirname "$0")/log.sh"
p=""; schema=""; prev=""
for a in "$@"; do
  case "$a" in -p=*) p="${a#-p=}" ;; esac
  [ "$prev" = --json-schema ] && schema="$a"
  prev="$a"
done
# What lib/models.sh probes: the models agy serves, or nothing when STUB_AGY_DOWN is set.
if [ "${1:-}" = models ]; then
  [ -z "${STUB_AGY_DOWN:-}" ] || { echo "not signed in" >&2; exit 1; }
  printf 'gemini-3.8-flash-high\tGemini 3.8 Flash (high)\n'; exit 0
fi
case "$schema" in
  *findings.schema.json)
    stub_log agy-find "$@"
    diff="$(printf '%s\n' "$p" | sed -n 's|.*The diff under review is at \([^ ]*\) and.*|\1|p' | head -1)"
    first="$(sed -n 's|^+++ b/||p' "$diff" | head -1)"
    # Real agy reports a spent model on stderr only; the stdout envelope has no is_error.
    if [ -n "${STUB_AGY_QUOTA:-}" ]; then
      echo 'AGY_ERROR: {"short_error":"RESOURCE_EXHAUSTED (code 429): Individual quota reached.","status":"RESOURCE_EXHAUSTED","error_code":429}' >&2
      echo '{"status":"ERROR","response":"read a file"}'; exit 1
    fi
    # A delivered run whose stderr merely mentions a spent quota: exit 0, findings in the envelope.
    [ -z "${STUB_AGY_NOISE:-}" ] || echo 'AGY_ERROR: {"short_error":"RESOURCE_EXHAUSTED (code 429): quota mentioned by the model","error_code":429}' >&2
    if [ -n "${STUB_EMPTY:-}" ]; then
      chk="$(sed -n 's|^diff --git a/.* b/||p' "$diff" | jq -R '. + ": traced callers"' | jq -sc .)"
      printf '{"structured_output":{"findings":[],"read":["%s"],"checked":%s}}\n' "$first" "$chk"; exit 0
    fi
    printf '{"structured_output":{"findings":[{"id":"F1","file":"%s","line":44,"severity":"low","claim":"stub agy","mechanism":"stub","repro":"stub"}],"read":["%s"]}}\n' \
      "$first" "$first"
    ;;
  *)
    stub_log agy-refute "$@"
    id="$(claim_id "$p")"
    printf '%s\n' "$p" > "$STUB_LOG/prompt.$id"
    case "$id" in c01*|c03*) v=REFUTED ;; *) v=CONFIRMED ;; esac
    printf '{"structured_output":{"id":"%s","verdict":"%s","evidence":"stub.dart:1","reason":"stub"}}\n' "$id" "$v"
    ;;
esac
STUB
# Stage 5's autofix, stubbed for every run, so a fix author's review never opens a real PR. Logs its mode, reviewer and argv; answers STUB_AUTOFIX_STATUS.
cat > "$SANDBOX/stub/autofix" <<'STUB'
#!/usr/bin/env bash
f="$(mktemp "$STUB_LOG/autofix.XXXXXX")"
lane="${AUTOFIX_LANE:-stacked}"; echo "$lane" >> "$STUB_LOG/lanes"
{ echo "MODE=${AUTOFIX_MODE:-}"; echo "LANE=$lane"; echo "REVIEWER=${AUTOFIX_REVIEWER:-}"; for a; do echo "arg=$a"; done; } > "$f"
# STUB_AUTOFIX_STATUS_<lane> answers that lane alone, over STUB_AUTOFIX_STATUS.
eval "st=\${STUB_AUTOFIX_STATUS_$lane:-\${STUB_AUTOFIX_STATUS:-opened:https://github.com/acme/widgets/pull/99}}"
echo "STATUS=$st"
exit "${STUB_AUTOFIX_RC:-0}"
STUB
chmod +x "$SANDBOX/stub/claude" "$SANDBOX/stub/agy" "$SANDBOX/stub/autofix"
export PR_REVIEW_AUTOFIX="$SANDBOX/stub/autofix"
unset PR_REVIEW_FIX_AUTHORS PEER_REVIEW_FIX_AUTHORS AUTOFIX_MODE AUTOFIX_LANE AUTOFIX_LINT

# ------------------------------------------------------------------- jq filters
# Pure, so checked on fixtures before any stubbed run.
echo "jq filters"
last_event() { printf '%s' "$1" | jq -c -L "$HERE" 'include "last-event"; last_event | .r'; }
check "a bare result object is its own last event" \
  test "$(last_event '{"type":"result","r":1}')" = 1
check "a transcript is read at its result event" \
  test "$(last_event '[{"type":"system","r":0},{"type":"result","r":2}]')" = 2
check "an event after the result does not hide it" \
  test "$(last_event '[{"type":"result","r":3},{"type":"system","r":0}]')" = 3
check "a transcript with no result event falls back to its last" \
  test "$(last_event '[{"type":"system","r":4}]')" = 4

# slice_unchecked: a changed file is covered only by a "checked" entry that is its path, or its
# path then a colon and anything -- not by a longer path or a mention that merely contains it.
echo "coverage matching"
unchecked() { # <checked-json-array>: the files of a one-file diff the entry leaves uncovered
  printf 'diff --git a/lib/a.dart b/lib/a.dart\n' > "$SANDBOX/cov.diff"
  printf '{"findings":[],"read":["x"],"checked":%s}\n' "$1" > "$SANDBOX/cov.json"
  bash -c "$(sed -n '/^slice_unchecked()/,/^}/p' "$HERE/pr-review.sh"); slice_unchecked \"\$1\" \"\$2\"" _ "$SANDBOX/cov.json" "$SANDBOX/cov.diff"
}
check "an entry of path: text covers the file" test -z "$(unchecked '["lib/a.dart: traced callers"]')"
check "  and the bare path does too" test -z "$(unchecked '["lib/a.dart"]')"
check "lib/a.dart.bak does not cover lib/a.dart" test "$(unchecked '["lib/a.dart.bak: looked"]')" = lib/a.dart
check "  nor does a longer path ending in it" test "$(unchecked '["xlib/a.dart: looked"]')" = lib/a.dart
check "  nor a mention inside the text" test "$(unchecked '["notes: also see lib/a.dart"]')" = lib/a.dart

# quota_hit: a limit is reported by an error event, never by a successful result's own text.
quota() { printf '%s' "$1" | jq -r -L "$HERE" 'include "last-event"; quota_hit // "none"'; }
check "quota_hit: a successful result saying it hit a usage limit is not a quota hit" \
  test "$(quota '{"type":"result","subtype":"success","is_error":false,"result":"you hit your usage limit"}')" = none
check "  nor one with is_error absent" \
  test "$(quota '{"type":"result","result":"You hit your session limit"}')" = none
check "  nor in a transcript array" \
  test "$(quota '[{"type":"result","is_error":false,"result":"usage limit reached"}]')" = none
check "  an is_error result with that wording and no reset time is not" \
  test "$(quota '{"type":"result","is_error":true,"result":"You hit your session limit"}')" = none
check "  with a reset time it is" \
  test "$(quota '{"type":"result","is_error":true,"result":"You hit your session limit · resets 9:20pm (UTC)"}')" = "You hit your session limit · resets 9:20pm (UTC)"
check "  a reset in a zone it cannot read still counts as named" \
  test "$(quota '{"type":"result","is_error":true,"result":"hit your usage limit · resets 12:30am (Asia/Calcutta)"}')" != none
check "  a rejected window in the transcript names the reset" \
  test "$(quota '[{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":99}},{"type":"result","is_error":true,"result":"hit your 5-hour limit"}]')" = "hit your 5-hour limit"
check "  an is_error 429 is, whatever it says" \
  test "$(quota '{"type":"result","is_error":true,"api_error_status":429,"result":"slow down"}')" = "slow down"
check "  an is_error result with neither a status nor the wording is not" \
  test "$(quota '{"type":"result","is_error":true,"result":"boom"}')" = none
check "  a 429 in a successful result is not" \
  test "$(quota '{"type":"result","is_error":false,"api_error_status":429,"result":"x"}')" = none
# The wording fires on a result event only: never on what the model said along the way.
check "  an assistant text saying it, then a successful result, is not" \
  test "$(quota '[{"type":"assistant","message":{"content":[{"type":"text","text":"You'"'"'ve hit your limit · resets 9pm (UTC)"}]}},{"type":"result","is_error":false,"result":"done"}]')" = none
check "  nor an is_error assistant event when no result event follows" \
  test "$(quota '[{"type":"assistant","is_error":true,"result":"You hit your limit · resets 9:20pm (UTC)"}]')" = none
check "  nor the reset time in that text" \
  test "$(printf '%s' '[{"type":"assistant","is_error":true,"result":"hit your limit · resets 9:20pm (UTC)"}]' | jq -r -L "$HERE" 'include "last-event"; quota_reset // "none"')" = none
check "  nor is it an auth failure" \
  test "$(printf '%s' '[{"type":"assistant","is_error":true,"api_error_status":401,"result":"x"}]' | jq -r -L "$HERE" 'include "last-event"; auth_hit // "none"')" = none
check "  an is_error 402 is not: unpaid is a billing failure" \
  test "$(quota '{"type":"result","is_error":true,"api_error_status":402,"result":"pay up"}')" = none
check "  an is_error 401 is not: that is a sign-in problem" \
  test "$(quota '{"type":"result","is_error":true,"api_error_status":401,"result":"x"}')" = none
check "  nor an is_error 403" \
  test "$(quota '{"type":"result","is_error":true,"api_error_status":403,"result":"x"}')" = none
auth() { printf '%s' "$1" | jq -r -L "$HERE" 'include "last-event"; auth_hit // "none"'; }
check "auth_hit: an is_error 402 is" \
  test "$(auth '{"type":"result","is_error":true,"api_error_status":402,"result":"pay up"}')" = "pay up"
check "  an is_error 401 is" \
  test "$(auth '{"type":"result","is_error":true,"api_error_status":401,"result":"not signed in"}')" = "not signed in"
check "  an is_error 403 is" \
  test "$(auth '{"type":"result","is_error":true,"api_error_status":403,"result":"forbidden"}')" = forbidden
check "  a 401 in a successful result is not" \
  test "$(auth '{"type":"result","is_error":false,"api_error_status":401,"result":"x"}')" = none
check "  a 429 is not" \
  test "$(auth '{"type":"result","is_error":true,"api_error_status":429,"result":"x"}')" = none

# safe_id / valid_id: finding ids name files, so they are restricted to [A-Za-z0-9._-].
sid() { jq -nr -L "$HERE" --arg i "$1" 'include "finding-id"; $i | safe_id'; }
check "safe_id: an ordinary id is unchanged"      test "$(sid F1)" = F1
check "  a path becomes one file name"            test "$(sid '../../x')" = "____x"
check "  no slash survives"                       test "$(sid 'a/b\c')" = "a_b_c"
check "  no .. survives"                          test "$(sid 'a..b')" = "a_b"
check "  no leading dot"                          test "$(sid '.hidden')" = "_hidden"
check "  at most 64 characters"                   test "$(printf '%s' "$(sid "$(for ((_n=0;_n<100;_n++)); do printf a; done)")" | wc -c | tr -d ' ')" = 64
check "  empty is not empty"                      test "$(sid '')" = "_"
validid() { jq -nr -L "$HERE" --arg i "$1" 'include "finding-id"; $i | valid_id'; }
check "valid_id: a slice-prefixed id passes"      test "$(validid anthropic.c01-F1)" = true
check "  a path does not"                         test "$(validid '../../x')" = false
check "  a slash does not"                        test "$(validid 'a/b')" = false
check "  .. does not"                             test "$(validid 'a..b')" = false
check "  a leading dot does not"                  test "$(validid '.x')" = false
check "the schema states the same pattern" \
  jq -e '.properties.findings.items.properties.id.pattern == "^[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}$"' "$HERE/findings.schema.json"

# fix_lanes: which autofix lanes a review's CONFIRMED findings need, in run order.
lanes_of() { printf '%s' "$2" | jq -r -L "$HERE" --arg s "$1" 'include "lanes"; fix_lanes($s) | join(" ")'; }
F_INTRO='{"v":{"verdict":"CONFIRMED"},"route":"introduced"}'
F_PRE='{"v":{"verdict":"CONFIRMED"},"route":"pre-existing"}'
F_OLD='{"v":{"verdict":"CONFIRMED"}}'
F_REFUTED='{"v":{"verdict":"REFUTED"},"route":"pre-existing"}'
check "fix_lanes: OPEN, introduced only -> stacked"       test "$(lanes_of OPEN "[$F_INTRO]")" = stacked
check "  pre-existing only -> trunk"                      test "$(lanes_of OPEN "[$F_PRE]")" = trunk
check "  both -> stacked trunk"                           test "$(lanes_of OPEN "[$F_PRE,$F_INTRO]")" = "stacked trunk"
check "  unrouted (an earlier review) -> stacked"         test "$(lanes_of OPEN "[$F_OLD]")" = stacked
check "  a refuted pre-existing one needs no lane"        test "$(lanes_of OPEN "[$F_INTRO,$F_REFUTED]")" = stacked
check "  MERGED: every finding -> trunk"                  test "$(lanes_of MERGED "[$F_INTRO,$F_PRE]")" = trunk
check "  nothing confirmed -> none"                       test -z "$(lanes_of OPEN "[$F_REFUTED]")"

AGREE_IN='[{"id":"anthropic.c01-F1","file":"a.dart","line":10},
  {"id":"anthropic.c01-F2","file":"a.dart","line":11},
  {"id":"agy.c01-F1","file":"a.dart","line":13},
  {"id":"agy.c01-F2","file":"a.dart","line":14},
  {"id":"agy.c02-F1","file":"b.dart","line":10},
  {"id":"agy.c03-F1","file":"a.dart"}]'
agreed() { printf '%s' "$AGREE_IN" | jq -c -f "$HERE/agree.jq" | jq -c --arg id "$1" '.[] | select(.id == $id) | .also'; }
check "another finder 3 lines away is cited" test "$(agreed anthropic.c01-F1)" = '["agy.c01-F1"]'
check "every match is cited, in both directions" \
  test "$(agreed agy.c01-F1)" = '["anthropic.c01-F1","anthropic.c01-F2"]'
check "4 lines away is not agreement" test "$(agreed agy.c01-F2)" = '["anthropic.c01-F2"]'
check "a finder's own nearby finding is not agreement" \
  test "$(agreed anthropic.c01-F2)" = '["agy.c01-F1","agy.c01-F2"]'
check "the same line in another file is not agreement" test "$(agreed agy.c02-F1)" = '[]'
check "a finding with no line agrees with nothing, and does not fail the merge" \
  test "$(agreed agy.c03-F1)" = '[]'
check "agree.jq adds .also and changes nothing else" \
  test "$(printf '%s' "$AGREE_IN" | jq -c -f "$HERE/agree.jq" | jq -c 'map(del(.also))')" \
     = "$(printf '%s' "$AGREE_IN" | jq -c .)"
# The report, review body and inline comments: their own suite, fast enough to run alone.
check "render-test.sh: report, body and inline comments" "$HERE/render-test.sh"
check "diagram-test.sh: diagram.sh and diagram-backfill.sh" "$HERE/diagram-test.sh"
check "mermaid-check.test.mjs: parse and grounding" node --test "$HERE/mermaid-check.test.mjs"

echo "offline pipeline test — PR #$PIN_PR, both models stubbed"
STUB_SLOW_FEATURES=2 PATH="$SANDBOX/stub:$SANDBOX/fixture/gh:$PATH" "$HERE/pr-review.sh" "$PIN_PR" --no-cache > "$SANDBOX/run1.log" 2>&1 \
  || { cat "$SANDBOX/run1.log"; bad "first run exited non-zero"; exit 1; }

grep -q 'slice(s) + 1 cross-cutting pass' "$SANDBOX/run1.log" \
  && ok "diff was sliced, cross-cutting pass added" || bad "no slicing happened"
grep -q 'test file(s) in [0-9]* test slice(s)' "$SANDBOX/run1.log" \
  && ok "test files held out of the feature slices" || bad "tests were not held out"
# With a brief, the test pass needs nothing from the feature pass, so it starts with it.
check "test slices start with stage 1, not after it" awk '
  /    c[0-9][0-9] / { last = NR }
  /    t[0-9][0-9] / && !first { first = NR }
  END { exit !(first && last && first < last) }' "$SANDBOX/run1.log"
PR_REVIEW_CROSS_RE='\.nomatch$' PATH="$SANDBOX/stub:$SANDBOX/fixture/gh:$PATH" "$HERE/pr-review.sh" "$PIN_PR" --no-cache > "$SANDBOX/cross-re.log" 2>&1 || true
check "PR_REVIEW_CROSS_RE decides which files earn a cross-cutting pass" \
  grep -q 'no cross-cutting pass (nothing in the diff matches PR_REVIEW_CROSS_RE)' "$SANDBOX/cross-re.log"
check "stage messages carry a timestamp" grep -qE '==>.{0,8} [0-9]{2}:[0-9]{2}:[0-9]{2} stage 1:' "$SANDBOX/run1.log"
MERGED="$PR_REVIEW_DIR/$AUTHOR/widgets/$PIN_PR/merged.json"
check "test files were reviewed, in t-slices" \
  jq -e 'any(.[]; (.id | startswith("t")) and (.file | test("(^|/)tests?/|_test\\.dart$")))' "$MERGED"
check "the test pass was handed the brief" every tctx '^brief=yes'
check "  and no feature findings, which are still being written" every tctx '^n=missing$'
grep -q 'no findings from: c02' "$SANDBOX/run1.log" \
  && ok "failed slice reported as a coverage gap, run continued" || bad "a failed slice did not surface"
[ -f "$REPORT" ] && ok "report written despite the failed slice" || bad "no report written"
grep -q '⚠️ \*\*Incomplete' "$REPORT" \
  && ok "report carries the incomplete-coverage banner" || bad "banner missing from report"
FAILED_DIR="$PR_REVIEW_DIR/$AUTHOR/widgets/$PIN_PR/failed-slices"
for ext in json err prompt reason; do
  check "a failed slice keeps its .$ext evidence" test -s "$FAILED_DIR/c02.$ext"
done
check "the reason file carries the finder's stderr" grep -q 'simulated limit' "$FAILED_DIR/c02.reason"
check "the report names why the slice produced nothing" \
  grep -q '`c02`: error_during_execution after 3 turns' "$REPORT"
check "the finder's stderr stays out of the report" absent "$REPORT" 'simulated limit'
check "the finder's stderr stays out of the inline payload" absent "$INLINE" 'simulated limit'
touch "$FAILED_DIR/zz.reason"
grep -qE '^\| c0[0-9]-F1 ' "$REPORT" \
  && ok "finding ids are namespaced by slice" || bad "ids not namespaced — stage 3 join is unsafe"
grep -q '<details>' "$REPORT" \
  && ok "refuted findings kept in the collapsed section" || bad "refuted findings vanished"
check "the refuter ran inside the tree, not the caller's cwd" every agy-refute '^cwd=.*/tree$'
check "the default refuter prompt carries the strict burden" logged prompt 'Inability to confirm is a refutation'
check "the refuter judges the code at this head, not only what the PR introduced" \
  logged prompt 'asserted that the code at this head has a specific defect'
check "merged.json carries a route on every finding" \
  jq -e 'length > 0 and all(.[]; .route == "introduced" or .route == "pre-existing")' "$MERGED"
check "the report shows each finding's route" grep -qE '· (introduced|pre-existing)$' "$REPORT"
check "the default finder ran at medium" every claude-find '^arg=medium$'
check "the default finder is budget-capped" every claude-find '^arg=--max-budget-usd$'
check "the finder ran without your settings and hooks" every claude-find '^arg=--setting-sources$'

# ------------------------------------------------------------------ stage 0.5 brief
check "the brief was written beside the report" test -f "$BRIEF"
check "the brief ran on sonnet" every claude-brief '^arg=claude-sonnet-5-5$'
check "the brief ran at medium effort, same as the finder's default" every claude-brief '^arg=medium$'
check "the brief is guarded, not budgeted" every claude-brief '^arg=1\.00$'
check "the brief had no tools to wander with" every claude-brief '^arg=Read$'
check "the brief saw no local CLAUDE.md or skills" every claude-brief '^arg=--setting-sources$'
# The brief is for the reviewer, never the PR. $REPORT is what --post sends to GitHub and
# inline.json is what --inline sends; neither may carry a word of it.
check "the brief stayed out of the posted report" absent "$REPORT" 'stub brief bullet'
check "the brief stayed out of the inline payload" absent "$INLINE" 'stub brief bullet'
check "the report does not even name the brief" absent "$REPORT" 'explainer'
DIAG="${BRIEF%-explainer.md}-diagram"
check "the brief's diagram was checked" test "$(jq -r .status "$DIAG.json")" = ok
check "the checked diagram is beside the brief" grep -q 'A --> B' "$DIAG.mmd"
check "the diagram records the head it was drawn at" grep -q "$(jq -r .headRefOid "$(dirname "$BRIEF")/meta.json")" "$DIAG.json"
check "a diagram that parses costs no repair call" nolog claude-repair

PATH="$SANDBOX/stub:$SANDBOX/fixture/gh:$PATH" "$HERE/pr-review.sh" "$PIN_PR" > "$SANDBOX/run2.log" 2>&1 || true
[ "$(grep -c 'cached' "$SANDBOX/run2.log")" -ge 3 ] \
  && ok "second run resumed from cache" || bad "cache did not resume — a 429 would cost full price again"
check "a rerun clears the last run's failed-slice evidence" test ! -e "$FAILED_DIR/zz.reason"
check "  and records this run's" test -s "$FAILED_DIR/c02.reason"
grep -q 'c02     FAILED' "$SANDBOX/run2.log" \
  && ok "the failed slice was retried, not cached" || bad "a failed slice got cached"
check "the brief cache is keyed on brief.prompt, so editing the prompt misses it" \
  ls "$SANDBOX/pr-review-cache/brief-"*"-$(cksum < "$HERE/brief.prompt" | awk '{print $1}')-"*
check "a cached brief's diagram is checked again" test "$(jq -r .status "$DIAG.json")" = ok

# ------------------------------------------------------------- zero findings
# "**No findings.**" is what peer-review's approve gate trusts: it may only appear when the
# anthropic finder -- the one with measured recall -- actually finished a slice.
echo "zero findings — the headline names only finders that ran"
zero_run() { d="$SANDBOX/zero-$1"; shift
  env PR_REVIEW_DIR="$d" STUB_EMPTY=1 PATH="$SANDBOX/stub:$SANDBOX/fixture/gh:$PATH" \
    "$@" "$HERE/pr-review.sh" "$PIN_PR" --no-cache > "$d.log" 2>&1 || true
  ZREPORT="$d/$AUTHOR/widgets/$PIN_PR/pr${PIN_PR}-review.md"; }
zero_run anthropic
check "the anthropic finder ran: a plain No findings headline" grep -q '^\*\*No findings\.\*\* .* reviewed the diff' "$ZREPORT"
TWO=(PR_REVIEW_FINDERS="anthropic:claude-opus-5-5 agy:gemini-x" PR_REVIEW_REFUTER=agy:gemini-y)
zero_run both-ran "${TWO[@]}"
check "both finders ran: the headline names both" grep -q '^\*\*No findings\.\*\* claude-opus-5-5 + gemini-x via agy reviewed' "$ZREPORT"
zero_run nocheck STUB_NOCHECK=1
check "an empty result without \"checked\" fails its slice, naming a file" grep -q 'does not name' "$d.log"
check "  and when every slice does, the run dies instead of reporting a clean pass" grep -q 'every slice failed' "$d.log"
check "  a slice naming several files is rejected too (c04 and _cross)" \
  bash -c '! grep -q "c04     0 finding" "$1" && ! grep -q "_cross  0 finding" "$1"' _ "$d.log"
zero_run anthropic-failed "${TWO[@]}" STUB_CLAUDE_FAIL=1
check "every anthropic slice failed: no plain No findings headline" absent "$ZREPORT" '^\*\*No findings\.\*\*'
check "  the headline names only the finder that ran" grep -qx '\*\*No findings reported\*\* by gemini-x via agy\.' "$ZREPORT"
check "  and says the anthropic finder produced nothing" grep -q 'no result from the anthropic finder' "$ZREPORT"
echo '{"findings":[]}' > "$SANDBOX/empty-findings.json"
zero_run supplied
d="$SANDBOX/zero-supplied"
env PR_REVIEW_DIR="$d" PATH="$SANDBOX/stub:$SANDBOX/fixture/gh:$PATH" \
  "$HERE/pr-review.sh" "$PIN_PR" --findings "$SANDBOX/empty-findings.json" > "$d.log" 2>&1 || true
check "--findings: no claim that anything reviewed the diff" absent "$ZREPORT" 'reviewed the diff'
check "  no plain No findings headline" absent "$ZREPORT" '^\*\*No findings\.\*\*'
check "  the headline names the file it read" grep -q 'No findings.* in .*empty-findings.json' "$ZREPORT"

# ------------------------------------------------------------- quota fail-fast
# A session limit stops every slice on that account; waiting out the rest burns the stage-1
# timeout per slice for nothing.
echo "quota — the first session-limit result stops stage 1"
d="$SANDBOX/quota"; start=$SECONDS; rc=0
# Watchdog: without the fail-fast the run would wait out every slice; this ends them so a
# regression fails the timing check instead of hanging the suite.
( for ((_n=0;_n<30;_n++)); do sleep 2; pkill -f '[s]leep 4711'; done ) & watchdog=$!
env PR_REVIEW_DIR="$d" STUB_QUOTA=1 PR_REVIEW_STAGE1_JOBS=3 PATH="$SANDBOX/stub:$SANDBOX/fixture/gh:$PATH" \
  "$HERE/pr-review.sh" "$PIN_PR" --no-cache > "$d.log" 2>&1 || rc=$?
check "the run fails" test "$rc" -ne 0
check "  within seconds, not a slice timeout" test $((SECONDS - start)) -lt 30
check "  naming the limit and its reset" grep -q "hit your session limit · resets 12:30am" "$d.log"
check "  and no slice is left running" sh -c '! pgrep -f "[s]leep 4711" >/dev/null'
check "  and no report claims a review" test ! -e "$d/$AUTHOR/widgets/$PIN_PR/pr${PIN_PR}-review.md"
kill "$watchdog" 2>/dev/null || true; pkill -f '[s]leep 4711' 2>/dev/null || true

# ---------------------------------------------------------------- finding ids
echo "finding ids — a finder's id never becomes a path"
d="$SANDBOX/badid"
env PR_REVIEW_DIR="$d" STUB_ID='../../x' PATH="$SANDBOX/stub:$SANDBOX/fixture/gh:$PATH" \
  "$HERE/pr-review.sh" "$PIN_PR" --no-cache --no-brief > "$d.log" 2>&1 || true
BADMERGED="$(ls "$d/$AUTHOR/widgets/$PIN_PR/"*merged*.json 2>/dev/null | head -1)"
check "the run produced merged findings" test -n "$BADMERGED"
check "  no id holds a slash or .." sh -c "! grep -E '\"id\": ?\"[^\"]*(/|\\.\\.)' '$BADMERGED'"
check "  the sanitised id is kept, prefixed by its slice" grep -qE '"id": ?"[a-z.]*c0[0-9]-_+x"' "$BADMERGED"
check "  nothing was written outside the review store" test ! -e "$SANDBOX/x"

# The deferral says when the limit lifts: RESUME_AT=<reset + 60s> on stdout, beside STATUS=deferred,
# which is what peer-review passes through and the watcher pauses on. A reset with no date is
# today's, or tomorrow's once past; one that names no readable time (or zone) is the flat fallback.
echo "quota — stage 1 reports when the limit lifts"
quota_run() {  # quota_run <name> <reset text> -- stdout in $d.out, stderr in $d.log
  d="$SANDBOX/$1"; rc=0
  ( for ((_n=0;_n<30;_n++)); do sleep 2; pkill -f '[s]leep 4711'; done ) & watchdog=$!
  env PR_REVIEW_DIR="$d" STUB_QUOTA=1 STUB_QUOTA_WHEN="$2" AUTOFIX_DEFER_FALLBACK=1000 PR_REVIEW_STAGE1_JOBS=3 \
    PATH="$SANDBOX/stub:$SANDBOX/fixture/gh:$PATH" "$HERE/pr-review.sh" "$PIN_PR" --no-cache > "$d.out" 2> "$d.log" || rc=$?
  kill "$watchdog" 2>/dev/null || true; pkill -f '[s]leep 4711' 2>/dev/null || true
}
resume_at() { sed -n 's/^RESUME_AT=//p' "$d.out"; }
t=$(( $(date +%s) + 7200 ))
quota_run quota-at "$(clock "$t") (UTC)"
check "a reset time ahead: exits 75" test "$rc" -eq 75
check "  says STATUS=deferred on stdout" grep -qx 'STATUS=deferred' "$d.out"
check "  RESUME_AT is the reset plus a minute" test "$(resume_at)" = "$(( t - t % 60 + 60 ))"
t=$(( $(date +%s) - 7200 ))
quota_run quota-past "$(clock "$t") (UTC)"
check "a reset time already past today means tomorrow" test "$(resume_at)" = "$(( t - t % 60 + 86400 + 60 ))"
quota_run quota-nozone "12:30am (Asia/Calcutta)"
check "a reset in a zone it cannot read: exits 75" test "$rc" -eq 75
check "  RESUME_AT is the flat fallback" sh -c "t=\$(sed -n 's/^RESUME_AT=//p' '$d.out'); [ \$((t - \$(date +%s))) -ge 900 ] && [ \$((t - \$(date +%s))) -le 1100 ]"

# An account the finder is signed out of, or not authorised on, is not a limit that lifts: the
# run fails naming it, with no deferral and no resume time. So is a 402 (unpaid). A 429, or the
# limit's wording with a reset time, defers.
quota_run_as() {  # quota_run_as <name> <status> <text>
  STUB_QUOTA_STATUS="$2" STUB_QUOTA_TEXT="$3" quota_run "$1" x
}
quota_run_as auth-401 401 "Invalid authentication credentials"
check "a finder that is not signed in (401): the run fails, exit 1" test "$rc" -eq 1
check "  no STATUS=deferred"  sh -c "! grep -q '^STATUS=deferred' '$d.out'"
check "  no RESUME_AT"        sh -c "! grep -q '^RESUME_AT=' '$d.out'"
check "  says to sign in"     grep -qi "not signed in" "$d.log"
quota_run_as auth-403 403 "Forbidden"
check "a finder not authorised (403): the run fails, exit 1" test "$rc" -eq 1
check "  no STATUS=deferred"  sh -c "! grep -q '^STATUS=deferred' '$d.out'"
check "  says it is not authorised" grep -qi "not authorised" "$d.log"
quota_run_as quota-429 429 "slow down"
check "a 429: exits 75" test "$rc" -eq 75
quota_run_as billing-402 402 "payment required"
check "a 402 is a billing failure: the run fails, exit 1" test "$rc" -eq 1
check "  no STATUS=deferred" sh -c "! grep -q '^STATUS=deferred' '$d.out'"
check "  no RESUME_AT"       sh -c "! grep -q '^RESUME_AT=' '$d.out'"
# The limit's wording alone does not defer: with no reset time named it is a plain failure.
quota_run_as quota-noreset 400 "You've hit your usage limit"
check "limit wording naming no reset: the run fails, exit 1" test "$rc" -eq 1
check "  no STATUS=deferred" sh -c "! grep -q '^STATUS=deferred' '$d.out'"
quota_run_as quota-worded 400 "You've hit your usage limit · resets 9:20pm (UTC)"
check "limit wording with a reset time: exits 75" test "$rc" -eq 75
check "  with a RESUME_AT" grep -q '^RESUME_AT=' "$d.out"
# A rejected window whose resetsAt is 0 is no reset time: the flat fallback applies.
d="$SANDBOX/quota-zero"; rc=0
( for ((_n=0;_n<30;_n++)); do sleep 2; pkill -f '[s]leep 4711'; done ) & watchdog=$!
env PR_REVIEW_DIR="$d" STUB_QUOTA=1 STUB_QUOTA_RESETSAT=0 AUTOFIX_DEFER_FALLBACK=1000 PR_REVIEW_STAGE1_JOBS=3 \
  PATH="$SANDBOX/stub:$SANDBOX/fixture/gh:$PATH" "$HERE/pr-review.sh" "$PIN_PR" --no-cache > "$d.out" 2> "$d.log" || rc=$?
kill "$watchdog" 2>/dev/null || true; pkill -f '[s]leep 4711' 2>/dev/null || true
check "a resetsAt of 0: exits 75" test "$rc" -eq 75
check "  RESUME_AT is the flat fallback" sh -c "t=\$(sed -n 's/^RESUME_AT=//p' '$d.out'); [ \$((t - \$(date +%s))) -ge 900 ] && [ \$((t - \$(date +%s))) -le 1100 ]"
check "quota_resume_at: zero, empty and negative all fall back" bash -c '. "$1/quota-resume.sh"; now=$(date +%s)
  for v in 0 000 "" -5; do r="$(quota_resume_at "$v" 1000)"; [ $((r - now)) -ge 990 ] && [ $((r - now)) -le 1010 ] || exit 1; done; [ "$(quota_resume_at 100 1000)" = 160 ]' _ "$HERE"

echo "refuter — a claude model on the login"
d="$SANDBOX/claude-refuter"
env PR_REVIEW_DIR="$d" PR_REVIEW_REFUTER=anthropic:claude-refuter-x PATH="$SANDBOX/stub:$SANDBOX/fixture/gh:$PATH" \
  "$HERE/pr-review.sh" "$PIN_PR" --no-brief > "$d.log" 2>&1 || { cat "$d.log"; bad "claude-refuter run exited non-zero"; }
check "PR_REVIEW_REFUTER takes an anthropic model" logged claude-refute '^arg=claude-refuter-x$'
check "  the report names it" grep -q 'claude-refuter-x' "$d/$AUTHOR/widgets/$PIN_PR/pr${PIN_PR}-review.md"
check "  and flags it as the finder's own family" \
  grep -q '^> ⚠️ \*\*Same-family refuter' "$d/$AUTHOR/widgets/$PIN_PR/pr${PIN_PR}-review.md"
check "  on stderr too" grep -q 'same model family' "$d.log"
check "a cross-family refuter is not flagged" absent "$REPORT" 'Same-family refuter'

echo "refuter chain — an explicit PR_REVIEW_REFUTER_CHAIN wins over the computed one"
d="$SANDBOX/chain-explicit"
env PR_REVIEW_DIR="$d" PR_REVIEW_REFUTER_CHAIN=agy:gemini-chain-x PATH="$SANDBOX/stub:$SANDBOX/fixture/gh:$PATH" \
  "$HERE/pr-review.sh" "$PIN_PR" --no-brief --no-cache > "$d.log" 2>&1 || { cat "$d.log"; bad "explicit-chain run exited non-zero"; }
check "the refuter is the one the chain names" logged agy-refute 'gemini-chain-x'

# The default chain is built in pr-review.sh, so it is observed where refute receives it: a copy
# of the skill directory (symlinks, lib included) whose refute logs its argv and runs the real one.
# Probes are stubbed so agy, ollama and claude all answer.
echo "refuter chain — the default is the reachable rows of the preset, in table order"
MIR="$SANDBOX/mirror"; mkdir -p "$MIR/skills/pr-review" "$SANDBOX/stub-net"
ln -s "$HERE/../../lib" "$MIR/lib"
for f in "$HERE"/../*; do [ "$f" = "$HERE" ] || ln -s "$f" "$MIR/skills/$(basename "$f")"; done
for f in "$HERE"/*; do [ "$(basename "$f")" = refute ] || ln -s "$f" "$MIR/skills/pr-review/$(basename "$f")"; done
cat > "$MIR/skills/pr-review/refute" <<SHIM
#!/usr/bin/env bash
printf '%s\\n' "\$@" > "$SANDBOX/refute.args"
exec "$HERE/refute" "\$@"
SHIM
chmod +x "$MIR/skills/pr-review/refute"
cat > "$SANDBOX/stub-net/curl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  */v1/models*) printf '{"data":[{"id":"glm-5.3-flash"},{"id":"deepseek-v4.1-flash"}]}' ;;
  */v1/messages*) cat > /dev/null; printf 200 ;;
  *) exit 64 ;;
esac
STUB
chmod +x "$SANDBOX/stub-net/curl"
chain_run() {  # chain_run <name> [VAR=val...]: the --chain refute was given, "-" when none
  d="$SANDBOX/chain-$1"; shift; rm -f "$SANDBOX/refute.args"
  env PR_REVIEW_DIR="$d" REVIEW_SKILLS_MODELS=auto REVIEW_SKILLS_CACHE="$d-cache" OLLAMA_API_KEY=k-oll \
    PATH="$SANDBOX/stub-net:$SANDBOX/stub:$SANDBOX/fixture/gh:$PATH" "$@" \
    "$MIR/skills/pr-review/pr-review.sh" "$PIN_PR" --no-brief --no-cache > "$d.log" 2>&1 || true
  [ -s "$SANDBOX/refute.args" ] || { echo "refute was not run"; return 1; }
  awk 'p { print; found = 1; exit } $0 == "--chain" { p = 1 } END { if (!found) print "-" }' "$SANDBOX/refute.args"
}
check "no pins, every row reachable: agy, then ollama, then claude" \
  test "$(chain_run default)" = "agy:gemini-3.8-flash-high ollama:glm-5.3-flash anthropic:claude-opus-5-5"
check "an unreachable row (agy signed out) is skipped" \
  test "$(chain_run noagy STUB_AGY_DOWN=1)" = "ollama:glm-5.3-flash anthropic:claude-opus-5-5"
check "PR_REVIEW_REFUTER pins a single refuter: no chain" test "$(chain_run pin PR_REVIEW_REFUTER=agy:gemini-pin)" = "-"
check "PR_REVIEW_REFUTER_FALLBACK set (even empty): no chain" test "$(chain_run fallback PR_REVIEW_REFUTER_FALLBACK=)" = "-"
check "PR_REVIEW_REFUTER_CHAIN set: pr-review adds none, refute reads the explicit one" \
  test "$(chain_run explicit PR_REVIEW_REFUTER_CHAIN=agy:gemini-chain-y)" = "-"

echo "claude signed out — the brief is skipped, the review runs"
d="$SANDBOX/claude-out"
env PR_REVIEW_DIR="$d" REVIEW_SKILLS_MODELS=auto STUB_CLAUDE_OUT=1 PR_REVIEW_FINDERS=agy:gemini-x \
  PR_REVIEW_REFUTER=agy:gemini-y PATH="$SANDBOX/stub:$SANDBOX/fixture/gh:$PATH" \
  "$HERE/pr-review.sh" "$PIN_PR" --no-cache > "$d.log" 2>&1 || { cat "$d.log"; bad "claude-out run exited non-zero"; }
check "the review is written" test -f "$d/$AUTHOR/widgets/$PIN_PR/pr${PIN_PR}-review.md"
check "  with no brief" test ! -e "$d/$AUTHOR/widgets/$PIN_PR/pr${PIN_PR}-explainer.md"
check "  saying why" grep -q 'brief skipped (claude is not signed in)' "$d.log"

# --------------------------------------------------------- per-transport pools
# Each transport has its own quota, so each gets its own slots: a busy anthropic pool must
# not hold agy slices back.
echo "pools — one per transport"
d="$SANDBOX/pools"
env PR_REVIEW_DIR="$d" PR_REVIEW_STAGE1_JOBS=1 STUB_SLOW_CLAUDE=4 "${TWO[@]}" \
  PATH="$SANDBOX/stub:$SANDBOX/fixture/gh:$PATH" "$HERE/pr-review.sh" "$PIN_PR" --no-cache --no-brief > "$d.log" 2>&1 || true
check "every agy feature slice finished while the anthropic pool was busy" awk '
  /    anthropic\.(c[0-9]+|_cross) / { a++ }
  /    agy\.(c[0-9]+|_cross) / { if (a > 1) late = 1; g++ }
  END { exit !(g > 1 && !late) }' "$d.log"


# ------------------------------------------------- pipeline speed
echo "gates — a finder's test slices wait for its own feature slices only"
d="$SANDBOX/gate"
env PR_REVIEW_DIR="$d" STUB_SLOW_FEATURES=4 "${TWO[@]}" \
  PATH="$SANDBOX/stub:$SANDBOX/fixture/gh:$PATH" "$HERE/pr-review.sh" "$PIN_PR" --no-cache --no-brief > "$d.log" 2>&1 || true
check "agy's test slices ran before the slow anthropic feature slices finished" awk '
  /    anthropic\.c[0-9]+ +[0-9]+ finding/ { if (!g) late = 1 }
  /    agy\.t[0-9]+ / { g = 1 }
  END { exit !(g && !late) }' "$d.log"
check "  anthropic's test slices still waited for its own" awk '
  /    anthropic\.t[0-9]+ / { t = 1 }
  /    anthropic\.c[0-9]+ +[0-9]+ finding/ { if (t) late = 1 }
  END { exit !(t && !late) }' "$d.log"

echo "queue — largest slice first, five per transport by default"
d="$SANDBOX/order"; rm -rf "$STUB_LOG"; mkdir -p "$STUB_LOG"; : > "$SANDBOX/order.txt"
env PR_REVIEW_DIR="$d" PR_REVIEW_STAGE1_JOBS=1 STUB_ORDER="$SANDBOX/order.txt" \
  PATH="$SANDBOX/stub:$SANDBOX/fixture/gh:$PATH" "$HERE/pr-review.sh" "$PIN_PR" --no-cache --no-brief > "$d.log" 2>&1 || true
# Test slices wait on their gate, so the order holds within each group, not across them.
check "with one slot, slices start in non-increasing size" \
  awk '{ g = ($1 ~ /^t[0-9]/) ? "t" : "f"; if (g in prev && $2 > prev[g]) bad = 1; prev[g] = $2 }
       END { exit !(NR > 3 && !bad) }' "$SANDBOX/order.txt"
rm -rf "$STUB_LOG"; mkdir -p "$STUB_LOG"
d="$SANDBOX/jobs"
env PR_REVIEW_DIR="$d" PR_REVIEW_CHUNK_BYTES=500 STUB_HOLD=3 \
  PATH="$SANDBOX/stub:$SANDBOX/fixture/gh:$PATH" "$HERE/pr-review.sh" "$PIN_PR" --no-cache > "$d.log" 2>&1 || true
check "the fixture has more than five slices to hold" \
  test "$(grep -cE '^    [a-z_0-9]+ +[0-9]+ finding' "$d.log")" -ge 6
check "unset PR_REVIEW_STAGE1_JOBS runs five at once" \
  test "$(sort -n "$STUB_LOG/maxlive.n" | tail -1)" = 5
rm -rf "$STUB_LOG"; mkdir -p "$STUB_LOG"

echo "agy finder quota — stderr alone defers stage 1"
d="$SANDBOX/agy-quota"; rc=0
env PR_REVIEW_DIR="$d" PR_REVIEW_FINDERS=agy:gemini-x PR_REVIEW_REFUTER=agy:gemini-y STUB_AGY_QUOTA=1 \
  PATH="$SANDBOX/stub:$SANDBOX/fixture/gh:$PATH" "$HERE/pr-review.sh" "$PIN_PR" --no-cache --no-brief > "$d.log" 2>&1 || rc=$?
check "an AGY_ERROR 429 with no is_error exits 75" test "$rc" -eq 75
check "  naming the limit" grep -q 'RESOURCE_EXHAUSTED' "$d.log"
check "  with RESUME_AT, the flat fallback (agy names no reset)" grep -q '^RESUME_AT=[0-9]' "$d.log"
d="$SANDBOX/agy-noise"; rc=0
env PR_REVIEW_DIR="$d" PR_REVIEW_FINDERS=agy:gemini-x PR_REVIEW_REFUTER=agy:gemini-y STUB_AGY_NOISE=1 \
  PATH="$SANDBOX/stub:$SANDBOX/fixture/gh:$PATH" "$HERE/pr-review.sh" "$PIN_PR" --no-cache --no-brief > "$d.log" 2>&1 || rc=$?
check "an AGY_ERROR line on a call that exited 0 does not defer" test "$rc" -ne 75
check "  and its findings are kept" grep -qE '^    [a-z_0-9]+ +[0-9]+ finding' "$d.log"

# The real lib/ollama_messages.py against a local fake of ollama.com's /v1/messages, on a PATH
# with no claude binary. Nothing here is mocked above the HTTP socket: the client builds the
# request, reads the reply, and pr-review.sh takes the result envelope from it. The one
# test-only seam is a python3 shim that appends --endpoint (argparse keeps the last), because
# the client reads no environment and has no default: --endpoint is required, and the shell
# caller passes "$OLLAMA_ORIGIN/v1/messages".
echo "ollama finder — real client against a local fake endpoint, no claude on PATH"
cat > "$SANDBOX/fake-ollama.py" <<'PY'
import http.server, json, re, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("content-length", 0)); body = json.loads(self.rfile.read(n))
        last = body["messages"][-1]["content"]
        results = [b for b in last if isinstance(b, dict) and b.get("type") == "tool_result"] if isinstance(last, list) else []
        entry = {"auth": self.headers.get("authorization"), "path": self.path, "tools": "tools" in body}
        if results:
            entry["result"] = results[0]["content"][:4000]
        with open(sys.argv[2], "a") as f:
            f.write(json.dumps(entry) + "\n")
        found = {"findings": [{"id": "OL1", "file": "ollama-fake.txt", "line": 7, "severity": "medium",
                               "claim": "fake ollama finding", "mechanism": "stub", "repro": "stub"}],
                 "read": ["ollama-fake.txt"]}
        if not results:
            # First turn: Read the diff at the path the prompt names, which lives under the work dir.
            m = re.search(r"(/\S+?/chunks/\S+?\.diff)", body["messages"][0]["content"])
            content = [{"type": "tool_use", "id": "t1", "name": "Read", "input": {"file_path": m.group(1) if m else "no-diff-path-in-prompt"}}]
        else:
            content = [{"type": "text", "text": "Done.\n" + json.dumps(found)}]
        reply = json.dumps({"content": content}).encode()
        self.send_response(200); self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(reply))); self.end_headers(); self.wfile.write(reply)
    def log_message(self, *a): pass
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(s.server_address[1]))
s.serve_forever()
PY
rm -f "$SANDBOX/fake.port" "$SANDBOX/fake.requests"
python3 "$SANDBOX/fake-ollama.py" "$SANDBOX/fake.port" "$SANDBOX/fake.requests" &
FAKE_PID=$!
for ((_n=1;_n<=50;_n++)); do [ -s "$SANDBOX/fake.port" ] && break; sleep 0.1; done
# A PATH of the system tools plus the stubs, minus claude: agy and its helper are copied in
# (the stub finds log.sh beside itself), python3 is the endpoint shim.
NC="$SANDBOX/noclaude"; mkdir -p "$NC"
cp "$SANDBOX/stub/agy" "$SANDBOX/stub/log.sh" "$NC/"
printf '#!/usr/bin/env bash\ncase "$1" in *ollama_messages.py) exec %s "$@" --endpoint "http://127.0.0.1:%s/v1/messages" ;; esac\nexec %s "$@"\n' \
  "$(command -v python3)" "$(cat "$SANDBOX/fake.port")" "$(command -v python3)" > "$NC/python3"
chmod +x "$NC/python3"
d="$SANDBOX/ollama-fake"; rc=0
env PR_REVIEW_DIR="$d" PR_REVIEW_FINDERS=ollama:fake-model PR_REVIEW_REFUTER=agy:gemini-y OLLAMA_ORIGIN=http://evil.invalid \
  OLLAMA_API_KEY=stub-key PATH="$NC:$SANDBOX/fixture/gh:/usr/bin:/bin" \
  "$HERE/pr-review.sh" "$PIN_PR" --no-cache --no-brief > "$d.log" 2>&1 || rc=$?
kill "$FAKE_PID" 2>/dev/null || true; wait "$FAKE_PID" 2>/dev/null || true
OMERGED="$d/$AUTHOR/widgets/$PIN_PR/merged.json"
check "(the PATH really has no claude)" sh -c "! PATH='$NC:$SANDBOX/fixture/gh:/usr/bin:/bin' command -v claude"
check "an ollama-only PATH with no claude runs stage 1" absent "$d.log" 'need.*claude|claude.* not found'
check "the client reached the fake endpoint, with its key and the tool list" \
  grep -q '"auth": "Bearer stub-key".*"path": "/v1/messages".*"tools": true' "$SANDBOX/fake.requests"
check "the finder could Read its own diff under the work dir (tool_result is the diff, not a refusal)" \
  grep -q '"result": "diff --git' "$SANDBOX/fake.requests"
check "an inherited OLLAMA_ORIGIN did not move the request" absent "$SANDBOX/fake.requests" 'evil'
check "the slices were accepted, with their findings" grep -qE '^    c[0-9]+ +[0-9]+ finding' "$d.log"
check "  none FAILED" absent "$d.log" 'FAILED'
check "the findings reach the merged output" jq -e 'any(.[]; .file == "ollama-fake.txt")' "$OMERGED"
check "  the run completed" test "$rc" -eq 0

echo "ollama finder — bounded by the slice timeout"
mkdir -p "$SANDBOX/pystub"
printf '#!/usr/bin/env bash\ncase "$1" in *ollama_messages.py) trap '"'"'kill $p; exit 143'"'"' TERM; sleep 29 & p=$!; wait $p; touch "%s" ; exit 1 ;; esac\nexec %s "$@"\n' "$SANDBOX/ollama-hang.finished" "$(command -v python3)" > "$SANDBOX/pystub/python3"
chmod +x "$SANDBOX/pystub/python3"
d="$SANDBOX/ollama-hang"; rc=0
env PR_REVIEW_DIR="$d" PR_REVIEW_FINDERS=ollama:x PR_REVIEW_REFUTER=agy:gemini-y PR_REVIEW_S1_TIMEOUT=1s OLLAMA_API_KEY=stub \
  PATH="$SANDBOX/pystub:$SANDBOX/stub:$SANDBOX/fixture/gh:$PATH" "$HERE/pr-review.sh" "$PIN_PR" --no-cache --no-brief > "$d.log" 2>&1 || rc=$?
check "a hung ollama call is cut off: the run ends" test "$rc" -ne 0
check "  by the timeout: the stub was killed, never ran to its end" test ! -e "$SANDBOX/ollama-hang.finished"
check "  its slices are FAILED, not hanging" grep -q 'FAILED' "$d.log"
check "  and nothing is left running" sh -c '! pgrep -x -f "sleep 29" >/dev/null'

echo "cache — keyed on the finder's prompts only"
CP="$SANDBOX/copy"; mkdir -p "$CP/skills" "$CP/lib"
cp -R "$HERE" "$CP/skills/pr-review"; cp -R "$HERE/../../lib/." "$CP/lib/"
d="$SANDBOX/cachekey"
cached_run() { env PR_REVIEW_DIR="$d" PATH="$SANDBOX/stub:$SANDBOX/fixture/gh:$PATH" \
  "$CP/skills/pr-review/pr-review.sh" "$PIN_PR" --no-brief > "$d.$1.log" 2>&1 || true; }
cached_run 1
echo "# edited" >> "$CP/skills/pr-review/refute.prompt"
cached_run 2
check "editing refute.prompt keeps the finder slices cached" grep -qE 'c01 +cached' "$d.2.log"
echo "# edited" >> "$CP/skills/pr-review/review.prompt"
cached_run 3
check "editing review.prompt re-runs them" sh -c '! grep -qE "c01 +cached" "$1" && grep -qE "c01 +[0-9]+ finding" "$1"' _ "$d.3.log"
echo "# edited" >> "$CP/skills/pr-review/scope/tests.txt"
cached_run 4
check "editing the test scope keeps the feature slices cached" grep -qE 'c01 +cached' "$d.4.log"
echo "# edited" >> "$CP/skills/pr-review/scope/package.txt"
cached_run 5
check "editing the package scope re-runs them" sh -c '! grep -qE "c01 +cached" "$1"' _ "$d.5.log"

# ------------------------------------------------------------------ per-PR lock
echo "lock — one run per PR"
LOCK="$SANDBOX/locks/github.com_acme_widgets_pull_$PIN_PR"
check "a finished run leaves no lock behind" test ! -L "$LOCK"
check "  nor does a failed one" sh -c '! ls "$1"/locks/* >/dev/null 2>&1' _ "$SANDBOX"
mkdir -p "$SANDBOX/locks"; ln -s $$ "$LOCK"; rc=0
PATH="$SANDBOX/stub:$SANDBOX/fixture/gh:$PATH" "$HERE/pr-review.sh" "$PIN_PR" --no-cache > "$SANDBOX/lock.log" 2>&1 || rc=$?
check "a PR another live run holds is refused" test "$rc" -ne 0
check "  naming why" grep -q 'already being reviewed' "$SANDBOX/lock.log"
check "  before stage 1 spends anything" absent "$SANDBOX/lock.log" 'stage 1'
check "  and the holder's lock is left alone" test "$(readlink "$LOCK")" = "$$"
rm -f "$LOCK"

# ------------------------------------------------------------------ diff past GitHub's cap
echo "diff — GitHub refuses past 300 files"
FIXTURE_GH_DIFF_FAIL=1 PATH="$SANDBOX/stub:$SANDBOX/fixture/gh:$PATH" \
  "$HERE/pr-review.sh" "$PIN_PR" --no-cache --no-brief > "$SANDBOX/bigdiff.log" 2>&1 || true
check "a diff GitHub refuses is built from the clone" grep -q 'building the diff from the clone' "$SANDBOX/bigdiff.log"
check "  without dying at stage 0" absent "$SANDBOX/bigdiff.log" 'stage 0: gh pr diff failed'
check "  and the review goes on" grep -q 'stage 1' "$SANDBOX/bigdiff.log"

# ------------------------------------------------------------------ intense preset
echo "intense preset — two finders, ollama refuter, evidence burden"
DEFAULT_SUM="$(cksum < "$REPORT")"
rm -rf "$STUB_LOG"; mkdir -p "$STUB_LOG"
# The ollama key lives only in config.env; the environment carries keys and an endpoint no
# finder or refuter should see.
printf 'OLLAMA_API_KEY=from-config\nPR_REVIEW_FINDERS=ollama:regular-pin\nPR_REVIEW_REFUTER=ollama:regular-pin\n' > "$SANDBOX/intense.env"; chmod 600 "$SANDBOX/intense.env"
( unset OLLAMA_API_KEY
  PATH="$SANDBOX/stub:$SANDBOX/fixture/gh:$PATH" REVIEW_SKILLS_CONFIG="$SANDBOX/intense.env" STUB_BARE=1 STUB_DIAGRAM=bad \
  ANTHROPIC_API_KEY=leaked-api-key GEMINI_API_KEY=leaked-gemini ANTHROPIC_BASE_URL=https://evil.example \
  "$HERE/../intense-review/intense-review.sh" "$PIN_PR" --no-cache ) > "$SANDBOX/run3.log" 2>&1 \
  || { cat "$SANDBOX/run3.log"; bad "intense run exited non-zero"; exit 1; }

check "intense report lands in its own store" test -f "$IREPORT"
check "a bare-object brief is read as well as a transcript array" test -f "$IBRIEF"
check "the default report was not touched" test "$DEFAULT_SUM" = "$(cksum < "$REPORT")"
IDIAG="${IBRIEF%-explainer.md}-diagram"
check "a diagram that fails to parse gets exactly one repair call" \
  test "$(ls "$STUB_LOG"/claude-repair.* 2>/dev/null | wc -l | tr -d ' ')" = 1
check "the repair ran at low effort on the brief's model" every claude-repair '^arg=low$'
check "a repaired diagram says so" test "$(jq -r .status "$IDIAG.json")" = repaired
check "the brief carries the repaired block" grep -q 'subgraph S\["S §1"\]' "$IBRIEF"
check "the cache holds the repaired brief, written after the check" \
  grep -lq 'subgraph S\["S §1"\]' "$SANDBOX/pr-review-cache/"brief-*
check "ids carry the anthropic finder's tag" grep -q '"anthropic\.c0[0-9]-F1"' "$IMERGED"
check "ids carry the agy finder's tag" grep -q '"agy\.c0[0-9]-F1"' "$IMERGED"
check "one finder's failed slice is a gap for that finder only" \
  grep -q 'no findings from: anthropic\.c02 —' "$SANDBOX/run3.log"
check "the other finder still covered that slice" grep -q '"agy\.c02-F1"' "$IMERGED"
check "the claude finder ran at --effort medium (never above)" every claude-find '^arg=medium$'
check "the claude finder ran with no budget cap" never claude-find '^arg=--max-budget-usd$'
check "the agy finder ran inside the tree" every agy-find '^cwd=.*/tree$'
check "the agy finder was handed the findings schema" every agy-find '^arg=.*/findings\.schema\.json$'
check "the refuter ran under CLAUDE_CODE_SIMPLE" every claude-refute '^CLAUDE_CODE_SIMPLE=1$'
check "a key kept only in config.env reached the ollama refuter" every claude-refute '^auth=from-config$'
check "  which saw no key variable at all" never claude-refute '^key:'
check "the claude finder saw no key variable" never claude-find '^key:'
check "  nor the inherited endpoint" every claude-find '^ANTHROPIC_BASE_URL=$'
check "the brief saw no key variable" never claude-brief '^key:'
check "  nor the inherited endpoint" every claude-brief '^ANTHROPIC_BASE_URL=$'
check "the agy finder saw no key variable" never agy-find '^key:'
check "the refuter went to ollama.com" every claude-refute '^ANTHROPIC_BASE_URL=https://ollama\.com$'
check "the refuter had no Bash" every claude-refute '^arg=Bash$'
check "the refuter had no Edit" every claude-refute '^arg=Edit$'
check "the refuter ran inside the tree" every claude-refute '^cwd=.*/tree$'
check "the refuter got the schema inline, as claude requires" every schema '^\{'
check "the refuter schema carries the evidence burden" every schema 'counter-evidence'
check "the refuter prompt carries the evidence burden" every prompt 'quote the source that disproves it'
check "the evidence intro judges the code at this head" every prompt 'the code at this head has a specific defect'
check "the refuter prompt drops the strict rule" never prompt 'Inability to confirm is a refutation'
check "every claim got a verdict" jq -e 'all(.[]; .v.verdict != "ERROR")' "$IMERGED"
check "UNVERIFIABLE findings survive into the report" grep -q 'UNVERIFIABLE' "$IREPORT"
check "the report names the opus finder" grep -q 'claude-opus-5-5/medium' "$IREPORT"
check "the report names the gemini finder" grep -q 'gemini-3.8-flash-high' "$IREPORT"
check "the report names the refuter" grep -q 'glm-5.3-flash' "$IREPORT"
check "a regular pin in config.env does not reach intense" absent "$IREPORT" 'regular-pin'
check "the report states the evidence burden" grep -q 'counter-evidence' "$IREPORT"
check "findings both finders reported are tagged" jq -e 'any(.[]; (.also // []) | length > 0)' "$IMERGED"

PATH="$SANDBOX/stub:$SANDBOX/fixture/gh:$PATH" OLLAMA_API_KEY=test-key-not-real \
  "$HERE/../intense-review/intense-review.sh" "$PIN_PR" > "$SANDBOX/run4.log" 2>&1 || true
check "the anthropic finder resumes from its own cache" grep -q 'anthropic.c01 cached' "$SANDBOX/run4.log"
check "the agy finder resumes from its own cache" grep -q 'agy.c01 cached' "$SANDBOX/run4.log"

# ------------------------------------------------------------------- --sonnet opt-in
# The regression this guards: FINDERS used to be computed ~50 lines above the arg loop, so
# a flag that set it during parsing was overwritten by the default before stage 1 read it.
echo "--sonnet opt-in"
rm -rf "$STUB_LOG"; mkdir -p "$STUB_LOG"
STUB_SLOW_CROSS=4 PATH="$SANDBOX/stub:$SANDBOX/fixture/gh:$PATH" "$HERE/pr-review.sh" "$PIN_PR" --sonnet --no-cache --no-brief \
  > "$SANDBOX/run5.log" 2>&1 || true
check "--sonnet reaches the finder" every claude-find '^arg=claude-sonnet-5-5$'
check "--sonnet keeps the finder's effort" every claude-find '^arg=medium$'
check "--no-brief fires no brief call" nolog claude-brief
check "--no-brief is reported, not silent" grep -q 'brief skipped' "$SANDBOX/run5.log"
check "--no-brief checks no diagram" bash -c "! grep -q 'diagram' '$SANDBOX/run5.log'"
check "with no brief, the test pass is told so" every tctx '^brief=none$'
check "  and gets the feature findings instead" every tctx '^n=[1-9]'
check "  so it waits for every feature slice" awk '
  /    c[0-9][0-9] / { last = NR }
  /    t[0-9][0-9] / && !first { first = NR }
  END { exit !(first && last && last < first) }' "$SANDBOX/run5.log"
check "  but not for the cross-cutting pass" awk '
  /    _cross / { x = NR }
  /    t[0-9][0-9] / && !first { first = NR }
  END { exit !(first && x && first < x) }' "$SANDBOX/run5.log"
check "the report names the model that actually ran" grep -q 'claude-sonnet-5-5' "$REPORT"
PATH="$SANDBOX/stub:$SANDBOX/fixture/gh:$PATH" PR_REVIEW_FINDERS="anthropic:claude-opus-5-5@medium" \
  "$HERE/pr-review.sh" "$PIN_PR" --sonnet --no-brief > "$SANDBOX/run6.log" 2>&1 || true
check "--sonnet beats PR_REVIEW_FINDERS, and says so" \
  grep -q 'overrides PR_REVIEW_FINDERS' "$SANDBOX/run6.log"
rm -rf "$STUB_LOG"; mkdir -p "$STUB_LOG"
PATH="$SANDBOX/stub:$SANDBOX/fixture/gh:$PATH" PR_REVIEW_DIAGRAM=0 STUB_DIAGRAM=bad "$HERE/pr-review.sh" "$PIN_PR" \
  --sonnet --no-cache > "$SANDBOX/run6d.log" 2>&1 || true
check "PR_REVIEW_DIAGRAM=0 keeps the explainer" grep -q 'subgraph S §1' "$BRIEF"
check "PR_REVIEW_DIAGRAM=0 checks nothing, repairs nothing" \
  bash -c "! ls '$DIAG'.* 2>/dev/null && ! ls '$STUB_LOG'/claude-repair.* 2>/dev/null"

# ---------------------------------------------------------------- test-only PR
# Every code file of PR 8 lives under tests/. When tests were excluded outright, stage 1
# reviewed only YAML and docs and the report read "No findings." with no caveat.
echo "test-only PR — #8"
TO_PR=8
TO_DIR="$PR_REVIEW_DIR/bob/widgets/$TO_PR"
rm -rf "$STUB_LOG"; mkdir -p "$STUB_LOG"
PATH="$SANDBOX/stub:$SANDBOX/fixture/gh:$PATH" "$HERE/pr-review.sh" "$TO_PR" --no-cache --no-brief \
  > "$SANDBOX/run7.log" 2>&1 || { cat "$SANDBOX/run7.log"; bad "test-only run exited non-zero"; }
check "the e2e package's code was reviewed" \
  jq -e 'any(.[]; (.id | startswith("t")) and (.file | startswith("tests/at_end2end_test/")))' "$TO_DIR/merged.json"
check "the test pass ran on #8" grep -qE '    t[0-9][0-9] ' "$SANDBOX/run7.log"

# ------------------------------------------------------------- stage 5: fix PR
echo "stage 5 -- a fix PR stacked on a fix author's PR"
META5="$PR_REVIEW_DIR/$AUTHOR/widgets/$PIN_PR/meta.json"
fix_run() {
  rm -rf "$STUB_LOG"; mkdir -p "$STUB_LOG"; rc=0
  PATH="$SANDBOX/stub:$SANDBOX/fixture/gh:$PATH" "$HERE/pr-review.sh" "$PIN_PR" --no-brief "$@" > "$SANDBOX/fix.log" 2>&1 || rc=$?
}
fixes() { ls "$STUB_LOG"/autofix.* 2>/dev/null | wc -l | tr -d ' '; }
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

PR_REVIEW_FIX_AUTHORS="$AUTHOR" fix_run
check "precondition: the stub review confirmed a finding" \
  jq -e 'any(.[]; .v.verdict == "CONFIRMED")' "$PR_REVIEW_DIR/$AUTHOR/widgets/$PIN_PR/merged.json"
check "precondition: lanes.jq sends #$PIN_PR's findings to trunk alone" \
  test "$(lanes_of "$(jq -r .state "$META5")" "$(cat "$PR_REVIEW_DIR/$AUTHOR/widgets/$PIN_PR/merged.json")")" = trunk
check "a fix author's PR: one autofix per lane, here trunk" test "$(cat "$STUB_LOG/lanes")" = trunk
check "  one-shot, not prepare" every autofix '^MODE=$'
check "  on the PR" every autofix "^arg=$PIN_PR\$"
check "  at the head the review read" every autofix "^arg=$(jq -r .headRefOid "$META5")\$"
check "  in the repo under review" every autofix "^arg=$FIXTURE_ROOT\$"
check "  asking the author to review the fix" every autofix "^REVIEWER=$AUTHOR\$"
check "  exits 0" test "$rc" = 0
check "  reports the opened PR, by lane" grep -q '^LANE=trunk STATUS=opened:' "$SANDBOX/fix.log"

PR_REVIEW_FIX_AUTHORS="$AUTHOR" AUTOFIX_LINT=1 fix_run
check "AUTOFIX_LINT=1: the lint lane runs last" test "$(paste -sd' ' "$STUB_LOG/lanes")" = "trunk lint"
PR_REVIEW_FIX_AUTHORS="$AUTHOR" AUTOFIX_LINT=1 STUB_AUTOFIX_STATUS_lint=none fix_run
check "  nothing to lint: exits 0" test "$rc" = 0
PR_REVIEW_FIX_AUTHORS="$AUTHOR" AUTOFIX_LINT=1 STUB_AUTOFIX_STATUS_lint=none STUB_AUTOFIX_RC=1 fix_run
check "  a lane that fails: exits 4" test "$rc" = 4
PR_REVIEW_FIX_AUTHORS="$AUTHOR" STUB_AUTOFIX_STATUS=dropped fix_run
check "trunk found nothing to fix: exits 0" test "$rc" = 0
check "  and says the finding was dropped" grep -q 'dropped' "$SANDBOX/fix.log"

PR_REVIEW_FIX_AUTHORS="$AUTHOR" fix_run --no-fix
check "--no-fix: no autofix" test "$(fixes)" = 0
check "  exits 0" test "$rc" = 0
PR_REVIEW_FIX_AUTHORS="" fix_run
check "an empty fix-author list: no autofix" test "$(fixes)" = 0
PR_REVIEW_FIX_AUTHORS="nobody" fix_run
check "an author not on the list: no autofix" test "$(fixes)" = 0
PEER_REVIEW_FIX_AUTHORS="$AUTHOR" fix_run
check "PEER_REVIEW_FIX_AUTHORS is an alias" test "$(fixes)" = 1
PR_REVIEW_FIX_AUTHORS="nobody, $(upper "$AUTHOR")" fix_run
check "the list is comma-separated and case-blind" test "$(fixes)" = 1
PR_REVIEW_FIX_AUTHORS="$AUTHOR" fix_run --sha "$(jq -r .headRefOid "$META5")"
check "--sha: a pinned review opens no fix PR" test "$(fixes)" = 0
check "  and says why" grep -q 'pinned' "$SANDBOX/fix.log"

PR_REVIEW_FIX_AUTHORS="$AUTHOR" STUB_AUTOFIX_STATUS="exists:https://x/pull/98" fix_run
check "a fix PR already open: exits 0" test "$rc" = 0
PR_REVIEW_FIX_AUTHORS="$AUTHOR" STUB_AUTOFIX_STATUS=stale STUB_AUTOFIX_RC=1 fix_run
check "the head moved during the review: exits 4" test "$rc" = 4
check "  and says no fix PR was opened" grep -q 'NO fix PR' "$SANDBOX/fix.log"
PR_REVIEW_FIX_AUTHORS="$AUTHOR" STUB_AUTOFIX_STATUS=none STUB_AUTOFIX_RC=1 fix_run
check "autofix failed: exits 4" test "$rc" = 4
check "  and says no fix PR was opened" grep -q 'NO fix PR' "$SANDBOX/fix.log"

rm -rf "$STUB_LOG"; mkdir -p "$STUB_LOG"; rc=0
PATH="$SANDBOX/stub:$SANDBOX/fixture/gh:$PATH" OLLAMA_API_KEY=test-key-not-real PR_REVIEW_FIX_AUTHORS="$AUTHOR" \
  STUB_AUTOFIX_STATUS=stale STUB_AUTOFIX_RC=1 \
  "$HERE/../intense-review/intense-review.sh" "$PIN_PR" --no-brief > "$SANDBOX/fix.log" 2>&1 || rc=$?
check "intense-review: the same stage 5, and its exit 4" test "$rc" = 4

# ------------------------------------------------- store layout, config, PR references
echo "store layout, config file, PR references"
store_run() { rm -rf "$STUB_LOG"; mkdir -p "$STUB_LOG"; rc=0
  env -u PR_REVIEW_DIR -u PR_REVIEW_INTENSE_DIR HOME="$SANDBOX/home" PATH="$SANDBOX/stub:$SANDBOX/fixture/gh:$PATH" \
    "$@" > "$SANDBOX/store.log" 2>&1 || rc=$?; }
store_run "$HERE/pr-review.sh" 7 --no-brief
check "the store defaults to ~/.reviews/<author>/<repo>/<N>" test -f "$SANDBOX/home/.reviews/alice/widgets/7/pr7-review.md"
store_run env OLLAMA_API_KEY=test-key-not-real "$HERE/../intense-review/intense-review.sh" 7 --no-brief
check "intense defaults to ~/.reviews/_intense" test -f "$SANDBOX/home/.reviews/_intense/alice/widgets/7/pr7-review.md"
store_run env PR_REVIEW_DIR="$SANDBOX/moved" OLLAMA_API_KEY=test-key-not-real \
  "$HERE/../intense-review/intense-review.sh" 7 --no-brief
check "  and follows PR_REVIEW_DIR" test -f "$SANDBOX/moved/_intense/alice/widgets/7/pr7-review.md"

CFG="$SANDBOX/config.env"
printf 'PR_REVIEW_FIX_AUTHORS=alice\nPR_REVIEW_DIR=%s\n' "$SANDBOX/from-config" > "$CFG"; chmod 600 "$CFG"
store_run env -u PR_REVIEW_FIX_AUTHORS REVIEW_SKILLS_CONFIG="$CFG" "$HERE/pr-review.sh" 7 --no-brief
check "the config file sets the store" test -f "$SANDBOX/from-config/alice/widgets/7/pr7-review.md"
check "the config file sets the fix authors" test "$(fixes)" = 1
store_run env PR_REVIEW_FIX_AUTHORS= REVIEW_SKILLS_CONFIG="$CFG" "$HERE/pr-review.sh" 7 --no-brief
check "the environment beats the config file" test "$(fixes)" = 0
store_run env -u PR_REVIEW_FIX_AUTHORS -u PEER_REVIEW_FIX_AUTHORS REVIEW_SKILLS_CONFIG=/nonexistent \
  "$HERE/pr-review.sh" 7 --no-brief
check "with no fix authors configured, no fix PR" test "$(fixes)" = 0

store_run "$HERE/pr-review.sh" acme/widgets#7 --no-brief
check "owner/repo#N is accepted" test -f "$SANDBOX/home/.reviews/alice/widgets/7/pr7-review.md"
store_run "$HERE/pr-review.sh" https://github.com/acme/widgets/pull/7 --no-brief
check "a PR URL is accepted" test "$rc" = 0
store_run "$HERE/pr-review.sh" other/thing#7 --no-brief
check "a PR in another repo is refused" test "$rc" = 1
check "  naming both repos" grep -q 'other/thing.*acme/widgets' "$SANDBOX/store.log"
check "  before anything is spent" nolog claude-find
store_run "$HERE/pr-review.sh" 7x
check "junk is refused" test "$rc" = 1

[ "$fail" -eq 0 ] && { echo; printf '\033[32mall offline checks passed\033[0m\n'; } \
                  || { echo; printf '\033[31moffline checks FAILED\033[0m\n'; }
exit $fail
