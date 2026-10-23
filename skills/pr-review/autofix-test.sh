#!/usr/bin/env bash
# autofix.sh -- guards, the test gate, the prepare/ship split, resuming a half-finished ship,
# the reviewer request, and the unset-env path watch.sh takes. gh, claude and dart are
# stubbed; origin is a local bare repo, so the real `git push` runs and nothing leaves this
# machine.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SB="$(mktemp -d "${TMPDIR:-/tmp}/autofix-test.XXXXXX")"; trap 'rm -rf "$SB"' EXIT
export TMPDIR="$SB"                    # autofix.sh's mktemp work dirs land in the sandbox
fail=0; n=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=1; }
check() { desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }

mkdir -p "$SB/bin"
cat > "$SB/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG/gh"
case "$1 $2" in
  "repo view") echo "$STUB_REPO" ;;
  "pr view")   echo "$STUB_PRVIEW" ;;
  "pr list")   [ -z "${STUB_EXISTING:-}" ] || echo "$STUB_EXISTING" ;;
  "pr create")
    [ "${STUB_CREATE_RC:-0}" = 0 ] || exit "$STUB_CREATE_RC"
    while [ $# -gt 0 ]; do
      case "$1" in
        --title) printf '%s' "$2" > "$STUB_LOG/title"; shift ;;
        --body-file) cp "$2" "$STUB_LOG/body"; shift ;;
      esac; shift
    done
    echo "https://github.com/$STUB_REPO/pull/99" ;;
  "pr edit")   exit "${STUB_EDIT_RC:-0}" ;;
  "api user")  echo "$STUB_ME" ;;
  *) echo "gh stub: unhandled: $*" >&2; exit 64 ;;
esac
STUB
cat > "$SB/bin/claude" <<'STUB'
#!/usr/bin/env bash
# One line per call; the flags, the prompt and where it ran are kept for the checks.
echo call >> "$STUB_LOG/claude"
printf '%s\n' "$@" > "$STUB_LOG/claude.args"
pwd > "$STUB_LOG/claude.cwd"; git rev-parse HEAD > "$STUB_LOG/claude.head"
git remote > "$STUB_LOG/claude.remotes"
while [ $# -gt 0 ]; do case "$1" in -p) printf '%s\n' "$2" > "$STUB_LOG/task.md"; shift ;; esac; shift; done
[ "${STUB_CLAUDE_RC:-0}" = 0 ] || exit "$STUB_CLAUDE_RC"
[ -n "${STUB_NOOP:-}" ] || git apply "$STUB_PATCH"
if [ -n "${STUB_COMMIT:-}" ]; then
  git add -A; git -c user.name=x -c user.email=x@example.com commit -qm wip
  git branch -f fix/pr7-review-findings   # refs in its tree must never reach your clone
fi
# What its own `dart pub get` leaves: neither is part of the fix.
: > pkg/pubspec.lock; mkdir -p pkg/.dart_tool; echo x > pkg/.dart_tool/cache
printf '{"type":"result","subtype":"%s","is_error":%s,"result":"done"}\n' \
  "${STUB_SUBTYPE:-success}" "${STUB_IS_ERROR:-false}"
STUB
cat > "$SB/bin/dart" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG/dart"
# pub get leaves what the real one does: a lockfile and .dart_tool/, neither part of the fix.
if [ "$1 $2" = "pub get" ]; then : > pubspec.lock; mkdir -p .dart_tool; fi
if [ "$1" = test ]; then pwd >> "$STUB_LOG/dart.cwd"; [ -z "${STUB_DART_STDIN:-}" ] || cat >/dev/null; exit "${STUB_DART_RC:-0}"; fi
if [ "$1" = analyze ]; then pwd >> "$STUB_LOG/analyze.cwd"; exit "${STUB_ANALYZE_RC:-0}"; fi
STUB
chmod +x "$SB/bin/"*
export PATH="$SB/bin:$PATH" REVIEW_SKILLS_CONFIG="$SB/no-config"

prlist() {  # prlist <number>:<state>... -- gh pr list --json url,state, in that order
  local out="" p
  for p in "$@"; do out="$out${out:+,}{\"url\":\"https://github.com/acme/widgets/pull/${p%%:*}\",\"state\":\"${p#*:}\"}"; done
  echo "[$out]"
}
prview() {  # prview <isCrossRepository> <headRefOid> [state]
  printf '{"headRefName":"feature-x","headRefOid":"%s","state":"%s","isCrossRepository":%s}' "$2" "${3:-OPEN}" "$1"
}

# A fresh case: a one-package Dart repo at $SHA, its bare origin at remotes/acme/widgets.git,
# a review store with one CONFIRMED and one UNVERIFIABLE finding, and every stub knob reset.
# Flags add to it: `workspace` a root pubspec.yaml, as a pub workspace has; `twopkg` a second
# package, pkg2; `ci` a workflow under .github/; `live` tests/live, a pack that needs a live rig.
setup() {
  n=$((n + 1)); C="$SB/case$n"
  mkdir -p "$C/remotes/acme" "$C/out" "$C/log" "$C/repo/pkg/lib"
  git init -q -b main "$C/repo"
  git -C "$C/repo" config user.name tester; git -C "$C/repo" config user.email tester@example.com
  printf 'name: pkg\n' > "$C/repo/pkg/pubspec.yaml"
  mkdir -p "$C/repo/pkg/test"; printf 'void main() {}\n' > "$C/repo/pkg/test/a_test.dart"
  case " $* " in *" workspace "*) printf 'name: root\nworkspace: [pkg]\n' > "$C/repo/pubspec.yaml" ;; esac
  case " $* " in *" twopkg "*) mkdir -p "$C/repo/pkg2/test"; printf 'name: pkg2\n' > "$C/repo/pkg2/pubspec.yaml"
                               printf 'void main() {}\n' > "$C/repo/pkg2/test/a_test.dart" ;; esac
  case " $* " in *" live "*) mkdir -p "$C/repo/tests/live/test"; printf 'name: live\n' > "$C/repo/tests/live/pubspec.yaml"
                             printf 'void main() {}\n' > "$C/repo/tests/live/test/a_test.dart" ;; esac
  case " $* " in *" ci "*) mkdir -p "$C/repo/.github/workflows"; printf 'on: push\n' > "$C/repo/.github/workflows/ci.yaml" ;; esac
  printf 'old\n' > "$C/repo/pkg/lib/a.dart"
  git -C "$C/repo" add -A; git -C "$C/repo" commit -qm init
  git clone -q --bare "$C/repo" "$C/remotes/acme/widgets.git"
  git -C "$C/repo" remote add origin "$C/remotes/acme/widgets.git"
  SHA="$(git -C "$C/repo" rev-parse HEAD)"; FB="fix/pr7-review-findings-${SHA:0:12}"
  printf 'new\n' > "$C/repo/pkg/lib/a.dart"
  git -C "$C/repo" diff > "$C/fix.patch"; git -C "$C/repo" checkout -q -- .
  cat > "$C/out/merged.json" <<'JSON'
