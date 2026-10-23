#!/usr/bin/env bash
# autofix -- turn a review's CONFIRMED findings into a companion PR on top of the reviewed PR.
#
# Never touches the reviewed PR's own branch. Implements with `claude -p` in a throwaway clone
# at the reviewed SHA and takes back only a patch, then re-applies that patch to a fresh
# worktree itself so the compile+test gate runs against a clean checkout, not the one the
# implementer worked in. A patch that doesn't compile or fails existing tests never reaches a push.
#
#   autofix.sh <pr-number> <sha> <repo-dir> <outdir>
#
# <outdir> is the review's store, as pr-review.sh left it. pr-review.sh writes merged.json and
# meta.json only when a review finds something, so a record whose meta.json names another
# head is an earlier review's: unset and prepare act only on one pinned to the full <sha>,
# and report none otherwise. Ship reads only the frozen files.
#
# AUTOFIX_MODE picks how far one call goes:
#   unset    implement, gate, push, open -- one shot, what watch.sh runs
#   prepare  implement and gate, then freeze patch, title, body and SHA into AUTOFIX_FROZEN
#   ship     re-apply the frozen patch (claude is not re-run), re-gate, push, open with the
#            frozen title and body -- what a human approved is exactly what gets posted
# AUTOFIX_REVIEWER=<login> requests that login's review on the PR once it's open.
# AUTOFIX_ANALYZE_ONLY (space-separated globs on a package's dir, default `tests/*`) names
# packages whose tests need a live rig: the gate runs `dart analyze` there, not `dart test`,
# and the PR body says so. Empty tests every package.
# AUTOFIX_MODEL (default claude-opus-5-5), AUTOFIX_EFFORT (default high) and AUTOFIX_BUDGET
# (USD, default 8.00, `none` uncaps) pick the implementer's run; AUTOFIX_CLAUDE swaps its binary.
#
# stdout carries only these lines; progress goes to stderr:
#   STATUS=none | exists:<url> | stale | prepared | opened:<url>
#   REVIEWER=requested:<login> | skipped:<login> | failed:<login>
#   IMPLEMENTER=<model>      the model that wrote the patch (ship: the one frozen at prepare)
#
# exit 0  none, exists, prepared or opened -- a failed reviewer request still exits 0
# exit 1  a confirmed finding exists but nothing was opened or prepared (guard, stale head,
#         implementer, test gate, a fix branch already on origin with other content, or a
#         failed push or `pr create` -- a re-run ship resumes its pushed branch, see below)
#
# Targets bash 3.2 (macOS system bash): no mapfile, no assoc arrays.
set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../lib/common.sh"
load_config

LAST_EVENT='include "last-event"; last_event'
CLAUDE="${AUTOFIX_CLAUDE:-claude}"
MODEL="${AUTOFIX_MODEL:-claude-opus-5-5}"
EFFORT="${AUTOFIX_EFFORT:-high}"
# A runaway guard like pr-review.sh's PR_REVIEW_BUDGET_USD, not a budget: watch.sh runs this
# unattended, and nothing else bounds the run. A capped run ends in error, so no PR.
BUDGET="${AUTOFIX_BUDGET:-8.00}"; [ "$BUDGET" != none ] || BUDGET=""
DRY_RUN="${AUTOFIX_DRY_RUN:-0}"          # stop after the test gate; never push or open a PR
MODE="${AUTOFIX_MODE:-}"
FROZEN="${AUTOFIX_FROZEN:-}"
REVIEWER="${AUTOFIX_REVIEWER:-}"
# `-`, not `:-`: set-but-empty is the opt-out. read -a splits without globbing against $PWD.
read -r -a ANALYZE_ONLY <<< "${AUTOFIX_ANALYZE_ONLY-tests/*}" || true
PR="$1"; SHA="$2"; REPO_DIR="$3"; OUTDIR="$4"

