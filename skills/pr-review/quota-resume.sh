# shellcheck shell=bash
# quota-resume.sh -- sourced by autofix.sh and pr-review.sh. Targets bash 3.2.
#
# One rule for when to try again after a model account's limit: the reset time it names
# (quota_reset in last-event.jq) plus a minute, or a flat wait when it names none.
# Both scripts print the result as RESUME_AT=<epoch> beside STATUS=deferred (exit 75).

# quota_resume_at <reset-epoch-or-empty> <fallback-seconds> -- the epoch to resume at.
# An empty, non-numeric or zero reset (a transcript's resetsAt of 0 is "unset", not 1970) is no
# reset at all.
quota_resume_at() {
  case "$1" in
    ''|*[!0-9]*) echo $(( $(date +%s) + $2 )) ;;
    *) if [ $(( 10#$1 )) -gt 0 ]; then echo $(( 10#$1 + 60 )); else echo $(( $(date +%s) + $2 )); fi ;;
  esac
}
