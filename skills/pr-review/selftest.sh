#!/usr/bin/env bash
# Does the refutation stage still discriminate?
#
# Runs three claims against a known tree: one true, one citing a nonexistent file, one
# inventing a mechanism on a real file at a real line. The last is the one that matters —
# a validator that pattern-matches plausible claims confirms it; one that reads the source
# refutes it. If this test stops failing the fakes, stage 2 is theater and every report
# the pipeline has produced since is suspect.
#
# Run after changing refute, refute.prompt, burden/, verdict.schema.json, or the validator.
#   PR_REVIEW_REFUTER=ollama:glm-5.3-flash PR_REVIEW_BURDEN=evidence ./selftest.sh
set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../lib/common.sh"
load_config

PIN_PR=2179
PIN_SHA=41a4cc648b2b0cb153c76d8ed9f5b084c40d6202
GEMINI_MODEL="${PR_REVIEW_GEMINI_MODEL:-gemini-3.8-flash-high}"
REFUTER="${PR_REVIEW_REFUTER:-agy:$GEMINI_MODEL}"
BURDEN="${PR_REVIEW_BURDEN:-strict}"
TIMEOUT="${PR_REVIEW_REFUTE_TIMEOUT:-${PR_REVIEW_AGY_TIMEOUT:-9m}}"

die() { printf '\033[31mselftest: %s\033[0m\n' "$*" >&2; exit 1; }
say() { printf '\033[36m==>\033[0m %s\n' "$*" >&2; }

case "$REFUTER" in *:?*) ;; *) die "PR_REVIEW_REFUTER must be transport:model, got: $REFUTER" ;; esac
ROOT="$(git rev-parse --show-toplevel)" || die "not inside a git repository"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pr-review-selftest.XXXXXX")"
TREE="$WORK/tree"

cleanup() {
  rc=$?
  rm -rf "$WORK"
  exit $rc
}
trap cleanup EXIT INT TERM

# The fixtures cite at_client_sdk source at a pinned commit, so this test only runs there.
git -C "$ROOT" cat-file -e "$PIN_SHA" 2>/dev/null || \
  git -C "$ROOT" fetch --quiet origin "pull/$PIN_PR/head" 2>/dev/null || \
  die "cannot reach $PIN_SHA from $(basename "$ROOT") — the fixtures are pinned to
       atsign-foundation/at_client_sdk PR #$PIN_PR. Run this from that repo, or repoint
       PIN_PR/PIN_SHA and rewrite fixtures/ to cite code in the repo you are using."
# A clone, not a worktree -- same reason as pr-review.sh: agy follows a worktree's gitdir
# pointer back to $ROOT and writes its scratch there. This gate has to run the real geometry.
git clone --quiet --shared --no-checkout "$ROOT" "$TREE" || die "clone failed"
git -C "$TREE" checkout --quiet --detach "$PIN_SHA" || die "checkout failed at $PIN_SHA"
say "tree at $PIN_SHA"

# The gate runs the production path rather than a lookalike: refute owns the prompt
# substitution, the validator invocation and the retry, so a drift in any of them fails
# here instead of sailing past a private copy that no longer matches.
jq -s '{findings: .}' \
  "$HERE/fixtures/true-claim.json" \
  "$HERE/fixtures/fake-file.json" \
  "$HERE/fixtures/fake-mechanism.json" > "$WORK/findings.json"

say "running 3 fixtures against $REFUTER, $BURDEN burden"
rc=0
# Pinned: this measures $REFUTER's discrimination. A quota fallback would score another
# model's verdicts as its own -- a spent model comes back ERROR here instead.
PR_REVIEW_REFUTER_FALLBACK="" "$HERE/refute" --findings "$WORK/findings.json" --tree "$TREE" --root "$ROOT" \
  --work "$WORK" --jobs 3 --transport "${REFUTER%%:*}" --model "${REFUTER#*:}" \
  --burden "$BURDEN" --timeout "$TIMEOUT" || rc=$?
# 3 is a quarantined escape: the verdicts are still complete, and refute has already
# said what it moved. Anything else means no verdicts to judge.
[ "$rc" = 0 ] || [ "$rc" = 3 ] || die "refute exited $rc; no verdicts to check"

# expect <id> <accepted verdict>...
expect() {
  id="$1"; shift
  got="$(jq -r '.verdict // "ERROR"' "$WORK/verdicts/$id.json" 2>/dev/null || echo ERROR)"
  case " $* " in
    *" $got "*)
      printf '\033[32m  PASS\033[0m %-12s expected %s, got %s\n' "$id" "$*" "$got" >&2 ;;
    *)
      printf '\033[31m  FAIL\033[0m %-12s expected %s, got %s\n' "$id" "$*" "$got" >&2
      jq -r '.reason // "(no reason recorded)"' "$WORK/verdicts/$id.json" 2>/dev/null \
        | sed 's/^/        /' >&2 || true
      echo "$id" >> "$WORK/failures" ;;
  esac
}

# Under the evidence burden an UNVERIFIABLE true claim still reaches the report.
if [ "$BURDEN" = evidence ]; then expect TRUE_CLAIM CONFIRMED UNVERIFIABLE
else expect TRUE_CLAIM CONFIRMED; fi
expect FAKE_FILE  REFUTED
expect FAKE_MECH  REFUTED

if [ -s "$WORK/failures" ]; then
  n="$(wc -l < "$WORK/failures" | tr -d ' ')"
  die "$n fixture(s) failed -- do not trust pipeline output until this passes"
fi
say "all fixtures passed; the validator still discriminates"
