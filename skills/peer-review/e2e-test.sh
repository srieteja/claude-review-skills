#!/usr/bin/env bash
# peer-review.sh driving the real autofix.sh, prepare through ship, plus the two decisions
# that post a review instead. offline-test.sh pins each
# side of the seam against a stub of the other; this one runs the seam itself -- store paths,
# the pinned SHA, the frozen files, the reviewer hand-off. The sandbox is e2e-sandbox.sh's.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/e2e-sandbox.sh"

echo "prepare"
setup; run 7
check "exits 0"                                    rc_is 0
check "reports prepared"                           said "STATUS=prepared"
check "  as a fix"                                 said "DECISION=fix"
check "freezes the reviewed SHA"                   [ "$(cat "$FROZEN/sha")" = "$SHA" ]
check "freezes a patch that carries the fix"       grep -qx '+new' "$FROZEN/fix.patch"
check "freezes a body naming the finding"          grep -qF "Old value leaks past the reset" "$FROZEN/body.md"
check "nothing pushed"                             unpushed
check "no PR opened"                               never gh "pr create"
check "tells you how to ship"                      grep -qF -- "--ship" "$C/stderr"

echo "ship"
printf '\nEDITED BEFORE SHIPPING\n' >> "$FROZEN/body.md"; run 7 --ship
check "exits 0"                                    rc_is 0
check "reports the opened PR"                      said "LANE=stacked STATUS=opened:$URL"
check "reports the author was asked"               said "REVIEWER=requested:alice"
check "asks alice on the fix PR"                   logged gh "pr edit $URL --add-reviewer alice"
check "pushes the fix onto alice's head"           pushed_file_is new
check "  as one commit on top of it"               [ "$(git --git-dir="$C/remotes/acme/widgets.git" rev-parse $FB~1)" = "$SHA" ]
check "  with no AI co-author"                     sh -c "! git --git-dir='$C/remotes/acme/widgets.git' log -1 --format=%B $FB | grep -qi co-authored"
check "  titled as the PR is"                      [ "$(commit_msg | head -n 1)" = "$(cat "$FROZEN/title")" ]
check "  and naming no finding"                    sh -c "! git --git-dir='$C/remotes/acme/widgets.git' log -1 --format=%B $FB | grep -qF 'Old value'"
check "opens against alice's branch"               logged gh "--base feature-x --head $FB"
check "posts the body as edited"                   grep -qF "EDITED BEFORE SHIPPING" "$C/log/body"
check "review ran once, implementer ran once"      [ "$(calls intense):$(calls claude)" = 1:1 ]

run 7 --ship
check "shipping twice: exits 0"                    rc_is 0
check "  reports the existing PR"                  said "LANE=stacked STATUS=exists:$URL"
check "  opens nothing new"                        [ "$(grep -c '^pr create' "$C/log/gh")" = 1 ]

echo "a ship cut short after the push"
setup; run 7; export STUB_CREATE_RC=1; run 7 --ship
check "pr create fails: exits 1"                   rc_is 1
check "  the branch is already on origin"          pushed
TIP="$(git --git-dir="$C/remotes/acme/widgets.git" rev-parse $FB)"
export STUB_CREATE_RC=0; rerun 7 --ship
check "ship again: opens the PR"                   said "LANE=stacked STATUS=opened:$URL"
check "  on the branch already pushed"             [ "$(git --git-dir="$C/remotes/acme/widgets.git" rev-parse $FB)" = "$TIP" ]
check "  and asks alice"                           said "REVIEWER=requested:alice"
check "  one push, one PR"                         [ "$(git --git-dir="$C/remotes/acme/widgets.git" rev-list --count $FB)" = 2 ]

echo "refusals"
setup; run 7; echo "moved000" > "$C/log/live"; run 7 --ship
check "alice pushed after the review: refused"     rc_is 1
check "  reports stale"                            said "LANE=stacked STATUS=stale"
check "  nothing pushed"                           unpushed

setup; export STUB_ME=ALICE; run 7
check "your own PR: refused"                       rc_is 1
check "  before any review"                        [ "$(calls intense)" = 0 ]

echo "decisions that post a review"
setup; printf '%s' "$unverifiable" > "$C/merged.json"; run 7
check "only UNVERIFIABLE findings: approve"        said "DECISION=approve"
check "  freezes no fix"                           [ ! -e "$FROZEN" ]
run 7 --ship
check "  ship approves"                            said "STATUS=approved:$REVIEW_URL"
check "  pinned to the reviewed SHA"               posted_review '.event == "APPROVE" and .commit_id == $sha'
check "  nothing pushed, no PR opened"             sh -c "! git --git-dir='$C/remotes/acme/widgets.git' rev-parse -q --verify refs/heads/$FB && ! grep -q '^pr create' '$C/log/gh'"

setup; export PR_REVIEW_FIX_AUTHORS=bob; run 7; export PR_REVIEW_FIX_AUTHORS=alice
check "CONFIRMED, author not on the fix list: request-changes" said "DECISION=request-changes"
check "  the implementer never runs"               [ "$(calls claude)" = 0 ]
run 7 --ship
check "  ship requests changes"                    said "STATUS=changes-requested:$REVIEW_URL"
check "  pinned to the reviewed SHA"               posted_review '.event == "REQUEST_CHANGES" and .commit_id == $sha'
check "  naming the finding"                       posted_review '.body | contains("Old value leaks past the reset")'
check "  nothing pushed"                           unpushed

[ "$fail" = 0 ] && echo "all passed" || { echo "FAILURES"; exit 1; }
