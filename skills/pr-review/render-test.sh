#!/usr/bin/env bash
# What a review says, and to whom: report.jq (the local report), confirmed.jq (every public
# body) and inline.py (the inline payload), on real merged.json fixtures. Pure: no model, no
# network -- gh is a stub that serves one PR's file list. offline-test.sh runs it too.
#
#   fixtures/merged-2382.json  6 CONFIRMED, 5 of them in tests, no titles (an old run)
#   fixtures/merged-2387.json  one defect found by both finders: a mutual .also pair
#   fixtures/merged-synthetic.json  every edge at once: a title, no severity/repro/title, an
#                              .also pair whose verdicts differ, a REFUTED, an @ to quiet,
#                              evidence holding a fence, a finding off the diff
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FX="$HERE/fixtures"
T="$(mktemp -d "${TMPDIR:-/tmp}/render-test.XXXXXX")"; trap 'rm -rf "$T"' EXIT
PY="${PYTHON:-python3}"

fail=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=1; }
check() { desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }
has()    { grep -qF -- "$2" "$1"; }
hasnt()  { ! grep -qF -- "$2" "$1"; }
count()  { grep -cE -- "$2" "$1" || true; }     # count <file> <ere>
is()     { [ "$1" = "$2" ]; }
# A missing field rendered as jq's null: alone, bolded, in a marker, or as a word of its own.
nonull() { ! grep -qE -- '(^|\*\*|`| )null($|\*\*|`|:| ·)' "$1"; }

render() {  # render <fixture> <out> [gaps]
  jq -r -L "$HERE" -f "$HERE/report.jq" --arg pr 2382 --arg title "feat: a title" \
    --arg url "https://github.com/acme/widgets/pull/2382" \
    --arg sha 84cb6995e85dd5e6754997892b6736cdae877ae8 --arg om "opus-5.5/max + gemini-3.8-flash" \
    --arg gm glm-5.3-flash --arg same 0 --arg burden "${BURDEN:-evidence}" --arg gaps "${3:-}" --arg gap_notes "" "$1" > "$2" || true
}
# ids <fixture> [select]: the ids of the findings matching a jq condition
ids() { jq -r ".[] | select(${2:-true}) | .id" "$1"; }

BANNER='> ⚠️ **Incomplete.** These review slices produced nothing: agy.t05. The files in them were **not reviewed** — absence of a finding there means absence of a reviewer, not absence of a bug.'

echo "report.jq -- the outcome first"
render "$FX/merged-2382.json" "$T/2382.md" " agy.t05"
render "$FX/merged-2382.json" "$T/2382-whole.md"
render "$FX/merged-synthetic.json" "$T/syn.md"
render "$FX/merged-2387.json" "$T/2387.md"
check "line 1 is the title"                       is "$(sed -n 1p "$T/2382.md")" "# PR #2382 — feat: a title"
check "line 3 is the outcome, with severity counts and the code/test split" \
  is "$(sed -n 3p "$T/2382.md")" "**6 survived refutation · 0 disputed · 0 refuted.** 3 🟠 medium · 3 🟡 low · 1 code defect, 5 test gaps"
check "  every severity, worst first, unrated last" \
  is "$(sed -n 3p "$T/syn.md")" "**4 survived refutation · 1 disputed · 1 refuted.** 1 🔴 high · 1 🟠 medium · 1 🟡 low · 1 ⚪ unrated · 3 code defects, 1 test gap"
check "  a report indexer's counts regex still parses it" \
  is "$(sed -n 3p "$T/2382.md" | "$PY" -c 'import re,sys; m=re.search(r"\*\*(\d+) survived refutation . (\d+) disputed . (\d+) refuted", sys.stdin.read()); print(m and m.groups())')" "('6', '0', '0')"
check "with gaps, the Incomplete banner is byte-identical"   is "$(sed -n 5p "$T/2382.md")" "$BANNER"
check "  and report.jq still holds it verbatim"   has "$HERE/report.jq" '"> ⚠️ **Incomplete.** These review slices produced nothing:\($gaps). The files in them were **not reviewed** — absence of a finding there means absence of a reviewer, not absence of a bug."'
check "without gaps, no banner"                   hasnt "$T/2382-whole.md" "**Incomplete.**"
check "the head, the PR, who found and who refuted, in one line" \
  has "$T/2382.md" '`84cb6995e85d` · [PR](https://github.com/acme/widgets/pull/2382) · found by opus-5.5/max + gemini-3.8-flash · refuted by glm-5.3-flash ([method](#method))'
