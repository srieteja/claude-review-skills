# shellcheck shell=bash
# models.sh -- sourced by common.sh. Which finders and refuter a review runs, from the ranked
# rows in models.tsv and the backends this machine can reach:
#
#   anthropic  claude signed in (`claude auth status`), or ANTHROPIC_USE_API_KEY=1 with a key
#   agy        agy signed in (`agy models` lists what it serves)
#   ollama     OLLAMA_API_KEY that ollama.com accepts (/v1/models is open to anyone, so the
#              key is proven with a 1-token call)
#
# REVIEW_SKILLS_MODELS=manual skips the probes and takes every preset's first rows. A model
# list that answered is cached for a day under models_cache; one that did not is asked again.
#
# Targets bash 3.2 (macOS system bash).

MODELS_TSV="$(dirname "${BASH_SOURCE[0]}")/models.tsv"
models_cache() { printf '%s' "${REVIEW_SKILLS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/review-skills}"; }

# model_family <transport:model[@effort]>: anthropic, google, or the model name's first word.
model_family() {
  local m="${1#*:}"; m="${m%@*}"; m="${m%%:*}"
  case "$m" in
    claude-*) printf anthropic ;;
    gemini*|gemma*) printf google ;;
    *) printf '%s' "${m%%-*}" ;;
  esac
}

# ollama_answers <model>: a 1-token call over the endpoint ollama_env routes claude to, with
# the same Bearer auth: reachability, key and model in one go. The key goes in on stdin as
# curl config, never on argv. Sets OLLAMA_HTTP to the status, "none" if there was no answer.
ollama_answers() {
  OLLAMA_HTTP=none
  [ -n "${OLLAMA_API_KEY:-}" ] || return 1
  OLLAMA_HTTP="$(printf 'header = "Authorization: Bearer %s"\n' "$OLLAMA_API_KEY" \
    | curl -sS -K - -o /dev/null -w '%{http_code}' --max-time 10 \
        -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' \
        -d "{\"model\":\"$1\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}" \
        https://ollama.com/v1/messages 2>/dev/null)" || OLLAMA_HTTP="${OLLAMA_HTTP:-none}"
  [ "$OLLAMA_HTTP" = 200 ]
}

anthropic_ready() {
  if [ "${ANTHROPIC_USE_API_KEY:-}" = 1 ]; then [ -n "${ANTHROPIC_API_KEY:-}" ]; return; fi
  anthropic_env claude auth status 2>/dev/null | jq -e '.loggedIn == true' >/dev/null 2>&1
}

agy_list() {
  local out
  out="$(agy_env agy models 2>/dev/null)" || return 1
  printf '%s\n' "$out" | awk -F'\t' 'NF > 1 { print $1 }'
}

ollama_list() {
  local ids m
  [ -n "${OLLAMA_API_KEY:-}" ] || return 1
  ids="$(curl -sS --max-time 10 https://ollama.com/v1/models 2>/dev/null | jq -r '.data[].id' 2>/dev/null)" || return 1
  for m in $(awk -F'\t' '$3 ~ /^ollama:/ { sub(/^ollama:/, "", $3); sub(/@.*/, "", $3); print $3 }' "$MODELS_TSV"); do
    printf '%s\n' "$ids" | grep -qxF "$m" || continue
    ollama_answers "$m" || return 1
    printf '%s\n' "$ids"; return 0
  done
  return 1
}

# models_of <agy|ollama>: the models that transport serves, from a cache under a day old or
# asked afresh. Only a list that answered is cached.
models_of() {
  local f list
  f="$(models_cache)/$1.models"
  if [ -s "$f" ] && [ -n "$(find "$f" -mmin -1440 2>/dev/null)" ]; then cat "$f"; return 0; fi
  rm -f "$f"
  list="$("$1_list")" && [ -n "$list" ] || return 1
  mkdir -p "$(models_cache)"
  printf '%s\n' "$list" > "$f.$$" && mv "$f.$$" "$f"
  printf '%s\n' "$list"
}

_spec_reachable() {
  local t="${1%%:*}" m="${1#*:}"
  m="${m%@*}"
  [ "$_MODELS_MANUAL" = 0 ] || return 0
  case "$t" in
    anthropic) [ "$CLAUDE_OK" = 1 ] ;;
    agy) printf '%s\n' "$_MODELS_AGY" | grep -qxF "$m" ;;
    ollama) printf '%s\n' "$_MODELS_OLLAMA" | grep -qxF "$m" ;;
    *) return 1 ;;
  esac
}

# _rows <preset> <role>: that preset's specs for the role, best first.
_rows() { awk -F'\t' -v p="$1" -v r="$2" '$1 == p && $2 == r { print $3 }' "$MODELS_TSV"; }