die()    { printf '\033[31mautofix: %s\033[0m\n' "$*" >&2; exit 1; }
say()    { printf '\033[36m==>\033[0m %s\n' "$*" >&2; }
warn()   { printf '\033[33m!!\033[0m %s\n' "$*" >&2; }
status() { echo "STATUS=$*"; }
lower()  { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
# analyze_only <package-dir> -- whether AUTOFIX_ANALYZE_ONLY names it
analyze_only() {
  local g
  for g in ${ANALYZE_ONLY[@]+"${ANALYZE_ONLY[@]}"}; do case "$1" in $g) return 0 ;; esac; done
  return 1
}

# request_review <fix-pr-url> <login> -- ask <login> to review the fix PR, and print exactly
# one REVIEWER=requested|skipped|failed:<login> line. Must not fail the run: the PR is
# already public by the time this is called, and STATUS=opened has been printed.
request_review() {
  local url="$1" who="$2" me
  # GitHub answers 422 for both: a bot can't review, and you can't review a PR you opened.
  case "$who" in
    app/*|*\[bot\]) say "$who is a bot -- no review to request"; echo "REVIEWER=skipped:$who"; return 0 ;;
  esac
  # If this lookup fails, attempt the request anyway: a wrong guess only costs a reported
  # failure, while skipping would silently drop a request that might have gone through.
  me="$(gh api user -q .login 2>/dev/null)" || me=""
  if [ -n "$me" ] && [ "$(lower "$who")" = "$(lower "$me")" ]; then
    say "$who is you -- no review to request"; echo "REVIEWER=skipped:$who"; return 0
  fi
  if gh pr edit "$url" --add-reviewer "$who" >&2; then
    echo "REVIEWER=requested:$who"
  else
    warn "could not request $who's review on $url -- the PR is open; ask them directly"
    echo "REVIEWER=failed:$who"
  fi
}

case "$MODE" in
  "")      command -v "$CLAUDE" >/dev/null || die "claude not found as $CLAUDE (set AUTOFIX_CLAUDE)" ;;
  prepare) [ -n "$FROZEN" ] || die "AUTOFIX_MODE=prepare needs AUTOFIX_FROZEN"
           command -v "$CLAUDE" >/dev/null || die "claude not found as $CLAUDE (set AUTOFIX_CLAUDE)" ;;
  ship)    [ -n "$FROZEN" ] || die "AUTOFIX_MODE=ship needs AUTOFIX_FROZEN"
           for f in fix.patch title body.md sha; do
             [ -s "$FROZEN/$f" ] || die "nothing prepared in $FROZEN (no $f) -- run prepare first"
           done
           grep -q '[^[:space:]]' "$FROZEN/title" || die "$FROZEN/title is blank -- a PR needs one"
           [ "$(cat "$FROZEN/sha")" = "$SHA" ] \
             || die "$FROZEN was prepared against $(cat "$FROZEN/sha"), not $SHA" ;;
  *)       die "unknown AUTOFIX_MODE=$MODE (prepare|ship)" ;;
esac
if [ "$MODE" != ship ]; then
  RECORDED="$(jq -r '.headRefOid // empty' "$OUTDIR/meta.json" 2>/dev/null)" || RECORDED=""
  if [ "$RECORDED" != "$SHA" ] || [ ! -s "$OUTDIR/merged.json" ]; then
    say "no findings recorded for #$PR at ${SHA:0:12} -- nothing to fix"; status none; exit 0
  fi
  CONFIRMED_COUNT="$(jq '[.[] | select(.v.verdict == "CONFIRMED")] | length' "$OUTDIR/merged.json")"
  if [ "$CONFIRMED_COUNT" -eq 0 ]; then
    say "no confirmed findings for #$PR -- nothing to fix"; status none; exit 0
  fi
fi

ROOT="$(git -C "$REPO_DIR" rev-parse --show-toplevel)" || die "$REPO_DIR is not a git repository"
REPO="$(cd "$ROOT" && gh repo view --json nameWithOwner -q .nameWithOwner)" \
  || die "could not resolve owner/repo from $ROOT"

# The fix branch is pushed to origin but the PR is opened in $REPO with a bare --head, so the
# two must be the same repository -- a clone whose origin is a personal fork would push
# somewhere the PR can't see. The push URL, since that's where a push goes when it differs.
ORIGIN="$(git -C "$ROOT" remote get-url --push origin)" || die "$ROOT has no origin remote"
ORIGIN_REPO="$(printf '%s' "$ORIGIN" | sed -E 's#/+$##; s#\.git$##; s#.*[:/]([^/:]+/[^/:]+)$#\1#')"
[ "$(lower "$ORIGIN_REPO")" = "$(lower "$REPO")" ] \
  || die "origin is $ORIGIN_REPO, not $REPO -- refusing to push a fix branch the PR can't reach"

# meta.json is pr-review.sh's own record and doesn't carry the PR's head branch (it only
# needs the SHA to pin line numbers) -- fetch it directly, since it's what a companion PR
# has to target.
LIVE="$(gh pr view "$PR" --repo "$REPO" --json headRefName,headRefOid,state,isCrossRepository)" \
  || die "could not look up #$PR"
BASE_BRANCH="$(printf '%s' "$LIVE" | jq -r '.headRefName')"
LIVE_SHA="$(printf '%s' "$LIVE" | jq -r '.headRefOid')"
# Merged or closed since the review: its branch may be gone, and a fix to it is moot.
STATE="$(printf '%s' "$LIVE" | jq -r '.state')"
[ "$STATE" = OPEN ] || die "#$PR is $STATE, not open -- no fix PR"
# A fork's head branch lives in the fork, but its name still resolves here: a PR from
# contributor:main would otherwise open a fix PR against this repo's own main.
[ "$(printf '%s' "$LIVE" | jq -r '.isCrossRepository')" = false ] \
  || die "#$PR comes from a fork -- its branch isn't in $REPO, so a fix PR can't sit on top of it"
[ -n "$BASE_BRANCH" ] && [ "$BASE_BRANCH" != "null" ] || die "#$PR has no head branch"

# One fix branch per reviewed head, so one fix PR per review, whichever path opened it. Any
# PR on it, in any state, ends the run: these same findings are already open, merged, or a
# human's no. A fix PR for an earlier head, open or not, never blocks this one -- a valid
# finding is a valid finding.
BRANCH="fix/pr${PR}-review-findings-${SHA:0:12}"
EXISTING="$(gh pr list --repo "$REPO" --head "$BRANCH" --state all --json url | jq -r '.[0].url // empty')" \
  || die "could not check for an existing fix PR on branch $BRANCH"
if [ -n "$EXISTING" ]; then
  say "a fix PR already exists for #$PR: $EXISTING -- not opening another"
  status "exists:$EXISTING"; exit 0
fi

# Every mode stands on the reviewed SHA. If the author has pushed since, the findings -- and
# any frozen patch -- describe code that is no longer the PR, and after a rebase a fix on the
# old head would carry the commits they dropped back into their branch. watch.sh has already
# marked this head seen, so its next tick reviews the new one.
if [ "$LIVE_SHA" != "$SHA" ]; then
  warn "#$PR head is now ${LIVE_SHA:0:12}, not the reviewed ${SHA:0:12} -- re-run the review"
  status stale; exit 1
fi

# Checked before claude is paid for: the gate is the only thing between its patch and a push.
command -v dart >/dev/null || die "dart is not on PATH -- the test gate can't run"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/autofix-${PR}.XXXXXX")"
IMPL="$WORK/impl"; TREE="$WORK/tree"
# One trap for both trees: the implementer's clone is plain files, the gate's is a worktree.
trap 'rm -rf "$IMPL"; git -C "$ROOT" worktree remove --force "$TREE" >/dev/null 2>&1 || true' EXIT

if [ "$MODE" = ship ]; then
  say "shipping the patch frozen at prepare for #$PR -- claude is not re-run"
  PATCH="$FROZEN/fix.patch"
  IMPLEMENTER="$(cat "$FROZEN/model" 2>/dev/null || echo unknown)"
else
  say "$CONFIRMED_COUNT confirmed finding(s) for #$PR ($BASE_BRANCH) -- implementing on $MODEL"

  # One task, one patch: findings from a single review land as one commit, not a scramble
  # of per-finding runs that would then need reconciling against each other. The preamble is
  # load-bearing: a print-mode model not told it is unattended ends on "shall I proceed?"
  # with nothing edited (seen twice under agy -- delegate/SKILL.md, design notes).
  {
    echo "You are running unattended: no one will answer a question or approve a plan, so"
    echo "make the edits now. Fix each of the following, confirmed by an adversarial code"
    echo "review. Each was traced to a real defect and independently verified against this"
    echo "exact source -- do not re-litigate whether it's a bug, only how to fix it correctly"
    echo "and minimally. Stay inside this directory, leave .github/ alone, add or update a"
    echo "test where one would have caught it, and run \`dart test\` in each package you touch."
    [ ${#ANALYZE_ONLY[@]} = 0 ] \
      || echo "Packages matching ${ANALYZE_ONLY[*]} need a live environment that isn't here: run \`dart analyze\` there instead."
    echo "Do not commit; your working-tree changes are the result."
    echo
    jq -r '.[] | select(.v.verdict == "CONFIRMED") |
      "- \(.file):\(.line) -- \(.claim)\n  mechanism: \(.mechanism)\n  repro: \(.repro)\n"' \
      "$OUTDIR/merged.json"
  } > "$WORK/task.md"

  # A clone, not a worktree: a worktree shares refs and the stash with $ROOT, so a stray
  # commit, branch or stash in there would land in your clone. --shared borrows $ROOT's
  # objects, so cutting it costs nothing; dropping origin leaves a push from inside nowhere
  # to go -- the clone's origin would be $ROOT itself.
  git clone --quiet --shared --no-checkout "$ROOT" "$IMPL" && git -C "$IMPL" checkout --quiet --detach "$SHA" \
    && git -C "$IMPL" remote remove origin || die "could not cut the implementer's tree at $SHA"
  # acceptEdits confines its own writes to this tree, and its only shell is three dart
  # subcommands -- no git, no `dart format .` across every package. Code it writes still runs
  # under `dart test`: the untrusted-code risk the gate already carries. --setting-sources ""
  # keeps your settings' broader permissions, hooks and CLAUDE.md out of an unattended run.
  if ( cd "$IMPL" && "$CLAUDE" -p "$(cat "$WORK/task.md")" \
         --model "$MODEL" --effort "$EFFORT" --output-format json \
         --strict-mcp-config --setting-sources "" --permission-mode acceptEdits \
         ${BUDGET:+--max-budget-usd "$BUDGET"} \
         --allowedTools Read Edit Write Glob Grep "Bash(dart test:*)" "Bash(dart pub get:*)" "Bash(dart analyze:*)" \
     ) > "$WORK/claude.json" 2>"$WORK/claude.err"; then
    # Exit 0 is not success: a run cut off by its budget or turn limit still exits 0, with
    # half an edit on disk that may well apply and pass.
    jq -L "$HERE" -e "$LAST_EVENT"' | select(.is_error != true)' "$WORK/claude.json" >/dev/null 2>&1 \
      || { warn "implementer ended in error ($(jq -L "$HERE" -r "$LAST_EVENT"' | .subtype // "unknown"' "$WORK/claude.json" 2>/dev/null)) -- no PR (see $WORK/claude.json)"; exit 1; }
  else
    warn "implementer exited non-zero -- no PR (see $WORK/claude.err)"; exit 1
  fi

  # The patch is everything against the reviewed SHA, committed or not. pub get's lockfile and
  # .dart_tool/ are its own output, which the gate regenerates; a fix never ships them.
  PATCH="$WORK/fix.patch"
  git -C "$IMPL" add -A
  git -C "$IMPL" diff --cached --binary "$SHA" -- . \
    ':(exclude,glob)**/pubspec.lock' ':(exclude,glob)**/.dart_tool/**' > "$PATCH"
  [ -s "$PATCH" ] || { warn "implementer reported success but made no change -- no PR (see $WORK/claude.json)"; exit 1; }
  rm -rf "$IMPL"
  IMPLEMENTER="$MODEL"
fi
say "patch implemented on $IMPLEMENTER"
echo "IMPLEMENTER=$IMPLEMENTER"

# Re-apply against a clean worktree of our own: the implementer's tree is wherever it left
# things, so the compile+test gate belongs to this script, on a tree it controls. Ship
# re-gates the frozen patch the same way.
git -C "$ROOT" worktree add --detach "$TREE" "$SHA" >/dev/null || die "worktree add failed"

# --index, so the gate and the commit both see exactly the patch: new files included, and
# nothing that `dart pub get` leaves in the tree.
git -C "$TREE" apply --index "$PATCH" || { warn "patch does not apply cleanly to $SHA -- no PR"; exit 1; }

# Test gate: every touched package with a test/ dir, nearest pubspec.yaml walking up from each
# changed file. Fail closed -- Dart code no package's tests cover, a file outside any package,
# or a package whose tests we couldn't run blocks the PR the same as a red test. A package
# without test/ (a pub workspace root) gates nothing: its docs need no test, but its Dart code
# and its workspace-wide config (pubspec, analysis_options) are refused. CI config is refused
# outright. --no-renames, so a move counts as both its paths: the package it leaves is gated
# too, and a workflow can't leave .github/ under a destination's name.
PACKAGES=""; CHANGED=0
while IFS= read -r -d '' f; do
  CHANGED=1
  case "$f" in .github/*) warn "the patch changes $f -- CI config is out of a fix PR's reach; no PR"; exit 1 ;; esac
  d="$(dirname "$f")"
  while [ "$d" != . ] && [ ! -f "$TREE/$d/pubspec.yaml" ]; do d="$(dirname "$d")"; done
  [ -f "$TREE/$d/pubspec.yaml" ] || { warn "the patch changes $f, outside any Dart package -- no test covers it; no PR"; exit 1; }
  if [ -d "$TREE/$d/test" ]; then PACKAGES="$PACKAGES$d"$'\n'; continue; fi
  case "$f" in
    *.dart) warn "the patch changes $f, Dart code no package's tests cover; no PR"; exit 1 ;;
    pubspec*.yaml|*/pubspec*.yaml|analysis_options.yaml|*/analysis_options.yaml)
      warn "the patch changes $f, config every package under $d depends on; no PR"; exit 1 ;;
  esac
