# transport-env.sh -- the credential-isolation contracts, one wrapper per transport. Sourced by
# common.sh, never executed. Each wrapper runs its arguments with only the credential that
# transport needs: anthropic_env the caller's Claude login (or, with ANTHROPIC_USE_API_KEY=1,
# ANTHROPIC_API_KEY); ollama_env OLLAMA_API_KEY as the Bearer token for ollama.com; agy_env
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
# Runs its arguments with every credential and endpoint override that could route a nested
# `claude` somewhere other than ollama.com removed from the environment.
ollama_env() {
  env -u ANTHROPIC_API_KEY -u OLLAMA_API_KEY -u GEMINI_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN \
      -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX \
      -u ANTHROPIC_MODEL -u ANTHROPIC_CUSTOM_HEADERS \
      CLAUDE_CODE_SIMPLE=1 \
      ANTHROPIC_SMALL_FAST_MODEL="$MODEL" \
      ANTHROPIC_DEFAULT_HAIKU_MODEL="$MODEL" \
      ANTHROPIC_BASE_URL="https://ollama.com" \
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
  env -u ANTHROPIC_API_KEY -u OLLAMA_API_KEY -u GEMINI_API_KEY \
      -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_CUSTOM_HEADERS \
      -u ANTHROPIC_MODEL -u ANTHROPIC_SMALL_FAST_MODEL -u ANTHROPIC_DEFAULT_HAIKU_MODEL \
      -u CLAUDE_CODE_SIMPLE -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX \
      ${key:+"ANTHROPIC_API_KEY=$key"} \
      "$@"
}

# agy_env() -- agy authenticates through its own sign-in and reads none of these.
agy_env() {
  env -u ANTHROPIC_API_KEY -u OLLAMA_API_KEY -u GEMINI_API_KEY \
      -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_BASE_URL \
      "$@"
}
