# Sourced by pr-review.sh and peer-review.sh. is_fix_author <login>: the login is on
# PR_REVIEW_FIX_AUTHORS (alias PEER_REVIEW_FIX_AUTHORS; default gkc) -- space- or
# comma-separated, case-insensitive, empty for none.
FIX_AUTHORS="${PR_REVIEW_FIX_AUTHORS-${PEER_REVIEW_FIX_AUTHORS-gkc}}"
is_fix_author() {
  local a who
  who="$(printf '%s' "${1#app/}" | tr '[:upper:]' '[:lower:]')"
  for a in $(printf '%s' "$FIX_AUTHORS" | tr ',' ' '); do
    [ "$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')" != "$who" ] || return 0
  done
  return 1
}
