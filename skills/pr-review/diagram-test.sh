#!/usr/bin/env bash
# The brief's diagram: diagram.sh (extract, check, one repair, write) and diagram-backfill.sh
# (the same over every store, no model). claude is a stub that logs each call and answers
# STUB_REPAIR (good | bad | fail), so this costs nothing. node and ./mermaid must be
# installed (selftest.sh does it). offline-test.sh runs it too.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FX="$HERE/fixtures"
T="$(mktemp -d "${TMPDIR:-/tmp}/diagram-test.XXXXXX")"; trap 'rm -rf "$T"' EXIT
export STUB_LOG="$T/log"; mkdir -p "$STUB_LOG" "$T/stub"

fail=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=1; }
check() { desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }
calls() { ls "$STUB_LOG" | grep -c '^repair\.' || true; }
is()    { [ "$1" = "$2" ]; }
meta()  { jq -r "$2" "$1"; }

GOOD='flowchart LR
  A["serveHttpOn()"] --> B["handleFoo"]'
QUOTED="$(sed 's/subgraph Envelope §9.4/subgraph Envelope["Envelope §9.4"]/' "$FX/diagram-subgraph-unquoted.mmd")"

cat > "$T/stub/claude" <<'STUB'
#!/usr/bin/env bash
# Logs argv (the prompt to its own file) and answers per STUB_REPAIR.
n="$(ls "$STUB_LOG" | grep -c '^repair\.' || true)"
prev=""
for a in "$@"; do
  [ "$prev" = -p ] && printf '%s\n' "$a" > "$STUB_LOG/prompt.$n"
  prev="$a"
done
printf '%s\n' "$@" > "$STUB_LOG/repair.$n"
case "${STUB_REPAIR:-good}" in
  fail) exit 1 ;;
  good) block="$STUB_GOOD" ;;
  bad)  block="flowchart LR\n  subgraph Still §broken\n  end" ;;
esac
body="Here it is:\n\n\`\`\`mermaid\n$block\n\`\`\`\n"
printf '[{"type":"system"},{"type":"result","is_error":false,"result":"%s"}]\n' "$body"
STUB
chmod +x "$T/stub/claude"
export STUB_GOOD="$(printf '%s' "$QUOTED" | awk '{printf "%s\\n", $0}' | sed 's/"/\\"/g; s/\\n$//')"

explainer() {   # explainer <dir> <pr> <block>: a brief with prose around one mermaid block
  mkdir -p "$1"
  printf '# PR #%s — t\n\nBrief by claude-sonnet-5-5. Written from the diff.\n\n## How it fits together\n\n```mermaid\n%s\n```\n\nprose after\n' \
    "$2" "$3" > "$1/pr$2-explainer.md"
}
run() { PATH="$T/stub:$PATH" "$HERE/diagram.sh" "$@" 2>>"$T/err" && rc=0 || rc=$?; }

echo "diagram.sh -- a valid diagram"
D="$T/s/gkc/widgets/1"; explainer "$D" 1 "$GOOD"; cp "$D/pr1-explainer.md" "$T/before.md"
run --sha abc123 --model m1 --repair "$D/pr1-explainer.md" "$FX/diagram-grounding.diff"
check "the block lands in pr<N>-diagram.mmd" is "$(cat "$D/pr1-diagram.mmd")" "$GOOD"
check "status ok, no error" is "$(meta "$D/pr1-diagram.json" '[.status, .error] | @tsv')" "ok	"
check "grounding: handleFoo isn't in the diff" is "$(meta "$D/pr1-diagram.json" '.ungrounded | join(",")')" handleFoo
check "sha and model are recorded" is "$(meta "$D/pr1-diagram.json" '"\(.sha) \(.model)"')" "abc123 m1"
check "a valid diagram costs no call" is "$(calls)" 0
check "the explainer is untouched" cmp -s "$D/pr1-explainer.md" "$T/before.md"

echo "diagram.sh -- a broken diagram, no repair asked"
D="$T/s/gkc/widgets/2"; explainer "$D" 2 "$(cat "$FX/diagram-subgraph-unquoted.mmd")"
run --sha s --model m "$D/pr2-explainer.md" "$FX/diagram-grounding.diff"
check "status invalid with mermaid's error" is "$(meta "$D/pr2-diagram.json" '.status')" invalid
check "the error is mermaid's own" grep -q 'Lexical error' "$D/pr2-diagram.json"
check "no .mmd for an invalid diagram: the page shows the explainer's raw block" test ! -e "$D/pr2-diagram.mmd"
check "no repair without --repair" is "$(calls)" 0

echo "diagram.sh -- one repair that parses"
D="$T/s/gkc/widgets/3"; explainer "$D" 3 "$(cat "$FX/diagram-subgraph-unquoted.mmd")"
run --sha s --model claude-sonnet-5-5 --repair "$D/pr3-explainer.md" "$FX/diagram-grounding.diff"
check "exactly one repair call" is "$(calls)" 1
check "status repaired" is "$(meta "$D/pr3-diagram.json" '.status')" repaired
check "the repaired block is the .mmd" is "$(cat "$D/pr3-diagram.mmd")" "$QUOTED"
check "the explainer now carries the repaired block" grep -qF 'subgraph Envelope["Envelope §9.4"]' "$D/pr3-explainer.md"
check "the rest of the explainer is kept" grep -q '^prose after$' "$D/pr3-explainer.md"
check "the repair ran on the brief's model" grep -qx claude-sonnet-5-5 "$STUB_LOG/repair.0"
check "the repair ran at low effort" grep -qx low "$STUB_LOG/repair.0"
check "the repair had no tools" grep -qx Read "$STUB_LOG/repair.0"
check "the repair prompt carries the parse error" grep -q 'Lexical error' "$STUB_LOG/prompt.0"
check "the repair prompt carries the changed files" grep -q 'at_root_server_impl.dart' "$STUB_LOG/prompt.0"
check "the repair prompt carries no diff body" bash -c "! grep -q 'runZonedGuarded' '$STUB_LOG/prompt.0'"

