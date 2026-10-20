# ollama-env.sh -- the credential-isolation contract, in one place because two callers need the
# SAME environment or neither proves anything. Sourced, never executed: `. "$HERE/ollama-env.sh"`.
#
# Reads $MODEL and $OLLAMA_API_KEY from the caller AT CALL TIME, so a caller may parse its own
# --model after sourcing this.
#
# This lived inline in ollama-do while selftest.sh hand-rolled its own shorter version. The two
# drifted, and selftest.sh's live call failed against a model ollama-do was succeeding with on the
# same machine. Nothing regressed in ollama-do: selftest had been pinning an environment the tool
# never uses, so its failure said nothing about the tool and its passes had said nothing either. A pin that
# tests a different environment than the code is worse than no pin: it fails for reasons that have
# nothing to do with the thing it claims to guard.
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
  env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN \
      -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX \
      -u ANTHROPIC_MODEL -u ANTHROPIC_CUSTOM_HEADERS \
      CLAUDE_CODE_SIMPLE=1 \
      ANTHROPIC_SMALL_FAST_MODEL="$MODEL" \
      ANTHROPIC_DEFAULT_HAIKU_MODEL="$MODEL" \
      ANTHROPIC_BASE_URL="https://ollama.com" \
      ANTHROPIC_AUTH_TOKEN="$OLLAMA_API_KEY" \
      "$@"
}

# anthropic_env() -- the mirror contract for --transport anthropic: the call must reach Anthropic
# on the caller's own Claude Code login, so every override that would redirect it (BASE_URL,
# AUTH_TOKEN, CUSTOM_HEADERS) or switch off the Keychain session (CLAUDE_CODE_SIMPLE, see above)
# is stripped. A caller exporting ollama_env's variables -- or running inside another nested
# session -- must not silently send an Opus request to ollama.com. ANTHROPIC_API_KEY and the
# OAuth token are KEPT: they are the caller's own deliberate choice of Anthropic credential.
anthropic_env() {
  env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_CUSTOM_HEADERS \
      -u ANTHROPIC_MODEL -u ANTHROPIC_SMALL_FAST_MODEL -u ANTHROPIC_DEFAULT_HAIKU_MODEL \
      -u CLAUDE_CODE_SIMPLE -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX \
      "$@"
}
