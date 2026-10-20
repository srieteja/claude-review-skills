#!/usr/bin/env bash
# intense-review -- pr-review.sh with two finders at their highest effort, run in parallel,
# every finding refuted by glm-5.3-flash over ollama under the evidence burden. If glm is
# unavailable, the other finder's model refutes it (opus <-> gemini).
#
#   intense-review.sh <pr-number> [any pr-review.sh option]
#
# Stage 1 has no dollar cap; PR_REVIEW_S1_TIMEOUT bounds each slice instead.
# Reports land in their own store, so a default review of the same PR is never overwritten.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PR_REVIEW_FINDERS="${PR_REVIEW_INTENSE_FINDERS:-anthropic:claude-opus-5-5@max agy:gemini-3.8-flash-high}"
export PR_REVIEW_REFUTER="${PR_REVIEW_INTENSE_REFUTER:-ollama:glm-5.3-flash}"
export PR_REVIEW_BURDEN=evidence
export PR_REVIEW_CROSS=1
export PR_REVIEW_BUDGET_USD=none
export PR_REVIEW_DIR="${PR_REVIEW_INTENSE_DIR:-$HOME/work/reviews-intense}"
export PR_REVIEW_S1_TIMEOUT="${PR_REVIEW_S1_TIMEOUT:-60m}"
export PR_REVIEW_STAGE1_JOBS="${PR_REVIEW_STAGE1_JOBS:-4}"

exec "$HERE/../pr-review/pr-review.sh" "$@"
