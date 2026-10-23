#!/usr/bin/env bash
# peer-review -- review someone else's PR and end in one of three decisions, frozen for a human
# to read before anything goes public:
#
#   approve          nothing CONFIRMED, every finding checked, every slice reviewed
#   fix              CONFIRMED findings by an author on PR_REVIEW_FIX_AUTHORS: autofix.sh
#                    prepares a companion PR stacked on theirs
#   request-changes  CONFIRMED findings by anyone else, or a fix autofix.sh wouldn't prepare
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
# The decision lands in <store>/<author>/<repo>/<N>/decision/{decision,sha,body.md}; a fix's patch,
# title and body in .../autofix/. Edit body.md (or autofix/body.md) in between to change what
# is posted. Ship refuses if the PR head moved since the review. Approve and request-changes
# post one review pinned to the reviewed SHA, once.
#
# stdout carries only these lines; progress goes to stderr:
#   prepare  ENGINE=intense|regular, then STATUS=prepared and DECISION=approve|fix|request-changes,
#            or autofix.sh's STATUS=exists:<url> | stale
#   ship     STATUS=approved:<url> | changes-requested:<url> | exists:<url> | stale, or for a
#            fix autofix.sh's STATUS=opened:<url> and REVIEWER=requested|skipped|failed:<login>
#
# exit 1  refused or failed -- including any finding left unchecked (ERROR or no verdict) and
#         a clean review that didn't cover every slice: neither can support a decision
#
# env (or the config file, see lib/common.sh; the environment wins):
#      PR_REVIEW_FIX_AUTHORS, alias PEER_REVIEW_FIX_AUTHORS (default none; space- or comma-separated)
#      OLLAMA_API_KEY (no key, no probe: the regular review runs)
#      PR_REVIEW_INTENSE_REFUTER (the model probed)
#      PR_REVIEW_DIR (default ~/.reviews), PR_REVIEW_INTENSE_DIR (default <PR_REVIEW_DIR>/_intense)
#      PEER_REVIEW_INTENSE, PEER_REVIEW_REGULAR, PEER_REVIEW_AUTOFIX (the scripts wrapped, for tests)
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

die()   { printf '\033[31mpeer-review: %s\033[0m\n' "$*" >&2; exit 1; }
say()   { printf '\033[36m==>\033[0m %s\n' "$*" >&2; }
warn()  { printf '\033[33m!!\033[0m %s\n' "$*" >&2; }
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
STATE="$(printf '%s' "$META" | jq -r '.state')"
[ "$STATE" = OPEN ] || die "#$PR is not open ($STATE)"
[ "$(printf '%s' "$META" | jq -r '.isCrossRepository')" = false ] \
  || die "#$PR comes from a fork -- a fix PR can't be stacked on a branch outside this repo"
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

prepare_fix() {  # prepare_fix -- autofix prepare from the reviewed $SHA; sets OUT and rc
  # The SHA the review read, not the live head: autofix refuses as stale if the author pushed.
  rc=0
  OUT="$(AUTOFIX_MODE=prepare AUTOFIX_FROZEN="$OUTDIR/autofix" "$AUTOFIX" "$PR" "$SHA" "$ROOT" "$OUTDIR")" || rc=$?
}

freeze() {  # freeze <decision> [body-file] -- write $DEC; the decision file last, since ship
  # reads a decision only once everything it posts is in place
  mkdir -p "$DEC"
  printf '%s\n' "$SHA" > "$DEC/sha"
  if [ -n "${2:-}" ]; then
    cp "$2" "$DEC/body.md"
  else
    case "$1" in
      approve) echo "An adversarial review of this PR at \`${SHA:0:12}\` confirmed no findings." > "$DEC/body.md" ;;
      request-changes)
        { echo "An adversarial review of this PR at \`${SHA:0:12}\` confirmed these findings:"
          jq -L "$HERE/../pr-review" -r 'include "confirmed"; confirmed_md' "$OUTDIR/merged.json"
        } > "$DEC/body.md" ;;
    esac
  fi
  [ "$1" = fix ] || rm -rf "$OUTDIR/autofix"
  printf '%s\n' "$1" > "$DEC/decision"
}

if [ -n "$DECIDE" ]; then
  OUTDIR="$(find_outdir "pr$PR-review.md")"
  [ -n "$OUTDIR" ] || die "nothing reviewed for #$PR -- run without --decide first"
  DEC="$OUTDIR/decision"
  [ ! -s "$DEC/posted" ] || die "#$PR's decision already went out: $(cat "$DEC/posted")"
  [ "$(cat "$DEC/decision" 2>/dev/null)" != "$DECIDE" ] || [ -n "$BODY_FILE" ] \
    || die "#$PR is already decided $DECIDE"
  SHA="$(reviewed_sha "$OUTDIR")"
  [ -n "$SHA" ] || die "can't tell which head the review of #$PR read -- see $OUTDIR"
  CONFIRMED=0
  [ ! -s "$OUTDIR/merged.json" ] || CONFIRMED="$(jq '[.[] | select(.v.verdict == "CONFIRMED")] | length' "$OUTDIR/merged.json")"
  case "$DECIDE" in
    request-changes) [ -n "$BODY_FILE" ] || [ "$CONFIRMED" -gt 0 ] \
                       || die "nothing CONFIRMED to request changes for -- pass --body-file with what to change" ;;
    fix)             [ "$CONFIRMED" -gt 0 ] || die "nothing CONFIRMED for a fix to address" ;;
  esac
  mark_running "$OUTDIR"
  if [ "$DECIDE" = fix ]; then
    prepare_fix
    case "$rc:$OUT" in
      0:*STATUS=prepared*) ;;
      *) rm -rf "$OUTDIR/autofix"; printf '%s\n' "$OUT"
         die "autofix didn't prepare a fix for #$PR -- the earlier decision stands" ;;
    esac
  fi
  freeze "$DECIDE" "$BODY_FILE"
  echo "STATUS=prepared"; echo "DECISION=$DECIDE"
  say "read $DEC and $OUTDIR/autofix if a fix, then: peer-review.sh $PR --ship"
  exit 0