echo "diagram.sh -- a repair that still fails, and one that errors"
rm -f "$STUB_LOG"/*
D="$T/s/gkc/widgets/4"; explainer "$D" 4 "$(cat "$FX/diagram-subgraph-unquoted.mmd")"; cp "$D/pr4-explainer.md" "$T/before.md"
STUB_REPAIR=bad run --sha s --model m --repair "$D/pr4-explainer.md" "$FX/diagram-grounding.diff"
check "still one call, never a second" is "$(calls)" 1
check "status invalid" is "$(meta "$D/pr4-diagram.json" '.status')" invalid
check "the explainer keeps its raw block" cmp -s "$D/pr4-explainer.md" "$T/before.md"
check "a failed diagram is not a failed run" is "$rc" 0
rm -f "$STUB_LOG"/*
STUB_REPAIR=fail run --sha s --model m --repair "$D/pr4-explainer.md" "$FX/diagram-grounding.diff"
check "an erroring repair call is invalid too, exit 0" is "$(meta "$D/pr4-diagram.json" '.status') $rc" "invalid 0"

echo "diagram.sh -- no diagram at all"
D="$T/s/gkc/widgets/5"; mkdir -p "$D"; printf '# PR\n\n```dart\nvoid f() {}\n```\n' > "$D/pr5-explainer.md"
echo stale > "$D/pr5-diagram.mmd"; echo '{}' > "$D/pr5-diagram.json"
run --sha s --model m --repair "$D/pr5-explainer.md" "$FX/diagram-grounding.diff"
check "a brief with no mermaid block leaves no diagram files, stale ones removed" \
  bash -c "! ls '$D'/pr5-diagram.* 2>/dev/null"
D="$T/s/gkc/widgets/6"; explainer "$D" 6 "$GOOD"; sed -i '' '/^```$/d' "$D/pr6-explainer.md"
run --sha s --model m "$D/pr6-explainer.md" "$FX/diagram-grounding.diff"
check "an unclosed fence is no diagram" bash -c "! ls '$D'/pr6-diagram.* 2>/dev/null"

echo "diagram.sh -- no diff: grounding not checked"
D="$T/s/gkc/widgets/7"; explainer "$D" 7 "$GOOD"
run --sha s --model m "$D/pr7-explainer.md" -
check "ungrounded is null, not empty" is "$(meta "$D/pr7-diagram.json" '.ungrounded')" null

echo "diagram-backfill.sh -- every store, no model, idempotent"
rm -rf "$T/s" "$STUB_LOG"; mkdir -p "$STUB_LOG"
for s in a b; do
  explainer "$T/s/$s/gkc/widgets/10" 10 "$GOOD"
  printf '{"headRefOid":"sha%s"}\n' "$s" > "$T/s/$s/gkc/widgets/10/meta.json"
done
explainer "$T/s/b/alice/widgets/11" 11 "$(cat "$FX/diagram-subgraph-unquoted.mmd")"
mkdir -p "$T/s/b/bob/widgets/12"; echo "# no explainer" > "$T/s/b/bob/widgets/12/pr12-review.md"
backfill() { PATH="$T/stub:$PATH" "$HERE/diagram-backfill.sh" "$T/s/a" "$T/s/b" >"$T/bf.out" 2>&1 || true; }
backfill
check "both stores' diagrams written" test -s "$T/s/a/gkc/widgets/10/pr10-diagram.mmd" -a -s "$T/s/b/gkc/widgets/10/pr10-diagram.mmd"
check "the head comes from meta.json" is "$(meta "$T/s/b/gkc/widgets/10/pr10-diagram.json" .sha)" shab
check "the model comes from the explainer's byline" is "$(meta "$T/s/b/gkc/widgets/10/pr10-diagram.json" .model)" claude-sonnet-5-5
check "a broken one is recorded invalid, not repaired" is "$(meta "$T/s/b/alice/widgets/11/pr11-diagram.json" .status)" invalid
check "a run with no explainer is skipped" bash -c "! ls '$T/s/b/bob/widgets/12'/pr12-diagram.* 2>/dev/null"
check "backfill makes no model call" is "$(calls)" 0
touch -t 202001010000 "$T"/s/*/*/*/*/pr*-diagram.*
before="$(ls -lT "$T"/s/*/*/*/*/pr*-diagram.* | awk '{print $6,$7,$8,$9}')"
backfill
check "a second run rewrites nothing" is "$(ls -lT "$T"/s/*/*/*/*/pr*-diagram.* | awk '{print $6,$7,$8,$9}')" "$before"

[ "$fail" -eq 0 ] && echo "all passed" || { echo "FAILED"; cat "$T/err" >&2; exit 1; }