check "the method is a heading the line links to"  is "$(count "$T/2382.md" '^### Method$')" 1
check "  and says what the refuter needed"        has "$T/2382.md" "A refutation needed quoted counter-evidence"
BURDEN=strict render "$FX/merged-2382.json" "$T/2382-strict.md"
check "  under strict, UNVERIFIABLE stays for state outside the repo" has "$T/2382-strict.md" "UNVERIFIABLE only when the outcome depends on state outside the repository"

# No-loss: every field of every finding that survived is in the report, verbatim. The
# refuter's reasoning and evidence sit inside a <details>, one click away, never outside.
NOLOSS='
import json, re, sys
findings, text = json.load(open(sys.argv[1])), open(sys.argv[2]).read()
folded = "".join(re.findall(r"<details>.*?</details>", text, re.S))
outside = re.sub(r"<details>.*?</details>", "", text, flags=re.S)
for f in findings:
    if f["v"]["verdict"] == "REFUTED":
        continue
    for k in ("claim", "mechanism", "repro"):
        if f.get(k) and f[k] not in text:
            sys.exit(f["id"] + "." + k + " lost")
    v = f["v"]
    if v.get("correction") and v["correction"] not in outside:
        sys.exit(f["id"] + ".correction folded or lost")
    for k in ("reason", "evidence"):
        if v.get(k) and v[k] not in folded:
            sys.exit(f["id"] + ".v." + k + " not in a <details>")
        if v.get(k) and v[k] in outside:
            sys.exit(f["id"] + ".v." + k + " also outside the <details>")
'

echo "report.jq -- one row and one section per finding, nothing lost"
for f in 2382 2387 synthetic; do
  out="$T/$f.md"; [ "$f" != synthetic ] || out="$T/syn.md"
  for id in $(ids "$FX/merged-$f.json" '.v.verdict != "REFUTED"'); do
    esc="$(printf '%s' "$id" | sed 's/[.]/\\./g')"
    check "$f: $id opens exactly one table row"  is "$(count "$out" "^\\| $esc \\| ")" 1
    check "$f: $id opens exactly one ## section" is "$(count "$out" "^## $esc — ")" 1
  done
  check "$f: every field of every surviving finding appears verbatim" \
    "$PY" -c "$NOLOSS" "$FX/merged-$f.json" "$out"
done
check "the table is | # | Sev | Where | What breaks |" has "$T/2382.md" "| # | Sev | Where | What breaks |"
check "a row names the file, not its whole path"  has "$T/2382.md" '| anthropic.t03-F1 | 🟠 | `pq_signing_chain_test.dart:1507` |'
check "the section names the whole path"          has "$T/2382.md" '🟠 medium · `packages/at_client/test/pq_signing_chain_test.dart:1507` · **CONFIRMED**'
check "medium rows come before low ones"          is "$(grep -m1 -E '^\| anthropic\.' "$T/2382.md" | cut -d'|' -f3 | tr -d ' ')" "🟠"
check "the verification folds, counting its quoted lines" \
  has "$T/syn.md" "<details><summary>Verification — glm-5.3-flash: CONFIRMED · 4 quoted lines</summary>"
check "evidence holding a fence gets a longer one" has "$T/syn.md" '````'
check "a correction stays visible"                has "$T/syn.md" "**Refuter's correction.** Only the second call leaks"
check "the title heads the row and the section"   has "$T/syn.md" "## anthropic.c01-F1 — Cache survives reset"
check "  a | in a cell can't split the row"       has "$T/syn.md" '| anthropic.c02-F1 | 🟡 | `b.dart:3` | The timer is never cancelled. |'
check "with no title, the claim heads both"       has "$T/2382.md" "## anthropic.c03-F1 — $(jq -r '.[0].claim' "$FX/merged-2382.json")"
check "a disputed finding says so in its row"     grep -qE '^\| agy\.c02-F1 \| .* ⚠️ UNVERIFIABLE' "$T/syn.md"
check "no field renders as null"                  nonull "$T/syn.md"
check "the refuted one is kept, collapsed"        has "$T/syn.md" "<details><summary><b>1 finding(s) refuted by glm-5.3-flash</b> — kept so a wrong refutation stays visible</summary>"
check "the report quiets nothing: it is local, and verbatim" has "$T/syn.md" "so @foo reads"

