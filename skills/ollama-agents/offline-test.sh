#!/usr/bin/env bash
# offline-test.sh -- exercise ollama-do against a stubbed executor. Spends nothing: no
# OLLAMA_API_KEY required, no network.
#
# Ported from delegate/offline-test.sh, but this executor's envelope is a JSON ARRAY of typed
# events (not a flat object), and success is decided by `is_error`, not `subtype` -- a rate
# limited turn can read subtype:"success" while is_error:true. Test 15 exists because that
# distinction is exactly the kind of thing a mechanical port would get wrong silently.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REVIEW_SKILLS_CONFIG="$(mktemp -d "${TMPDIR:-/tmp}/ollama-do-cfg.XXXXXX")/config.env"
PASS=0; FAIL=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

mkrepo() {
  R="$(mktemp -d "${TMPDIR:-/tmp}/ollama-do-test.XXXXXX")/repo"
  mkdir -p "$R"; git -C "$R" init -q
  echo "original" > "$R/tracked.txt"; echo "shared" > "$R/shared.txt"
  git -C "$R" add -A >/dev/null
  git -C "$R" -c user.email=t -c user.name=t commit -qm init >/dev/null
  echo "$R"
}

run() { # mode task-args... -> sets RC, WORKDIR
  mode="$1"; shift
  WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/ollama-do-work.XXXXXX")"
  RC=0
  STUB_MODE="$mode" STUB_ROOT="$ROOT" OLLAMA_API_KEY="test-key-not-real" \
  OLLAMA_DO_BIN="$HERE/stub-claude" OLLAMA_DO_SKIP_SHOW_CHECK=1 OLLAMA_DO_LEDGER="$WORKDIR/ledger" \
    "$HERE/ollama-do" --root "$ROOT" --work "$WORKDIR" "$@" >"$WORKDIR/out" 2>&1 || RC=$?
}

verdict() { cat "$WORKDIR/$1.verdict" 2>/dev/null || echo MISSING; }

echo "ollama-do offline tests"
TASKDIR="$(mktemp -d "${TMPDIR:-/tmp}/ollama-do-task.XXXXXX")"; echo "do the thing" > "$TASKDIR/task.md"

# --- test 1: missing key ---------------------------------------------------
ROOT="$(mkrepo)"; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/ollama-do-work.XXXXXX")"; RC=0
( unset OLLAMA_API_KEY; STUB_MODE=write STUB_ROOT="$ROOT" \
  OLLAMA_DO_BIN="$HERE/stub-claude" OLLAMA_DO_SKIP_SHOW_CHECK=1 OLLAMA_DO_LEDGER="$WORKDIR/ledger" \
    "$HERE/ollama-do" --root "$ROOT" --work "$WORKDIR" --task "$TASKDIR/task.md" >"$WORKDIR/out" 2>&1 ) || RC=$?
[ "$RC" = "1" ] && grep -qi "OLLAMA_API_KEY" "$WORKDIR/out" \
  && ok "missing OLLAMA_API_KEY -> exit 1, remediation string not a stack trace" \
  || bad "missing key (rc=$RC)"

# --- test 2: capability gate -------------------------------------------------
ROOT="$(mkrepo)"; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/ollama-do-work.XXXXXX")"; RC=0
STUB_MODE=write STUB_ROOT="$ROOT" OLLAMA_API_KEY="test-key" \
OLLAMA_DO_BIN="$HERE/stub-claude" OLLAMA_DO_SHOW_STUB="no-tools" OLLAMA_DO_LEDGER="$WORKDIR/ledger" \
  "$HERE/ollama-do" --root "$ROOT" --work "$WORKDIR" --task "$TASKDIR/task.md" >"$WORKDIR/out" 2>&1 || RC=$?
[ "$RC" = "1" ] && grep -qi "tools" "$WORKDIR/out" \
  && ok "model lacking 'tools' capability -> refused before inference" \
  || bad "capability gate (rc=$RC)"

# --- verdict semantics ------------------------------------------------------
ROOT="$(mkrepo)"; run write --task "$TASKDIR/task.md"
[ "$(verdict task)" = "OK" ] && [ -s "$WORKDIR/task.patch" ] \
  && ok "ordinary success -> OK with a patch" || bad "ordinary success (got $(verdict task))"
