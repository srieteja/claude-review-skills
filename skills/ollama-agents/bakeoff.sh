#!/usr/bin/env bash
# bakeoff.sh -- step 1 of picking a real default: run the same --ask task through the three
# seeded models (glm-5.3, kimi-k3, deepseek-v4-pro:0813 -- see DESIGN.md's Models table, all
# ranked but none measured) and tabulate. Run selftest.sh first to confirm model naming before
# spending three calls here. Needs a real repo to --root against; ~/work itself is not one.
#
# Each model gets its own --work subdir: --ask always writes id "ask", so reusing one dir across
# models would overwrite the previous model's .verdict/.answer before they're read.
set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../lib/common.sh"
load_config

ROOT="${1:?usage: bakeoff.sh <root-repo> [question]}"
QUESTION="${2:-Summarize what this repository does and its main entry point, in 2-3 sentences.}"
MODELS=(glm-5.3 kimi-k3 "deepseek-v4-pro:0813")

[ -n "${OLLAMA_API_KEY:-}" ] || {
  echo "bakeoff.sh: OLLAMA_API_KEY is not set. Create one at https://ollama.com/settings/keys" >&2
  exit 1
}

work="$(mktemp -d "${TMPDIR:-/tmp}/ollama-bakeoff.XXXXXX")"
printf '%-24s %10s %8s %s\n' "model" "verdict" "secs" "answer (first line)"

for model in "${MODELS[@]}"; do
  id="$(echo "$model" | tr -c 'a-zA-Z0-9' '_')"
  mwork="$work/$id"
  mkdir -p "$mwork"
  start=$(date +%s)
  set +e
  "$HERE/ollama-do" --ask "$QUESTION" --root "$ROOT" --model "$model" --work "$mwork" \
    >"$mwork/run.log" 2>&1
  rc=$?
  set -e
  secs=$(( $(date +%s) - start ))

  verdict="ERR($rc)"
  [ -f "$mwork/ask.verdict" ] && verdict="$(cat "$mwork/ask.verdict")"
  first_line="-"
  [ -f "$mwork/ask.answer" ] && first_line="$(head -c 120 "$mwork/ask.answer" | head -1)"

  printf '%-24s %10s %8s %s\n' "$model" "$verdict" "${secs}s" "$first_line"
done

echo "" >&2
echo "bakeoff.sh: full logs and answers under $work/<model>/" >&2
echo "bakeoff.sh: per-call token counts in the ledger (\$OLLAMA_DO_LEDGER, default ~/.local/state/ollama-do/ledger)" >&2
