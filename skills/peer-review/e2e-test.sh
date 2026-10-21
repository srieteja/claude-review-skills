#!/usr/bin/env bash
# peer-review.sh driving the real autofix.sh, prepare through ship, plus the two decisions
# that post a review instead. offline-test.sh pins each
# side of the seam against a stub of the other; this one runs the seam itself -- store paths,
# the pinned SHA, the frozen files, the reviewer hand-off. gh, claude, dart and the intense
# review and the ollama probe are stubbed; origin is a local bare repo, so the real `git push` runs and nothing
# leaves this machine. The gh stub remembers the PR it created, so a second ship sees it.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SB="$(mktemp -d "${TMPDIR:-/tmp}/peer-review-e2e.XXXXXX")"; trap 'rm -rf "$SB"' EXIT
export TMPDIR="$SB"
fail=0; n=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=1; }
check() { desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }

mkdir -p "$SB/bin"
cat > "$SB/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG/gh"
case "$1 $2" in
  "repo view") echo acme/widgets ;;
  "pr view")   printf '{"url":"https://github.com/acme/widgets/pull/7","author":{"login":"%s","is_bot":false},"headRefName":"feature-x","headRefOid":"%s","state":"OPEN","isCrossRepository":false}\n' \
                 "$STUB_AUTHOR" "$(cat "$STUB_LOG/live")" ;;
  "pr list")   cat "$STUB_LOG/created" 2>/dev/null || true ;;
  "pr create")
    [ "${STUB_CREATE_RC:-0}" = 0 ] || exit "$STUB_CREATE_RC"
    while [ $# -gt 0 ]; do
      case "$1" in
        --title) printf '%s' "$2" > "$STUB_LOG/title"; shift ;;
        --body-file) cp "$2" "$STUB_LOG/body"; shift ;;
      esac; shift
    done
    echo "https://github.com/acme/widgets/pull/99" | tee "$STUB_LOG/created" ;;
  "pr edit")   exit 0 ;;
  "api user")  echo "$STUB_ME" ;;
  "api -X")    while [ $# -gt 0 ]; do
                 case "$1" in -F) case "$2" in body=@*) cp "${2#body=@}" "$STUB_LOG/review-body" ;; esac ;; esac; shift
               done
               echo "$REVIEW_URL" ;;
  *) echo "gh stub: unhandled: $*" >&2; exit 64 ;;
esac
STUB
cat > "$SB/bin/intense-review.sh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG/intense"
d="$PR_REVIEW_INTENSE_DIR/$STUB_AUTHOR/widgets/$1"; mkdir -p "$d"
cp "$STUB_MERGED" "$d/merged.json"
printf '{"url":"u","headRefOid":"%s","author":{"login":"%s"}}' "$(cat "$STUB_LOG/live")" "$STUB_AUTHOR" > "$d/meta.json"
printf '# PR #%s\n\nu · reviewed at `%s`\n' "$1" "$(cat "$STUB_LOG/live")" > "$d/pr$1-review.md"
STUB
cat > "$SB/bin/curl" <<'STUB'
#!/usr/bin/env bash
cat > /dev/null; printf 200
STUB
cat > "$SB/bin/claude" <<'STUB'
#!/usr/bin/env bash
# autofix's implementer: edits the tree it is run in, and reports a clean result.
echo call >> "$STUB_LOG/claude"
git apply "$STUB_PATCH"; echo '{"type":"result","is_error":false,"result":"done"}'
STUB
cat > "$SB/bin/dart" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG/dart"
STUB
chmod +x "$SB/bin/"*
# PEER_REVIEW_AUTOFIX is deliberately left unset: the wrapper's own default path is under test.
export PATH="$SB/bin:$PATH" PEER_REVIEW_INTENSE="$SB/bin/intense-review.sh" \
       OLLAMA_API_KEY=k PR_REVIEW_FIX_AUTHORS=alice REVIEW_SKILLS_CONFIG="$SB/no-config" REVIEW_SKILLS_LOCK_DIR="$SB/locks"
