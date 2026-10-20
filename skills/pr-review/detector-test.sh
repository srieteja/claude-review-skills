#!/usr/bin/env bash
# Exercises the stage-2 escape detector, which by design only runs when something goes
# wrong -- so it is the one piece of pr-review.sh that a passing normal run never touches.
#
# An `agy` shim reproduces the escape observed in the wild (a repo-relative scratch write
# that lands in the real checkout, not in $TREE) and returns a well-formed verdict, so this
# is deterministic and costs nothing. Stage 0 still fetches, so it needs network + gh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git rev-parse --show-toplevel)"
PIN_SHA=41a4cc648b2b0cb153c76d8ed9f5b084c40d6202
PR=2179
TRACKED=packages/at_auth/CHANGELOG.md

die() { printf '\033[31m  FAIL\033[0m %s\n' "$*" >&2; exit 1; }
ok()  { printf '\033[32m  PASS\033[0m %s\n' "$*"; }
say() { printf '\033[36m==>\033[0m %s\n' "$*"; }

[ -z "$(git -C "$ROOT" status --porcelain "$TRACKED")" ] || die "$TRACKED is dirty; refusing to touch it"

D="$(mktemp -d "${TMPDIR:-/tmp}/detector-test.XXXXXX")"
# The run writes a review built from a fabricated claim. Clear it out, or it sits in the
# review store next to the real pr2179 notes looking like a genuine one -- but only if we
# are the ones who created it, since a real review of the same PR may already be there.
PR_AUTHOR="$(gh pr view "$PR" --json author -q '.author.login' 2>/dev/null || echo unknown)"
OUT="${PR_REVIEW_DIR:-$HOME/work/reviews}/${PR_AUTHOR#app/}/$PR/pr${PR}-review.md"
[ -e "$OUT" ] && OUT=""
trap 'git -C "$ROOT" checkout -- "$TRACKED" 2>/dev/null || true
      rm -rf "$D" "$ROOT/packages/at_auth/zz_escape_scratch.dart" "$ROOT/packages/at_auth/zz_escape_dir" ${OUT:+"$OUT"}' EXIT INT TERM
mkdir -p "$D/bin"
cat > "$D/findings.json" <<'J'
{"findings":[{"id":"F1","file":"packages/at_auth/lib/at_auth.dart","line":1,"severity":"low",
"claim":"detector harness claim","mechanism":"n/a","repro":"n/a"}]}
J

shim() {
  { echo '#!/usr/bin/env bash'; echo "$1"
    echo "printf '%s\\n' '{\"structured_output\":{\"id\":\"X\",\"verdict\":\"REFUTED\",\"evidence\":\"\",\"reason\":\"shim\"}}'"
  } > "$D/bin/agy"
  chmod +x "$D/bin/agy"
}
# No stage 5: this pins a fix author's PR, and only the detector is under test.
run() { ( cd "$ROOT" && PATH="$D/bin:$PATH" PR_REVIEW_FIX_AUTHORS="" bash "$HERE/pr-review.sh" "$PR" --sha "$PIN_SHA" --findings "$D/findings.json" ) > "$D/log" 2>&1; }

# --- case 1: untracked scratch is quarantined, including a whole directory ---
say "case 1: untracked escape is quarantined"
shim ": > \"$ROOT/packages/at_auth/zz_escape_scratch.dart\"
mkdir -p \"$ROOT/packages/at_auth/zz_escape_dir\"
: > \"$ROOT/packages/at_auth/zz_escape_dir/nested.dart\""
run || die "case 1: pipeline exited nonzero; the escape should be recoverable, not fatal"
grep -q 'quarantined in' "$D/log" || die "case 1: no quarantine warning$(printf '\n'; tail -5 "$D/log")"
W="$(sed -n 's/.*work dir kept: //p' "$D/log" | tr -d '\r')"
[ -n "$W" ] || die "case 1: the guard did not force --keep, so the evidence was deleted"
[ -f "$W/escaped/packages/at_auth/zz_escape_scratch.dart" ] || die "case 1: file not quarantined at its original path"
[ -f "$W/escaped/packages/at_auth/zz_escape_dir/nested.dart" ] || die "case 1: directory escape not quarantined intact"
[ -z "$(git -C "$ROOT" status --porcelain | grep zz_escape || true)" ] || die "case 1: escape left behind in the repo"
rm -rf "$W"
ok "quarantined both, repo left clean, work dir kept"

# --- case 2: a modified tracked file is refused, never moved ---
say "case 2: tracked-file escape is refused"
shim "printf '\\n<!-- detector harness -->\\n' >> \"$ROOT/$TRACKED\""
run && die "case 2: pipeline exited 0; a tracked-file escape must be fatal"
grep -q 'modified tracked files' "$D/log" || die "case 2: wrong failure$(printf '\n'; tail -5 "$D/log")"
[ -n "$(git -C "$ROOT" status --porcelain "$TRACKED")" ] || die "case 2: the guard moved a tracked file instead of leaving it"
ok "refused, exited nonzero, left the file in place"

say "escape detector works in both directions"