grep -q "created.txt" "$WORKDIR/task.patch" 2>/dev/null \
  && ok "new files appear in the patch" || bad "new files missing from the patch"

ROOT="$(mkrepo)"; run noop --task "$TASKDIR/task.md"
[ "$(verdict task)" = "NO-OP" ] \
  && ok "success with no diff -> NO-OP, not a pass" || bad "no-op (got $(verdict task))"
# A NO-OP that prints nothing is the failure mode that cost two production runs their evidence:
# the executor's reason was on disk in <id>.answer and the reporting loop dropped it. Assert the
# text reaches stderr, not merely that the file exists.
grep -q "already satisfied so I changed nothing" "$WORKDIR/out" \
  && ok "NO-OP surfaces the executor's own reason, not just the verdict" \
  || bad "NO-OP swallowed .answer -- reason() did not fire"

# --- test 15: the is_error/subtype trap --------------------------------------
ROOT="$(mkrepo)"; run rate_limited --task "$TASKDIR/task.md"
[ "$(verdict task)" = "FAILED" ] \
  && ok "is_error:true + subtype:success + empty diff -> FAILED, never NO-OP" \
  || bad "rate-limited turn (got $(verdict task)) -- parse_envelope trusting subtype over is_error?"

ROOT="$(mkrepo)"; run commit --task "$TASKDIR/task.md"
[ "$(verdict task)" = "OK" ] && grep -q "created.txt" "$WORKDIR/task.patch" 2>/dev/null \
  && ok "work committed inside the worktree -> OK, full patch" \
  || bad "committed work (got $(verdict task)) -- diffing --cached instead of the base SHA?"

ROOT="$(mkrepo)"; run partial --task "$TASKDIR/task.md"
[ "$(verdict task)" = "PARTIAL" ] \
  && ok "died mid-write -> PARTIAL, not FAILED" || bad "partial (got $(verdict task))"

ROOT="$(mkrepo)"; run ctrlchars --task "$TASKDIR/task.md"
[ "$(verdict task)" = "OK" ] && [ -s "$WORKDIR/task.resume" ] \
  && ok "control chars in the envelope -> salvaged, session id captured (jq refuses this)" \
  || bad "control-char envelope (got $(verdict task))"

ROOT="$(mkrepo)"; run unparseable --task "$TASKDIR/task.md"
[ "$(verdict task)" = "FAILED" ] \
  && ok "no JSON at all -> FAILED, never a silent pass" || bad "unparseable (got $(verdict task))"

ROOT="$(mkrepo)"; run preamble --task "$TASKDIR/task.md"
[ "$(verdict task)" = "OK" ] \
  && ok "task is wrapped in the non-interactive preamble, and survives wrapping" \
  || bad "preamble not applied (got $(verdict task)) -- executor will answer conversationally"

# --- ask mode ----------------------------------------------------------------
ROOT="$(mkrepo)"
ASKTREE="$(dirname "$ROOT")/asktree"; git -C "$ROOT" worktree add -q --detach "$ASKTREE" HEAD
run ask --ask "where is X handled?" --tree "$ASKTREE"
[ "$(verdict ask)" = "OK" ] \
  && ok "ask is wrapped in its own preamble and stays read-only" \
  || bad "ask preamble/read-only (got $(verdict ask)) -- bare question risks a clarifying reply"
[ -s "$WORKDIR/ask.answer" ] && [ ! -s "$WORKDIR/ask.patch" ] \
  && ok "ask returns an answer and no patch" || bad "ask produced a patch or no answer"

ROOT="$(mkrepo)"; run ask --ask "where is X handled?"
[ "$(verdict ask)" = "OK" ] \
  && ok "ask with no --tree cuts its own worktree" || bad "cold ask (got $(verdict ask))"

# --- the guard ----------------------------------------------------------------
ROOT="$(mkrepo)"; run escape_untracked --task "$TASKDIR/task.md"
[ "$RC" = "3" ] && [ -e "$WORKDIR/escaped/stub-scratch.tmp" ] && [ ! -e "$ROOT/stub-scratch.tmp" ] \
  && ok "scratch into the repo -> exit 3 and quarantined" || bad "untracked escape (rc=$RC)"