export REVIEW_SKILLS_MODELS=manual
unset PEER_REVIEW_AUTOFIX AUTOFIX_MODE AUTOFIX_FROZEN AUTOFIX_REVIEWER AUTOFIX_DRY_RUN AUTOFIX_CLAUDE AUTOFIX_MODEL

confirmed='[{"id":"anthropic.c01-F1","file":"pkg/lib/a.dart","line":1,"claim":"Old value leaks past the reset",
  "mechanism":"reset() returns before clearing the cache","repro":"call reset twice","v":{"verdict":"CONFIRMED"}}]'
unverifiable='[{"id":"agy.c01-F1","file":"pkg/lib/a.dart","line":1,"claim":"Possibly racy",
  "mechanism":"unclear","repro":"none","v":{"verdict":"UNVERIFIABLE"}}]'

# A fresh case: alice's branch feature-x at $SHA in a one-package Dart repo, pushed to a bare
# origin at remotes/acme/widgets.git; the PR's live head starts at $SHA.
setup() {
  n=$((n + 1)); C="$SB/case$n"; mkdir -p "$C/remotes/acme" "$C/log" "$C/store" "$C/repo/pkg/lib" "$C/repo/pkg/test"
  git init -q -b feature-x "$C/repo"
  git -C "$C/repo" config user.name tester; git -C "$C/repo" config user.email tester@example.com
  printf 'name: pkg\n' > "$C/repo/pkg/pubspec.yaml"; printf 'old\n' > "$C/repo/pkg/lib/a.dart"; : > "$C/repo/pkg/test/a_test.dart"
  git -C "$C/repo" add -A; git -C "$C/repo" commit -qm init
  git clone -q --bare "$C/repo" "$C/remotes/acme/widgets.git"
  git -C "$C/repo" remote add origin "$C/remotes/acme/widgets.git"
  SHA="$(git -C "$C/repo" rev-parse HEAD)"
  printf 'new\n' > "$C/repo/pkg/lib/a.dart"; git -C "$C/repo" diff > "$C/fix.patch"; git -C "$C/repo" checkout -q -- .
  printf '%s' "$confirmed" > "$C/merged.json"; echo "$SHA" > "$C/log/live"
  FROZEN="$C/store/alice/widgets/7/autofix"
  export STUB_LOG="$C/log" STUB_PATCH="$C/fix.patch" STUB_MERGED="$C/merged.json" STUB_AUTHOR=alice \
         STUB_ME=me STUB_CREATE_RC=0 PR_REVIEW_INTENSE_DIR="$C/store"
}
run() { rc=0; ( cd "$C/repo" && "$HERE/peer-review.sh" "$@" ) >"$C/stdout" 2>"$C/stderr" || rc=$?; }
# rerun -- run, committing at another time. Two runs in the same second build byte-identical
# commits, so a "resumed" push would be a no-op and pass without the resume.
rerun() { GIT_AUTHOR_DATE=2001-01-01T00:00:00Z GIT_COMMITTER_DATE=2001-01-01T00:00:00Z run "$@"; }
rc_is()  { [ "$rc" = "$1" ]; }
said()   { grep -qxF -- "$1" "$C/stdout"; }
logged() { [ -f "$C/log/$1" ] && grep -qF -- "$2" "$C/log/$1"; }
never()  { ! logged "$@"; }
calls()  { if [ -f "$C/log/$1" ]; then wc -l < "$C/log/$1" | tr -d ' '; else echo 0; fi; }
pushed() { git --git-dir="$C/remotes/acme/widgets.git" rev-parse -q --verify refs/heads/fix/pr7-review-findings; }
unpushed() { ! pushed; }
commit_msg() { git --git-dir="$C/remotes/acme/widgets.git" log -1 --format=%B fix/pr7-review-findings; }
pushed_file_is() { [ "$(git --git-dir="$C/remotes/acme/widgets.git" show fix/pr7-review-findings:pkg/lib/a.dart)" = "$1" ]; }
URL=https://github.com/acme/widgets/pull/99
export REVIEW_URL=https://github.com/acme/widgets/pull/7#pullrequestreview-1

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
check "reports the opened PR"                      said "STATUS=opened:$URL"
check "reports the author was asked"               said "REVIEWER=requested:alice"
check "asks alice on the fix PR"                   logged gh "pr edit $URL --add-reviewer alice"
check "pushes the fix onto alice's head"           pushed_file_is new
check "  as one commit on top of it"               [ "$(git --git-dir="$C/remotes/acme/widgets.git" rev-parse fix/pr7-review-findings~1)" = "$SHA" ]
check "  with no AI co-author"                     sh -c "! git --git-dir='$C/remotes/acme/widgets.git' log -1 --format=%B fix/pr7-review-findings | grep -qi co-authored"
check "  titled as the PR is"                      [ "$(commit_msg | head -n 1)" = "$(cat "$FROZEN/title")" ]
check "  and naming no finding"                    sh -c "! git --git-dir='$C/remotes/acme/widgets.git' log -1 --format=%B fix/pr7-review-findings | grep -qF 'Old value'"
check "opens against alice's branch"               logged gh "--base feature-x --head fix/pr7-review-findings"
check "posts the body as edited"                   grep -qF "EDITED BEFORE SHIPPING" "$C/log/body"
check "review ran once, implementer ran once"      [ "$(calls intense):$(calls claude)" = 1:1 ]

