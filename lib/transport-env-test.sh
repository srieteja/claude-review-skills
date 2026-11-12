#!/usr/bin/env bash
# Unit checks for lib/transport-env.sh: what each transport wrapper lets through.
set -euo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=1; }
check() { desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }
is() { test "$1" = "$2"; }
# in_env <cmd...>: a clean shell holding the given NAME=value pairs in $ENVV, transport-env.sh
# sourced, then the command.
ENVV=()
in_env() { env -i PATH="$PATH" HOME=/home/real "${ENVV[@]+"${ENVV[@]}"}" \
             bash -c '. "$1"; shift; eval "$*"' _ "$HERE/transport-env.sh" "$@"; }
# Names of every credential-looking or Claude-routing variable the child sees, sorted.
SEEN='python3 -c "import os; print(\" \".join(sorted(k for k in os.environ if k.endswith((\"_KEY\",\"_TOKEN\")) or k.startswith((\"ANTHROPIC\",\"CLAUDE\")) or k.startswith(\"OLLAMA\"))))"'

echo "ollama_api_env"
ENVV=(ANTHROPIC_API_KEY=a ANTHROPIC_AUTH_TOKEN=b CLAUDE_CODE_OAUTH_TOKEN=c GEMINI_API_KEY=d
      ANTHROPIC_BASE_URL=http://elsewhere CLAUDE_CODE_USE_BEDROCK=1 OLLAMA_API_KEY=k-oll)
check "only OLLAMA_API_KEY reaches the client"   is "$(in_env "ollama_api_env $SEEN")" "OLLAMA_API_KEY"
check "  with its value"                         is "$(in_env 'ollama_api_env sh -c '"'"'printf %s "$OLLAMA_API_KEY"'"'")" "k-oll"
ENVV=(ANTHROPIC_API_KEY=a GEMINI_API_KEY=d)
check "an unset key stays unset"                 is "$(in_env "OLLAMA_API_KEY=; ollama_api_env $SEEN")" ""
check "a key held as a shell variable is passed" is "$(in_env "OLLAMA_API_KEY=from-config; ollama_api_env $SEEN")" "OLLAMA_API_KEY"
ENVV=(ANTHROPIC_API_KEY=a CLAUDE_CODE_OAUTH_TOKEN=c GEMINI_API_KEY=d)
check "the client refuses to run without it"     test "$(in_env "ollama_api_env python3 $HERE/ollama_messages.py --endpoint \$OLLAMA_ORIGIN/v1/messages --model m --prompt-file /dev/null >/dev/null 2>&1; echo \$?")" = 1

echo "ollama_env"
ENVV=(OLLAMA_API_KEY=k-oll ANTHROPIC_API_KEY=a)
check "a nested claude is pointed at the ollama origin" is "$(in_env 'MODEL=m ollama_env sh -c '"'"'printf %s "$ANTHROPIC_BASE_URL"'"'")" "https://ollama.com"
check "  and the origin is not inherited"       is "$(env -i PATH="$PATH" OLLAMA_ORIGIN=http://x bash -c '. "$1"; printf %s "$OLLAMA_ORIGIN"' _ "$HERE/transport-env.sh")" "https://ollama.com"

echo "agy_env"
ENVV=(AGY_HOME=/home/agy ANTHROPIC_API_KEY=a OLLAMA_API_KEY=k GEMINI_API_KEY=d)
check "AGY_HOME becomes HOME"                    is "$(in_env 'agy_env sh -c '"'"'printf %s "$HOME"'"'")" "/home/agy"
check "  and no key comes along"                 is "$(in_env "agy_env $SEEN")" ""
ENVV=()
check "no AGY_HOME leaves HOME alone"            is "$(in_env 'agy_env sh -c '"'"'printf %s "$HOME"'"'")" "/home/real"
ENVV=(AGY_HOME=)
check "an empty AGY_HOME leaves HOME alone"      is "$(in_env 'agy_env sh -c '"'"'printf %s "$HOME"'"'")" "/home/real"

# Every wrapper starts from the same strip list; each lets through only what it passes itself.
echo "every wrapper strips the shared credential list"
ALLVARS=(ANTHROPIC_API_KEY=a ANTHROPIC_AUTH_TOKEN=b ANTHROPIC_BASE_URL=http://elsewhere ANTHROPIC_CUSTOM_HEADERS=h
         ANTHROPIC_MODEL=m ANTHROPIC_SMALL_FAST_MODEL=s ANTHROPIC_DEFAULT_HAIKU_MODEL=h2 CLAUDE_CODE_SIMPLE=1
         CLAUDE_CODE_USE_BEDROCK=1 CLAUDE_CODE_USE_VERTEX=1 CLAUDE_CODE_OAUTH_TOKEN=c GEMINI_API_KEY=d OLLAMA_API_KEY=k OLLAMA_ORIGIN=http://evil)
ENVV=("${ALLVARS[@]}")
check "ollama_api_env: only its own key survives" is "$(in_env "ollama_api_env $SEEN")" "OLLAMA_API_KEY"
check "ollama_env: only what it sets itself survives" \
  is "$(in_env "MODEL=m ollama_env $SEEN")" "ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_SMALL_FAST_MODEL CLAUDE_CODE_SIMPLE"
check "  and its token is the ollama key, not the inherited one" \
  is "$(in_env 'MODEL=m ollama_env sh -c '"'"'printf %s "$ANTHROPIC_AUTH_TOKEN"'"'")" "k"
check "anthropic_env: only the login's OAuth token survives" is "$(in_env "anthropic_env $SEEN")" "CLAUDE_CODE_OAUTH_TOKEN"
check "agy_env: nothing survives" is "$(in_env "agy_env $SEEN")" ""

[ "$fail" -eq 0 ]
