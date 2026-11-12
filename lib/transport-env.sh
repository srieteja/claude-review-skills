# transport-env.sh -- the credential-isolation contracts, one wrapper per transport. Sourced by
# common.sh, never executed. Each wrapper runs its arguments with only the credential that
# transport needs: anthropic_env the caller's Claude login (or, with ANTHROPIC_USE_API_KEY=1,
# ANTHROPIC_API_KEY); ollama_env (a nested claude) and ollama_api_env (the direct client)
# OLLAMA_API_KEY as the Bearer token for ollama.com; agy_env
# none, since agy signs in on its own. Every other key, and every endpoint override, is
# stripped, so no review prompt reaches a provider on a key meant for another.
#
# Reads $MODEL, $OLLAMA_API_KEY, $ANTHROPIC_API_KEY and $ANTHROPIC_USE_API_KEY at call time.
#
# CLAUDE_CODE_SIMPLE=1 is load-bearing, not cosmetic: without it, a nested `claude` with an
# active OAuth login prefers the Keychain-stored "Claude Code-credentials" session over
# ANTHROPIC_AUTH_TOKEN and sends that Bearer token to ollama.com instead -- a silent 401, not a
# crash, and invisible unless you capture the actual outbound header (confirmed by pointing
# ANTHROPIC_BASE_URL at a local listener and reading what it sent). `claude --help` documents
# the flag: "Anthropic auth is strictly ANTHROPIC_API_KEY or apiKeyHelper... OAuth and keychain
# are never read."
#
# Reproducer for the symptom, measured live -- drop CLAUDE_CODE_SIMPLE=1 and nothing else:
#
#   ANTHROPIC_BASE_URL=https://ollama.com ANTHROPIC_AUTH_TOKEN=$OLLAMA_API_KEY \
#     claude -p ping --model glm-5.3 --output-format json
#
# returns, in the result event, `is_error: true` beside `subtype: "success"` and
# `result: "Failed to authenticate. API Error: 401 Unauthorized"`; the init event's tool list is
# the full harness rather than the ["Bash","Edit","Read"] the flag produces. Re-add the flag and
# the same call returns "pong". That the 401 comes from the Keychain session specifically is the
# hypothesis above, not something this reproducer establishes -- a Keychain credential is not an
# environment variable and does not show up in `env`. What IS established: the flag is load-bearing
# for AUTH, not merely for shrinking the tool surface.
#
# The small/fast tier is PINNED to $MODEL rather than unset: unsetting restores claude's built-in
# default, which is a `claude-haiku-*` id ollama.com does not serve, so any nested background call
# (titles, summaries) 404s against a key that is otherwise fine. Overriding costs a little more per
# background call and always resolves. ANTHROPIC_MODEL is unset instead -- `--model` on argv is the
# single source of truth for the main model -- and ANTHROPIC_CUSTOM_HEADERS is stripped because a
# header set for the user's own Anthropic account has no business on an ollama.com request.
# ollama.com's origin: the one place bash names it (ollama_env, lib/models.sh, and the
# --endpoint handed to lib/ollama_messages.py, which names no URL itself). A plain
# assignment, not read from the environment, so no inherited variable can move the Bearer key.
# It is also in _CRED_VARS, so an exported copy never reaches a child: the client reads no
# environment and takes only the --endpoint expanded from this shell variable.
OLLAMA_ORIGIN="https://ollama.com"

# The strip list every wrapper starts from: each credential, token and routing override that could
# send a call to a provider on a key or endpoint meant for another. A wrapper removes all of them
# (_strip_args), then adds back only what it passes itself; anthropic_env keeps the login's own
# CLAUDE_CODE_OAUTH_TOKEN.
_CRED_VARS=(ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_CUSTOM_HEADERS
            ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL
            CLAUDE_CODE_SIMPLE CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_OAUTH_TOKEN
            GEMINI_API_KEY OLLAMA_API_KEY OLLAMA_ORIGIN)
# _strip_args [keep ...]: sets _STRIP to the `-u NAME` arguments for _CRED_VARS less the names kept.
_strip_args() {
  local v k
  _STRIP=()
  for v in "${_CRED_VARS[@]}"; do
    for k in "$@"; do [ "$v" != "$k" ] || continue 2; done
    _STRIP+=(-u "$v")
  done
}

# ollama_api_env() -- runs its arguments (lib/ollama_messages.py) with OLLAMA_API_KEY as the only
# credential: every other key, token and endpoint override is removed. OLLAMA_API_KEY is passed
# explicitly because common.sh loads it from config.env as a shell variable, not an exported one;
# when it is empty it is left unset, and the client says so.
ollama_api_env() {
  _strip_args
  env "${_STRIP[@]}" \
      ${OLLAMA_API_KEY:+"OLLAMA_API_KEY=$OLLAMA_API_KEY"} \
      "$@"
}

# Runs its arguments with every credential and endpoint override that could route a nested
# `claude` somewhere other than ollama.com removed from the environment.
ollama_env() {
  _strip_args
  env "${_STRIP[@]}" \
      CLAUDE_CODE_SIMPLE=1 \
      ANTHROPIC_SMALL_FAST_MODEL="$MODEL" \
      ANTHROPIC_DEFAULT_HAIKU_MODEL="$MODEL" \
      ANTHROPIC_BASE_URL="$OLLAMA_ORIGIN" \
      ANTHROPIC_AUTH_TOKEN="$OLLAMA_API_KEY" \
      "$@"
}

# anthropic_env() -- the mirror contract: the call reaches Anthropic on the caller's own Claude
# Code login, so every override that would redirect it (BASE_URL, AUTH_TOKEN, CUSTOM_HEADERS)
# or switch off the Keychain session (CLAUDE_CODE_SIMPLE, see above) is stripped. An exported
# ANTHROPIC_API_KEY is stripped too -- claude prefers it over the login, so a key exported for
# some other tool would silently move every review onto API billing. ANTHROPIC_USE_API_KEY=1
# opts in: ANTHROPIC_API_KEY, from the environment or config.env, is then the credential.
anthropic_key_check() {
  [ "${ANTHROPIC_USE_API_KEY:-}" != 1 ] || [ -n "${ANTHROPIC_API_KEY:-}" ] || {
    printf 'review-skills: ANTHROPIC_USE_API_KEY=1 but ANTHROPIC_API_KEY is empty\n' >&2; return 1; }
}
anthropic_env() {
  local key=""
  anthropic_key_check || return 1
  [ "${ANTHROPIC_USE_API_KEY:-}" != 1 ] || key="$ANTHROPIC_API_KEY"
  _strip_args CLAUDE_CODE_OAUTH_TOKEN
  env "${_STRIP[@]}" \
      ${key:+"ANTHROPIC_API_KEY=$key"} \
      "$@"
}

# agy_env() -- agy authenticates through its own sign-in and reads none of these.
agy_env() {
  _strip_args
  env "${_STRIP[@]}" \
      ${AGY_HOME:+"HOME=$AGY_HOME"} \
      "$@"
}
