#!/usr/bin/env bash
# Exercises stage 1 slicing, id namespacing, gap reporting, caching, and the merge —
# with both models stubbed, so it costs nothing and can run on every edit.
#
# What it cannot test: whether the models are any good. That is selftest.sh (discrimination)
# and the T6 end-to-end run. This tests the plumbing those two depend on.
set -euo pipefail

PIN_PR="${1:-2179}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git rev-parse --show-toplevel)" || { echo "run this inside the repo under review" >&2; exit 1; }
# Templated on purpose: BSD mktemp -d with no template ignores TMPDIR and lands in the
# per-user /var/folders dir, which is unwritable under a Seatbelt sandbox.
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/pr-review-test.XXXXXX")"
export TMPDIR="$SANDBOX"                           # keeps the slice cache out of the real one
# The review store is redirected into the sandbox, so the test never touches the real
# ~/work/reviews and needs no save/restore dance around a pre-existing report.
export PR_REVIEW_DIR="$SANDBOX/reviews"
export PR_REVIEW_INTENSE_DIR="$SANDBOX/reviews-intense"
export STUB_LOG="$SANDBOX/log"
AUTHOR="$(gh pr view "$PIN_PR" --json author -q '.author.login' 2>/dev/null || echo unknown)"
REPORT="$PR_REVIEW_DIR/${AUTHOR#app/}/$PIN_PR/pr${PIN_PR}-review.md"
BRIEF="$PR_REVIEW_DIR/${AUTHOR#app/}/$PIN_PR/pr${PIN_PR}-explainer.md"
INLINE="$PR_REVIEW_DIR/${AUTHOR#app/}/$PIN_PR/inline.json"
IREPORT="$PR_REVIEW_INTENSE_DIR/${AUTHOR#app/}/$PIN_PR/pr${PIN_PR}-review.md"
IMERGED="$PR_REVIEW_INTENSE_DIR/${AUTHOR#app/}/$PIN_PR/merged.json"
IBRIEF="$PR_REVIEW_INTENSE_DIR/${AUTHOR#app/}/$PIN_PR/pr${PIN_PR}-explainer.md"

fail=0
cleanup() {
  rm -rf "$SANDBOX"
  git -C "$ROOT" worktree prune >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
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
    for a in "$@"; do [ ${#a} -gt 200 ] || echo "arg=$a"; done
  } > "$f"
}
claim_id() { printf '%s\n' "$1" | sed -n 's/.*"id"[: ]*"\([^"]*\)".*/\1/p' | head -1; }
STUB
cat > "$SANDBOX/stub/claude" <<'STUB'
#!/usr/bin/env bash
. "$(dirname "$0")/log.sh"
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
case "$key" in *c02) echo '{"type":"result","result":"simulated slice failure"}'; exit 1 ;; esac
# A test slice records what context it was handed: how many feature findings the file it was
# pointed at holds, and whether the brief it was pointed at exists.
case "$key" in *t[0-9][0-9])
  ff="$(printf '%s\n' "$prompt" | sed -n 's|.*feature review.s findings are at \([^ ]*\) .*|\1|p' | head -1)"
  br="$(printf '%s\n' "$prompt" | sed -n 's|.*The brief is at \([^ ]*\) .*|\1|p' | head -1)"
  { echo "n=$(jq '.findings|length' "$ff" 2>/dev/null || echo missing)"
    if [ -s "$br" ]; then echo brief=yes; else echo brief=none; fi
  } > "$(mktemp "$STUB_LOG/tctx.XXXXXX")" ;;