echo "report.jq -- one defect found twice"
check "2387: the pair is one entry naming both ids" \
  has "$T/2387.md" 'Also found by `agy.t01-F1`'
check "  the second keeps its own section, pointing back" \
  has "$T/2387.md" "Same defect as [anthropic.t01-F1](#"
check "  its write-up is folded, not lost"        is "$(count "$T/2387.md" '^<details><summary>agy\.t01-F1')" 1
check "a pair whose verdicts differ is not merged" hasnt "$T/syn.md" "Same defect as"

echo "confirmed.jq -- what goes public"
cmd() { jq -L "$HERE" -r "include \"confirmed\"; $2" "$1" || true; }
cmd "$FX/merged-2382.json" confirmed_md > "$T/md"
cmd "$FX/merged-2382.json" confirmed_full > "$T/full"
cmd "$FX/merged-synthetic.json" confirmed_md > "$T/syn-md"
cmd "$FX/merged-synthetic.json" confirmed_full > "$T/syn-full"
cmd "$FX/merged-2387.json" confirmed_md > "$T/2387-md"
markers_in() {  # every CONFIRMED id's `file:line` is in <file>
  jq -r '.[] | select(.v.verdict == "CONFIRMED") | "`\(.file):\(.line)`"' "$1" | while IFS= read -r m; do
    grep -qF -- "$m" "$2" || { echo "missing $m"; return 1; }; done
}
no_mechanism() {
  jq -r '.[] | select(.v.verdict == "CONFIRMED") | .mechanism' "$1" | while IFS= read -r m; do
    ! grep -qF -- "$m" "$2" || { echo "carries $m"; return 1; }; done
}
for f in md full syn-md syn-full; do
  src="$FX/merged-2382.json"; case "$f" in syn-*) src="$FX/merged-synthetic.json" ;; esac
  check "$f: one marker per CONFIRMED id"         markers_in "$src" "$T/$f"
  check "$f: no mechanism"                         no_mechanism "$src" "$T/$f"
  check "$f: no null"                              nonull "$T/$f"
done
check "confirmed_md: one bullet per defect"       is "$(count "$T/md" '^- `')" 6
check "  the title when there is one"             has "$T/syn-md" '- `lib/a.dart:5` — Cache survives reset'
check "  else the claim's first sentence"         has "$T/syn-md" '- `lib/a.dart:8` — Old value leaks past the reset.'
check "  the unconfirmed half of a pair stays out" hasnt "$T/syn-md" "lib/b.dart:4"
check "  2387: one bullet for the pair, its marker kept" \
  is "$(count "$T/2387-md" '^- `packages/at_onboarding_cli/lib/src/cli/auth_cli\.dart:1080`')" 1
check "confirmed_full: the claim in full, and the repro" has "$T/full" "$(jq -r '.[2].repro' "$FX/merged-2382.json")"
check "  an @ that starts a word is quieted"      has "$T/syn-full" "so @⁠foo reads"
check "  in the repro too"                        has "$T/syn-full" "via @⁠bar."
check "  and no live one is left"                 hasnt "$T/syn-full" "@foo"

body() { jq -L "$HERE" -r --arg sha "$2" --argjson full "$3" \
           "include \"confirmed\"; [.[] | select(.v.verdict == \"CONFIRMED\")] | review_body(\$sha; \"REQUEST_CHANGES\"; \$full)" "$1"; }
body "$FX/merged-2382.json" 84cb6995e85dd5e6754997892b6736cdae877ae8 '[]' > "$T/rc"
check "a change request opens with its verdict"   is "$(sed -n 1p "$T/rc")" 'Requesting changes at `84cb6995e85d`: 6 confirmed defects (3 medium, 3 low), each inline below.'
check "  then one bullet per defect"              is "$(count "$T/rc" '^- `')" 6
body "$FX/merged-2387.json" aaaaaaaaaaaaaaaa '[]' > "$T/rc87"
check "  a defect found twice counts once"        is "$(sed -n 1p "$T/rc87")" 'Requesting changes at `aaaaaaaaaaaa`: 1 confirmed defect (1 medium), inline below.'
body "$FX/merged-synthetic.json" bbbbbbbbbbbbbbbb '["anthropic.t04-F1"]' > "$T/rcsyn"
check "  one with no comment goes in full instead" has "$T/rcsyn" "**No test covers a double reset** (\`test/z_test.dart:40\`)"
check "  and is not also a bullet"                hasnt "$T/rcsyn" '- `test/z_test.dart:40`'
check "  the verdict says which are inline"       is "$(sed -n 1p "$T/rcsyn")" 'Requesting changes at `bbbbbbbbbbbb`: 4 confirmed defects (1 high, 1 medium, 1 low, 1 unrated), inline below where the diff has the line.'

