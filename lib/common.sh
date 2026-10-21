# shellcheck shell=bash
# common.sh -- sourced by every entry point, never executed. Config loading, the review store
# layout, fix authors, PR references and (transport-env.sh) the per-transport environments, in
# one place so every script agrees on them.
#
#   HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$HERE/../../lib/common.sh"
#
# Entry points resolve through a symlinked skill directory (how they are installed), not a
# symlink to the script file itself.
#
# Targets bash 3.2 (macOS system bash).

. "$(dirname "${BASH_SOURCE[0]}")/transport-env.sh"
. "$(dirname "${BASH_SOURCE[0]}")/models.sh"

# ------------------------------------------------------------------------------ config
# config.env holds KEY=VALUE lines (# comments, an optional `export `, optional quotes, a
# leading ~/ for the home directory). Only
# keys this toolkit reads are taken. The environment beats the file, an empty value included.
# Secrets (*_API_KEY, *_TOKEN) are set for this shell only; everything else is exported for
# the scripts this one runs. A file readable by group or others is refused.
config_file() { printf '%s' "${REVIEW_SKILLS_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/review-skills/config.env}"; }

load_config() {
  local f line key val
  f="$(config_file)"
  [ -r "$f" ] || return 0
  if [ -n "$(find "$f" \( -perm -040 -o -perm -004 \) -print 2>/dev/null)" ]; then
    printf 'review-skills: %s is readable by others -- chmod 600 it (it holds API keys)\n' "$f" >&2
    exit 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line#export }"
    case "$line" in
      PR_REVIEW_*=*|PEER_REVIEW_*=*|OLLAMA_*=*|AGY_DO_*=*|AUTOFIX_MODEL=*|AUTOFIX_EFFORT=*|AUTOFIX_BUDGET=*) ;;
      ANTHROPIC_API_KEY=*|ANTHROPIC_USE_API_KEY=*|REVIEW_SKILLS_MODELS=*) ;;
      *) continue ;;
    esac
    key="${line%%=*}"; val="${line#*=}"
    case "$key" in *[!A-Za-z0-9_]*) continue ;; esac
    case "$val" in \"*\") val="${val#\"}"; val="${val%\"}" ;; \'*\') val="${val#\'}"; val="${val%\'}" ;; esac
    case "$val" in "~/"*) val="$HOME/${val#"~/"}" ;; esac
    [ -z "${!key+set}" ] || continue
    case "$key" in
      *_API_KEY|*_TOKEN) printf -v "$key" '%s' "$val" ;;
      *) export "$key=$val" ;;
    esac
  done < "$f"
}

# ------------------------------------------------------------------------------ stores
# Every review lives at <store>/<author>/<repo>/<N>. The intense preset keeps its own store
# so a regular review of the same PR is never overwritten; `_` cannot begin a GitHub login.
review_store()  { printf '%s' "${PR_REVIEW_DIR:-$HOME/.reviews}"; }
intense_store() { printf '%s' "${PR_REVIEW_INTENSE_DIR:-$(review_store)/_intense}"; }
review_dir()    { printf '%s/%s/%s/%s' "$1" "${2#app/}" "$3" "$4"; }
repo_of_url()   { local u="${1%/pull/*}"; printf '%s' "${u##*/}"; }

# ---------------------------------------------------------------------- per-PR lock
# One run per PR at a time, whatever the store. The lock is a symlink named for the PR's URL
# whose target is the holder's pid: created atomically with its payload. A child of the
# holder (REVIEW_SKILLS_LOCK_HELD, exported) passes through; a lock whose pid is gone is
# taken over.
lock_root() { printf '%s' "${REVIEW_SKILLS_LOCK_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/review-skills/locks}"; }
lock_path() { printf '%s/%s' "$(lock_root)" "$(printf '%s' "${1#*://}" | tr -c 'A-Za-z0-9._-' '_')"; }

# pr_lock <pr-url>: takes the lock or exits 1 naming the live holder. Sets PR_LOCK.
pr_lock() {
  local l holder
  l="$(lock_path "$1")"
  [ "${REVIEW_SKILLS_LOCK_HELD:-}" != "$l" ] || return 0
  mkdir -p "$(lock_root)"
  if ! ln -s "$$" "$l" 2>/dev/null; then
    holder="$(readlink "$l" 2>/dev/null)" || holder=""
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
      printf 'review-skills: %s is already being reviewed (pid %s) -- wait for it, or remove %s if that pid is not a review\n' \
        "$1" "$holder" "$l" >&2
      exit 1
    fi
    rm -f "$l"
    ln -s "$$" "$l" 2>/dev/null && [ "$(readlink "$l")" = "$$" ] || {
      printf 'review-skills: lost the race for %s -- another run took it\n' "$1" >&2; exit 1; }
  fi
  PR_LOCK="$l"; REVIEW_SKILLS_LOCK_HELD="$l"; export REVIEW_SKILLS_LOCK_HELD
}
pr_unlock() { [ -z "${PR_LOCK:-}" ] || rm -f "$PR_LOCK"; PR_LOCK=""; }

# ------------------------------------------------------------------------- fix authors
# is_fix_author <login>: the login is on PR_REVIEW_FIX_AUTHORS (alias PEER_REVIEW_FIX_AUTHORS;
# space- or comma-separated, case-blind; empty, the default, for none).
is_fix_author() {
  local a who
  who="$(printf '%s' "${1#app/}" | tr '[:upper:]' '[:lower:]')"
  for a in $(printf '%s' "${PR_REVIEW_FIX_AUTHORS-${PEER_REVIEW_FIX_AUTHORS-}}" | tr ',' ' '); do
    [ "$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')" != "$who" ] || return 0
  done
  return 1
}

# ----------------------------------------------------------------------- PR references
# parse_pr_ref <ref>: sets PR and PR_REPO (owner/repo; empty for a bare number) from N, #N,
# owner/repo#N or a pull request URL on any host. Returns 1 on anything else.
parse_pr_ref() {
  local r="$1" path
  PR=""; PR_REPO=""
  case "$r" in
    http://*/pull/*|https://*/pull/*)
      path="${r#*://*/}"
      PR_REPO="${path%%/pull/*}"; r="${path#*/pull/}"; r="${r%%/*}"
      case "$PR_REPO" in */*/*|/*|*/) return 1 ;; */?*) ;; *) return 1 ;; esac ;;
    ?*/?*\#*) PR_REPO="${r%%#*}"; r="${r#*#}"
      case "$PR_REPO" in */*/*) return 1 ;; esac ;;
    \#*) r="${r#\#}" ;;
  esac
  case "$r" in ''|*[!0-9]*) PR_REPO=""; return 1 ;; esac
  PR="$r"
}

# check_pr_repo: dies unless PR_REPO is empty or the repository cwd's gh resolves to. Callers
# define die().
check_pr_repo() {
  local here
  [ -n "$PR_REPO" ] || return 0
  here="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || here=""
  [ "$(printf '%s' "$PR_REPO" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$here" | tr '[:upper:]' '[:lower:]')" ] \
    || die "#$PR is in $PR_REPO, but this checkout is ${here:-not a GitHub repo gh knows} -- run from a clone of $PR_REPO"
}
