#!/usr/bin/env bash
# selftest.sh -- one live call against ollama.com. Pins two things offline-test.sh cannot:
# model naming (bare "glm-5.3" vs a possible ":cloud" suffix -- the plan flags this as unverified,
# see DESIGN.md trap 3) and that ANTHROPIC_AUTH_TOKEN auth actually clears the cloud's gate.
# Not part of the TDD suite: it spends a real call and needs OLLAMA_API_KEY, so it's a manual
# gate to run once before the first real ollama-do invocation, not on every change.
set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../lib/common.sh"
load_config

MODEL="${1:-glm-5.3}"

[ -n "${OLLAMA_API_KEY:-}" ] || {
  echo "selftest.sh: OLLAMA_API_KEY is not set. Create one at https://ollama.com/settings/keys" >&2
  exit 1
}

echo "== capability gate: GET /api/show for '$MODEL' (unauthenticated) ==" >&2
show="$(curl -fsS "https://ollama.com/api/show" -d "{\"model\":\"$MODEL\"}")" || {
  echo "selftest.sh: /api/show rejected '$MODEL' -- try '${MODEL}:cloud' or check https://ollama.com/library" >&2
  exit 1
}
echo "$show" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("capabilities:", d.get("capabilities"))'

echo "== live call: claude -p through ollama.com with model '$MODEL' ==" >&2
work="$(mktemp -d "${TMPDIR:-/tmp}/ollama-selftest.XXXXXX")"
trap 'rm -rf "$work"' EXIT

rc=0
ollama_env claude -p "reply with exactly the word: pong" \
    --model "$MODEL" --output-format json \
    --strict-mcp-config --setting-sources "" \
    --add-dir "$work" >"$work/out" 2>"$work/stderr" || rc=$?

# A failed call still writes a full envelope to stdout, and the only useful error text is inside
# its result event -- an auth failure arrives as `is_error:true` next to `subtype:"success"`, the
# same envelope trap ollama-do encodes. stderr carries claude's client-side `unrecognized_model`
# warning, which is BENIGN: it appears on passing runs too, because claude's local model registry
# has never heard of an ollama id. An earlier version of this script printed only stderr on
# failure and sent the reader chasing that warning while a 401 sat unread in the envelope.
# So: parse the envelope first, and fall back to stderr only when there is no envelope at all.
[ -s "$work/out" ] || {
  echo "selftest.sh: live call produced no envelope (exit $rc). stderr:" >&2
  cat "$work/stderr" >&2
  exit 1
}

python3 - "$work/out" <<'PY'
import json, sys
# strict=False for the same reason parse_envelope uses it: claude has emitted raw control
# characters inside JSON strings, which strict JSON rejects.
events = json.loads(open(sys.argv[1]).read(), strict=False)
result = next((e for e in reversed(events) if e.get("type") == "result"), None)
if result is None:
    print("selftest.sh: no result event in envelope -- envelope shape has changed", file=sys.stderr)
    sys.exit(1)
for k in ("is_error", "subtype", "session_id", "result"):
    print(k + ":", result.get(k))
if result.get("is_error"):
    print("selftest.sh: model call reported is_error -- see result text above", file=sys.stderr)
    sys.exit(1)
PY

# A clean envelope beside a non-zero exit is not a pass -- say so rather than printing OK.
[ "$rc" = 0 ] || { echo "selftest.sh: envelope parsed clean but claude exited $rc" >&2; exit 1; }

echo "== selftest.sh: OK -- model '$MODEL' resolves, auth clears, envelope shape holds ==" >&2