ROOT="$(mkrepo)"; run escape_tracked --task "$TASKDIR/task.md"
[ "$RC" = "1" ] && grep -q "tampered" "$ROOT/tracked.txt" \
  && ok "tracked file touched -> exit 1, left in place" || bad "tracked escape (rc=$RC)"

ROOT="$(mkrepo)"; run escape_git --task "$TASKDIR/task.md"
[ "$RC" = "1" ] \
  && ok "git metadata mutated -> exit 1 (porcelain alone misses this)" || bad "git escape (rc=$RC)"

# --- fan-out -------------------------------------------------------------------
FAN="$(mktemp -d "${TMPDIR:-/tmp}/ollama-do-fan.XXXXXX")"; echo "a" > "$FAN/collide_a.md"; echo "b" > "$FAN/collide_b.md"
ROOT="$(mkrepo)"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/ollama-do-work.XXXXXX")"; RC=0
STUB_ROOT="$ROOT" OLLAMA_API_KEY="test-key" OLLAMA_DO_BIN="$HERE/stub-claude" \
OLLAMA_DO_SKIP_SHOW_CHECK=1 OLLAMA_DO_LEDGER="$WORKDIR/ledger" \
  env STUB_MODE=collide_a "$HERE/ollama-do" --root "$ROOT" --work "$WORKDIR" \
      --tasks "$FAN" --jobs 2 >"$WORKDIR/out" 2>&1 || RC=$?
grep -q "shared.txt" "$WORKDIR/out" && grep -qi "same files" "$WORKDIR/out" \
  && ok "overlapping slices -> collision reported" || bad "collision not reported"
[ "$(verdict collide_a)" = "OK" ] && [ "$(verdict collide_b)" = "OK" ] \
  && ok "fan-out settles every slice" || bad "fan-out verdicts (a=$(verdict collide_a) b=$(verdict collide_b))"

# --- --map: no repo required --------------------------------------------------
NOREPODIR="$(mktemp -d "${TMPDIR:-/tmp}/ollama-do-norepo.XXXXXX")"
echo "one" > "$NOREPODIR/a.txt"; echo "two" > "$NOREPODIR/b.txt"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/ollama-do-work.XXXXXX")"; RC=0
OLLAMA_API_KEY="test-key" OLLAMA_DO_SKIP_SHOW_CHECK=1 OLLAMA_MAP_STUB=extract \
  "$HERE/ollama-do" --map "$NOREPODIR" --schema '{"type":"object"}' --work "$WORKDIR" \
    >"$WORKDIR/out" 2>&1 || RC=$?
[ "$RC" = "0" ] && [ -s "$WORKDIR/results.json" ] \
  && ok "--map runs with no git repo present and writes results.json" \
  || bad "--map without a repo (rc=$RC)"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/ollama-do-work.XXXXXX")"; RC=0
OLLAMA_API_KEY="test-key" OLLAMA_DO_SKIP_SHOW_CHECK=1 OLLAMA_MAP_STUB=schema_invalid \
  "$HERE/ollama-do" --map "$NOREPODIR" --schema '{"type":"object"}' --work "$WORKDIR" \
    >"$WORKDIR/out" 2>&1 || RC=$?
[ "$RC" = "0" ] && grep -q '"a.txt"' "$WORKDIR/results.json" && grep -qi "failed" "$WORKDIR/results.json" \
  && ok "--map: one file's schema-invalid response marked failed, siblings unaffected" \
  || bad "--map schema-invalid handling (rc=$RC)"

# --- isolation contract ---------------------------------------------------------
# DESIGN.md trap #8: CLAUDE_CODE_SIMPLE=1 keeps a Keychain OAuth session from beating
# ANTHROPIC_AUTH_TOKEN and shipping the user's own Anthropic Bearer token to ollama.com. It is
# empirically verified, silently regressible on a CLI upgrade, and was pinned by nothing. The
# caller's env is deliberately POISONED here -- passing these means the unsets really unset.
TRACE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ollama-do-trace.XXXXXX")"
ROOT="$(mkrepo)"
export ANTHROPIC_API_KEY="leaked-anthropic-key" CLAUDE_CODE_OAUTH_TOKEN="leaked-oauth-token"
export ANTHROPIC_MODEL="claude-opus-5" ANTHROPIC_SMALL_FAST_MODEL="claude-haiku-4-5"
export ANTHROPIC_CUSTOM_HEADERS="X-Leak: yes"
export OLLAMA_DO_STUB_TRACE="$TRACE_DIR/task.trace"
run write --task "$TASKDIR/task.md"
T="$TRACE_DIR/task.trace"
env_of() { sed -n '/^--- env$/,/^--- argv$/p' "$1" | grep "^$2=" | head -1 | cut -d= -f2-; }
argv_of() { sed -n '/^--- argv$/,$p' "$1"; }