esac
first="$(sed -n 's|^+++ b/||p' "$diff" | head -1)"
printf '{"findings":[{"id":"F1","file":"%s","line":42,"severity":"medium","claim":"stub %s","mechanism":"stub","repro":"stub"}]}\n' \
  "$first" "$key" > "$out"
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
case "$schema" in
  *findings.schema.json)
    stub_log agy-find "$@"
    diff="$(printf '%s\n' "$p" | sed -n 's|.*The diff under review is at \([^ ]*\) and.*|\1|p' | head -1)"
    first="$(sed -n 's|^+++ b/||p' "$diff" | head -1)"
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
# Stage 5's autofix, stubbed for every run: #2179's author is a default fix author, so the
# real one would open a PR. Logs its mode, reviewer and argv; answers STUB_AUTOFIX_STATUS.
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
PATH="$SANDBOX/stub:$PATH" "$HERE/pr-review.sh" "$PIN_PR" --no-cache > "$SANDBOX/run1.log" 2>&1 \
  || { cat "$SANDBOX/run1.log"; bad "first run exited non-zero"; exit 1; }

grep -q 'slice(s) + 1 cross-cutting pass' "$SANDBOX/run1.log" \
  && ok "diff was sliced, cross-cutting pass added" || bad "no slicing happened"
grep -q 'test file(s) held for the test pass' "$SANDBOX/run1.log" \
  && ok "test files held out of the feature slices" || bad "tests were not held out"
# The test pass reviews tests against what the feature review found, so it must start only
# once every feature slice has finished.
check "the test pass ran after every feature slice" awk '
  /    (c[0-9][0-9]|_cross) / { last = NR }
  /    t[0-9][0-9] / && !first { first = NR }
  END { exit !(first && last && last < first) }' "$SANDBOX/run1.log"
MERGED="$PR_REVIEW_DIR/${AUTHOR#app/}/$PIN_PR/merged.json"
check "test files were reviewed, in t-slices" \
  jq -e 'any(.[]; (.id | startswith("t")) and (.file | test("(^|/)tests?/|_test\\.dart$")))' "$MERGED"
check "the test pass was handed the feature findings" every tctx '^n=[1-9]'
check "the test pass was handed the brief" every tctx '^brief=yes'
grep -q 'no findings from: c02' "$SANDBOX/run1.log" \
  && ok "failed slice reported as a coverage gap, run continued" || bad "a failed slice did not surface"
[ -f "$REPORT" ] && ok "report written despite the failed slice" || bad "no report written"
grep -q '⚠️ \*\*Incomplete' "$REPORT" \
  && ok "report carries the incomplete-coverage banner" || bad "banner missing from report"
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
check "the default finder ran at xhigh" every claude-find '^arg=xhigh$'
check "the default finder is budget-capped" every claude-find '^arg=--max-budget-usd$'
check "the finder ran without your settings and hooks" every claude-find '^arg=--setting-sources$'

# ------------------------------------------------------------------ stage 0.5 brief
check "the brief was written beside the report" test -f "$BRIEF"
check "the brief ran on sonnet" every claude-brief '^arg=claude-sonnet-5-5$'
check "the brief ran at medium effort, not the finder's xhigh" every claude-brief '^arg=medium$'
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

PATH="$SANDBOX/stub:$PATH" "$HERE/pr-review.sh" "$PIN_PR" > "$SANDBOX/run2.log" 2>&1 || true
[ "$(grep -c 'cached' "$SANDBOX/run2.log")" -ge 3 ] \
  && ok "second run resumed from cache" || bad "cache did not resume — a 429 would cost full price again"
grep -q 'c02     FAILED' "$SANDBOX/run2.log" \
  && ok "the failed slice was retried, not cached" || bad "a failed slice got cached"
check "the brief cache is keyed on brief.prompt, so editing the prompt misses it" \
  ls "$SANDBOX/pr-review-cache/brief-"*"-$(cksum < "$HERE/brief.prompt" | awk '{print $1}')-"*
check "a cached brief's diagram is checked again" test "$(jq -r .status "$DIAG.json")" = ok

