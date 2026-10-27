#!/usr/bin/env bash
# CONTRACT.md's items, checked against the real engine. The `out` and `file` items are what the
# runs below print and leave in the store -- prepare and ship for each decision, a re-decide,
# a refused ship -- in e2e-sandbox.sh's sandbox. The rest are checked where they live.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/e2e-sandbox.sh"
ROOT="$(cd "$HERE/../.." && pwd)"
items() { awk -v k="$1" '/^```contract$/ {on=1; next} /^```$/ {on=0} on && $1 == k {sub(/^[^ ]+ +/, ""); print}' "$ROOT/CONTRACT.md"; }

# Every line printed and every file left by: a fix, shipped twice; a fix whose head moved; a
# request-changes from the fix list; a fix re-decided as request-changes; an approve, shipped
# twice; a request-changes whose head moved.
ALL="$SB/stdout.all"; : > "$ALL"
keep() { cat "$C/stdout" >> "$ALL"; }
setup; run 7; keep; run 7 --ship; keep; run 7 --ship; keep
setup; run 7; echo moved000 > "$C/log/live"; run 7 --ship; keep
setup; export PR_REVIEW_FIX_AUTHORS=bob; run 7; keep; run 7 --ship; keep; export PR_REVIEW_FIX_AUTHORS=alice
setup; run 7; echo "Please reset the cache." > "$C/why.md"; run 7 --decide request-changes --body-file "$C/why.md"; keep
setup; printf '%s' "$unverifiable" > "$C/merged.json"; run 7; keep; run 7 --ship; keep; run 7 --ship; keep
setup; export PR_REVIEW_FIX_AUTHORS=bob; run 7; echo moved000 > "$C/log/live"; run 7 --ship; keep; export PR_REVIEW_FIX_AUTHORS=alice
FILES="$SB/files.all"
(cd "$SB" && find case*/store -type f) | sed 's|^case[0-9]*/store/[^/]*/[^/]*/[0-9]*/||' | sort -u > "$FILES"

[ -n "$(items out)" ] || bad "CONTRACT.md has no contract block"

echo "out: lines a wrapper matches"
while IFS= read -r re; do check "$re" grep -qE "^($re)\$" "$ALL"; done < <(items out)

echo "file: what a wrapper reads from the store"
while IFS= read -r f; do check "$f" grep -qxF "$f" "$FILES"; done < <(items file)

echo "pinned: checked by the suite that runs its producer"
while read -r suite lit; do check "$lit  ($suite)" grep -qF -- "$lit" "$ROOT/$suite"; done < <(items pinned)

echo "env: read by the engine"
engine_reads() { grep -rlw --include='*.sh' --include='*.py' -- "$1" "$ROOT/skills" "$ROOT/lib" | grep -qvE -- '-test\.sh$|/test_[^/]*\.py$|/e2e-sandbox\.sh$'; }
while IFS= read -r v; do check "$v" engine_reads "$v"; done < <(items env)

echo "api: review_learn as a wrapper calls it"
has_params() {  # has_params <name(p1, p2)>
  python3 -I - "$HERE" "$1" <<'PY'
import inspect, re, sys
sys.path.insert(0, sys.argv[1]); import review_learn
name, params = re.match(r"(\w+)\((.*)\)$", sys.argv[2]).groups()
want = [p.strip() for p in params.split(",") if p.strip()]
sys.exit(0 if set(want) <= set(inspect.signature(getattr(review_learn, name)).parameters) else 1)
PY
}
while IFS= read -r sig; do check "$sig" has_params "$sig"; done < <(items api)

echo "cli: review_learn.py subcommands"
while IFS= read -r c; do check "$c" python3 -I "$HERE/review_learn.py" "$c" --help; done < <(items cli)

[ "$fail" = 0 ] && echo "all passed" || { echo "FAILURES"; exit 1; }