fi

if [ "$SHIP" -eq 1 ]; then
  OUTDIR="$(find_outdir decision/decision)"
  [ -n "$OUTDIR" ] || die "nothing prepared for #$PR -- run without --ship first"
  DEC="$OUTDIR/decision"; DECISION="$(cat "$DEC/decision")"; SHA="$(cat "$DEC/sha")"
  if [ -s "$DEC/posted" ]; then
    say "#$PR already has this decision out: $(cat "$DEC/posted")"; echo "STATUS=exists:$(cat "$DEC/posted")"; exit 0
  fi

  case "$DECISION" in
    fix)             rc=0
                     OUT="$(AUTOFIX_MODE=ship AUTOFIX_FROZEN="$OUTDIR/autofix" AUTOFIX_REVIEWER="$AUTHOR" \
                       "$AUTOFIX" "$PR" "$SHA" "$ROOT" "$OUTDIR")" || rc=$?
                     printf '%s\n' "$OUT"
                     # Marked like a posted review, so a second ship -- or a dashboard -- sees it went out.
                     URL="$(printf '%s\n' "$OUT" | sed -n 's/^STATUS=opened://p' | head -n 1)"
                     [ -z "$URL" ] || printf '%s\n' "$URL" > "$DEC/posted"
                     exit "$rc" ;;
    approve)         EVENT=APPROVE;         POSTED=approved ;;
    request-changes) EVENT=REQUEST_CHANGES; POSTED=changes-requested ;;
    *)               die "$DEC/decision is '$DECISION', not approve|fix|request-changes" ;;
  esac
  if [ "$LIVE" != "$SHA" ]; then
    warn "#$PR head is now ${LIVE:0:12}, not the reviewed ${SHA:0:12} -- re-run the review"
    echo "STATUS=stale"; exit 1
  fi
  # GitHub takes an empty approval but not an empty change request.
  [ "$EVENT" = APPROVE ] || grep -q '[^[:space:]]' "$DEC/body.md" 2>/dev/null \
    || die "$DEC/body.md is blank -- a change request needs one"
  # commit_id pins the review to the tree that was read; `gh pr review` would attach it to
  # whatever the head is by then.
  URL="$(gh api -X POST "repos/{owner}/{repo}/pulls/$PR/reviews" -f event="$EVENT" -f commit_id="$SHA" \
           -F body=@"$DEC/body.md" -q .html_url)" || die "could not post the review of #$PR"
  printf '%s\n' "$URL" > "$DEC/posted"
  echo "STATUS=$POSTED:$URL"; exit 0
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
# review ends in. The old report is kept aside, not read.
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
  ! grep -qF '**Incomplete.**' "$REPORT" || INCOMPLETE=1
else
  # No record: the zero-findings report is all there is. It says "**No findings.**" only when
  # the anthropic finder -- the one with measured recall -- ran.
  CONFIRMED=0
  grep -q '^\*\*No findings\.\*\* ' "$REPORT" \
    || die "the review of #$PR found nothing, but not with the anthropic finder -- see $REPORT; nothing decided"
  ! grep -qF 'Slices that produced nothing' "$REPORT" || INCOMPLETE=1
fi
SHA="$(reviewed_sha "$OUTDIR")"
[ -n "$SHA" ] || die "can't tell which head the review of #$PR read -- see $REPORT"

if [ "$CONFIRMED" -eq 0 ]; then
  [ "$INCOMPLETE" -eq 0 ] \
    || die "slices of #$PR went unreviewed -- an approval would vouch for files no one read; see $REPORT"
  DECISION=approve
elif is_fix_author "$AUTHOR"; then
  prepare_fix
  case "$rc:$OUT" in
    0:*STATUS=prepared*) DECISION=fix ;;
    # Not this run's call to make: the head moved, or a fix PR is already out there.
    *STATUS=stale*|*STATUS=exists:*) printf '%s\n' "$OUT"; exit "$rc" ;;
    *) warn "autofix didn't prepare a fix for #$PR -- requesting changes instead"
       rm -rf "$OUTDIR/autofix"; DECISION=request-changes ;;
  esac
else
  DECISION=request-changes
fi

freeze "$DECISION"

echo "STATUS=prepared"; echo "DECISION=$DECISION"
# AUTOFIX_MODEL picks the implementer; say which one the fix you are about to read came from.
[ "$DECISION" = fix ] && printf '%s\n' "$OUT" | grep '^IMPLEMENTER=' || true
case "$DECISION" in
  fix) say "read $REPORT and $OUTDIR/autofix/{fix.patch,title,body.md}, then: peer-review.sh $PR --ship" ;;
  *)   say "read $REPORT and $DEC/body.md, then: peer-review.sh $PR --ship" ;;
esac
