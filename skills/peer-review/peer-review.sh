#!/usr/bin/env bash
# peer-review -- review someone else's PR and end in one of three decisions, frozen for a human
# to read before anything goes public:
#
#   approve          nothing CONFIRMED, every finding checked, every slice reviewed
#   fix              CONFIRMED findings by an author on PR_REVIEW_FIX_AUTHORS: autofix.sh
#                    prepares a companion PR stacked on theirs
#   request-changes  CONFIRMED findings by anyone else, or a fix autofix.sh wouldn't prepare
#
# Only what the PR introduced weighs on that decision (pr-review's route, lanes.jq). What was
# already on its base gets a fix PR of its own on the base branch -- the trunk lane, whoever
# the author -- frozen beside the decision; once the PR has merged that is all there is.
# AUTOFIX_LINT=1 adds the lint lane beside it: dart analyze issues on that base, in the
# packages the PR touches.
#
#   peer-review.sh <pr> [review options]   review, decide, freeze
#   peer-review.sh <pr> --decide <d> [--body-file f]
#                                          re-freeze decision d from the review already done, no
#                                          re-review: a human overriding the call (fix here
#                                          ignores PR_REVIEW_FIX_AUTHORS)
#   peer-review.sh <pr> --ship             post exactly what was frozen
#
# <pr> is N, owner/repo#N or a PR URL.
#
# While prepare or --decide runs, <store>/<author>/<repo>/<N>/running holds its pid, so a
# dashboard can tell a live run from a crashed one.
#
# The engine is intense-review.sh when the intense preset resolves to a refuter of a third
# family that is ready -- on ollama, one that answers a 1-token call now -- and pr-review.sh
# with its own models otherwise. Run from inside the PR's repository.
#
# The decision lands in <store>/<author>/<repo>/<N>/decision/{decision,sha,why,body.md}; a fix's
# patch, title and body in .../autofix/, the trunk lane's in .../autofix/trunk/. why is one line naming the branch taken. A
# request-changes also freezes review.json: inline.py's comments, one per finding the diff has
# a line for, each carrying the `file:line` marker body.md names it by. Edit body.md (or
# autofix/body.md) in between to change what is posted: ship posts body.md as edited, with
# only the comments whose marker it still holds -- delete a finding's line, and its comment
# goes too. Approve and request-changes post one review pinned to the reviewed SHA, once,
# and keep it as outgoing.json. Ship refuses if the PR head moved since the review, and
# leaves the head it saw in decision/stale.
#
# stdout carries only these lines; progress goes to stderr:
#   prepare  ENGINE=intense|regular, then STATUS=prepared and DECISION=approve|fix|request-changes,
#            or autofix.sh's STATUS=exists:<url> | stale; merged with nothing confirmed,
#            STATUS=merged-clean
#   ship     STATUS=approved:<url> | changes-requested:<url> | exists:<url> | stale for a review
#   both     a fix PR's lines, one lane at a time: LANE=<lane> STATUS=<autofix.sh's status>,
#            then its IMPLEMENTER= (prepare) or REVIEWER= (ship)
#
# exit 1  refused or failed -- including any finding left unchecked (ERROR or no verdict) and
#         a clean review that didn't cover every slice: neither can support a decision; at
#         ship, any lane or review that didn't go out (the rest still do)
#
# env (or the config file, see lib/common.sh; the environment wins):
#      PR_REVIEW_FIX_AUTHORS, alias PEER_REVIEW_FIX_AUTHORS (default none; space- or comma-separated)
#      OLLAMA_API_KEY (no key, no probe: the regular review runs)
#      PR_REVIEW_INTENSE_REFUTER (the model probed)
#      PR_REVIEW_DIR (default ~/.reviews), PR_REVIEW_INTENSE_DIR (default <PR_REVIEW_DIR>/_intense)
#      PEER_REVIEW_INTENSE, PEER_REVIEW_REGULAR, PEER_REVIEW_AUTOFIX (the scripts wrapped, for tests)
#      PR_REVIEW_LEARN=off (no capture, no restyled body), PR_REVIEW_LEARN_DIR, PEER_REVIEW_SHIPPER
#        (watch when unattended) -- see review_learn.py
#
# Targets bash 3.2 (macOS system bash).
set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../lib/common.sh"
load_config
INTENSE="${PEER_REVIEW_INTENSE:-$HERE/../intense-review/intense-review.sh}"
REGULAR="${PEER_REVIEW_REGULAR:-$HERE/../pr-review/pr-review.sh}"
AUTOFIX="${PEER_REVIEW_AUTOFIX:-$HERE/../pr-review/autofix.sh}"
INTENSE_STORE="$(intense_store)"
REGULAR_STORE="$(review_store)"
ENGINE_DIR="$HERE/../pr-review"   # lanes.jq, confirmed.jq, inline.py

