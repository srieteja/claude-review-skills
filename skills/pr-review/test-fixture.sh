# shellcheck shell=bash
# Sourced by the offline tests. fixture_repo <dir> builds a local stand-in for a GitHub repo,
# acme/widgets, and a gh stub that serves its PRs -- no network, no real repo:
#
#   <dir>/origin   bare remote, trunk plus refs/pull/<N>/head
#   <dir>/work     clone of it, cwd for the run under test (FIXTURE_ROOT)
#   <dir>/gh/gh    the stub; put <dir>/gh on PATH
#
#   PR 7  alice   feature: three lib/src files, the package barrel, pubspec.yaml, one test
#   PR 8  bob     test-only: an e2e package under tests/ and a workflow file
#
# The gh stub answers `pr view <N> --json ... [-q|--jq <expr>]`, `pr diff <N>`,
# `repo view --json nameWithOwner [-q ...]` and `api user [-q ...]`, logging every call to
# $FIXTURE_GH_LOG when set. FIXTURE_ME is the login `api user` returns (default reviewer).

fixture_lines() {
  i=0
  while [ "$i" -lt "$2" ]; do
    printf '  // %s line %s: padding so each file is a slice of its own\n' "$1" "$i"
    i=$((i + 1))
  done
}

fixture_commit() { git -C "$1" add -A && git -C "$1" -c user.name=t -c user.email=t@t commit -qm "$2"; }

fixture_repo() {
  d="$1"; mkdir -p "$d/src" "$d/gh"
  git init -q -b trunk "$d/src"
  s="$d/src/packages/widgets"; mkdir -p "$s/lib/src" "$s/test"
  printf 'name: widgets\nversion: 1.0.0\n' > "$s/pubspec.yaml"
  printf "library widgets;\nexport 'src/alpha.dart';\n" > "$s/lib/widgets.dart"
  for f in alpha beta gamma; do printf 'int %s() => 1;\n' "$f" > "$s/lib/src/$f.dart"; done
  printf "void main() {}\n" > "$s/test/alpha_test.dart"
  fixture_commit "$d/src" base

  git -C "$d/src" checkout -qb pr7
  printf 'name: widgets\nversion: 1.1.0\n' > "$s/pubspec.yaml"
  printf "library widgets;\nexport 'src/alpha.dart';\nexport 'src/beta.dart';\n" > "$s/lib/widgets.dart"
  for f in alpha beta gamma; do
    { printf 'int %s() {\n' "$f"; fixture_lines "$f" 30; printf '  return 2;\n}\n'; } > "$s/lib/src/$f.dart"
  done
  { printf 'void main() {\n'; fixture_lines alpha_test 10; printf '}\n'; } > "$s/test/alpha_test.dart"
  fixture_commit "$d/src" "widgets 1.1"

  git -C "$d/src" checkout -q trunk && git -C "$d/src" checkout -qb pr8
  e="$d/src/tests/at_end2end_test"; mkdir -p "$e/lib" "$e/test" "$d/src/.github/workflows"
  { printf 'void e2e() {\n'; fixture_lines e2e 10; printf '}\n'; } > "$e/lib/e2e.dart"
  { printf 'void main() {\n'; fixture_lines e2e_test 10; printf '}\n'; } > "$e/test/e2e_test.dart"
  printf 'on: push\njobs: {}\n' > "$d/src/.github/workflows/e2e.yaml"
  fixture_commit "$d/src" "e2e tests"

  git clone -q --bare "$d/src" "$d/origin"
  for n in 7 8; do git -C "$d/origin" update-ref "refs/pull/$n/head" "refs/heads/pr$n"; done
  git clone -q "$d/origin" "$d/work"
  FIXTURE_ROOT="$(git -C "$d/work" rev-parse --show-toplevel)"

  fixture_meta 7 alice "widgets 1.1" > "$d/gh/pr7.json"
  fixture_meta 8 bob "e2e tests" > "$d/gh/pr8.json"
  cat > "$d/gh/gh" <<'STUB'
#!/usr/bin/env bash
[ -z "${FIXTURE_GH_LOG:-}" ] || printf '%s\n' "$*" >> "$FIXTURE_GH_LOG"
dir="$(cd "$(dirname "$0")" && pwd)"
q=""; prev=""
for a in "$@"; do case "$prev" in -q|--jq) q="$a" ;; esac; prev="$a"; done
out() { if [ -n "$q" ]; then jq -r "$q"; else cat; fi; }
case "$1 $2" in
  "pr view")   [ -f "$dir/pr$3.json" ] || { echo "no pull requests found for $3" >&2; exit 1; }
               out < "$dir/pr$3.json" ;;
  "pr diff")   git diff "origin/trunk...refs/remotes/origin/pr$3" ;;
  "repo view") echo '{"nameWithOwner":"acme/widgets","name":"widgets"}' | out ;;
  "api user")  printf '{"login":"%s"}\n' "${FIXTURE_ME:-reviewer}" | out ;;
  *)           echo "gh stub: unhandled: $*" >&2; exit 64 ;;
esac
STUB
  chmod +x "$d/gh/gh"
}

fixture_meta() {
  w="$FIXTURE_ROOT"; ref="refs/remotes/origin/pr$1"
  stat="$(git -C "$w" diff --numstat "origin/trunk...$ref" | awk '{f++; a+=$1; d+=$2} END{print f+0, a+0, d+0}')"
  set -- "$1" "$2" "$3" $stat
  jq -n --argjson n "$1" --arg who "$2" --arg title "$3" \
        --arg sha "$(git -C "$w" rev-parse "$ref")" \
        --argjson f "$4" --argjson a "$5" --argjson del "$6" '
    {number:$n, title:$title, url:"https://github.com/acme/widgets/pull/\($n)",
     author:{login:$who, is_bot:false}, headRefOid:$sha, baseRefName:"trunk", state:"OPEN",
     isCrossRepository:false, changedFiles:$f, additions:$a, deletions:$del, body:"fixture PR"}'
}
