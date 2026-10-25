#!/usr/bin/env bash
# Writes prN-diagram.{mmd,json} for every review that predates them, from the block already in
# its explainer. No model call: a broken block is recorded invalid, not repaired, and the page
# shows its raw text. Grounding is skipped (ungrounded: null) -- stores keep no diff.
# Idempotent: diagram.sh rewrites only what changed, so a rerun touches nothing.
#
#   diagram-backfill.sh [store ...]     default: $PR_REVIEW_INTENSE_DIR and $PR_REVIEW_DIR
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../lib/common.sh"
[ $# -gt 0 ] || set -- "$(intense_store)" "$(review_store)"

n=0; tally=""
for store in "$@"; do
  for ex in "$store"/*/*/[0-9]*/pr[0-9]*-explainer.md; do
    [ -f "$ex" ] || continue
    d="$(dirname "$ex")"
    sha="$(jq -r '.headRefOid // ""' "$d/meta.json" 2>/dev/null || true)"
    model="$(sed -n 's/^Brief by \(.*\)\. Written.*/\1/p' "$ex" | head -1)"
    "$HERE/diagram.sh" --sha "$sha" --model "$model" "$ex" - 2>/dev/null || {
      echo "diagram-backfill: diagram.sh can't run (node, or ./mermaid not installed)" >&2; exit 2; }
    n=$((n + 1))
    j="${ex%-explainer.md}-diagram.json"
    tally="$tally$( [ -f "$j" ] && jq -r .status "$j" || echo none)"$'\n'
  done
done
printf '%s explainer(s):' "$n"
printf '%s' "$tally" | sort | uniq -c | awk '{printf " %s %s", $1, $2}'
echo