[{"id":"anthropic.c01-F1","file":"pkg/lib/a.dart","line":1,"claim":"Old value leaks past the reset",
  "mechanism":"reset() returns before clearing the cache","repro":"call reset twice","v":{"verdict":"CONFIRMED"}},
 {"id":"agy.c01-F1","file":"pkg/lib/a.dart","line":1,"claim":"Possibly racy under isolates",
  "mechanism":"unclear","repro":"none","v":{"verdict":"UNVERIFIABLE"}}]
JSON
  printf '{"url":"https://github.com/acme/widgets/pull/7","headRefOid":"%s"}' "$SHA" > "$C/out/meta.json"
  FROZEN="$C/out/autofix"
  export STUB_LOG="$C/log" STUB_PATCH="$C/fix.patch" STUB_REPO=acme/widgets STUB_EXISTING="" \
         STUB_ME=me STUB_EDIT_RC=0 STUB_DART_RC=0 STUB_ANALYZE_RC=0 STUB_CLAUDE_RC=0 STUB_CREATE_RC=0 STUB_DART_STDIN="" \
         STUB_PRVIEW="$(prview false "$SHA")" STUB_NOOP="" STUB_COMMIT="" STUB_IS_ERROR=false STUB_SUBTYPE=success
  unset AUTOFIX_MODE AUTOFIX_FROZEN AUTOFIX_REVIEWER AUTOFIX_DRY_RUN AUTOFIX_MODEL AUTOFIX_EFFORT AUTOFIX_BUDGET AUTOFIX_CLAUDE AUTOFIX_ANALYZE_ONLY
  REFS_BEFORE="$(refs)"
}
# patch [--no-fix] <file>... -- the implementer's patch adds each <file>, alongside the a.dart
# fix unless --no-fix
patch() {
  local fix=1; [ "$1" != --no-fix ] || { fix=0; shift; }
  [ "$fix" = 0 ] || printf 'new\n' > "$C/repo/pkg/lib/a.dart"
  for f in "$@"; do mkdir -p "$(dirname "$C/repo/$f")"; echo added > "$C/repo/$f"; git -C "$C/repo" add -N "$f"; done
  git -C "$C/repo" diff > "$C/fix.patch"
  git -C "$C/repo" reset -q; git -C "$C/repo" checkout -q -- .; git -C "$C/repo" clean -qfd
}
# patch_mv <from> <to> -- the implementer's patch is a plain move, which git writes as a rename
patch_mv() {
  mkdir -p "$(dirname "$C/repo/$2")"; git -C "$C/repo" mv "$1" "$2"
  git -C "$C/repo" diff --cached > "$C/fix.patch"; git -C "$C/repo" reset -q --hard
}
# occupy_fix_branch [content]... -- someone else's commits on top of $SHA, one per content
# of pkg/lib/a.dart (default: one, "theirs"), already on origin's fix branch
occupy_fix_branch() {
  git -C "$C/repo" checkout -q -b other
  for c in "${@:-theirs}"; do echo "$c" > "$C/repo/pkg/lib/a.dart"; git -C "$C/repo" commit -qam "$c"; done
  git -C "$C/repo" push -q origin other:refs/heads/$FB
  git -C "$C/repo" checkout -q main; git -C "$C/repo" branch -qD other
}
run() {  # run [sha] -- autofix.sh for PR #7 against this case; sets rc, captures stdout/stderr
  rc=0
  ( cd "$C/repo" && "$HERE/autofix.sh" 7 "${1:-$SHA}" "$C/repo" "$C/out" ) >"$C/stdout" 2>"$C/stderr" || rc=$?
}
# rerun [sha] -- run, committing at another time. Two runs in the same second build
# byte-identical commits, so a "resumed" push would be a no-op and pass without the resume.
rerun() { GIT_AUTHOR_DATE=2001-01-01T00:00:00Z GIT_COMMITTER_DATE=2001-01-01T00:00:00Z run "$@"; }
rc_is()   { [ "$rc" = "$1" ]; }
said()    { grep -qxF -- "$1" "$C/stdout"; }                 # an exact STATUS=/REVIEWER= line
logged()  { [ -f "$C/log/$1" ] && grep -qF -- "$2" "$C/log/$1"; }
never()   { ! logged "$@"; }
calls()   { if [ -f "$C/log/$1" ]; then wc -l < "$C/log/$1" | tr -d ' '; else echo 0; fi; }
pushed()  { git --git-dir="$C/remotes/acme/widgets.git" rev-parse -q --verify refs/heads/$FB; }
unpushed() { ! pushed; }
no_headings() { ! grep -q '^#' "$C/log/body"; }
pushed_file_is() { [ "$(git --git-dir="$C/remotes/acme/widgets.git" show $FB:pkg/lib/a.dart)" = "$1" ]; }
pushed_has()   { git --git-dir="$C/remotes/acme/widgets.git" cat-file -e "$FB:$1"; }
remote_tip()   { git --git-dir="$C/remotes/acme/widgets.git" rev-parse $FB; }
commit_msg()   { git --git-dir="$C/remotes/acme/widgets.git" log -1 --format=%B $FB; }
subject_is()   { [ "$(commit_msg | head -n 1)" = "$1" ]; }
commit_lacks() { ! commit_msg | grep -qiF -- "$1"; }
no_local_branch() { ! git -C "$C/repo" rev-parse -q --verify refs/heads/$FB; }
# arg <flag> -- the value claude was given for <flag>
arg()     { grep -A1 -xF -- "$1" "$C/log/claude.args" | sed -n 2p; }
has_arg() { grep -qxF -- "$1" "$C/log/claude.args"; }
refs()    { git -C "$C/repo" for-each-ref --format='%(refname) %(objectname)' refs/heads refs/tags refs/stash; }   # local refs, not origin's mirror
refs_untouched() { [ "$(refs)" = "$REFS_BEFORE" ]; }
impl_gone() { [ ! -e "$(cat "$C/log/claude.cwd")" ]; }
ran_in_own_tree() { case "$(cat "$C/log/claude.cwd")" in "$C/repo"|"$C/repo"/*) return 1 ;; esac; }
only_tested_in() { [ -s "$C/log/dart.cwd" ] && ! grep -qv -- "$1\$" "$C/log/dart.cwd"; }
pushed_lacks() { ! git --git-dir="$C/remotes/acme/widgets.git" cat-file -e "$FB:$1"; }
URL=https://github.com/acme/widgets/pull/99

echo "default path (what watch.sh runs)"
setup; run
check "exits 0"                                rc_is 0
check "reports the opened PR"                  said "STATUS=opened:$URL"
check "implements via claude once"                [ "$(calls claude)" = 1 ]
check "pushes the fix branch"                  pushed
check "pushed tree carries the fix"            pushed_file_is new
check "opens against the reviewed head branch" logged gh "--base feature-x --head $FB"
check "no reviewer request without AUTOFIX_REVIEWER" never gh "pr edit"
check "freezes nothing"                        [ ! -e "$FROZEN" ]
check "task carries the CONFIRMED finding"     logged task.md "Old value leaks past the reset"
check "task omits the UNVERIFIABLE finding"    never task.md "Possibly racy"
check "body leads with the bolded claim"       logged body "**Old value leaks past the reset**"
check "body explains the mechanism"            logged body "reset() returns before clearing the cache"
check "body omits the UNVERIFIABLE finding"    never body "Possibly racy"
check "body has no headings"                   no_headings
check "body has no Claude Code footer"         never body "Generated with"
check "commit subject is the PR title"         subject_is "fix: review findings from #7"
check "commit carries no finding text"         commit_lacks "Old value leaks"
check "commit has no AI co-author"             commit_lacks co-authored
check "commits only the patch, not pub get's lockfile" pushed_lacks pkg/pubspec.lock
check "  nor .dart_tool/"                       pushed_lacks pkg/.dart_tool/cache
check "leaves no fix branch in your clone"     no_local_branch
check "relays the implementer"                 said "IMPLEMENTER=claude-opus-5-5"
check "implements in a tree of its own"        ran_in_own_tree
check "  at the reviewed SHA"                  [ "$(cat "$C/log/claude.head")" = "$SHA" ]
check "  and removes it"                       impl_gone
check "defaults to claude-opus-5-5"            [ "$(arg --model)" = claude-opus-5-5 ]
check "  at high effort"                       [ "$(arg --effort)" = high ]
check "  under the \$8 runaway guard"           [ "$(arg --max-budget-usd)" = 8.00 ]
check "accepts edits, unattended"              [ "$(arg --permission-mode)" = acceptEdits ]
check "  keeps your settings and MCP out"      has_arg --strict-mcp-config
check "  may run dart test"                    has_arg "Bash(dart test:*)"
check "  and pub get"                          has_arg "Bash(dart pub get:*)"
check "  but not all of dart"                  sh -c "! grep -qxF 'Bash(dart:*)' '$C/log/claude.args'"
check "  in a clone with no remote to push to" [ ! -s "$C/log/claude.remotes" ]
check "  but no other shell"                   sh -c "! grep -qxE 'Bash|Bash\\((git|\\*).*' '$C/log/claude.args'"
check "prompt says it runs unattended"         logged task.md "unattended"

setup; export AUTOFIX_MODEL=claude-sonnet-5-5 AUTOFIX_EFFORT=medium AUTOFIX_BUDGET=4; run
check "AUTOFIX_MODEL picks the model"          [ "$(arg --model)" = claude-sonnet-5-5 ]
check "  and is what it relays"                said "IMPLEMENTER=claude-sonnet-5-5"
check "AUTOFIX_EFFORT picks the effort"        [ "$(arg --effort)" = medium ]
check "AUTOFIX_BUDGET caps the spend"          [ "$(arg --max-budget-usd)" = 4 ]
setup; printf 'AUTOFIX_MODEL=claude-haiku-5-5\n' > "$SB/config.env"; chmod 600 "$SB/config.env"; REVIEW_SKILLS_CONFIG="$SB/config.env" run
check "AUTOFIX_MODEL can come from the config file"              [ "$(arg --model)" = claude-haiku-5-5 ]

setup; export AUTOFIX_BUDGET=none; run
check "AUTOFIX_BUDGET=none uncaps it"          sh -c "! grep -qxF -- --max-budget-usd '$C/log/claude.args'"

setup; mkdir -p "$SB/alt"; cp "$SB/bin/claude" "$SB/alt/my-claude"; export AUTOFIX_CLAUDE="$SB/alt/my-claude"; run
check "AUTOFIX_CLAUDE swaps the implementer"   said "STATUS=opened:$URL"

echo "implementer"
setup; export STUB_CLAUDE_RC=1; run
check "claude fails: exits 1"                  rc_is 1
check "  never pushes"                         unpushed
check "  never opens a PR"                     never gh "pr create"

setup; export STUB_IS_ERROR=true STUB_SUBTYPE=error_max_budget_usd; run
check "claude exits 0 but reports an error: exits 1" rc_is 1
check "  even with a patch on disk"            unpushed
check "  says why"                             grep -qF error_max_budget_usd "$C/stderr"

setup; export STUB_NOOP=1; run
check "claude changes nothing: exits 1"        rc_is 1
check "  says it made no change"               grep -qi "no change" "$C/stderr"
check "  before the gate"                      [ "$(calls dart)" = 0 ]

setup; export STUB_COMMIT=1; run
check "claude commits its work: still the patch" said "STATUS=opened:$URL"
check "  carrying the fix"                     pushed_file_is new
check "  and its refs never reach your clone"  refs_untouched

setup; SAVED_PATH="$PATH"; mkdir -p "$SB/noclaude"; for b in gh dart; do ln -sf "$SB/bin/$b" "$SB/noclaude/$b"; done
PATH="$SB/noclaude:/usr/bin:/bin"; run; PATH="$SAVED_PATH"
check "no claude on PATH: refused"             rc_is 1
check "  says why"                             grep -qi claude "$C/stderr"
check "  before any work"                      [ ! -e "$C/log/dart" ]

setup; export STUB_PRVIEW="$(prview false deadbeef)"; run
check "head moved since the review: reports stale" said "STATUS=stale"
check "  exits 1"                              rc_is 1
check "  before claude"                           [ "$(calls claude)" = 0 ]
check "  never pushes"                         unpushed

echo "nothing to do"
setup; rm "$C/out/merged.json" "$C/out/meta.json"; run
check "no review record (the review found nothing): exits 0" rc_is 0
check "  reports none"                         said "STATUS=none"
check "  never calls claude"                      [ "$(calls claude)" = 0 ]

setup; printf '{"headRefOid":"0ld0000000000000000000000000000000000000"}' > "$C/out/meta.json"; run
check "record is an earlier review's, of another head: exits 0" rc_is 0
check "  reports none"                         said "STATUS=none"
check "  never re-files its findings"          [ "$(calls claude)" = 0 ]
check "  never pushes"                         unpushed

setup; printf '[{"id":"x","file":"f","line":1,"claim":"c","mechanism":"m","repro":"r","v":{"verdict":"REFUTED"}}]' > "$C/out/merged.json"; run
check "no CONFIRMED finding: exits 0"          rc_is 0
check "  reports none"                         said "STATUS=none"
check "  never calls claude"                      [ "$(calls claude)" = 0 ]

setup; export STUB_EXISTING="$(prlist 50:OPEN)"; run
check "fix PR open: exits 0"                   rc_is 0
check "  reports its URL"                      said "STATUS=exists:https://github.com/acme/widgets/pull/50"
check "  never calls claude"                      [ "$(calls claude)" = 0 ]
check "  never pushes"                         unpushed

setup; export STUB_EXISTING="$(prlist 50:CLOSED)"; run
check "fix PR closed unmerged: exists, a human said no" said "STATUS=exists:https://github.com/acme/widgets/pull/50"
check "  never calls claude"                   [ "$(calls claude)" = 0 ]

setup; export STUB_EXISTING="$(prlist 50:MERGED)"; run
check "fix PR for this head merged: exists"    said "STATUS=exists:https://github.com/acme/widgets/pull/50"

echo "fix PRs for earlier heads"
setup; run
check "looks only at this head's fix branch"   logged gh "--head fix/pr7-review-findings-${SHA:0:12} "

setup; git -C "$C/repo" push -q origin "$SHA:refs/heads/fix/pr7-review-findings-0123456789ab"; run
check "an earlier head's fix branch on origin: opens another" said "STATUS=opened:$URL"
check "  on this head's branch"                pushed_file_is new
check "  leaving the earlier one alone"        [ "$(git --git-dir="$C/remotes/acme/widgets.git" rev-parse fix/pr7-review-findings-0123456789ab)" = "$SHA" ]

echo "guards"
setup; export STUB_PRVIEW="$(prview true "$SHA")"; run
check "fork PR: refused"                       rc_is 1
check "  says why"                             grep -qi fork "$C/stderr"
check "  before claude"                           [ "$(calls claude)" = 0 ]
check "  never pushes"                         unpushed

setup; export STUB_REPO=acme/other; run
check "origin is not the PR's repo: refused"   rc_is 1
check "  says why"                             grep -qi origin "$C/stderr"
check "  before claude"                           [ "$(calls claude)" = 0 ]

setup; export STUB_PRVIEW="$(prview false "$SHA" MERGED)"; run
check "PR no longer open: refused"             rc_is 1
check "  says why"                             grep -qF MERGED "$C/stderr"
check "  before claude"                           [ "$(calls claude)" = 0 ]

setup; git clone -q --bare "$C/repo" "$C/remotes/acme/elsewhere.git"
git -C "$C/repo" remote set-url --push origin "$C/remotes/acme/elsewhere.git"; run
check "origin pushes to another repo: refused" rc_is 1
check "  before claude"                           [ "$(calls claude)" = 0 ]
check "  nothing pushed there"                 sh -c "! git --git-dir='$C/remotes/acme/elsewhere.git' rev-parse -q --verify $FB"

setup; mkdir -p "$SB/nodart"; for b in gh claude; do ln -sf "$SB/bin/$b" "$SB/nodart/$b"; done
SAVED_PATH="$PATH"; PATH="$SB/nodart:/usr/bin:/bin"; run; PATH="$SAVED_PATH"
check "no dart on PATH: refused"               rc_is 1
check "  says why"                             grep -qi dart "$C/stderr"
check "  before claude"                           [ "$(calls claude)" = 0 ]

echo "test gate"
setup; export STUB_DART_RC=1; run
check "red tests: exits 1"                     rc_is 1
check "  never pushes"                         unpushed
check "  never opens a PR"                     never gh "pr create"

setup; patch --no-fix pkg/lib/b.dart; run
check "patch only adds a file: still gated"    logged dart test
check "  and opened"                           said "STATUS=opened:$URL"
check "  with the new file"                    pushed_has pkg/lib/b.dart

setup; patch aa.txt; run
check "a file outside any package (first): refused" rc_is 1
check "  names it"                             grep -qF aa.txt "$C/stderr"
check "  never pushes"                         unpushed

setup; patch zz.txt; run
check "a file outside any package (last): refused" rc_is 1
check "  names it"                             grep -qF zz.txt "$C/stderr"

setup workspace; patch .github/workflows/ci.yaml; run
check "CI config, even under a root pubspec: refused" rc_is 1
check "  names it"                             grep -qF .github/workflows/ci.yaml "$C/stderr"
check "  never pushes"                         unpushed

setup workspace; patch docs/x.md features/y.feature; run
check "docs beside a fix in a workspace: opened" said "STATUS=opened:$URL"
check "  gates only the package with tests"     only_tested_in /pkg
check "  never runs dart test at the root"      [ "$(grep -c . "$C/log/dart.cwd")" = 1 ]

setup workspace; patch --no-fix docs/x.md; run
check "a docs-only patch: opened"              said "STATUS=opened:$URL"
check "  runs no tests"                        never dart test
check "  says nothing was tested"              grep -qF "no Dart package touched" "$C/stderr"

setup workspace; mkdir -p "$C/repo/test"; echo x > "$C/repo/test/local"; patch docs/x.md; run
check "a root test/ only in your clone: root not gated" only_tested_in /pkg

setup workspace; patch tool/x.dart; run
check "Dart outside any tested package: refused" rc_is 1
check "  names it"                             grep -qF tool/x.dart "$C/stderr"
check "  never pushes"                         unpushed

setup workspace; patch analysis_options.yaml; run
check "workspace-wide config: refused"         rc_is 1
check "  names it"                             grep -qF analysis_options.yaml "$C/stderr"

setup workspace; patch pubspec.yaml; run
check "the workspace pubspec: refused"         rc_is 1

setup twopkg; patch_mv pkg/lib/a.dart pkg2/lib/a.dart; run
check "a file moved between packages: both gated" [ "$(grep -c '^test' "$C/log/dart")" = 2 ]

setup workspace ci; patch_mv .github/workflows/ci.yaml tool/ci.yaml; run
check "CI config moved out by a rename: refused" rc_is 1
check "  names the source"                     grep -qF .github/workflows/ci.yaml "$C/stderr"
check "  never pushes"                         unpushed

setup twopkg; patch pkg2/lib/b.dart; export STUB_DART_STDIN=1; run
check "a test that reads stdin: every package still gated" [ "$(grep -c '^test' "$C/log/dart")" = 2 ]

echo "live-rig packs"
setup live; patch --no-fix tests/live/test/b_test.dart; run
check "a patch in tests/: opened"              said "STATUS=opened:$URL"
check "  analyzed there"                       grep -qF /tests/live "$C/log/analyze.cwd"
check "  at --fatal-infos"                     logged dart "analyze --fatal-infos"
check "  never tested there"                   never dart test
check "  the body names it"                    logged body '`tests/live`'

setup live; patch tests/live/test/b_test.dart; run
check "a fix beside a tests/ change: package tested" only_tested_in /pkg
check "  the pack analyzed"                    [ "$(grep -c . "$C/log/analyze.cwd")" = 1 ]

setup live; patch --no-fix tests/live/test/b_test.dart; export STUB_ANALYZE_RC=1; run
check "analyze fails in tests/: exits 1"       rc_is 1
check "  never pushes"                         unpushed
check "  never opens a PR"                     never gh "pr create"

setup live; patch --no-fix tests/live/test/b_test.dart; export AUTOFIX_ANALYZE_ONLY=""; run
check "AUTOFIX_ANALYZE_ONLY empty: tests/ is tested" only_tested_in /tests/live
check "  never only analyzed"                  [ ! -e "$C/log/analyze.cwd" ]
check "  body claims no analyze-only gate"     never body "analyze"

setup live twopkg; patch --no-fix pkg2/lib/b.dart; export AUTOFIX_ANALYZE_ONLY="pkg2 nomatch/*"; run
check "AUTOFIX_ANALYZE_ONLY names its own packages" grep -qF /pkg2 "$C/log/analyze.cwd"
check "  never tested there"                   never dart test

setup; run
check "prompt names the analyze-only packages" logged task.md "tests/*"
setup; export AUTOFIX_ANALYZE_ONLY=""; run
check "  and none when it's empty"             never task.md "dart analyze"

echo "prepare"
setup; export AUTOFIX_MODE=prepare AUTOFIX_FROZEN="$FROZEN"; run
check "exits 0"                                rc_is 0
check "reports prepared"                       said "STATUS=prepared"
check "freezes the patch"                      cmp -s "$FROZEN/fix.patch" "$C/fix.patch"
check "freezes the reviewed SHA"               [ "$(cat "$FROZEN/sha")" = "$SHA" ]
check "freezes the title"                      [ -s "$FROZEN/title" ]
check "freezes the body"                       grep -qF "**Old value leaks past the reset**" "$FROZEN/body.md"
check "runs the test gate"                     logged dart test
check "never pushes"                           unpushed
check "never opens a PR"                       never gh "pr create"

setup; export AUTOFIX_MODE=prepare AUTOFIX_FROZEN="$FROZEN" STUB_PRVIEW="$(prview false deadbeef)"; run
check "head moved since the review: refused"   rc_is 1
check "  reports stale"                        said "STATUS=stale"
check "  before claude"                           [ "$(calls claude)" = 0 ]

setup; export AUTOFIX_MODE=prepare AUTOFIX_FROZEN="$FROZEN" AUTOFIX_MODEL=claude-sonnet-5-5; run
check "relays the implementer"                 said "IMPLEMENTER=claude-sonnet-5-5"
check "  freezes it for ship"                  [ "$(cat "$FROZEN/model")" = claude-sonnet-5-5 ]

echo "ship"
setup; export AUTOFIX_MODE=prepare AUTOFIX_FROZEN="$FROZEN" AUTOFIX_MODEL=claude-sonnet-5-5; run
{ printf '\nEDITED BEFORE SHIPPING\n' >> "$FROZEN/body.md"; } 2>/dev/null || true   # what you approve is what posts
export AUTOFIX_MODE=ship AUTOFIX_MODEL=claude-opus-5-5 STUB_CLAUDE_RC=99; run
check "exits 0"                                rc_is 0
check "reports the opened PR"                  said "STATUS=opened:$URL"
check "never re-runs claude"                   [ "$(calls claude)" = 1 ]
check "relays the frozen implementer, not the env's" said "IMPLEMENTER=claude-sonnet-5-5"
check "re-runs the test gate"                  [ "$(grep -c '^test' "$C/log/dart")" = 2 ]
check "pushes the frozen patch"                pushed_file_is new
check "posts the frozen title"                 cmp -s "$C/log/title" "$FROZEN/title"
check "posts the frozen body as edited"        logged body "EDITED BEFORE SHIPPING"

check "commit subject is the frozen title"     subject_is "$(cat "$FROZEN/title")"

setup; export AUTOFIX_MODE=prepare AUTOFIX_FROZEN="$FROZEN"; run
printf 'fix: tidy the reset path' > "$FROZEN/title"; rm "$C/out/merged.json" "$C/out/meta.json"
export AUTOFIX_MODE=ship; run
check "review record gone since prepare: ships the frozen files" said "STATUS=opened:$URL"
check "  commit subject is the edited title"   subject_is "fix: tidy the reset path"
check "  commit carries no finding text"       commit_lacks "Old value leaks"

setup; export AUTOFIX_MODE=prepare AUTOFIX_FROZEN="$FROZEN"; run
export AUTOFIX_MODE=ship STUB_PRVIEW="$(prview false deadbeef)"; run
check "head moved since prepare: refused"      rc_is 1
check "  reports stale"                        said "STATUS=stale"
check "  never pushes"                         unpushed

setup; export AUTOFIX_MODE=prepare AUTOFIX_FROZEN="$FROZEN"; run
export AUTOFIX_MODE=ship STUB_EXISTING="$(prlist 51:OPEN)"; run
check "fix PR appeared since prepare: not opened again" said "STATUS=exists:https://github.com/acme/widgets/pull/51"
check "  never pushes"                         unpushed

setup; export AUTOFIX_MODE=prepare AUTOFIX_FROZEN="$FROZEN"; run
export AUTOFIX_MODE=ship; run 0000000000000000000000000000000000000000
check "SHA argument differs from the frozen one: refused" rc_is 1
check "  never pushes"                         unpushed

setup; export AUTOFIX_MODE=prepare AUTOFIX_FROZEN="$FROZEN"; run
printf ' \n' > "$FROZEN/title"; export AUTOFIX_MODE=ship; run
check "a blank frozen title: refused"          rc_is 1
check "  before anything is pushed"            unpushed
check "  never opens a PR"                     never gh "pr create"

setup; export AUTOFIX_MODE=ship AUTOFIX_FROZEN="$FROZEN"; run
check "nothing prepared: refused"              rc_is 1
check "  never pushes"                         unpushed

setup; export AUTOFIX_MODE=ship; run
check "a mode without AUTOFIX_FROZEN: refused" rc_is 1

echo "resuming and refusing"
setup; export AUTOFIX_MODE=prepare AUTOFIX_FROZEN="$FROZEN"; run
export AUTOFIX_MODE=ship STUB_CREATE_RC=1; run
check "pr create fails after the push: exits 1" rc_is 1
check "  the branch is on origin"              pushed
check "  no PR reported"                       sh -c "! grep -q '^STATUS=opened' '$C/stdout'"
check "  says to ship again"                   grep -qF "ship again" "$C/stderr"
TIP="$(remote_tip)"; export STUB_CREATE_RC=0; rerun
check "ship again: opens the PR"               said "STATUS=opened:$URL"
check "  on the branch already pushed"         [ "$(remote_tip)" = "$TIP" ]
check "  still one commit on the reviewed head" [ "$(git --git-dir="$C/remotes/acme/widgets.git" rev-parse $FB~1)" = "$SHA" ]

setup; git clone -q --bare "$C/repo" "$C/mirror.git"
git -C "$C/repo" remote set-url origin "$C/mirror.git"
git -C "$C/repo" remote set-url --push origin "$C/remotes/acme/widgets.git"
export AUTOFIX_MODE=prepare AUTOFIX_FROZEN="$FROZEN"; run
export AUTOFIX_MODE=ship STUB_CREATE_RC=1; run; TIP="$(remote_tip)"
export STUB_CREATE_RC=0; rerun
check "origin fetches from a mirror: ship again still resumes" said "STATUS=opened:$URL"
check "  on the branch already pushed"         [ "$(remote_tip)" = "$TIP" ]

setup; export STUB_CREATE_RC=1; run
check "pr create fails on the default path: exits 1" rc_is 1
check "  says how to clear the branch, since a re-run re-implements" grep -qF -- "--delete $FB" "$C/stderr"

setup; occupy_fix_branch; TIP="$(remote_tip)"; run
check "fix branch on origin holds other work: refused" rc_is 1
check "  says how to clear it"                 grep -qF -- "--delete $FB" "$C/stderr"
check "  never overwrites it"                  [ "$(remote_tip)" = "$TIP" ]
check "  never opens a PR"                     never gh "pr create"

setup; occupy_fix_branch half new; run
check "fix branch holds this fix's tree on another parent: refused" rc_is 1
check "  never opens a PR"                     never gh "pr create"

setup; git -C "$C/repo" config push.followTags true; git -C "$C/repo" tag -a v9-internal -m internal "$SHA"; run
check "push.followTags on: still opens"        said "STATUS=opened:$URL"
check "  pushes no local tag"                  [ -z "$(git --git-dir="$C/remotes/acme/widgets.git" tag)" ]

echo "public text"
setup; jq '.[0].claim = "Missing @override on reset, cc @alice, _@dave_ and a@b.com" | .[0].mechanism = "see @acme/core"' \
  "$C/out/merged.json" > "$C/m" && mv "$C/m" "$C/out/merged.json"; run
check "an @-word in a claim pings no one"      never body "@override"
check "  nor a handle"                         never body "@alice"
check "  nor one in underscore emphasis"       never body "@dave"
check "  nor a team in the mechanism"          never body "@acme/core"
check "  the words survive"                    logged body "override on reset"
check "  an email address is left alone"       logged body "a@b.com"

echo "reviewer request"
setup; export AUTOFIX_REVIEWER=alice; run
check "requests the author on the new PR"      logged gh "pr edit $URL --add-reviewer alice"
check "  reports it"                           said "REVIEWER=requested:alice"

setup; export AUTOFIX_REVIEWER=alice STUB_EDIT_RC=1; run
check "request fails: still exits 0"           rc_is 0
check "  the PR is still reported"             said "STATUS=opened:$URL"
check "  the failure is reported"              said "REVIEWER=failed:alice"

setup; export AUTOFIX_REVIEWER=me STUB_ME=Me; run
check "author is you (any case): skipped"      never gh "pr edit"
check "  reports it"                           said "REVIEWER=skipped:me"

setup; export AUTOFIX_REVIEWER=app/dependabot; run
check "author is a bot: skipped"               never gh "pr edit"
check "  reports it"                           said "REVIEWER=skipped:app/dependabot"

setup; export AUTOFIX_REVIEWER=alice STUB_EXISTING="$(prlist 50:OPEN)"; run
check "no PR opened: no request"               never gh "pr edit"

[ "$fail" = 0 ] && echo "all passed" || { echo "FAILURES"; exit 1; }