done < <(git -C "$TREE" diff --cached --name-only --no-renames -z)
[ "$CHANGED" = 1 ] || { warn "the patch changes nothing -- no PR"; exit 1; }
[ -n "$PACKAGES" ] || say "no Dart package touched -- nothing to test"

# A live-rig pack is test-only code, so analysis bounds what its patch can break; the PR's
# own CI runs it for real. The body names each one -- a weaker gate is never a silent one.
i=0; ANALYZED=""
while IFS= read -r pkg; do
  i=$((i + 1)); LOG="$WORK/gate.$i.log"
  if analyze_only "$pkg"; then
    say "analyzing $pkg -- its tests need a live rig"; GATE=(analyze --fatal-infos)
    ANALYZED="$ANALYZED${ANALYZED:+, }\`$pkg\`"
  else
    say "testing $pkg"; GATE=(test)
  fi
  # </dev/null: the loop's stdin is the package list, and a test that read it would skip the rest.
  ( cd "$TREE/$pkg" && dart pub get && dart "${GATE[@]}" ) </dev/null >"$LOG" 2>&1 \
    || { warn "dart ${GATE[0]} failed in $pkg -- no PR (see $LOG)"; exit 1; }
done < <(printf '%s' "$PACKAGES" | LC_ALL=C sort -u)

