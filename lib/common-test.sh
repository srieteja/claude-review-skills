#!/usr/bin/env bash
# Unit checks for lib/common.sh: config loading, store layout, fix authors, PR references.
set -euo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SB="$(mktemp -d "${TMPDIR:-/tmp}/common-test.XXXXXX")"; trap 'rm -rf "$SB"' EXIT
fail=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=1; }
check() { desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }
# in_lib <cmd...>: runs in a clean shell with only HOME and PATH, common.sh sourced.
in_lib() { env -i HOME="$SB/home" PATH="$PATH" ${CFG:+REVIEW_SKILLS_CONFIG="$CFG"} "${EXTRA[@]+"${EXTRA[@]}"}" \
             bash -c '. "$1"; shift; eval "$*"' _ "$HERE/common.sh" "$@"; }
is() { test "$(in_lib "$1")" = "$2"; }
EXTRA=()

echo "config"
CFG="$SB/config.env"
cat > "$CFG" <<'E'
# comment
PR_REVIEW_FIX_AUTHORS=alice,bob

export PR_REVIEW_JOBS=7
PR_REVIEW_FINDERS="anthropic:claude-opus-5-5@max agy:gemini-3.8-flash-high"
PEER_REVIEW_INTENSE='0'
PR_REVIEW_DIR=~/rv
PR_REVIEW_INTENSE_DIR="~/rv i"
OLLAMA_API_KEY=k-secret
PATH=/nowhere
LD_PRELOAD=/evil.so
not a line
E
chmod 600 "$CFG"
check "a key from the file is set" is 'load_config; echo "$PR_REVIEW_JOBS"' 7
check "export prefix is accepted" is 'load_config; bash -c "echo \$PR_REVIEW_JOBS"' 7
check "double quotes are stripped" is 'load_config; echo "$PR_REVIEW_FINDERS"' \
  "anthropic:claude-opus-5-5@max agy:gemini-3.8-flash-high"
check "a leading ~/ is the home directory" is 'load_config; echo "$PR_REVIEW_DIR|$PR_REVIEW_INTENSE_DIR"' "$SB/home/rv|$SB/home/rv i"
check "single quotes are stripped" is 'load_config; echo "$PEER_REVIEW_INTENSE"' 0
check "a key outside the toolkit's prefixes is ignored" is 'load_config; echo "$PATH" | grep -c nowhere || true' 0
check "LD_PRELOAD is ignored" is 'load_config; echo "${LD_PRELOAD:-unset}"' unset
check "a secret is set for this shell" is 'load_config; echo "$OLLAMA_API_KEY"' k-secret
check "a secret is not exported to children" is 'load_config; bash -c "echo \${OLLAMA_API_KEY:-unset}"' unset
EXTRA=(PR_REVIEW_JOBS=2 PR_REVIEW_FIX_AUTHORS=)
check "the environment beats the file" is 'load_config; echo "$PR_REVIEW_JOBS"' 2
check "an empty environment value beats the file too" is 'load_config; echo "[$PR_REVIEW_FIX_AUTHORS]"' "[]"
EXTRA=()
check "no file is not an error" is 'REVIEW_SKILLS_CONFIG=/nonexistent; load_config; echo ok' ok
check "the default file is under XDG_CONFIG_HOME" \
  is 'unset REVIEW_SKILLS_CONFIG; XDG_CONFIG_HOME=/x; config_file' /x/review-skills/config.env
check "XDG_CONFIG_HOME defaults to ~/.config" \
  is 'unset REVIEW_SKILLS_CONFIG; config_file' "$SB/home/.config/review-skills/config.env"
chmod 644 "$CFG"
check "a group/world-readable config is refused" is 'load_config 2>&1; echo rc=$?' \
  "review-skills: $CFG is readable by others -- chmod 600 it (it holds API keys)"
check "  and the shell exits" is '(load_config) 2>/dev/null; echo rc=$?' rc=1
chmod 600 "$CFG"
CFG=""

echo "credentials"
CFG="$SB/keys.env"
cat > "$CFG" <<'E'
ANTHROPIC_API_KEY=cfg-anthropic
ANTHROPIC_USE_API_KEY=1
REVIEW_SKILLS_MODELS=manual
ANTHROPIC_BASE_URL=https://evil.example
GEMINI_API_KEY=cfg-gemini
E
chmod 600 "$CFG"
check "ANTHROPIC_API_KEY is taken, as a secret" is 'load_config; echo "$ANTHROPIC_API_KEY ${ANTHROPIC_USE_API_KEY:-}"' "cfg-anthropic 1"
check "REVIEW_SKILLS_MODELS is taken" is 'load_config; echo "${REVIEW_SKILLS_MODELS:-}"' manual
check "ANTHROPIC_BASE_URL is not, or config.env could reroute reviews" is 'load_config; echo "${ANTHROPIC_BASE_URL:-unset}"' unset
check "GEMINI_API_KEY is not: agy signs in, it reads no key" is 'load_config; echo "${GEMINI_API_KEY:-unset}"' unset
envkeys='env | grep -E "^(ANTHROPIC_API_KEY|OLLAMA_API_KEY|GEMINI_API_KEY|ANTHROPIC_AUTH_TOKEN|CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_BASE_URL)=" | sort | tr "\n" " "'
check "with ANTHROPIC_USE_API_KEY=1, anthropic_env hands claude the config key and nothing else" \
  is "load_config; anthropic_env $envkeys" "ANTHROPIC_API_KEY=cfg-anthropic "