# ------------------------------------------------------------------ intense preset
echo "intense preset — two finders, ollama refuter, evidence burden"
DEFAULT_SUM="$(cksum < "$REPORT")"
rm -rf "$STUB_LOG"; mkdir -p "$STUB_LOG"
PATH="$SANDBOX/stub:$PATH" OLLAMA_API_KEY=test-key-not-real STUB_BARE=1 STUB_DIAGRAM=bad \
  "$HERE/../intense-review/intense-review.sh" "$PIN_PR" --no-cache > "$SANDBOX/run3.log" 2>&1 \
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
check "the claude finder ran at --effort max" every claude-find '^arg=max$'
check "the claude finder ran with no budget cap" never claude-find '^arg=--max-budget-usd$'
check "the agy finder ran inside the tree" every agy-find '^cwd=.*/tree$'
check "the agy finder was handed the findings schema" every agy-find '^arg=.*/findings\.schema\.json$'
check "the refuter ran under CLAUDE_CODE_SIMPLE" every claude-refute '^CLAUDE_CODE_SIMPLE=1$'
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
check "the report names the opus finder" grep -q 'claude-opus-5-5/max' "$IREPORT"
check "the report names the gemini finder" grep -q 'gemini-3.8-flash-high' "$IREPORT"
check "the report names the refuter" grep -q 'glm-5.3-flash' "$IREPORT"
check "the report states the evidence burden" grep -q 'counter-evidence' "$IREPORT"
check "findings both finders reported are tagged" jq -e 'any(.[]; (.also // []) | length > 0)' "$IMERGED"

PATH="$SANDBOX/stub:$PATH" OLLAMA_API_KEY=test-key-not-real \
  "$HERE/../intense-review/intense-review.sh" "$PIN_PR" > "$SANDBOX/run4.log" 2>&1 || true
check "the anthropic finder resumes from its own cache" grep -q 'anthropic.c01 cached' "$SANDBOX/run4.log"
check "the agy finder resumes from its own cache" grep -q 'agy.c01 cached' "$SANDBOX/run4.log"

# ------------------------------------------------------------------- --sonnet opt-in
# The regression this guards: FINDERS used to be computed ~50 lines above the arg loop, so
# a flag that set it during parsing was overwritten by the default before stage 1 read it.
echo "--sonnet opt-in"
rm -rf "$STUB_LOG"; mkdir -p "$STUB_LOG"
PATH="$SANDBOX/stub:$PATH" "$HERE/pr-review.sh" "$PIN_PR" --sonnet --no-cache --no-brief \
  > "$SANDBOX/run5.log" 2>&1 || true
check "--sonnet reaches the finder" every claude-find '^arg=claude-sonnet-5-5$'
check "--sonnet keeps the finder's effort" every claude-find '^arg=xhigh$'
check "--no-brief fires no brief call" nolog claude-brief
check "--no-brief is reported, not silent" grep -q 'brief skipped' "$SANDBOX/run5.log"
check "--no-brief checks no diagram" bash -c "! grep -q 'diagram' '$SANDBOX/run5.log'"
check "with no brief, the test pass is told so" every tctx '^brief=none$'
check "the report names the model that actually ran" grep -q 'claude-sonnet-5-5' "$REPORT"
PATH="$SANDBOX/stub:$PATH" PR_REVIEW_FINDERS="anthropic:claude-opus-5-5@max" \
  "$HERE/pr-review.sh" "$PIN_PR" --sonnet --no-brief > "$SANDBOX/run6.log" 2>&1 || true
check "--sonnet beats PR_REVIEW_FINDERS, and says so" \
  grep -q 'overrides PR_REVIEW_FINDERS' "$SANDBOX/run6.log"
rm -rf "$STUB_LOG"; mkdir -p "$STUB_LOG"
PATH="$SANDBOX/stub:$PATH" PR_REVIEW_DIAGRAM=0 STUB_DIAGRAM=bad "$HERE/pr-review.sh" "$PIN_PR" \
  --sonnet --no-cache > "$SANDBOX/run6d.log" 2>&1 || true