# The PR's public text: a short line of context, then one bolded paragraph per finding that
# leads with what breaks and why. The review report itself is local-only, so the body has
# to carry the reasoning the author is being asked to review.
if [ "$MODE" = ship ]; then
  TITLE="$(cat "$FROZEN/title")"; BODY="$FROZEN/body.md"
else
  TITLE="fix: review findings from #$PR"; BODY="$WORK/body.md"
  {
    echo "Fixes for what an adversarial review of #$PR confirmed at \`${SHA:0:12}\`, as one commit on top of \`$BASE_BRANCH\`."
    # Shared with peer-review.sh's change request; confirmed.jq says why the @s are quieted.
    jq -L "$HERE" -r 'include "confirmed"; confirmed_md' "$OUTDIR/merged.json"
    [ -z "$ANALYZED" ] || printf '\n%s gated by `dart analyze` only: its tests need a live environment, so CI runs them.\n' "$ANALYZED"
  } > "$BODY"
fi

if [ "$MODE" = prepare ]; then
  mkdir -p "$FROZEN"
  cp "$PATCH" "$FROZEN/fix.patch"; cp "$BODY" "$FROZEN/body.md"
  printf '%s' "$TITLE" > "$FROZEN/title"; printf '%s\n' "$SHA" > "$FROZEN/sha"
  printf '%s\n' "$IMPLEMENTER" > "$FROZEN/model"
  say "prepared: patch applies and tests pass for #$PR -- frozen in $FROZEN, nothing pushed"
  status prepared; exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
  say "dry run: patch applies and tests pass for #$PR -- stopping before push (patch kept at $PATCH)"
  exit 0
