#!/usr/bin/env bash
# autofix -- turn a review's CONFIRMED findings into a fix PR, in one of three lanes:
#   stacked  the findings the PR introduced, on top of its head branch, at the reviewed SHA
#   trunk    the findings already at its base (route's `pre-existing`), on the tip of the
#            branch it merges into -- every finding once the PR has merged
#   lint     no findings: `dart analyze` issues on that same tip, in the packages the PR
#            touches -- `dart fix` first, the implementer only for what it can't clear
#
# Never touches the reviewed PR's own branch. Implements with `claude -p` in a throwaway clone
# at the lane's base and takes back only a patch, then re-applies that patch to a fresh
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
#   unset    implement, gate, push, open -- one shot, what an unattended caller runs
#   prepare  implement and gate, then freeze patch, title, body and SHA into AUTOFIX_FROZEN
#   ship     re-apply the frozen patch (claude is not re-run), re-gate, push, open with the
#            frozen title and body -- what a human approved is exactly what gets posted
# AUTOFIX_LANE picks the lane (default stacked). The trunk and lint lanes ignore the PR's head
# moving and its fork, both stacked-only concerns, and ask the PR's author to review unless
# AUTOFIX_REVIEWER names someone; AUTOFIX_TRUNK_REVIEWER=blame asks who last touched the line.
# AUTOFIX_LINT_LEVEL (warning, the default, or info) is the least severe issue lint clears.
# AUTOFIX_REVIEWER=<login> requests that login's review on the PR once it's open.
# AUTOFIX_ANALYZE_ONLY (space-separated globs on a package's dir, default `tests/*`) names
# packages whose tests need a live rig: the gate runs `dart analyze` there, not `dart test`,
# and the PR body says so. Empty tests every package.
# AUTOFIX_MODEL (default claude-opus-5-5), AUTOFIX_EFFORT (default high) and AUTOFIX_BUDGET
# (USD, default 8.00, `none` uncaps) pick the implementer's run; AUTOFIX_CLAUDE swaps its binary.
#
# stdout carries only these lines; progress goes to stderr:
#   STATUS=none | exists:<url> | stale | retarget | dropped | prepared | opened:<url>
#     none:     nothing for this lane -- no finding of its, or for lint no issue at its level
#     retarget: a stacked lane whose PR merged after prepare -- re-run for the trunk lane
#     dropped:  the trunk implementer found nothing to fix there -- the defect is the PR's
#   REVIEWER=requested:<login> | skipped:<login> | failed:<login>
#   IMPLEMENTER=<model>      the model that wrote the patch (ship: the one frozen at prepare),
#                            or `dart fix` when lint needed no model
#
# exit 0  none, exists, dropped, prepared or opened -- a failed reviewer request still exits 0
# exit 1  a confirmed finding exists but nothing was opened or prepared (guard, stale head,
#         retarget, implementer, test gate, a fix branch already on origin with other content, or a
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
# A runaway guard like pr-review.sh's PR_REVIEW_BUDGET_USD, not a budget: a watcher may run this
# unattended, and nothing else bounds the run. A capped run ends in error, so no PR.
BUDGET="${AUTOFIX_BUDGET:-8.00}"; [ "$BUDGET" != none ] || BUDGET=""
DRY_RUN="${AUTOFIX_DRY_RUN:-0}"          # stop after the test gate; never push or open a PR
MODE="${AUTOFIX_MODE:-}"
FROZEN="${AUTOFIX_FROZEN:-}"
REVIEWER="${AUTOFIX_REVIEWER:-}"
LANE="${AUTOFIX_LANE:-stacked}"
TRUNK_REVIEWER="${AUTOFIX_TRUNK_REVIEWER:-author}"
LINT_LEVEL="${AUTOFIX_LINT_LEVEL:-warning}"
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

