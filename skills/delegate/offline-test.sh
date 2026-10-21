#!/usr/bin/env bash
# offline-test.sh -- exercise agy-do against a stubbed executor. Spends nothing.
#
# The happy path is the least interesting case here. What earns trust is that a change nobody
# made is never reported as success, and that a write into the guarded repo is always caught --
# including the git-metadata kind that `git status` cannot see.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REVIEW_SKILLS_CONFIG="$(mktemp -d "${TMPDIR:-/tmp}/agy-do-cfg.XXXXXX")/none"
PASS=0; FAIL=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

mkrepo() {
  R="$(mktemp -d "${TMPDIR:-/tmp}/agy-do-test.XXXXXX")/repo"
  mkdir -p "$R"; git -C "$R" init -q
  echo "original" > "$R/tracked.txt"; echo "shared" > "$R/shared.txt"
  git -C "$R" add -A >/dev/null
  git -C "$R" -c user.email=t -c user.name=t commit -qm init >/dev/null
  echo "$R"
}

run() { # mode task-args... -> sets RC, WORKDIR
  mode="$1"; shift
  WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/agy-do-work.XXXXXX")"
  RC=0
  STUB_MODE="$mode" STUB_ROOT="$ROOT" \
  AGY_DO_BIN="$HERE/stub-agy" AGY_DO_LEDGER="$WORKDIR/ledger" \
    "$HERE/agy-do" --root "$ROOT" --work "$WORKDIR" "$@" >"$WORKDIR/out" 2>&1 || RC=$?
}

verdict() { cat "$WORKDIR/$1.verdict" 2>/dev/null || echo MISSING; }

echo "agy-do offline tests"
TASKDIR="$(mktemp -d)"; echo "do the thing" > "$TASKDIR/task.md"

# --- verdict semantics ----------------------------------------------------
ROOT="$(mkrepo)"; run write --task "$TASKDIR/task.md"
[ "$(verdict task)" = "OK" ] && [ -s "$WORKDIR/task.patch" ] \
  && ok "ordinary success -> OK with a patch" || bad "ordinary success (got $(verdict task))"
grep -q "created.txt" "$WORKDIR/task.patch" 2>/dev/null \
  && ok "new files appear in the patch" || bad "new files missing from the patch"

ROOT="$(mkrepo)"; run noop --task "$TASKDIR/task.md"
[ "$(verdict task)" = "NO-OP" ] \
  && ok "success with no diff -> NO-OP, not a pass" || bad "no-op (got $(verdict task))"

ROOT="$(mkrepo)"; run commit --task "$TASKDIR/task.md"
[ "$(verdict task)" = "OK" ] && grep -q "created.txt" "$WORKDIR/task.patch" 2>/dev/null \
  && ok "work committed inside the worktree -> OK, full patch" \
  || bad "committed work (got $(verdict task)) -- diffing --cached instead of the base SHA?"

ROOT="$(mkrepo)"; run partial --task "$TASKDIR/task.md"
[ "$(verdict task)" = "PARTIAL" ] \
  && ok "died mid-write -> PARTIAL, not FAILED" || bad "partial (got $(verdict task))"

ROOT="$(mkrepo)"; run ctrlchars --task "$TASKDIR/task.md"
[ "$(verdict task)" = "OK" ] && [ -s "$WORKDIR/task.conv" ] \
  && ok "control chars in the envelope -> salvaged, id captured (jq refuses this)" \
  || bad "control-char envelope (got $(verdict task))"

ROOT="$(mkrepo)"; run unparseable --task "$TASKDIR/task.md"
[ "$(verdict task)" = "FAILED" ] \
  && ok "no JSON at all -> FAILED, never a silent pass" || bad "unparseable (got $(verdict task))"

ROOT="$(mkrepo)"; run preamble --task "$TASKDIR/task.md"
[ "$(verdict task)" = "OK" ] \
  && ok "task is wrapped in the non-interactive preamble, and survives wrapping" \
  || bad "preamble not applied (got $(verdict task)) -- executor will answer conversationally"

# --- ask mode -------------------------------------------------------------
# The stub exits 9 on a bare question and 8 if edit mode leaks in, so an OK here means the
# preamble arrived and the read-only posture held.
ROOT="$(mkrepo)"
ASKTREE="$(dirname "$ROOT")/asktree"; git -C "$ROOT" worktree add -q --detach "$ASKTREE" HEAD
run ask --ask "where is X handled?" --tree "$ASKTREE"
[ "$(verdict ask)" = "OK" ] \
  && ok "ask is wrapped in its own preamble and stays read-only" \
  || bad "ask preamble/read-only (got $(verdict ask)) -- bare question risks a clarifying reply"