[ -s "$T" ] \
  && ! sed -n '/^--- env$/,/^--- argv$/p' "$T" | grep -q '^ANTHROPIC_API_KEY=' \
  && ! sed -n '/^--- env$/,/^--- argv$/p' "$T" | grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' \
  && ! sed -n '/^--- env$/,/^--- argv$/p' "$T" | grep -q '^ANTHROPIC_CUSTOM_HEADERS=' \
  && [ "$(env_of "$T" ANTHROPIC_AUTH_TOKEN)" = "test-key-not-real" ] \
  && [ "$(env_of "$T" ANTHROPIC_BASE_URL)" = "https://ollama.com" ] \
  && ok "executor env is isolated: no ANTHROPIC_API_KEY/OAuth token/custom headers, Bearer is the ollama key" \
  || bad "executor env leaked the caller's Anthropic credentials"

[ "$(env_of "$T" CLAUDE_CODE_SIMPLE)" = "1" ] \
  && [ "$(env_of "$T" ANTHROPIC_SMALL_FAST_MODEL)" != "claude-haiku-4-5" ] \
  && [ "$(env_of "$T" ANTHROPIC_DEFAULT_HAIKU_MODEL)" = "$(env_of "$T" ANTHROPIC_SMALL_FAST_MODEL)" ] \
  && ok "CLAUDE_CODE_SIMPLE=1 set and the small/fast tier is pinned to an ollama model, not a haiku id" \
  || bad "CLAUDE_CODE_SIMPLE or the small/fast model pin regressed (trap #8)"

argv_of "$T" | grep -qx -- '--strict-mcp-config' \
  && [ -z "$(argv_of "$T" | grep -A1 -x -- '--setting-sources' | tail -1)" ] \
  && argv_of "$T" | grep -qx -- '--dangerously-skip-permissions' \
  && ok "--task argv carries --strict-mcp-config, an empty --setting-sources, and the permission bypass" \
  || bad "--task argv lost an isolation flag"

# The mirror: --ask is read-only and must NEVER receive the bypass.
OLLAMA_DO_STUB_TRACE="$TRACE_DIR/ask.trace" run ask --ask "where is the thing?"
! argv_of "$TRACE_DIR/ask.trace" | grep -qx -- '--dangerously-skip-permissions' \
  && argv_of "$TRACE_DIR/ask.trace" | grep -qx -- '--strict-mcp-config' \
  && ok "--ask never receives --dangerously-skip-permissions" \
  || bad "--ask was handed the permission bypass"

unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL
unset ANTHROPIC_CUSTOM_HEADERS OLLAMA_DO_STUB_TRACE

# --- capability gate ------------------------------------------------------------
# The gate reads `capabilities`, not the whole /api/show body. The decoy below is the reason:
# details/model_info are free-form vendor metadata, so a substring test for "tools" anywhere in
# the body passes a model that never advertised the capability.
gate() { # show-stub -> GATE_OUT
  GATE_RC=0
  GATE_OUT="$(OLLAMA_API_KEY="test-key" OLLAMA_DO_SHOW_STUB="$1" OLLAMA_DO_BIN="$HERE/stub-claude" \
    STUB_MODE=ask "$HERE/ollama-do" --ask "q" --root "$ROOT" \
    --work "$(mktemp -d "${TMPDIR:-/tmp}/ollama-do-gate.XXXXXX")" 2>&1)" || GATE_RC=$?
}
ROOT="$(mkrepo)"
gate '{"capabilities":["completion","thinking","tools"]}'
[ "$GATE_RC" = "0" ] && ok "capability gate passes a model advertising tools" \
  || bad "capability gate rejected a tools-capable model (rc=$GATE_RC)"

