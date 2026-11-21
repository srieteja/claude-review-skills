# shellcheck shell=bash
# quota-resume.sh -- sourced by autofix.sh and pr-review.sh. Targets bash 3.2.
#
# One rule for when to try again after a model account's limit: the reset time it names
# (quota_reset in last-event.jq) plus a minute, or a flat wait when it names none.
# Both scripts print the result as RESUME_AT=<epoch> beside STATUS=deferred (exit 75).

# fmt_epoch <epoch> -- local "YYYY-MM-DD HH:MM"; GNU date first, BSD (macOS) as the fallback.
fmt_epoch() { date -d "@$1" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$1" '+%Y-%m-%d %H:%M'; }

# quota_defer_fallback -- AUTOFIX_DEFER_FALLBACK (default 18000: one five-hour window) checked once
# by each caller at start-up: a positive integer of seconds, at most 9 digits. Prints it; on a bad
# value names the variable and returns 1.
quota_defer_fallback() {
  local v="${AUTOFIX_DEFER_FALLBACK:-18000}"
  case "$v" in
    *[!0-9]*|??????????*) ;;
    *) if [ $(( 10#$v )) -gt 0 ]; then printf '%s\n' "$(( 10#$v ))"; return 0; fi ;;
  esac
  echo "AUTOFIX_DEFER_FALLBACK must be a positive whole number of seconds, not '$v'" >&2
  return 1
}

# A reset further ahead than this is not believed (a mis-parsed or hostile value would park the
# run for good): the flat fallback is used instead.
QUOTA_RESET_CEILING=$(( 7 * 86400 ))

# quota_resume_at <reset-epoch-or-empty> <fallback-seconds> -- the epoch to resume at; the
# fallback is quota_defer_fallback's. An empty, non-numeric or zero reset (a transcript's
# resetsAt of 0 is "unset", not 1970), or one more than 7 days ahead, is no reset at all.
quota_resume_at() {
  local now; now="$(date +%s)"
  case "$1" in
    ''|*[!0-9]*|??????????????*) echo $(( now + $2 )) ;;
    *) if [ $(( 10#$1 )) -gt 0 ] && [ $(( 10#$1 )) -le $(( now + QUOTA_RESET_CEILING )) ]; then echo $(( 10#$1 + 60 )); else echo $(( now + $2 )); fi ;;
  esac
}