[ -s "$WORKDIR/ask.answer" ] && [ ! -s "$WORKDIR/ask.patch" ] \
  && ok "ask returns an answer and no patch" || bad "ask produced a patch or no answer"

# Cold ask: no --tree. The standing rule says to ask before grepping, and a fresh session has
# no warm worktree -- so requiring one would make the rule unfollowable exactly when it pays.
ROOT="$(mkrepo)"; run ask --ask "where is X handled?"
[ "$(verdict ask)" = "OK" ] \
  && ok "ask with no --tree cuts its own worktree" || bad "cold ask (got $(verdict ask))"

# --- the guard ------------------------------------------------------------
ROOT="$(mkrepo)"; run escape_untracked --task "$TASKDIR/task.md"
[ "$RC" = "3" ] && [ -e "$WORKDIR/escaped/stub-scratch.tmp" ] && [ ! -e "$ROOT/stub-scratch.tmp" ] \
  && ok "scratch into the repo -> exit 3 and quarantined" || bad "untracked escape (rc=$RC)"

ROOT="$(mkrepo)"; run escape_tracked --task "$TASKDIR/task.md"
[ "$RC" = "1" ] && grep -q "tampered" "$ROOT/tracked.txt" \
  && ok "tracked file touched -> exit 1, left in place" || bad "tracked escape (rc=$RC)"

ROOT="$(mkrepo)"; run escape_git --task "$TASKDIR/task.md"
[ "$RC" = "1" ] \
  && ok "git metadata mutated -> exit 1 (porcelain alone misses this)" || bad "git escape (rc=$RC)"

# --- fan-out --------------------------------------------------------------
FAN="$(mktemp -d)"; echo "a" > "$FAN/collide_a.md"; echo "b" > "$FAN/collide_b.md"
ROOT="$(mkrepo)"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/agy-do-work.XXXXXX")"; RC=0
STUB_ROOT="$ROOT" AGY_DO_BIN="$HERE/stub-agy" AGY_DO_LEDGER="$WORKDIR/ledger" \
  env STUB_MODE=collide_a "$HERE/agy-do" --root "$ROOT" --work "$WORKDIR" \
      --tasks "$FAN" --jobs 2 >"$WORKDIR/out" 2>&1 || RC=$?
grep -q "shared.txt" "$WORKDIR/out" && grep -qi "same files" "$WORKDIR/out" \
  && ok "overlapping slices -> collision reported" || bad "collision not reported"
[ "$(verdict collide_a)" = "OK" ] && [ "$(verdict collide_b)" = "OK" ] \
  && ok "fan-out settles every slice" || bad "fan-out verdicts (a=$(verdict collide_a) b=$(verdict collide_b))"

# --- ledger ---------------------------------------------------------------
[ -s "$WORKDIR/ledger" ] && [ "$(awk -F'\t' '{print NF}' "$WORKDIR/ledger" | sort -u)" = "11" ] \
  && ok "ledger records one 11-field row per task" || bad "ledger malformed"
[ "$(awk -F'\t' '$5=="OK"{print $11}' "$WORKDIR/ledger" | sort -u)" = "1" ] \
  && ok "files-changed count reaches the last column" || bad "files-changed column dropped"
grep -q "700" "$WORKDIR/ledger" \
  && ok "cache-read tokens recorded" || bad "cache-read tokens missing from ledger"

# --- config file -------------------------------------------------------------
CFGDIR="$(mktemp -d "${TMPDIR:-/tmp}/agy-do-cfg.XXXXXX")"
printf 'AGY_DO_BIN=%s\n' "$HERE/stub-agy" > "$CFGDIR/config.env"; chmod 600 "$CFGDIR/config.env"
mkdir -p "$CFGDIR/bin"; printf '#!/bin/sh\nexit 97\n' > "$CFGDIR/bin/agy"; chmod +x "$CFGDIR/bin/agy"
ROOT="$(mkrepo)"; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/agy-do-work.XXXXXX")"; RC=0
( unset AGY_DO_BIN; PATH="$CFGDIR/bin:$PATH" STUB_MODE=write STUB_ROOT="$ROOT" REVIEW_SKILLS_CONFIG="$CFGDIR/config.env" \
  AGY_DO_LEDGER="$WORKDIR/ledger" \
    "$HERE/agy-do" --root "$ROOT" --work "$WORKDIR" --task "$TASKDIR/task.md" >"$WORKDIR/out" 2>&1 ) || RC=$?
[ "$RC" = 0 ] && [ "$(verdict task)" = OK ] \
  && ok "AGY_DO_* settings come from the config file" || bad "agy-do config file (rc=$RC)"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