# resolve_models <regular|intense>: sets RESOLVED_FINDERS (space-separated specs),
# RESOLVED_REFUTER, SAME_FAMILY (1: the refuter shares a family with a finder) and CLAUDE_OK
# (1: claude can run, for the brief). A pin is taken as given:
#   regular  PR_REVIEW_FINDERS, else PR_REVIEW_TRANSPORT/S1_MODEL (alias OPUS_MODEL)/S1_EFFORT;
#            PR_REVIEW_REFUTER, else agy:$PR_REVIEW_GEMINI_MODEL
#   intense  PR_REVIEW_INTENSE_FINDERS, PR_REVIEW_INTENSE_REFUTER
# Returns 1, naming every way in, when no finder is reachable.
resolve_models() {
  local fpin rpin max spec t seen=" " n=0
  case "$1" in
    regular)
      fpin="${PR_REVIEW_FINDERS:-}"
      if [ -z "$fpin" ] && [ -n "${PR_REVIEW_TRANSPORT:-}${PR_REVIEW_S1_MODEL:-}${PR_REVIEW_OPUS_MODEL:-}${PR_REVIEW_S1_EFFORT:-}" ]; then
        fpin="${PR_REVIEW_TRANSPORT:-anthropic}:${PR_REVIEW_S1_MODEL:-${PR_REVIEW_OPUS_MODEL:-claude-opus-5-5}}@${PR_REVIEW_S1_EFFORT:-xhigh}"
      fi
      rpin="${PR_REVIEW_REFUTER:-${PR_REVIEW_GEMINI_MODEL:+agy:$PR_REVIEW_GEMINI_MODEL}}"; max=1 ;;
    intense)
      fpin="${PR_REVIEW_INTENSE_FINDERS:-}"; rpin="${PR_REVIEW_INTENSE_REFUTER:-}"; max=2 ;;
    *) printf 'review-skills: unknown preset: %s\n' "$1" >&2; return 1 ;;
  esac
  case "${REVIEW_SKILLS_MODELS:-auto}" in
    manual) _MODELS_MANUAL=1; CLAUDE_OK=1 ;;
    auto)
      _MODELS_MANUAL=0
      if anthropic_ready; then CLAUDE_OK=1; else CLAUDE_OK=0; fi
      _MODELS_AGY=""; _MODELS_OLLAMA=""
      if [ -z "$fpin" ] || [ -z "$rpin" ]; then
        _MODELS_AGY="$(models_of agy)" || _MODELS_AGY=""
        _MODELS_OLLAMA="$(models_of ollama)" || _MODELS_OLLAMA=""
      fi ;;
    *) printf 'review-skills: REVIEW_SKILLS_MODELS is auto or manual, not %s\n' "$REVIEW_SKILLS_MODELS" >&2; return 1 ;;
  esac

  RESOLVED_FINDERS="$fpin"
  if [ -z "$fpin" ]; then
    for spec in $(_rows "$1" finder); do
      t="${spec%%:*}"
      case "$seen" in *" $t "*) continue ;; esac
      _spec_reachable "$spec" || continue
      RESOLVED_FINDERS="${RESOLVED_FINDERS:+$RESOLVED_FINDERS }$spec"; seen="$seen$t "; n=$((n + 1))
      [ "$n" -lt "$max" ] || break
    done
  fi
  if [ -z "$RESOLVED_FINDERS" ]; then
    printf 'review-skills: no reviewer model is reachable. Any one of these will do:\n  sign claude in (claude auth login), or set ANTHROPIC_USE_API_KEY=1 and ANTHROPIC_API_KEY\n  sign agy in\n  put OLLAMA_API_KEY in %s\n' "$(config_file)" >&2
    return 1
  fi
  if [ -n "$rpin" ]; then
    RESOLVED_REFUTER="$rpin"; same_family "$rpin" $RESOLVED_FINDERS
  else
    _pick_refuter "$1" $RESOLVED_FINDERS || return 1
    # A second finder that leaves no refuter outside the finders' families is dropped.
    if [ "$SAME_FAMILY" = 1 ] && [ "$n" -gt 1 ]; then
      _pick_refuter "$1" "${RESOLVED_FINDERS%% *}"
      if [ "$SAME_FAMILY" = 0 ]; then RESOLVED_FINDERS="${RESOLVED_FINDERS%% *}"
      else _pick_refuter "$1" $RESOLVED_FINDERS; fi
    fi
  fi
}

# same_family <refuter> <finder...>: sets SAME_FAMILY (1: the refuter shares a finder's family).
same_family() {
  local r f
  r="$(model_family "$1")"; shift; SAME_FAMILY=0
  for f; do [ "$(model_family "$f")" != "$r" ] || SAME_FAMILY=1; done
}

# _pick_refuter <preset> <finder...>: sets RESOLVED_REFUTER to the best reachable refuter row
# outside every finder's family, else the best reachable one; and SAME_FAMILY.
_pick_refuter() {
  local preset="$1" spec first=""; shift
  RESOLVED_REFUTER=""
  for spec in $(_rows "$preset" refuter); do
    _spec_reachable "$spec" || continue
    [ -n "$first" ] || first="$spec"
    same_family "$spec" "$@"
    [ "$SAME_FAMILY" = 1 ] || { RESOLVED_REFUTER="$spec"; return 0; }
  done
  RESOLVED_REFUTER="$first"
  [ -n "$first" ] || { printf 'review-skills: no refuter model is reachable for %s -- set PR_REVIEW_REFUTER\n' "$*" >&2; return 1; }
  same_family "$first" "$@"
}
