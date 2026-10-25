#!/usr/bin/env bash
# The brief's "How it fits together" diagram, checked before anyone sees it.
#
#   diagram.sh --sha SHA --model MODEL [--repair] <prN-explainer.md> <pr.diff | ->
#
# Takes the explainer's first closed ```mermaid block and runs mermaid-check.mjs on it
# (mermaid's own parser, then grounding against the diff; "-" skips grounding). With
# --repair, a block that fails to parse gets ONE call to MODEL at low effort, carrying only
# the block, the error and the changed-file list -- never the diff -- and a repair that
# parses replaces the block in the explainer. Writes beside the explainer:
#
#   prN-diagram.mmd   the block, when it parses (ok | repaired)
#   prN-diagram.json  {status: ok|repaired|invalid, error, ungrounded[] | null, model, sha}
#
# Never fails the review: exit 0 whatever the diagram's fate, 2 only on a usage error or
# when node or ./mermaid is missing. Rewrites a file only when its content changed, so a
# rerun over the same explainer leaves every mtime alone (diagram-backfill.sh relies on it).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAST_EVENT='include "last-event"; last_event'

usage() { echo "usage: diagram.sh --sha SHA --model MODEL [--repair] <prN-explainer.md> <pr.diff|->" >&2; exit 2; }
SHA=""; MODEL=""; REPAIR=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sha) SHA="$2"; shift ;;
    --model) MODEL="$2"; shift ;;
    --repair) REPAIR=1 ;;
    -*) usage ;;
    *) break ;;
  esac
  shift
done
[ $# -eq 2 ] || usage
EXPLAINER="$1"; DIFF="$2"
[ -f "$EXPLAINER" ] || usage
[ "$DIFF" = - ] && DIFF=""
command -v node >/dev/null || { echo "diagram: node not found; no diagram check" >&2; exit 2; }

BASE="${EXPLAINER%-explainer.md}-diagram"
W="$(mktemp -d "${TMPDIR:-/tmp}/diagram.XXXXXX")"; trap 'rm -rf "$W"' EXIT

# extract <markdown>: the first ```mermaid block's body, only if its fence closes.
extract() {
  awk '!s && /^```mermaid[ \t]*$/ {s=1; next}
       s==1 && /^```[ \t]*$/ {s=2; exit}
       s==1 {b = b $0 "\n"}
       END {if (s==2) printf "%s", b}' "$1"
}
# check <block> -> $W/check.json; returns mermaid-check's exit (2 = can't check at all).
check() {
  node "$HERE/mermaid-check.mjs" "$1" ${DIFF:+"$DIFF"} > "$W/check.json" && return 0 || return $?
}
# put <src> <dest>: move into place only when the bytes differ.
put() { if cmp -s "$1" "$2"; then rm -f "$1"; else mv "$1" "$2"; fi; }

extract "$EXPLAINER" > "$W/block.mmd"
if [ ! -s "$W/block.mmd" ]; then
  rm -f "$BASE.mmd" "$BASE.json"
  echo "diagram: none in $(basename "$EXPLAINER")" >&2
  exit 0
fi

STATUS=ok; ERROR=null
check "$W/block.mmd" || rc=$?
case "${rc:-0}" in
  0) ;;
  1) ERROR="$(jq '.error' "$W/check.json")"; STATUS=invalid ;;
  *) echo "diagram: mermaid-check couldn't run (selftest.sh installs ./mermaid)" >&2; exit 2 ;;
esac

if [ "$STATUS" = invalid ] && [ "$REPAIR" -eq 1 ]; then
  {
    printf 'This Mermaid diagram fails to parse in mermaid 11.16.1. Fix the syntax only: keep every\n'
    printf 'node, edge and label meaning as it is. Put any label holding a character other than a\n'
    printf 'letter, digit, underscore or space in double quotes, subgraph titles too\n'
    printf '(subgraph id["title"]). Reply with the corrected diagram alone, in one ```mermaid block.\n\n'
    printf 'Parse error:\n\n%s\n\n' "$(jq -r '.error' "$W/check.json")"
    if [ -n "$DIFF" ]; then
      printf 'Files the PR changes, for node names:\n\n'
      sed -n 's|^+++ b/||p' "$DIFF" | sed 's/^/  - /'
      printf '\n'
    fi
    printf '```mermaid\n'; cat "$W/block.mmd"; printf '```\n'
  } > "$W/repair.in"
  # Same isolation as the brief: no tools, no settings, run where there is nothing to read.
  if ( cd "$W" && claude -p "$(cat "$W/repair.in")" \
         --model "$MODEL" --effort low --output-format json \
         --strict-mcp-config --setting-sources "" \
         --disallowedTools Bash Read Grep Glob Write Edit NotebookEdit Task WebSearch WebFetch \
     ) > "$W/repair.json" 2>"$W/repair.err" \
     && jq -L "$HERE" -r "$LAST_EVENT"' | select(.is_error != true) | .result // empty' \
          "$W/repair.json" > "$W/repair.md" 2>/dev/null
  then
    extract "$W/repair.md" > "$W/fixed.mmd"
    if [ -s "$W/fixed.mmd" ] && check "$W/fixed.mmd"; then
      STATUS=repaired
      cp "$W/fixed.mmd" "$W/block.mmd"
      # The explainer is what the brief cache holds: it carries the repaired block too.
      awk -v fixed="$W/fixed.mmd" '
        !s && /^```mermaid[ \t]*$/ {print; while ((getline l < fixed) > 0) print l; s=1; next}
        s==1 && /^```[ \t]*$/ {s=2}
        s!=1 {print}' "$EXPLAINER" > "$W/explainer.md"
      put "$W/explainer.md" "$EXPLAINER"
    else
      check "$W/block.mmd" || true   # the report on what stays is the original's
    fi
  fi
fi

if [ "$STATUS" = invalid ]; then rm -f "$BASE.mmd"; else cp "$W/block.mmd" "$W/out.mmd"; put "$W/out.mmd" "$BASE.mmd"; fi
jq -n --arg status "$STATUS" --argjson error "$ERROR" --slurpfile c "$W/check.json" \
  --arg model "$MODEL" --arg sha "$SHA" \
  '{status: $status, error: $error, ungrounded: $c[0].ungrounded, model: $model, sha: $sha}' > "$W/out.json"
put "$W/out.json" "$BASE.json"
echo "diagram: $STATUS ($(basename "$BASE").json)" >&2