CFG=""
EXTRA=(ANTHROPIC_API_KEY=k-env OLLAMA_API_KEY=k-oll GEMINI_API_KEY=k-gem CLAUDE_CODE_OAUTH_TOKEN=k-oauth ANTHROPIC_BASE_URL=https://evil.example ANTHROPIC_AUTH_TOKEN=k-tok)
check "without it, anthropic_env strips every key but the login's OAuth token" \
  is "anthropic_env $envkeys" "CLAUDE_CODE_OAUTH_TOKEN=k-oauth "
check "ANTHROPIC_USE_API_KEY=1 with no key is refused" \
  is 'unset ANTHROPIC_API_KEY; ANTHROPIC_USE_API_KEY=1; anthropic_env true 2>/dev/null; echo rc=$?' rc=1
check "ollama_env hands claude the ollama key as its Bearer token only" \
  is "MODEL=m; ollama_env $envkeys" "ANTHROPIC_AUTH_TOKEN=k-oll ANTHROPIC_BASE_URL=https://ollama.com "
check "agy_env strips every key" is "agy_env $envkeys" ""
EXTRA=()

echo "entry points"
mkdir -p "$SB/linked"; ln -s "$HERE/../skills/pr-review" "$SB/linked/pr-review"
check "an entry point runs through a directory symlink, as installed" \
  sh -c '"$1/linked/pr-review/pr-review.sh" --help 2>&1 | grep -q "^usage:"' _ "$SB"

echo "stores"
check "the store defaults to ~/.reviews" is 'review_store' "$SB/home/.reviews"
check "PR_REVIEW_DIR moves it" is 'PR_REVIEW_DIR=/s; review_store' /s
check "the intense store defaults inside it" is 'intense_store' "$SB/home/.reviews/_intense"
check "  and follows PR_REVIEW_DIR" is 'PR_REVIEW_DIR=/s; intense_store' /s/_intense
check "PR_REVIEW_INTENSE_DIR moves it on its own" is 'PR_REVIEW_DIR=/s; PR_REVIEW_INTENSE_DIR=/i; intense_store' /i
check "a review lives at <store>/<author>/<repo>/<N>" is 'review_dir /s alice widgets 7' /s/alice/widgets/7
check "  with a bot's app/ prefix dropped" is 'review_dir /s app/dependabot widgets 7' /s/dependabot/widgets/7
check "the repo name comes from a PR URL" is 'repo_of_url https://github.com/acme/widgets/pull/7' widgets

echo "fix authors"
check "nobody is a fix author by default" is 'is_fix_author alice && echo yes || echo no' no
EXTRA=(PR_REVIEW_FIX_AUTHORS="alice, Bob")
check "a listed author is one, case-blind" is 'is_fix_author BOB && echo yes || echo no' yes
check "  an unlisted one is not" is 'is_fix_author carol && echo yes || echo no' no
EXTRA=(PEER_REVIEW_FIX_AUTHORS=alice)
check "PEER_REVIEW_FIX_AUTHORS is an alias" is 'is_fix_author alice && echo yes || echo no' yes
EXTRA=()

echo "per-PR lock"
U=https://github.com/acme/widgets/pull/7
EXTRA=(REVIEW_SKILLS_LOCK_DIR="$SB/locks")
check "the lock dir defaults under XDG_STATE_HOME" \
  is 'unset REVIEW_SKILLS_LOCK_DIR; XDG_STATE_HOME=/st; lock_root' /st/review-skills/locks
check "a free PR is locked" is "pr_lock $U && ls \"\$(lock_root)\" | wc -l | tr -d ' '" 1
check "  and released" is "pr_lock $U; pr_unlock; ls \"\$(lock_root)\" | wc -l | tr -d ' '" 0
in_lib "pr_lock $U; echo \$\$ > '$SB/held.tmp'; mv '$SB/held.tmp' '$SB/held'; sleep 30" >/dev/null 2>&1 &
while [ ! -s "$SB/held" ]; do sleep 0.1; done; holder="$(cat "$SB/held")"
check "a PR held by a live run is refused" \
  is "(pr_lock $U) 2>&1 | grep -c 'already being reviewed'" 1
check "  with a non-zero exit" is "(pr_lock $U) 2>/dev/null; echo rc=\$?" rc=1
check "  another PR is not blocked" is 'pr_lock https://github.com/acme/widgets/pull/8 && echo ok' ok
check "  nor the same number in another repo" is 'pr_lock https://github.com/acme/gadgets/pull/7 && echo ok' ok
check "a child of the holder passes through" \
  is "REVIEW_SKILLS_LOCK_HELD=\"\$(lock_path $U)\" pr_lock $U && echo ok" ok
kill "$holder" 2>/dev/null; while kill -0 "$holder" 2>/dev/null; do sleep 0.1; done
check "a lock left by a dead run is taken over" is "pr_lock $U && echo ok" ok
EXTRA=()

echo "PR references"
ref() { is "parse_pr_ref '$1' && echo \"\$PR \$PR_REPO\"" "$2"; }
check "a number" ref 7 "7 "
check "#N" ref '#7' "7 "
check "owner/repo#N" ref 'acme/widgets#7' "7 acme/widgets"
check "a PR URL" ref https://github.com/acme/widgets/pull/7 "7 acme/widgets"
check "a PR URL with a tab path" ref https://github.com/acme/widgets/pull/7/files "7 acme/widgets"
check "an enterprise host URL" ref https://git.example.com/acme/widgets/pull/12 "12 acme/widgets"
check "junk is refused" is 'parse_pr_ref 7x && echo yes || echo no' no
check "an issue URL is refused" is 'parse_pr_ref https://github.com/acme/widgets/issues/7 && echo yes || echo no' no
check "owner/repo with no number is refused" is 'parse_pr_ref acme/widgets# && echo yes || echo no' no

[ "$fail" -eq 0 ] && printf '\n\033[32mall lib checks passed\033[0m\n' || printf '\n\033[31mlib checks FAILED\033[0m\n'
exit $fail