run 7 --ship
check "shipping twice: exits 0"                    rc_is 0
check "  reports the existing PR"                  said "STATUS=exists:$URL"
check "  opens nothing new"                        [ "$(grep -c '^pr create' "$C/log/gh")" = 1 ]

echo "a ship cut short after the push"
setup; run 7; export STUB_CREATE_RC=1; run 7 --ship
check "pr create fails: exits 1"                   rc_is 1
check "  the branch is already on origin"          pushed
TIP="$(git --git-dir="$C/remotes/acme/widgets.git" rev-parse fix/pr7-review-findings)"
export STUB_CREATE_RC=0; rerun 7 --ship
check "ship again: opens the PR"                   said "STATUS=opened:$URL"
check "  on the branch already pushed"             [ "$(git --git-dir="$C/remotes/acme/widgets.git" rev-parse fix/pr7-review-findings)" = "$TIP" ]
check "  and asks alice"                           said "REVIEWER=requested:alice"
check "  one push, one PR"                         [ "$(git --git-dir="$C/remotes/acme/widgets.git" rev-list --count fix/pr7-review-findings)" = 2 ]

echo "refusals"
setup; run 7; echo "moved000" > "$C/log/live"; run 7 --ship
check "alice pushed after the review: refused"     rc_is 1
check "  reports stale"                            said "STATUS=stale"
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
check "  pinned to the reviewed SHA"               logged gh "-f event=APPROVE -f commit_id=$SHA"
check "  nothing pushed, no PR opened"             sh -c "! git --git-dir='$C/remotes/acme/widgets.git' rev-parse -q --verify refs/heads/fix/pr7-review-findings && ! grep -q '^pr create' '$C/log/gh'"

setup; export PR_REVIEW_FIX_AUTHORS=bob; run 7; export PR_REVIEW_FIX_AUTHORS=alice
check "CONFIRMED, author not on the fix list: request-changes" said "DECISION=request-changes"
check "  the implementer never runs"               [ "$(calls claude)" = 0 ]
run 7 --ship
check "  ship requests changes"                    said "STATUS=changes-requested:$REVIEW_URL"
check "  pinned to the reviewed SHA"               logged gh "-f event=REQUEST_CHANGES -f commit_id=$SHA"
check "  naming the finding"                       grep -qF "Old value leaks past the reset" "$C/log/review-body"
check "  nothing pushed"                           unpushed

[ "$fail" = 0 ] && echo "all passed" || { echo "FAILURES"; exit 1; }