die()   { printf '\033[31mpeer-review: %s\033[0m\n' "$*" >&2; exit 1; }
say()   { printf '\033[36m==>\033[0m %s\n' "$*" >&2; }
warn()  { printf '\033[33m!!\033[0m %s\n' "$*" >&2; }
# learn <hook> <args> -- the learning engine's capture (review_learn.py). Silent and never
# fatal: it logs its own failures, and changes neither this script's stdout nor its exit.
learn() { python3 "$HERE/review_learn.py" "$@" >/dev/null 2>&1 || true; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

usage() {
  cat >&2 <<USAGE
usage: peer-review.sh <pr> [review options]   review and decide: approve, fix or request-changes
       peer-review.sh <pr> --decide approve|request-changes|fix [--body-file f]
                                             re-freeze another decision, no re-review
       peer-review.sh <pr> --ship             post the decision
<pr>: N, owner/repo#N or a PR URL. Settings: $(config_file); the environment wins.
USAGE
  exit 1
}

PR=""; SHIP=0; DECIDE=""; BODY_FILE=""; PASS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --ship) SHIP=1 ;;
    --decide|--body-file)
      [ $# -ge 2 ] || die "$1 needs a value"
      case "$1" in --decide) DECIDE="$2" ;; *) BODY_FILE="$2" ;; esac; shift ;;
    # What goes public is the frozen decision, posted by --ship -- not the review report.
    --post|--inline|--yes) die "$1 is not supported here: the decision is posted by --ship" ;;
    # A decision is about the PR as it stands; findings against an ancestor would be stale
    # the moment they were frozen.
    --sha) die "--sha is not supported here: the decision is about the PR's current head" ;;
    --findings|--jobs) [ $# -ge 2 ] || die "$1 needs a value"; PASS+=("$1" "$2"); shift ;;
    -h|--help) usage ;;
    -*) PASS+=("$1") ;;
    *) [ -z "$PR" ] || die "unexpected argument: $1"; PR="$1" ;;
  esac
  shift