check "PR_REVIEW_DIAGRAM=0 keeps the explainer" grep -q 'subgraph S §1' "$BRIEF"
check "PR_REVIEW_DIAGRAM=0 checks nothing, repairs nothing" \
  bash -c "! ls '$DIAG'.* 2>/dev/null && ! ls '$STUB_LOG'/claude-repair.* 2>/dev/null"

# ---------------------------------------------------------------- test-only PR
# Every code file of #2352 lives under tests/. When tests were excluded outright, stage 1
# reviewed only YAML and docs and the report read "No findings." with no caveat.
echo "test-only PR — #2352"
TO_PR=2352
TO_AUTHOR="$(gh pr view "$TO_PR" --json author -q '.author.login' 2>/dev/null || echo unknown)"
TO_DIR="$PR_REVIEW_DIR/${TO_AUTHOR#app/}/$TO_PR"
rm -rf "$STUB_LOG"; mkdir -p "$STUB_LOG"
PATH="$SANDBOX/stub:$PATH" "$HERE/pr-review.sh" "$TO_PR" --no-cache --no-brief \
  > "$SANDBOX/run7.log" 2>&1 || { cat "$SANDBOX/run7.log"; bad "test-only run exited non-zero"; }
check "the e2e package's code was reviewed" \
  jq -e 'any(.[]; (.id | startswith("t")) and (.file | startswith("tests/at_end2end_test/")))' "$TO_DIR/merged.json"
check "the test pass ran on #2352" grep -qE '    t[0-9][0-9] ' "$SANDBOX/run7.log"

# ------------------------------------------------------------- stage 5: fix PR
echo "stage 5 -- a fix PR stacked on a fix author's PR"
META5="$PR_REVIEW_DIR/${AUTHOR#app/}/$PIN_PR/meta.json"
fix_run() {
  rm -rf "$STUB_LOG"; mkdir -p "$STUB_LOG"; rc=0
  PATH="$SANDBOX/stub:$PATH" "$HERE/pr-review.sh" "$PIN_PR" --no-brief "$@" > "$SANDBOX/fix.log" 2>&1 || rc=$?
}
fixes() { ls "$STUB_LOG"/autofix.* 2>/dev/null | wc -l | tr -d ' '; }
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

PR_REVIEW_FIX_AUTHORS="$AUTHOR" fix_run
check "precondition: the stub review confirmed a finding" \
  jq -e 'any(.[]; .v.verdict == "CONFIRMED")' "$PR_REVIEW_DIR/${AUTHOR#app/}/$PIN_PR/merged.json"
check "precondition: #$PIN_PR is merged" jq -e '.state == "MERGED"' "$META5"
check "a merged fix author's PR: one autofix, the trunk lane" test "$(cat "$STUB_LOG/lanes")" = trunk
check "  one-shot, not prepare" every autofix '^MODE=$'
check "  on the PR" every autofix "^arg=$PIN_PR\$"
check "  at the head the review read" every autofix "^arg=$(jq -r .headRefOid "$META5")\$"
check "  in the repo under review" every autofix "^arg=$ROOT\$"
check "  asking the author to review the fix" every autofix "^REVIEWER=${AUTHOR#app/}\$"
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
PR_REVIEW_FIX_AUTHORS="nobody, $(upper "${AUTHOR#app/}")" fix_run
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
PATH="$SANDBOX/stub:$PATH" OLLAMA_API_KEY=test-key-not-real PR_REVIEW_FIX_AUTHORS="$AUTHOR" \
  STUB_AUTOFIX_STATUS=stale STUB_AUTOFIX_RC=1 \
  "$HERE/../intense-review/intense-review.sh" "$PIN_PR" --no-brief > "$SANDBOX/fix.log" 2>&1 || rc=$?
check "intense-review: the same stage 5, and its exit 4" test "$rc" = 4

[ "$fail" -eq 0 ] && { echo; printf '\033[32mall offline checks passed\033[0m\n'; } \
                  || { echo; printf '\033[31moffline checks FAILED\033[0m\n'; }
exit $fail