echo "inline.py -- the payload GitHub takes"
mkdir -p "$T/bin"
printf '%s\n' '#!/usr/bin/env bash' 'echo "$*" >> "$STUB_LOG"' \
  'case "$*" in *"/pulls/"*"/files"*) cat "$STUB_FILES" ;; *) exit 1 ;; esac' > "$T/bin/gh"
chmod +x "$T/bin/gh"
printf '%s' '[[{"filename":"lib/a.dart","patch":"@@ -1,3 +1,10 @@\n+x"},{"filename":"lib/b.dart","patch":"@@ -1,2 +1,5 @@\n+y"},{"filename":"packages/at_onboarding_cli/lib/src/cli/auth_cli.dart","patch":"@@ -1070,5 +1070,20 @@\n+z"}]]' > "$T/files.json"
printf '%s' '{"number":7,"url":"https://github.com/acme/widgets/pull/7","headRefOid":"cccccccccccccccccccccccccccccccccccccccc"}' > "$T/meta.json"
inline() { STUB_LOG="$T/gh.log" STUB_FILES="$T/files.json" PATH="$T/bin:$PATH" \
             "$PY" "$HERE/inline.py" --merged "$1" --meta "$T/meta.json" "${@:2}"; }
inline "$FX/merged-synthetic.json" --event REQUEST_CHANGES --out "$T/rc.json" 2>/dev/null || true
inline "$FX/merged-synthetic.json" > "$T/c.json" || true
inline "$FX/merged-2387.json" --event REQUEST_CHANGES > "$T/87.json" || true
check "the repo comes from meta.json's url"       grep -qF "repos/acme/widgets/pulls/7/files" "$T/gh.log"
check "event and commit_id are pinned"            is "$(jq -r '"\(.event) \(.commit_id)"' "$T/rc.json")" "REQUEST_CHANGES cccccccccccccccccccccccccccccccccccccccc"
check "a change request carries only CONFIRMED"   is "$(jq -c '[.comments[].marker]' "$T/rc.json")" '["`lib/a.dart:5`","`lib/b.dart:3`","`lib/a.dart:8`"]'
check "  and its body is review_body's"           is "$(jq -r .body "$T/rc.json")" "$(body "$FX/merged-synthetic.json" cccccccccccccccccccccccccccccccccccccccc '["anthropic.t04-F1"]')"
check "a comment is the claim and the repro"      is "$(jq -r '.comments[0].body' "$T/rc.json")" "$(printf '%s\n\n%s' '**🔴 high — reset() leaves the cache | full, so @⁠foo reads a stale value.**' 'Call reset() twice, then read via @⁠bar.')"
check "  no live @ in any comment"                is "$(jq '[.comments[].body | select(test("(?<![A-Za-z0-9])@(?=[A-Za-z0-9_])"))] | length' "$T/rc.json")" 0
check "  no mechanism, no evidence"               is "$(jq '[.comments[].body | select(test("returns before|_cache.clear"))] | length' "$T/rc.json")" 0
check "a missing severity or repro is not null"   is "$(jq -r '.comments[2].body' "$T/rc.json")" '**⚪ unrated — Old value leaks past the reset. A second reset() returns it.**'
check "a COMMENT review keeps disputed findings"  is "$(jq '.comments | length' "$T/c.json")" 4
check "  and says they're disputed"               jq -e '.comments[] | select(.marker == "`lib/b.dart:4`") | .body | test("UNVERIFIABLE")' "$T/c.json"
check "2387: one comment for the pair"            is "$(jq '.comments | length' "$T/87.json")" 1
check "a line inside a hunk is anchored exactly there" \
  jq -e '.comments[] | select(.marker == "`lib/a.dart:8`") | .line == 8' "$T/rc.json"

[ "$fail" = 0 ] && echo "all passed" || { echo "FAILURES"; exit 1; }
