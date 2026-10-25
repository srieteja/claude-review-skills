#!/usr/bin/env bash
# route -- labels each finding introduced or pre-existing from the PR's diff alone. No
# network, no models, no repo: a diff and a merged.json in, the same array with .route out.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SB="$(mktemp -d "${TMPDIR:-/tmp}/route-test.XXXXXX")"
trap 'rm -rf "$SB"' EXIT
fail=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=1; }
check() { desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }

# lib/a.dart: lines 10-12 added at the head. lib/src/b.dart and test/src/b.dart: one added
# line each, so the basename b.dart is ambiguous. lib/old.dart -> lib/new.dart: renamed, line 5
# added under the new name. lib/gone.dart: deleted.
cat > "$SB/pr.diff" <<'DIFF'
diff --git a/lib/a.dart b/lib/a.dart
index 1111111..2222222 100644
--- a/lib/a.dart
+++ b/lib/a.dart
@@ -8,4 +8,7 @@ class A {
 one
 two
+added ten
+added eleven
+added twelve
-removed
 three
--- not a header: a removed line that starts with "-- "
diff --git a/lib/src/b.dart b/lib/src/b.dart
--- a/lib/src/b.dart
+++ b/lib/src/b.dart
@@ -1,2 +1,3 @@
 x
+b in lib
 y
diff --git a/test/src/b.dart b/test/src/b.dart
--- a/test/src/b.dart
+++ b/test/src/b.dart
@@ -3,1 +3,2 @@
 z
+b in test
\ No newline at end of file
diff --git a/lib/old.dart b/lib/new.dart
similarity index 90%
rename from lib/old.dart
rename to lib/new.dart
--- a/lib/old.dart
+++ b/lib/new.dart
@@ -4,2 +4,3 @@
 keep
+renamed and added
 keep
diff --git a/lib/gone.dart b/lib/gone.dart
deleted file mode 100644
--- a/lib/gone.dart
+++ /dev/null
@@ -1,1 +0,0 @@
-bye
DIFF

# finding <id> <file> <line> <mechanism>
finding() { jq -n --arg id "$1" --arg f "$2" --argjson l "$3" --arg m "$4" \
  '{id:$id, file:$f, line:$l, claim:"c", mechanism:$m, repro:"r", v:{verdict:"CONFIRMED"}}'; }
{
  finding on-added       lib/a.dart 11 "nothing cited"
  finding unchanged      lib/a.dart 9  "a caller elsewhere"
  finding cites-full     lib/c.dart 40 "lib/c.dart:40 is reached from lib/a.dart:12, which now passes null"
  finding cites-base     lib/c.dart 40 "reached via a.dart:10"
  finding cites-range    lib/c.dart 40 "the job at a.dart:5-10 restarts"
  finding range-misses   lib/c.dart 40 "the job at a.dart:1-9 and a.dart:13-20 restarts"
  finding ambiguous      lib/c.dart 40 "b.dart:4 now returns early"
  finding cites-old      lib/c.dart 40 "see b.dart:1 and lib/c.dart:41"
  finding renamed        lib/new.dart 5 "n/a"
  finding deleted        lib/gone.dart 1 "n/a"
  finding not-in-diff    lib/c.dart 40 "only lib/c.dart:40-44 and pubspec.yaml:3"
  jq -n '{id:"no-line", file:"lib/a.dart", claim:"c", mechanism:"m", v:{verdict:"CONFIRMED"}}'
} | jq -s . > "$SB/merged.json"

"$HERE/route" --diff "$SB/pr.diff" "$SB/merged.json" > "$SB/out.json"; rc=$?
route_of() { jq -r --arg id "$1" '.[] | select(.id == $id) | .route' "$SB/out.json"; }
fails() { ! "$@"; }
is() { [ "$(route_of "$1")" = "$2" ]; }

check "exits 0"                                          [ "$rc" = 0 ]
check "keeps every finding, in order"                    [ "$(jq -c 'map(.id)' "$SB/out.json")" = "$(jq -c 'map(.id)' "$SB/merged.json")" ]
check "keeps every other field"                          [ "$(jq -c 'map(del(.route))' "$SB/out.json")" = "$(jq -c . "$SB/merged.json")" ]
check "cited line on an added line: introduced"          is on-added introduced
check "cited line unchanged, nothing cited: pre-existing" is unchanged pre-existing
check "mechanism cites an added line by path: introduced" is cites-full introduced
check "  by basename: introduced"                        is cites-base introduced
check "a cited range overlapping added lines: introduced" is cites-range introduced
check "ranges around the added lines: pre-existing"      is range-misses pre-existing
check "an ambiguous basename: introduced if either file has it" is ambiguous introduced
check "cites only unchanged lines: pre-existing"         is cites-old pre-existing
check "a renamed file: the head path counts"             is renamed introduced
check "a deleted file: pre-existing"                     is deleted pre-existing
check "a file the diff never touches: pre-existing"      is not-in-diff pre-existing
check "no line and no cites: introduced, today's lane"   is no-line introduced

# The real #2898: its one CONFIRMED finding sits in the test the PR added.
finding anthropic.t01-F1 tests/at_functional_test/test/certs_reload_test.dart 258 \
  "softRestart() (certs_reload_test.dart:251-267) only waits for info:brief" | jq -s . > "$SB/2898.json"
"$HERE/route" --diff "$HERE/fixtures/route-2898.diff" "$SB/2898.json" > "$SB/out.json"
check "#2898's finding: introduced"                      is anthropic.t01-F1 introduced

printf '[]' > "$SB/empty.json"
check "no findings: []"                                  [ "$("$HERE/route" --diff "$SB/pr.diff" "$SB/empty.json")" = "[]" ]
check "a missing diff: exits non-zero"                   fails "$HERE/route" --diff "$SB/nope.diff" "$SB/empty.json"

[ "$fail" = 0 ] && echo "all passed" || echo FAILURES
exit "$fail"
