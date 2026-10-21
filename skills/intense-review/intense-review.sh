#!/usr/bin/env bash
# intense-review -- pr-review.sh's intense preset: up to two finders of different families at
# their highest effort, run in parallel, every finding refuted under the evidence burden by a
# model of a third family. By default, with every backend reachable: opus and gemini find,
# glm-5.3-flash over ollama refutes; if glm is unavailable mid-run, the other finder's model
# refutes (opus <-> gemini). lib/models.tsv ranks the models; PR_REVIEW_INTENSE_FINDERS and
# PR_REVIEW_INTENSE_REFUTER pin them.
#
#   intense-review.sh <pr> [any pr-review.sh option]
#
# Stage 1 has no dollar cap; PR_REVIEW_S1_TIMEOUT bounds each slice instead.
# Reports land in their own store, so a default review of the same PR is never overwritten.
set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../lib/common.sh"
load_config

export PR_REVIEW_PRESET=intense
export PR_REVIEW_BURDEN=evidence
export PR_REVIEW_CROSS=1
export PR_REVIEW_BUDGET_USD=none
export PR_REVIEW_DIR="$(intense_store)"
export PR_REVIEW_S1_TIMEOUT="${PR_REVIEW_S1_TIMEOUT:-60m}"
export PR_REVIEW_STAGE1_JOBS="${PR_REVIEW_STAGE1_JOBS:-4}"

exec "$HERE/../pr-review/pr-review.sh" "$@"