case "$LANE" in stacked|trunk|lint) ;; *) die "unknown AUTOFIX_LANE=$LANE (stacked|trunk|lint)" ;; esac
case "$TRUNK_REVIEWER" in author|blame) ;; *) die "unknown AUTOFIX_TRUNK_REVIEWER=$TRUNK_REVIEWER (author|blame)" ;; esac
case "$LINT_LEVEL" in warning|info) ;; *) die "unknown AUTOFIX_LINT_LEVEL=$LINT_LEVEL (warning|info)" ;; esac
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
# Lint needs no findings, so no record: a clean review writes none, and is when it's likeliest wanted.
if [ "$MODE" != ship ] && [ "$LANE" != lint ]; then
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
LIVE="$(gh pr view "$PR" --repo "$REPO" --json headRefName,baseRefName,author,headRefOid,state,isCrossRepository,files)" \
  || die "could not look up #$PR"
live() { printf '%s' "$LIVE" | jq -r "$1"; }
LIVE_SHA="$(live .headRefOid)"; STATE="$(live .state)"; AUTHOR="$(live '.author.login // empty')"
# Closed unmerged: a human's no, to the PR and so to its findings. Merged: its branch may be
# gone, but trunk now carries every finding -- the trunk lane's to fix.
case "$STATE/$LANE" in
  OPEN/*|MERGED/trunk|MERGED/lint) ;;
  MERGED/stacked)
    [ "$MODE" != ship ] || { warn "#$PR merged after prepare -- re-run for the trunk lane"; status retarget; exit 1; }
    die "#$PR is MERGED -- use the trunk lane (AUTOFIX_LANE=trunk)" ;;
  *) die "#$PR is $STATE -- no fix PR" ;;
esac
if [ "$LANE" = stacked ]; then
  BASE_BRANCH="$(live .headRefName)"
  # A fork's head branch lives in the fork, but its name still resolves here: a PR from
  # contributor:main would otherwise open a fix PR against this repo's own main.
  [ "$(live .isCrossRepository)" = false ] \
    || die "#$PR comes from a fork -- its branch isn't in $REPO, so a fix PR can't sit on top of it"
else
  BASE_BRANCH="$(live .baseRefName)"
fi
[ -n "$BASE_BRANCH" ] && [ "$BASE_BRANCH" != "null" ] || die "#$PR has no $LANE base branch"

# This lane's findings, by lanes.jq's rule -- the one stage 5 picks its lanes with.
if [ "$MODE" != ship ] && [ "$LANE" != lint ]; then
  FINDINGS="$(jq -c -L "$HERE" --arg lane "$LANE" --arg state "$STATE" \
    'include "lanes"; lane_findings($lane; $state)' "$OUTDIR/merged.json")"
  if [ "$FINDINGS" = "[]" ]; then
    say "none of #$PR's confirmed findings are the $LANE lane's -- nothing to fix"; status none; exit 0
  fi
fi

# One fix branch per reviewed head and lane, so one fix PR each, whichever path opened it. Any
# PR on it, in any state, ends the run: these same findings are already open, merged, or a
# human's no. A fix PR for an earlier head, open or not, never blocks this one -- a valid
# finding is a valid finding.
case "$LANE" in
  stacked) BRANCH="fix/pr${PR}-review-findings-${SHA:0:12}" ;;
  trunk)   BRANCH="fix/pr${PR}-preexisting-${SHA:0:12}" ;;
  lint)    BRANCH="fix/pr${PR}-lint-${SHA:0:12}" ;;
esac
EXISTING="$(gh pr list --repo "$REPO" --head "$BRANCH" --state all --json url | jq -r '.[0].url // empty')" \
  || die "could not check for an existing fix PR on branch $BRANCH"
if [ -n "$EXISTING" ]; then
  say "a fix PR already exists for #$PR: $EXISTING -- not opening another"
  status "exists:$EXISTING"; exit 0
fi

# The lane's base: the reviewed SHA, or trunk's tip -- frozen at prepare, so ship commits on
# exactly what was gated. A stacked lane stands on the reviewed SHA: if the author has pushed
# since, the findings -- and any frozen patch -- describe code that is no longer the PR, and
# after a rebase a fix on the old head would carry the commits they dropped back into their
# branch. A watcher should mark this head seen, so its next tick reviews the new one.
# The trunk lane's findings describe trunk, which the PR's head moving doesn't change; nor
# does lint's analysis of it.
if [ "$MODE" = ship ] && [ -s "$FROZEN/base" ]; then
  read -r BASE_BRANCH BASE_SHA < "$FROZEN/base"
elif [ "$LANE" = stacked ]; then
  BASE_SHA="$SHA"
fi
if [ "$LANE" != stacked ]; then
  # Fetched by URL into FETCH_HEAD alone: no ref in your clone moves.
  git -C "$ROOT" fetch -q "$ORIGIN" "refs/heads/$BASE_BRANCH" || die "could not fetch $BASE_BRANCH"
  [ -n "${BASE_SHA:-}" ] || BASE_SHA="$(git -C "$ROOT" rev-parse FETCH_HEAD)"
elif [ "$LIVE_SHA" != "$SHA" ]; then
  warn "#$PR head is now ${LIVE_SHA:0:12}, not the reviewed ${SHA:0:12} -- re-run the review"
  status stale; exit 1
fi

# Checked before claude is paid for: the gate is the only thing between its patch and a push.
command -v dart >/dev/null || die "dart is not on PATH -- the test gate can't run"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/autofix-${PR}.XXXXXX")"
IMPL="$WORK/impl"; TREE="$WORK/tree"; BASE="$WORK/base"
# One trap for every tree: the implementer's clone is plain files, the gate's two are worktrees.
trap 'rm -rf "$IMPL"; for t in "$TREE" "$BASE"; do git -C "$ROOT" worktree remove --force "$t" >/dev/null 2>&1 || true; done' EXIT

# analyze_keys <tree> <pkg> -- the analyzer's issues in <pkg>, sorted, one per line with the
# position dropped: a patch shifts lines, and comm then diffs two runs as multisets. A key is
# severity|code|file|message.
analyze_keys() {
  local rc=0 out
  ( cd "$1/$2" && dart pub get ) >&2 || return 1
  out="$(cd "$1/$2" && dart analyze --fatal-infos --format=machine)" || rc=$?
  [ "$rc" -le 3 ] || return 1   # 1-3: infos, warnings or errors found; above that, no analysis
  # Paths come back absolute, normalized or symlink-resolved: strip the tree either way.
  printf '%s\n' "$out" | awk -F'|' -v l="$(cd "$1" && pwd)/" -v r="$(cd "$1" && pwd -P)/" \
    'NF >= 8 { f = $4
               if (index(f, l) == 1) f = substr(f, length(l) + 1)
               else if (index(f, r) == 1) f = substr(f, length(r) + 1)
               print $1 "|" $3 "|" f "|" $8 }' \
    | LC_ALL=C sort
}
# targeted -- the keys on stdin at LINT_LEVEL or above
targeted() { if [ "$LINT_LEVEL" = info ]; then cat; else grep -v '^INFO|' || true; fi; }

# analyze_pair <pkg> -- <pkg>'s keys at $BASE_SHA and with the patch, into an.before/an.after
analyze_pair() {
  : > "$WORK/an.before"
  [ -d "$BASE" ] || git -C "$ROOT" worktree add --detach "$BASE" "$BASE_SHA" >/dev/null || return 1
  if [ -f "$BASE/$1/pubspec.yaml" ]; then
    analyze_keys "$BASE" "$1" > "$WORK/an.before" || { echo "dart analyze didn't run on $1 at ${BASE_SHA:0:12}"; return 1; }
  fi
  analyze_keys "$TREE" "$1" > "$WORK/an.after" || { echo "dart analyze didn't run on $1 with the patch"; return 1; }
}
# analyze_new <pkg> -- fails, printing them, on analyzer issues the patch adds to <pkg>. What
# the pack already had at $BASE_SHA isn't the fix's to answer for.
analyze_new() {
  local new
  analyze_pair "$1" || return 1
  new="$(LC_ALL=C comm -13 "$WORK/an.before" "$WORK/an.after" | grep . || true)"
  [ -z "$new" ] || { printf 'new with the patch:\n%s\n' "$new"; return 1; }
}
# lint_cleared <pkg> -- analyze_new, and fails too on a targeted issue still standing. What it
# cleared goes to lint.summary, one bullet per package, for the PR body.
lint_cleared() {
  local left counts
  analyze_new "$1" || return 1
  left="$(targeted < "$WORK/an.before" | LC_ALL=C comm -12 - "$WORK/an.after" | grep . || true)"
  [ -z "$left" ] || { printf 'still there with the patch:\n%s\n' "$left"; return 1; }
  counts="$(targeted < "$WORK/an.before" | cut -d'|' -f2 | LC_ALL=C sort | uniq -c \
    | awk '{ printf "%s`%s`%s", (NR > 1 ? ", " : ""), $2, ($1 > 1 ? " ×" $1 : "") }')"
  [ -z "$counts" ] || printf -- '- `%s`: %s\n' "$1" "$counts" >> "$WORK/lint.summary"
}

# pkg_of <tree> <file> -- the package <file> belongs to: nearest pubspec.yaml walking up
pkg_of() {
  local d; d="$(dirname "$2")"
  while [ "$d" != . ] && [ ! -f "$1/$d/pubspec.yaml" ]; do d="$(dirname "$d")"; done
  [ -f "$1/$d/pubspec.yaml" ] && echo "$d"
}
# lint_packages <tree> -- the packages the PR's files fall in, as <tree> lays them out
lint_packages() {
  live '.files[]?.path' | while IFS= read -r f; do pkg_of "$1" "$f" || true; done | LC_ALL=C sort -u
}

# What the implementer is told whatever the lane: what it may run, and how its work comes back.
task_rules() {
  [ ${#ANALYZE_ONLY[@]} = 0 ] \
    || echo "Packages matching ${ANALYZE_ONLY[*]} need a live environment that isn't here: run \`dart analyze\` there instead."
  echo "Do not commit; your working-tree changes are the result."
}

# lint_prepass -- in the implementer's tree: `dart fix` each touched package for the codes it
# has at LINT_LEVEL, then a task for whatever is left. STATUS=none when there's nothing to clear.
lint_prepass() {
  local pkg keys codes left found=""
  while IFS= read -r pkg; do
    keys="$(analyze_keys "$IMPL" "$pkg" </dev/null)" || die "dart analyze didn't run on $pkg at ${BASE_SHA:0:12}"
    keys="$(printf '%s\n' "$keys" | targeted | grep . || true)"
    [ -n "$keys" ] || continue
    found=1
    # Only the targeted codes: dart fix alone would also rewrite every info it knows a fix for.
    codes="$(printf '%s\n' "$keys" | cut -d'|' -f2 | LC_ALL=C sort -u | sed 's/^/--code=/')"
    say "dart fix in $pkg: $(printf '%s' "$codes" | tr '\n' ' ')"
    # shellcheck disable=SC2086 # one --code=<code> word each
    ( cd "$IMPL/$pkg" && dart fix --apply $codes ) </dev/null >&2 || die "dart fix failed in $pkg"
    left="$(analyze_keys "$IMPL" "$pkg" </dev/null)" || die "dart analyze didn't run on $pkg after dart fix"
    printf '%s\n' "$keys" | LC_ALL=C comm -12 - <(printf '%s\n' "$left") | grep . >> "$WORK/lint.left" || true
  done < <(lint_packages "$IMPL")
  [ -n "$found" ] || { say "no $LINT_LEVEL-level analyzer issues on $BASE_BRANCH in the packages #$PR touches -- nothing to lint"
                       status none; exit 0; }
  [ -s "$WORK/lint.left" ] || return 0
  {
    echo "You are running unattended: no one will answer a question or approve a plan, so"
    echo "make the edits now. \`dart fix\` has already run here; clear each \`dart analyze\` issue"
    echo "below that it couldn't, without changing behaviour. Stay inside this directory, leave"
    echo ".github/ alone, and run \`dart analyze\` and \`dart test --concurrency=1\` in each package you touch."
    task_rules
    echo
    awk -F'|' '{ print "- " $3 ": " $2 " -- " $4 }' "$WORK/lint.left"
  } > "$WORK/task.md"
}

if [ "$MODE" = ship ]; then
  say "shipping the patch frozen at prepare for #$PR -- claude is not re-run"
  PATCH="$FROZEN/fix.patch"
  IMPLEMENTER="$(cat "$FROZEN/model" 2>/dev/null || echo unknown)"
else
  # A clone, not a worktree: a worktree shares refs and the stash with $ROOT, so a stray
  # commit, branch or stash in there would land in your clone. --shared borrows $ROOT's
  # objects, so cutting it costs nothing; dropping origin leaves a push from inside nowhere
  # to go -- the clone's origin would be $ROOT itself.
  git clone --quiet --shared --no-checkout "$ROOT" "$IMPL" && git -C "$IMPL" checkout --quiet --detach "$BASE_SHA" \
    && git -C "$IMPL" remote remove origin || die "could not cut the implementer's tree at $BASE_SHA"

  if [ "$LANE" = lint ]; then
    lint_prepass
  else
    say "$CONFIRMED_COUNT confirmed finding(s) for #$PR ($BASE_BRANCH) -- implementing on $MODEL"
    # One task, one patch: findings from a single review land as one commit, not a scramble
    # of per-finding runs that would then need reconciling against each other. The preamble is
    # load-bearing: a print-mode model not told it is unattended ends on "shall I proceed?"
    # with nothing edited (seen twice under agy).
    printf '%s\n' "$FINDINGS" > "$WORK/findings.json"
    {
      echo "You are running unattended: no one will answer a question or approve a plan, so"
      echo "make the edits now. Fix each of the following, confirmed by an adversarial code"
      echo "review. Each was traced to a real defect and independently verified against this"
      echo "exact source -- do not re-litigate whether it's a bug, only how to fix it correctly"
      echo "and minimally. Stay inside this directory, leave .github/ alone, add or update a"
      echo "test where one would have caught it, and run \`dart test --concurrency=1\` in each package you touch."
      task_rules
      # The safety net for a mis-routed finding: one that lives only in the PR isn't here, and
      # an empty patch drops it rather than shipping a guess.
      [ "$LANE" = stacked ] || { echo; echo "This tree is \`$BASE_BRANCH\`, not the PR the review read: its lines are cited at"
        echo "${SHA:0:12} and may sit elsewhere here. Fix each defect where this tree has it; one it"
        echo "doesn't have, leave alone."; }
      echo
      jq -r '.[] | "- \(.file):\(.line) -- \(.claim)\n  mechanism: \(.mechanism)\n  repro: \(.repro)\n"' \
        "$WORK/findings.json"
    } > "$WORK/task.md"
  fi

  # Lint that dart fix cleared alone leaves no task: no model is paid for.
  IMPLEMENTER="dart fix"
  if [ -s "$WORK/task.md" ]; then
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
    IMPLEMENTER="$MODEL"
  fi

  # The patch is everything against the lane's base, committed or not. pub get's lockfile and
  # .dart_tool/ are its own output, which the gate regenerates; a fix never ships them.
  PATCH="$WORK/fix.patch"
  git -C "$IMPL" add -A
  git -C "$IMPL" diff --cached --binary "$BASE_SHA" -- . \
    ':(exclude,glob)**/pubspec.lock' ':(exclude,glob)**/.dart_tool/**' > "$PATCH"
  if [ ! -s "$PATCH" ] && [ "$LANE" = trunk ]; then
    say "nothing to fix on $BASE_BRANCH -- these findings are #$PR's own"; status dropped; exit 0
  fi
  [ -s "$PATCH" ] || { warn "$IMPLEMENTER reported success but made no change -- no PR"; exit 1; }
  rm -rf "$IMPL"
fi
say "patch implemented on $IMPLEMENTER"
echo "IMPLEMENTER=$IMPLEMENTER"

# Re-apply against a clean worktree of our own: the implementer's tree is wherever it left
# things, so the compile+test gate belongs to this script, on a tree it controls. Ship
# re-gates the frozen patch the same way.
git -C "$ROOT" worktree add --detach "$TREE" "$BASE_SHA" >/dev/null || die "worktree add failed"

# --index, so the gate and the commit both see exactly the patch: new files included, and
# nothing that `dart pub get` leaves in the tree.
git -C "$TREE" apply --index "$PATCH" || { warn "patch does not apply cleanly to $BASE_SHA -- no PR"; exit 1; }

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
  d="$(pkg_of "$TREE" "$f")" || { warn "the patch changes $f, outside any Dart package -- no test covers it; no PR"; exit 1; }
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
  # </dev/null: the loop's stdin is the package list, and a test that read it would skip the rest.
  if analyze_only "$pkg"; then
    say "analyzing $pkg against ${BASE_SHA:0:12} -- its tests need a live rig"
    ANALYZED="$ANALYZED${ANALYZED:+, }\`$pkg\`"
    analyze_new "$pkg" </dev/null >"$LOG" 2>&1 \
      || { warn "dart analyze: the patch adds issues to $pkg -- no PR (see $LOG)"; exit 1; }
  else
    say "testing $pkg"
    # --concurrency=1: test files that share on-disk state race when run in parallel, and a
    # flaky gate would refuse a correct fix. Slower, never wrong.
    ( cd "$TREE/$pkg" && dart pub get && dart test --concurrency=1 ) </dev/null >"$LOG" 2>&1 \
      || { warn "dart test failed in $pkg -- no PR (see $LOG)"; exit 1; }
  fi
done < <(printf '%s' "$PACKAGES" | LC_ALL=C sort -u)

# Lint is done when every targeted issue in the packages the PR touches is gone, and none came
# in -- whatever dart fix or the model did to get there.
if [ "$LANE" = lint ]; then
  : > "$WORK/lint.summary"
  while IFS= read -r pkg; do
    i=$((i + 1)); LOG="$WORK/gate.$i.log"
    say "checking $pkg is clear of $LINT_LEVEL-level analyzer issues"
    lint_cleared "$pkg" </dev/null >"$LOG" 2>&1 \
      || { warn "dart analyze: $pkg isn't clear with the patch -- no PR (see $LOG)"; cat "$LOG" >&2; exit 1; }
  done < <(lint_packages "$TREE")
fi

# The PR's public text: one line of context, then one bullet per finding -- where, and what
# breaks, in a sentence. No walls of text: the diff shows the fix, the review keeps the why.
# The trunk lane names who last touched each cited line -- a login in backticks, so the
# code's owner is visible without being paged. Blamed at the reviewed SHA, where the cited
# line numbers hold.
BLAMED=""
last_touched() {
  local file line c who out=""
  while IFS=$'\t' read -r file line; do
    c="$(git -C "$ROOT" blame --porcelain -L "$line,$line" "$SHA" -- "$file" 2>/dev/null | awk 'NR == 1 { print $1 }')"
    [ -n "$c" ] || continue
    who="$(gh api "repos/$REPO/commits/$c" -q '.author.login // empty' 2>/dev/null)" || who=""
    [ -n "$who" ] || who="$(git -C "$ROOT" log -1 --format=%an "$c")"
    [ -n "$BLAMED" ] || BLAMED="$who"
    out="$out${out:+; }\`$file:$line\` by \`$who\` in \`${c:0:12}\`"
  done < <(jq -r '.[] | select(.line | type == "number") | "\(.file)\t\(.line)"' "$WORK/findings.json")
  [ -z "$out" ] || printf '\nLast touched: %s.\n' "$out"
}

if [ "$MODE" = ship ]; then
  TITLE="$(cat "$FROZEN/title")"; BODY="$FROZEN/body.md"
  [ -n "$REVIEWER" ] || REVIEWER="$(cat "$FROZEN/reviewer" 2>/dev/null || true)"
else
  BODY="$WORK/body.md"
  {
    if [ "$LANE" = lint ]; then
      printf 'Clears `dart analyze` issues (%s and up) on `%s` at `%s`, in the packages #%s touches:\n' \
        "$LINT_LEVEL" "$BASE_BRANCH" "${BASE_SHA:0:12}" "$PR"
      cat "$WORK/lint.summary"
    elif [ "$LANE" = stacked ]; then
      printf 'Fixes what review of #%s confirmed at `%s`:\n' "$PR" "${SHA:0:12}"
    elif [ "$STATE" = MERGED ]; then
      printf 'Fixes what review of #%s confirmed at `%s`, on `%s` since #%s merged:\n' "$PR" "${SHA:0:12}" "$BASE_BRANCH" "$PR"
    else
      printf 'Fixes what review of #%s at `%s` found already on `%s`:\n' "$PR" "${SHA:0:12}" "$BASE_BRANCH"
    fi
    if [ "$LANE" != lint ]; then
      # Shared with peer-review.sh's change request; confirmed.jq says why the @s are quieted.
      jq -L "$HERE" -r 'include "confirmed"; confirmed_md' "$WORK/findings.json"
      [ "$LANE" = stacked ] || last_touched
    fi
    [ -z "$ANALYZED" ] || printf '\n%s: `dart analyze` only here; CI runs its tests.\n' "$ANALYZED"
  } > "$BODY"
  case "$LANE" in
    stacked) TITLE="fix: review findings from #$PR" ;;
    trunk)   TITLE="fix: defects on $BASE_BRANCH found reviewing #$PR" ;;
    lint)    TITLE="chore: dart analyze issues on $BASE_BRANCH in packages #$PR touches" ;;
  esac
  # Off the PR's branch, someone owns the code: who last touched it if asked and found, else
  # the PR's author -- never no one.
  [ "$LANE" = stacked ] || [ -n "$REVIEWER" ] \
    || if [ "$TRUNK_REVIEWER" = blame ] && [ -n "$BLAMED" ]; then REVIEWER="$BLAMED"; else REVIEWER="$AUTHOR"; fi
fi

if [ "$MODE" = prepare ]; then
  mkdir -p "$FROZEN"
  cp "$PATCH" "$FROZEN/fix.patch"; cp "$BODY" "$FROZEN/body.md"
  printf '%s' "$TITLE" > "$FROZEN/title"; printf '%s\n' "$SHA" > "$FROZEN/sha"
  printf '%s\n' "$IMPLEMENTER" > "$FROZEN/model"; printf '%s %s\n' "$BASE_BRANCH" "$BASE_SHA" > "$FROZEN/base"
  [ -z "$REVIEWER" ] || printf '%s\n' "$REVIEWER" > "$FROZEN/reviewer"
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
# one commit on $BASE_SHA with this tree, as a run whose `pr create` failed leaves it. Anything
# else on that branch is someone's work: left for you to look at. Both talk to $ORIGIN, the
# push URL the guard checked, so the branch is looked for where it would go.
if git -C "$TREE" fetch -q "$ORIGIN" "refs/heads/$BRANCH" 2>/dev/null; then
  [ "$(git -C "$TREE" rev-parse 'FETCH_HEAD^{tree}')" = "$(git -C "$TREE" rev-parse 'HEAD^{tree}')" ] \
    && [ "$(git -C "$TREE" rev-parse -q --verify 'FETCH_HEAD~1')" = "$BASE_SHA" ] \
    || die "origin already has $BRANCH, and it isn't this fix -- look at it, then: git push origin --delete $BRANCH"
  say "$BRANCH is already on origin with this fix -- opening its PR"
else
  # --no-follow-tags: a push.followTags config would otherwise publish local tags on $BASE_SHA.
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