gate '{"capabilities":["completion"],"model_info":{"blurb":"great at \"tools\" use"}}'
[ "$GATE_RC" = "1" ] && echo "$GATE_OUT" | grep -q "does not advertise" \
  && ok "capability gate refuses a model whose free-form metadata merely mentions \"tools\"" \
  || bad "capability gate fooled by a substring outside capabilities (rc=$GATE_RC)"

gate '{"capabilities":'
[ "$GATE_RC" = "1" ] && echo "$GATE_OUT" | grep -q "could not parse" \
  && ok "unparseable /api/show body refuses distinctly, not as a missing capability" \
  || bad "malformed /api/show body mishandled (rc=$GATE_RC)"

# --- ledger --------------------------------------------------------------------
[ -s "$WORKDIR/ledger" ] || true  # ledger already checked against the fan-out WORKDIR below
WORKDIR_LEDGER="$(mktemp -d "${TMPDIR:-/tmp}/ollama-do-work.XXXXXX")"
ROOT="$(mkrepo)"
STUB_MODE=write STUB_ROOT="$ROOT" OLLAMA_API_KEY="test-key" OLLAMA_DO_BIN="$HERE/stub-claude" \
OLLAMA_DO_SKIP_SHOW_CHECK=1 OLLAMA_DO_LEDGER="$WORKDIR_LEDGER/ledger" \
  "$HERE/ollama-do" --root "$ROOT" --work "$WORKDIR_LEDGER" --task "$TASKDIR/task.md" >/dev/null 2>&1
[ -s "$WORKDIR_LEDGER/ledger" ] && [ "$(awk -F'\t' '{print NF}' "$WORKDIR_LEDGER/ledger" | sort -u)" = "12" ] \
  && ok "ledger records one 12-field row per task" || bad "ledger malformed"
grep -q "700" "$WORKDIR_LEDGER/ledger" \
  && ok "cache_read_input_tokens recorded" || bad "cache-read tokens missing from ledger"

# --- transport: anthropic ----------------------------------------------------------
# The second transport runs the same protocol on the user's own Claude login. It must need no
# Ollama key, and it must strip every inherited override that could redirect the call or switch
# off the Keychain login -- the mirror image of ollama_env's contract.
anthropic_run() { # mode extra-env... -- args... -> sets RC, WORKDIR
  mode="$1"; shift
  WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/ollama-do-work.XXXXXX")"; RC=0
  ( unset OLLAMA_API_KEY
    STUB_MODE="$mode" STUB_ROOT="$ROOT" OLLAMA_DO_BIN="$HERE/stub-claude" \
    OLLAMA_DO_LEDGER="$WORKDIR/ledger" OLLAMA_DO_STUB_TRACE="$WORKDIR/trace" \
    ANTHROPIC_BASE_URL="https://evil.example" ANTHROPIC_AUTH_TOKEN="leak" \
    CLAUDE_CODE_SIMPLE=1 ANTHROPIC_MODEL="wrong-model" \
      "$HERE/ollama-do" --transport anthropic --root "$ROOT" --work "$WORKDIR" "$@" \
      >"$WORKDIR/out" 2>&1 ) || RC=$?
}

ROOT="$(mkrepo)"; anthropic_run write --task "$TASKDIR/task.md"
[ "$RC" = "0" ] && [ "$(verdict task)" = "OK" ] \
  && ok "anthropic transport runs with OLLAMA_API_KEY unset" \
  || bad "anthropic transport without a key (rc=$RC, $(verdict task)): $(tail -3 "$WORKDIR/out")"
leaked="$(sed -n '/^--- env$/,/^--- argv$/p' "$WORKDIR/trace" 2>/dev/null \
  | grep -E '^(ANTHROPIC_BASE_URL|ANTHROPIC_AUTH_TOKEN|ANTHROPIC_MODEL|CLAUDE_CODE_SIMPLE)=' || true)"
[ -s "$WORKDIR/trace" ] && [ -z "$leaked" ] \
  && ok "anthropic transport strips inherited endpoint/auth/model overrides" \
  || bad "anthropic transport leaked: ${leaked:-no trace written}"
