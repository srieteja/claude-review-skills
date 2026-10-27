# shellcheck shell=bash
# Sourced by e2e-test.sh and contract-test.sh: a sandbox where peer-review.sh drives the real
# autofix.sh. gh, claude, dart, the intense review and the ollama probe are stubbed; origin is a
# local bare repo, so the real `git push` runs and nothing leaves this machine. The gh stub
# remembers the PR it created, so a second ship sees it. Defines setup, run and the check helpers.
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
  "pr list")   if [ -s "$STUB_LOG/created" ]; then printf '[{"url":"%s"}]\n' "$(cat "$STUB_LOG/created")"; else echo '[]'; fi ;;
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
  # inline.py's diff, so a finding on pkg/lib/a.dart:1 anchors as an inline comment.
  "api repos/acme/widgets/pulls/7/files") echo '[[{"filename":"pkg/lib/a.dart","patch":"@@ -1 +1 @@\n-old\n+old"}]]' ;;
  "api -X")    while [ $# -gt 0 ]; do
                 case "$1" in --input) cp "$2" "$STUB_LOG/review.json"; shift ;; esac; shift
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
printf '{"url":"https://github.com/acme/widgets/pull/7","number":7,"headRefOid":"%s","author":{"login":"%s"}}' "$(cat "$STUB_LOG/live")" "$STUB_AUTHOR" > "$d/meta.json"
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
# The learning engine's hooks are offline-test.sh's; here they'd only call the claude stub.
export PR_REVIEW_LEARN=off PR_REVIEW_LEARN_DIR="$SB/learn"
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
  SHA="$(git -C "$C/repo" rev-parse HEAD)"; FB="fix/pr7-review-findings-${SHA:0:12}"
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
# The one POST ship makes: its --input payload, tested with jq against the reviewed SHA.
posted_review() { jq -e --arg sha "$SHA" "$1" "$C/log/review.json" >/dev/null 2>&1; }
never()  { ! logged "$@"; }
calls()  { if [ -f "$C/log/$1" ]; then wc -l < "$C/log/$1" | tr -d ' '; else echo 0; fi; }
pushed() { git --git-dir="$C/remotes/acme/widgets.git" rev-parse -q --verify refs/heads/$FB; }
unpushed() { ! pushed; }
commit_msg() { git --git-dir="$C/remotes/acme/widgets.git" log -1 --format=%B $FB; }
pushed_file_is() { [ "$(git --git-dir="$C/remotes/acme/widgets.git" show $FB:pkg/lib/a.dart)" = "$1" ]; }
URL=https://github.com/acme/widgets/pull/99
export REVIEW_URL=https://github.com/acme/widgets/pull/7#pullrequestreview-1