fi

# Commit the index on the detached HEAD: a named branch here would land in your clone, since
# a worktree shares refs with $ROOT. The message is the title plus fixed text -- the body is
# what a human edits before ship, and nothing else from the review goes into history.
git -C "$TREE" -c user.name="$(git -C "$ROOT" config user.name)" \
               -c user.email="$(git -C "$ROOT" config user.email)" \
  commit -q -m "$TITLE" -m "Reviewed at ${SHA:0:12}; the PR description carries each finding."

# Never forced. A fix branch already on origin is resumed only when it is this fix exactly --
# one commit on $SHA with this tree, as a run whose `pr create` failed leaves it. Anything
# else on that branch is someone's work: left for you to look at. Both talk to $ORIGIN, the
# push URL the guard checked, so the branch is looked for where it would go.
if git -C "$TREE" fetch -q "$ORIGIN" "refs/heads/$BRANCH" 2>/dev/null; then
  [ "$(git -C "$TREE" rev-parse 'FETCH_HEAD^{tree}')" = "$(git -C "$TREE" rev-parse 'HEAD^{tree}')" ] \
    && [ "$(git -C "$TREE" rev-parse -q --verify 'FETCH_HEAD~1')" = "$SHA" ] \
    || die "origin already has $BRANCH, and it isn't this fix -- look at it, then: git push origin --delete $BRANCH"
  say "$BRANCH is already on origin with this fix -- opening its PR"
else
  # --no-follow-tags: a push.followTags config would otherwise publish local tags on $SHA.
  git -C "$TREE" push -q --no-follow-tags "$ORIGIN" "HEAD:refs/heads/$BRANCH" >&2 || die "push failed"
fi

# Only a ship's re-run finds this branch again: it re-applies the same frozen patch, where a
# one-shot re-run re-implements and builds a tree that won't match.
if [ "$MODE" = ship ]; then RETRY="ship again to open its PR"
else RETRY="open its PR by hand, or clear it for the next run: git push origin --delete $BRANCH"; fi
FIX_URL="$(gh pr create --repo "$REPO" --base "$BASE_BRANCH" --head "$BRANCH" \
  --title "$TITLE" --body-file "$BODY" | tail -n 1)" \
  || die "gh pr create failed -- $BRANCH is pushed; $RETRY"
say "opened $FIX_URL against $BASE_BRANCH"
status "opened:$FIX_URL"

[ -z "$REVIEWER" ] || request_review "$FIX_URL" "$REVIEWER"