done
[ -n "$PR" ] || usage
REF="$PR"; parse_pr_ref "$REF" || die "PR must be N, owner/repo#N or a PR URL, got: $REF"
[ "$SHIP" -eq 0 ] || [ ${#PASS[@]} -eq 0 ] || die "--ship takes no review options"
if [ -n "$DECIDE" ]; then
  case "$DECIDE" in approve|request-changes|fix) ;; *) die "--decide takes approve|request-changes|fix, not '$DECIDE'" ;; esac
  [ "$SHIP" -eq 0 ] || die "--decide and --ship are separate steps: decide, read it, then ship"
  [ ${#PASS[@]} -eq 0 ] || die "--decide re-freezes the review already done and takes no review options"
  [ -z "$BODY_FILE" ] || [ "$DECIDE" != fix ] || die "--body-file doesn't apply to a fix: edit autofix/body.md"
  [ -z "$BODY_FILE" ] || [ -r "$BODY_FILE" ] || die "can't read --body-file $BODY_FILE"
fi
[ -z "$BODY_FILE" ] || [ -n "$DECIDE" ] || die "--body-file goes with --decide"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo -- run from the PR's repository"
check_pr_repo

# Everything that would make the whole run pointless is checked before a review is paid
# for, and again at ship, since the PR can be merged or closed in between.
META="$(gh pr view "$PR" --json url,author,headRefOid,state,isCrossRepository)" || die "could not look up #$PR"
AUTHOR="$(printf '%s' "$META" | jq -r '.author.login // empty')"
[ -n "$AUTHOR" ] || die "#$PR has no author"
case "$(printf '%s' "$META" | jq -r '.author.is_bot'):$AUTHOR" in
  true:*|*:app/*|*:*\[bot\]) die "#$PR is by a bot ($AUTHOR) -- no one to review for" ;;
esac
# Merged leaves trunk work only: there is no one left to approve for or ask for changes.
STATE="$(printf '%s' "$META" | jq -r '.state')"
case "$STATE" in OPEN|MERGED) ;; *) die "#$PR is not open or merged ($STATE)" ;; esac
[ "$STATE" = OPEN ] || [ -z "$DECIDE" ] || [ "$DECIDE" = fix ] || die "#$PR is merged -- only fix applies"
# A fork's branch is outside this repo: nothing can be stacked on it, but trunk is still ours.
FORK="$(printf '%s' "$META" | jq -r '.isCrossRepository')"
# GitHub refuses a review of your own PR, and a fix PR on your own work is pointless. If the
# lookup fails, carry on: GitHub still refuses at ship.
ME="$(gh api user -q .login 2>/dev/null)" || ME=""
[ -z "$ME" ] || [ "$(lower "$ME")" != "$(lower "$AUTHOR")" ] || die "#$PR is your own PR -- nothing to review for"
LIVE="$(printf '%s' "$META" | jq -r '.headRefOid')"
REPO="$(repo_of_url "$(printf '%s' "$META" | jq -r '.url')")"
pr_lock "$(printf '%s' "$META" | jq -r '.url')"; trap pr_unlock EXIT

# Either engine may have decided, so both stores.
STORES="$INTENSE_STORE"
[ "$REGULAR_STORE" = "$INTENSE_STORE" ] || STORES="$STORES
$REGULAR_STORE"

find_outdir() {  # find_outdir <file> -- the one store dir for #PR holding <file>, else nothing
  local s d found=""
  while IFS= read -r s; do
    d="$(review_dir "$s" "$AUTHOR" "$REPO" "$PR")"
    [ -s "$d/$1" ] || continue
    [ -z "$found" ] || die "#$PR has $1 in both $found and $d -- re-run the review"
    found="$d"
  done <<EOF
$STORES
EOF
  printf '%s' "$found"
}

reviewed_sha() {  # reviewed_sha <outdir> -- the 40-hex head the review read, else nothing
  local s
  if [ -s "$1/meta.json" ]; then
    s="$(jq -r '.headRefOid // empty' "$1/meta.json")"
  else
    # No record: the zero-findings report is all there is, and it names the head it read.
    s="$(sed -n 's/.* · reviewed at head `\([0-9a-f]\{40\}\)`$/\1/p' "$1/pr$PR-review.md" | head -n 1)"
  fi
  case "$s" in *[!0-9a-f]*|"") return 0 ;; esac
  [ ${#s} -ne 40 ] || printf '%s' "$s"
}

mark_running() {  # mark_running <outdir> -- this pid in <outdir>/running until exit
  mkdir -p "$1"; printf '%s\n' "$$" > "$1/running"
  trap 'pr_unlock; rm -f "'"$1"'/running"' EXIT
}

plural() { if [ "$1" = 1 ]; then printf '%s %s' "$1" "$2"; else printf '%s %ss' "$1" "$2"; fi; }

# lane_dir <lane> -- where a lane freezes: the stacked one, from before lanes, in autofix/
# itself -- review_learn.py and review_index.py read it there -- every other in autofix/<lane>/.
lane_dir() { if [ "$1" = stacked ]; then echo "$OUTDIR/autofix"; else echo "$OUTDIR/autofix/$1"; fi; }
# drop_lane <lane> -- forget a lane's freeze; the stacked one leaves the others' dirs alone
drop_lane() {
  if [ "$1" = stacked ]; then [ ! -d "$OUTDIR/autofix" ] || find "$OUTDIR/autofix" -maxdepth 1 -type f -delete
  else rm -rf "$(lane_dir "$1")"; fi
  rmdir "$OUTDIR/autofix" 2>/dev/null || true
}
# posted_mark <lane> -- the stacked lane's PR is the decision itself, so decision/posted
posted_mark() { if [ "$1" = stacked ]; then echo "$DEC/posted"; else echo "$DEC/posted.$1"; fi; }
# lane_findings <lane> -- the confirmed findings that lane fixes, as a JSON array
lane_findings() {
  if [ -s "$OUTDIR/merged.json" ]; then
    jq -c -L "$ENGINE_DIR" --arg l "$1" --arg s "$STATE" 'include "lanes"; lane_findings($l; $s)' "$OUTDIR/merged.json"
  else echo '[]'; fi
}
# lane_lines <lane> -- autofix's stdout, its STATUS= line marked with the lane
lane_lines() { printf '%s\n' "$OUT" | sed "s/^STATUS=/LANE=$1 STATUS=/"; }

prepare_fix() {  # prepare_fix <lane> -- autofix prepare from the reviewed $SHA; sets OUT, rc and FIX_WHY
  # The SHA the review read, not the live head: autofix refuses as stale if the author pushed.
  # Its stderr still streams to ours; a copy keeps its last word, which is why it refused.
  local err; err="$(mktemp "${TMPDIR:-/tmp}/peer-review-autofix.XXXXXX")"
  rc=0
  OUT="$( { AUTOFIX_MODE=prepare AUTOFIX_LANE="$1" AUTOFIX_FROZEN="$(lane_dir "$1")" "$AUTOFIX" "$PR" "$SHA" "$ROOT" "$OUTDIR" \
              2>&1 1>&3 3>&- | tee "$err" >&2; } 3>&1 )" || rc=$?
  FIX_WHY="$(sed $'s/\033\\[[0-9;]*m//g' "$err" | grep '[^[:space:]]' | tail -n 1)" || true
  rm -f "$err"
  [ -n "$FIX_WHY" ] || FIX_WHY="exit $rc"
  case "$rc:$OUT" in 0:*STATUS=prepared*) ;; *) drop_lane "$1" ;; esac
}

# prepare_side <lane> -- freeze a lane beside the decision when there is anything for it: trunk
# for confirmed findings already on #PR's base, lint when AUTOFIX_LINT=1 asks. Its own outcome,
# never the decision's: prints its LANE= lines, sets SIDE_OK=1 once frozen.
prepare_side() {
  SIDE_OK=0
  case "$1" in
    trunk) local n; n="$(lane_findings trunk | jq length)"; [ "$n" -gt 0 ] || return 0
           say "trunk lane: $n confirmed finding(s) already on #$PR's base" ;;
    lint)  [ "${AUTOFIX_LINT:-}" = 1 ] || return 0
           say "lint lane: dart analyze issues on #$PR's base, in the packages it touches" ;;
  esac
  prepare_fix "$1"
  lane_lines "$1"
  case "$rc:$OUT" in
    0:*STATUS=prepared*) SIDE_OK=1 ;;
    0:*STATUS=dropped*|0:*STATUS=none*|0:*STATUS=exists:*) ;;
    *) warn "autofix didn't prepare the $1 lane's fix for #$PR ($FIX_WHY) -- the decision stands" ;;
  esac
}
# went_out -- the first URL anything of this decision went out at: the review or a lane's PR
went_out() { cat "$DEC/posted" "$DEC"/posted.* 2>/dev/null | head -n 1; }

freeze() {  # freeze <decision> <why> [body-file] -- write $DEC; the decision file last, since
  # ship reads a decision only once everything it posts is in place
  mkdir -p "$DEC"
  printf '%s\n' "$SHA" > "$DEC/sha"
  printf '%s\n' "$2" > "$DEC/why"
  rm -f "$DEC/review.json"
  if [ -n "${3:-}" ]; then
    cp "$3" "$DEC/body.md"
  else
    case "$1" in
      approve) echo "An adversarial review of this PR at \`${SHA:0:12}\` confirmed no findings." > "$DEC/body.md" ;;
      # A finding the diff has a line for goes inline, and the body names it in one line; the
      # rest go in the body in full. If the diff can't be read, all of them do.
      request-changes)
        # What the PR introduced: a defect already on its base is the trunk lane's, not the author's.
        lane_findings stacked > "$DEC/introduced.json"
        if "$ENGINE_DIR/inline.py" --event REQUEST_CHANGES --merged "$DEC/introduced.json" \
             --meta "$OUTDIR/meta.json" --out "$DEC/review.json"; then
          jq -r .body "$DEC/review.json" > "$DEC/body.md"
        else
          rm -f "$DEC/review.json"
          warn "couldn't anchor #$PR's findings in its diff -- the body carries every one in full"
          jq -L "$ENGINE_DIR" -r --arg sha "$SHA" \
            'include "confirmed"; confirmed | review_body($sha; "REQUEST_CHANGES"; map(.id))' \
            "$DEC/introduced.json" > "$DEC/body.md"
        fi
        # Restyled to the reviewer's learned rules, or left as is if that loses anything.
        learn write-body "$OUTDIR" ;;
    esac
  fi
  [ "$1" = fix ] || drop_lane stacked
  printf '%s\n' "$1" > "$DEC/decision"
}

if [ -n "$DECIDE" ]; then
  OUTDIR="$(find_outdir "pr$PR-review.md")"
  [ -n "$OUTDIR" ] || die "nothing reviewed for #$PR -- run without --decide first"
  DEC="$OUTDIR/decision"
  # Even a retarget: a trunk PR already out can't take the stacked findings too.
  [ -z "$(went_out)" ] || die "#$PR's decision already went out: $(went_out) -- anything still unshipped needs a follow-up by hand"
  # Merged, a fix can only be the trunk lane's; open, it's the one stacked on the author's branch.
  # So a stacked fix frozen before the merge (ship says retarget) re-freezes as the same decision.
  LANE=stacked; [ "$STATE" = OPEN ] || LANE=trunk
  [ "$(cat "$DEC/decision" 2>/dev/null)" != "$DECIDE" ] || [ -n "$BODY_FILE" ] \
    || { [ "$DECIDE" = fix ] && [ "$LANE" = trunk ] && [ -s "$OUTDIR/autofix/fix.patch" ]; } \
    || die "#$PR is already decided $DECIDE"
  SHA="$(reviewed_sha "$OUTDIR")"
  [ -n "$SHA" ] || die "can't tell which head the review of #$PR read -- see $OUTDIR"
  case "$DECIDE" in
    request-changes) [ -n "$BODY_FILE" ] || [ "$(lane_findings stacked | jq length)" -gt 0 ] \
                       || die "nothing #$PR introduced is CONFIRMED to request changes for -- pass --body-file with what to change" ;;
    fix)             [ "$(lane_findings "$LANE" | jq length)" -gt 0 ] || die "nothing CONFIRMED for a $LANE fix to address"
                     [ "$LANE" = trunk ] || [ "$FORK" = false ] \
                       || die "#$PR comes from a fork -- a fix PR can't be stacked on a branch outside this repo" ;;
  esac
  mark_running "$OUTDIR"
  if [ "$DECIDE" = fix ]; then
    prepare_fix "$LANE"
    case "$rc:$OUT" in
      0:*STATUS=prepared*) ;;
      *) lane_lines "$LANE"; die "autofix didn't prepare a fix for #$PR -- the earlier decision stands" ;;
    esac
    [ "$LANE" = stacked ] || drop_lane stacked   # its base merged away; trunk carries the fix now
  fi
  freeze "$DECIDE" "$DECIDE: set by hand${BODY_FILE:+, with its own body}" "$BODY_FILE"
  echo "STATUS=prepared"; echo "DECISION=$DECIDE"
  [ "$DECIDE" != fix ] || lane_lines "$LANE"
  say "read $DEC and $OUTDIR/autofix if a fix, then: peer-review.sh $PR --ship"
  exit 0
fi

# ship_review -- post the frozen approve or request-changes, once; its bare STATUS= line
ship_review() {
  local event posted url
  case "$DECISION" in approve) event=APPROVE; posted=approved ;; *) event=REQUEST_CHANGES; posted=changes-requested ;; esac
  if [ -s "$DEC/posted" ]; then
    say "#$PR already has this decision out: $(cat "$DEC/posted")"; echo "STATUS=exists:$(cat "$DEC/posted")"; return 0
  fi
  if [ "$STATE" != OPEN ]; then
    warn "#$PR merged since the review -- its $DECISION has no one left to reach; not posted"
    echo "STATUS=merged"; return 1
  fi
  if [ "$LIVE" != "$SHA" ]; then
    # Recorded, so a dashboard knows the head moved without asking GitHub itself.
    printf '%s\n' "$LIVE" > "$DEC/stale"
    warn "#$PR head is now ${LIVE:0:12}, not the reviewed ${SHA:0:12} -- re-run the review"
    echo "STATUS=stale"; return 1
  fi
  # GitHub takes an empty approval but not an empty change request.
  [ "$event" = APPROVE ] || grep -q '[^[:space:]]' "$DEC/body.md" 2>/dev/null \
    || die "$DEC/body.md is blank -- a change request needs one"
  # body.md as edited is the one control surface: a frozen comment goes out only while the
  # body still names its finding. A freeze with no review.json (approve, a hand-written body,
  # one from before inline comments) posts the body alone. commit_id pins the review to the
  # tree that was read; `gh pr review` would attach it to whatever the head is by then.
  if [ -s "$DEC/review.json" ]; then cat "$DEC/review.json"; else echo '{}'; fi \
    | jq --rawfile body "$DEC/body.md" --arg sha "$SHA" --arg event "$event" \
        '{commit_id: $sha, event: $event, body: $body,
          comments: [.comments[]? | select(.marker as $m | $body | contains($m)) | del(.marker)]}' \
    > "$DEC/outgoing.json"
  # One POST, comments and all: GitHub refuses the whole review (422) rather than post part of it.
  url="$(gh api -X POST "repos/{owner}/{repo}/pulls/$PR/reviews" --input "$DEC/outgoing.json" -q .html_url)" \
    || die "could not post the review of #$PR"
  printf '%s\n' "$url" > "$DEC/posted"
  learn record ship "$OUTDIR"
  echo "STATUS=$posted:$url"
}

# ship_lane <lane> -- open the lane's frozen fix PR, once; its LANE= lines. The stacked one asks
# the author; any other, whoever its prepare froze.
ship_lane() {
  local mark url who=""; mark="$(posted_mark "$1")"
  if [ -s "$mark" ]; then
    say "#$PR's $1 fix PR is already out: $(cat "$mark")"; echo "LANE=$1 STATUS=exists:$(cat "$mark")"; return 0
  fi
  [ "$1" != stacked ] || who="$AUTHOR"
  rc=0
  OUT="$(AUTOFIX_MODE=ship AUTOFIX_LANE="$1" AUTOFIX_FROZEN="$(lane_dir "$1")" AUTOFIX_REVIEWER="$who" \
    "$AUTOFIX" "$PR" "$SHA" "$ROOT" "$OUTDIR")" || rc=$?
  lane_lines "$1"
  # Marked like a posted review, so a second ship -- or a dashboard -- sees it went out.
  url="$(printf '%s\n' "$OUT" | sed -n 's/^STATUS=opened://p' | head -n 1)"
  if [ -n "$url" ]; then
    printf '%s\n' "$url" > "$mark"
    [ "$1" != stacked ] || { printf '%s\n' "$url" > "$DEC/posted.stacked"; learn record ship "$OUTDIR"; }
  fi
  return "$rc"
}

if [ "$SHIP" -eq 1 ]; then
  OUTDIR="$(find_outdir decision/decision)"
  [ -n "$OUTDIR" ] || die "nothing prepared for #$PR -- run without --ship first"
  DEC="$OUTDIR/decision"; DECISION="$(cat "$DEC/decision")"; SHA="$(cat "$DEC/sha")"
  # The decision, then each frozen lane in order. One that doesn't go out doesn't hold the rest
  # back -- a trunk fix needs nothing from the PR's head -- and the next ship resumes there.
  RC=0
  case "$DECISION" in
    approve|request-changes) ship_review || RC=1 ;;
    fix) ;;
    *) die "$DEC/decision is '$DECISION', not approve|fix|request-changes" ;;
  esac
  for lane in stacked trunk lint; do
    [ ! -s "$(lane_dir "$lane")/fix.patch" ] || ship_lane "$lane" || RC=1
  done
  exit "$RC"
fi

# intense runs only when its refuter is of a third family and, on ollama, answers a live
# 1-token call now: the one call that would otherwise fail mid-run.
intense_ready() {
  resolve_models intense || return 1
  [ "$SAME_FAMILY" = 0 ] || { say "intense would refute with $RESOLVED_REFUTER, a finder's own family"; return 1; }
  case "$RESOLVED_REFUTER" in
    ollama:*)
      [ -n "${OLLAMA_API_KEY:-}" ] || { say "OLLAMA_API_KEY is unset"; return 1; }
      ollama_answers "${RESOLVED_REFUTER#ollama:}" \
        || { say "ollama.com didn't serve ${RESOLVED_REFUTER#ollama:} (HTTP $OLLAMA_HTTP)"; return 1; } ;;
  esac
}

# A review with no findings exits 0 without writing merged.json or meta.json, so a record
# left by an earlier review would be read as this one's -- and an earlier decision would
# still be there for --ship to post. Clear every trace in both stores first, whatever this
# review ends in. The old report is kept aside, not read. A decision that never went out is
# recorded first: re-reviewing it says the human didn't take it.
learn record rerun --head "$LIVE" $(printf '%s\n' "$STORES" | while IFS= read -r s; do review_dir "$s" "$AUTHOR" "$REPO" "$PR"; echo; done)
while IFS= read -r s; do d="$(review_dir "$s" "$AUTHOR" "$REPO" "$PR")"; rm -rf "$d/decision" "$d/autofix"; done <<EOF
$STORES
EOF
if intense_ready; then
  ENGINE=intense; STORE="$INTENSE_STORE"
else
  ENGINE=regular; STORE="$REGULAR_STORE"; say "falling back to the regular review"
fi
echo "ENGINE=$ENGINE"
OUTDIR="$(review_dir "$STORE" "$AUTHOR" "$REPO" "$PR")"; REPORT="$OUTDIR/pr$PR-review.md"; DEC="$OUTDIR/decision"
mark_running "$OUTDIR"
rm -f "$OUTDIR/merged.json" "$OUTDIR/meta.json"
[ ! -f "$REPORT" ] || mv "$REPORT" "$REPORT.prev"

say "reviewing #$PR by $AUTHOR ($ENGINE)"
# Each store passed explicitly, so the engine writes where this script reads. The regular
# review resolves its own finders and refuter: regular pins and a preset in the environment are
# dropped. --no-fix:
# the fix PR is this script's decision, frozen for a human, not the engine's stage 5.
if [ "$ENGINE" = intense ]; then
  PR_REVIEW_INTENSE_DIR="$STORE" "$INTENSE" "$PR" ${PASS[@]+"${PASS[@]}"} --no-fix || die "the review of #$PR failed"
else
  env -u PR_REVIEW_FINDERS -u PR_REVIEW_REFUTER -u PR_REVIEW_PRESET PR_REVIEW_DIR="$STORE" \
    "$REGULAR" "$PR" ${PASS[@]+"${PASS[@]}"} --no-fix || die "the review of #$PR failed"
fi
[ -s "$REPORT" ] || die "the review of #$PR wrote no report at $REPORT"

# Every check below fails closed: an approval needs positive evidence the review was whole,
# because a missing line reads the same as a reworded one. offline-test.sh pins each string
# against pr-review.sh and report.jq.
INCOMPLETE=0
if [ -s "$OUTDIR/meta.json" ]; then
  # Anything but a known verdict -- ERROR, none, or one this script has never seen -- is a
  # claim no one checked, and supports neither an approval nor a change request.
  UNCHECKED="$(jq '[.[] | select((.v.verdict // "") | IN("CONFIRMED", "REFUTED", "UNVERIFIABLE") | not)] | length' "$OUTDIR/merged.json")"
  [ "$UNCHECKED" -eq 0 ] || die "$UNCHECKED finding(s) of #$PR were not checked (ERROR or no verdict) -- re-run the review; nothing decided"
  CONFIRMED="$(jq '[.[] | select(.v.verdict == "CONFIRMED")] | length' "$OUTDIR/merged.json")"
  FOUND="$(jq length "$OUTDIR/merged.json")"
  ! grep -qF '**Incomplete.**' "$REPORT" || INCOMPLETE=1
else
  # No record: the zero-findings report is all there is. It says "**No findings.**" only when
  # the anthropic finder -- the one with measured recall -- ran.
  CONFIRMED=0; FOUND=0
  grep -q '^\*\*No findings\.\*\* ' "$REPORT" \
    || die "the review of #$PR found nothing, but not with the anthropic finder -- see $REPORT; nothing decided"
  ! grep -qF 'Slices that produced nothing' "$REPORT" || INCOMPLETE=1
fi
SHA="$(reviewed_sha "$OUTDIR")"
[ -n "$SHA" ] || die "can't tell which head the review of #$PR read -- see $REPORT"

# Merged, every confirmed finding is the trunk lane's, and that fix is the whole decision.
if [ "$STATE" = MERGED ]; then
  [ "$CONFIRMED" -gt 0 ] || { say "#$PR merged with nothing confirmed -- nothing to fix"; echo "STATUS=merged-clean"; exit 0; }
  prepare_side trunk
  if [ "$SIDE_OK" = 0 ]; then
    # Nothing frozen and nothing owed: trunk already has its fix PR, or no longer has the bugs.
    [ "$rc" = 0 ] || exit "$rc"
    printf '%s\n' "$OUT" | grep -m1 '^STATUS=exists:' || echo "STATUS=merged-clean"
    exit 0
  fi
  freeze fix "fix: $CONFIRMED confirmed; #$PR merged, so the trunk lane fixes them on its base"
  learn record prepare "$OUTDIR"
  echo "STATUS=prepared"; echo "DECISION=fix"
  say "read $REPORT and $(lane_dir trunk)/{fix.patch,title,body.md}, then: peer-review.sh $PR --ship"
  prepare_side lint
  exit 0
fi

# Open, the decision weighs only what the PR introduced; the rest is the trunk lane's, below.
INTRO="$(lane_findings stacked | jq length)"
if [ "$INTRO" -eq 0 ]; then
  [ "$INCOMPLETE" -eq 0 ] \
    || die "slices of #$PR went unreviewed -- an approval would vouch for files no one read; see $REPORT"
  DECISION=approve; WHY="approve: 0 confirmed of $(plural "$FOUND" finding), every slice reviewed"
  [ "$CONFIRMED" -eq 0 ] \
    || WHY="approve: none of $(plural "$FOUND" finding) introduced by #$PR confirmed, every slice reviewed; $CONFIRMED already on its base"
elif is_fix_author "$AUTHOR" && [ "$FORK" = false ]; then
  prepare_fix stacked
  case "$rc:$OUT" in
    0:*STATUS=prepared*) DECISION=fix; WHY="fix: $INTRO confirmed; $AUTHOR is a fix author and autofix prepared a patch" ;;
    # Not this run's call to make: the head moved, or a fix PR is already out there.
    *STATUS=stale*|*STATUS=exists:*) printf '%s\n' "$OUT"; exit "$rc" ;;
    *) warn "autofix didn't prepare a fix for #$PR -- requesting changes instead"
       DECISION=request-changes
       WHY="request-changes: $INTRO confirmed; autofix didn't prepare a fix ($FIX_WHY)" ;;
  esac
elif is_fix_author "$AUTHOR"; then
  DECISION=request-changes; WHY="request-changes: $INTRO confirmed; #$PR comes from a fork, so no fix can be stacked on it"
else
  DECISION=request-changes; WHY="request-changes: $INTRO confirmed; $AUTHOR is not a fix author"
fi

freeze "$DECISION" "$WHY"
# The pipeline's own call and draft, kept before anyone edits them. Not on --decide: that is
# the human's call, recorded when it ships.
learn record prepare "$OUTDIR"

echo "STATUS=prepared"; echo "DECISION=$DECISION"
# AUTOFIX_MODEL picks the implementer; say which one the fix you are about to read came from.
[ "$DECISION" != fix ] || lane_lines stacked
case "$DECISION" in
  fix) say "read $REPORT and $OUTDIR/autofix/{fix.patch,title,body.md}, then: peer-review.sh $PR --ship" ;;
  *)   say "read $REPORT and $DEC/body.md, then: peer-review.sh $PR --ship" ;;
esac
for lane in trunk lint; do
  prepare_side "$lane"
  [ "$SIDE_OK" = 0 ] || say "and $(lane_dir "$lane")/{fix.patch,title,body.md}: --ship opens it too"
done