grep -qx "claude-opus-5-5" "$WORKDIR/trace" 2>/dev/null \
  && ok "anthropic transport defaults to claude-opus-5-5" \
  || bad "anthropic default model not claude-opus-5-5"
grep -qx -- "--setting-sources" "$WORKDIR/trace" 2>/dev/null \
  && ok "anthropic transport keeps the settings isolation" \
  || bad "anthropic transport dropped --setting-sources"

apikey() { sed -n '/^--- env$/,/^--- argv$/p' "$WORKDIR/trace" 2>/dev/null | grep -c '^ANTHROPIC_API_KEY=' || true; }
ROOT="$(mkrepo)"; ANTHROPIC_API_KEY=k-inherited anthropic_run write --task "$TASKDIR/task.md"
[ "$(apikey)" = 0 ] && ok "an inherited ANTHROPIC_API_KEY does not displace the login" \
  || bad "anthropic transport passed an inherited ANTHROPIC_API_KEY through"
ROOT="$(mkrepo)"; ANTHROPIC_API_KEY=k-chosen ANTHROPIC_USE_API_KEY=1 anthropic_run write --task "$TASKDIR/task.md"
[ "$(apikey)" = 1 ] && ok "  unless ANTHROPIC_USE_API_KEY=1 chooses it" \
  || bad "ANTHROPIC_USE_API_KEY=1 did not hand the key to claude"

ROOT="$(mkrepo)"; anthropic_run write --map "$TASKDIR" --schema '{}'
[ "$RC" = "1" ] && grep -qi "map" "$WORKDIR/out" \
  && ok "anthropic transport refuses --map (Ollama-direct API)" \
  || bad "anthropic --map not refused (rc=$RC)"

ROOT="$(mkrepo)"; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/ollama-do-work.XXXXXX")"; RC=0
OLLAMA_API_KEY="test-key" OLLAMA_DO_BIN="$HERE/stub-claude" OLLAMA_DO_SKIP_SHOW_CHECK=1 \
  "$HERE/ollama-do" --transport carrier-pigeon --root "$ROOT" --work "$WORKDIR" \
  --task "$TASKDIR/task.md" >"$WORKDIR/out" 2>&1 || RC=$?
[ "$RC" = "1" ] && grep -qi "transport" "$WORKDIR/out" \
  && ok "unknown --transport refuses" || bad "unknown transport accepted (rc=$RC)"

# --- config file -------------------------------------------------------------
printf 'OLLAMA_API_KEY=from-config\n' > "$REVIEW_SKILLS_CONFIG"; chmod 600 "$REVIEW_SKILLS_CONFIG"
ROOT="$(mkrepo)"; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/ollama-do-work.XXXXXX")"; RC=0
( unset OLLAMA_API_KEY; STUB_MODE=write STUB_ROOT="$ROOT" \
  OLLAMA_DO_BIN="$HERE/stub-claude" OLLAMA_DO_SKIP_SHOW_CHECK=1 OLLAMA_DO_LEDGER="$WORKDIR/ledger" \
    "$HERE/ollama-do" --root "$ROOT" --work "$WORKDIR" --task "$TASKDIR/task.md" >"$WORKDIR/out" 2>&1 ) || RC=$?
[ "$RC" = 0 ] && [ "$(verdict task)" = OK ] \
  && ok "OLLAMA_API_KEY from the config file satisfies the prerequisite" || bad "key from config (rc=$RC)"
NOREPODIR="$(mktemp -d "${TMPDIR:-/tmp}/ollama-do-norepo.XXXXXX")"; echo "x" > "$NOREPODIR/a.txt"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/ollama-do-work.XXXXXX")"; RC=0
( unset OLLAMA_API_KEY; OLLAMA_DO_SKIP_SHOW_CHECK=1 OLLAMA_MAP_STUB=extract \
  "$HERE/ollama-do" --map "$NOREPODIR" --schema '{"type":"object"}' --work "$WORKDIR" >"$WORKDIR/out" 2>&1 ) || RC=$?
[ "$RC" = 0 ] && [ -s "$WORKDIR/results.json" ] \
  && ok "--map passes the config file's key to map.py" || bad "--map key from config (rc=$RC)"
: > "$REVIEW_SKILLS_CONFIG"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
