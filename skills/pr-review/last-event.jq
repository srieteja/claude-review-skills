# Every reading of a failure below starts from a result event with is_error true. The prose
# regexes never see an assistant or tool event: what the model said along the way is not the
# account's answer, and last_event falls back to the last event when no result event exists.
#
# The event that carries a model call's result, from its --output-format json.
#
# That output is a bare result object on some CLI builds and a transcript array on others,
# and the array's result event is not guaranteed to be its last. Every read of model output
# starts here: jq -L "$HERE" 'include "last-event"; last_event | ...'
def last_event:
  if type == "array"
  then last(.[] | objects | select(.type == "result")) // .[-1]
  else . end;

# The structured half of quota_reset: epoch seconds at which the window that rejected the call
# reopens, from the rate_limit_event, else nothing. A rejection
# names its window: the five-hour one reopens within hours, the seven-day one in days, so the
# reset time is the only honest answer to "when can this run again".
def quota_reset_window:
  [ (if type == "array" then .[] else empty end)
    | objects | select(.type == "rate_limit_event") | .rate_limit_info
    | select(.status == "rejected")
    | ([.unifiedWindows[]? | select(.status == "rejected") | .resetsAt] | max) // .resetsAt ]
  | max;

# The reset time a limit names in words, for a CLI build that reports it only in the result text
# ("You've hit your 5-hour limit · resets 9:20pm (UTC)"), with no rate_limit_event. The text has
# no date, so a time already past today is tomorrow's. Only UTC is read: another zone's name
# says nothing this filter can turn into an epoch, so it yields nothing and the caller's flat
# fallback applies.
def quota_reset_text:
  last_event
  | select(.type == "result" and .is_error == true)
  | (.result // "") | tostring
  | capture("resets +(?<h>[0-9]{1,2})(:(?<m>[0-9]{2}))? *(?<ap>[ap]m) *\\(UTC\\)"; "i")
  | (now | floor) as $now
  | ((.h | tonumber) % 12 + (if (.ap | ascii_downcase) == "pm" then 12 else 0 end)) as $h
  | ($now - ($now % 86400) + $h * 3600 + ((.m // "0") | tonumber) * 60) as $t
  | if $t <= $now then $t + 86400 else $t end;

# Epoch seconds at which the limit that rejected the call lifts, else nothing: the rejected
# window's own resetsAt where the transcript carries one, else the time its message names.
def quota_reset: quota_reset_window // quota_reset_text;

# The result text of a call refused because its account is signed out (401), unpaid (402) or not
# authorised (403), else nothing. Nothing lifts that by waiting: a caller fails, or moves to
# another model.
def auth_hit:
  last_event
  | select(.type == "result" and .is_error == true and (.api_error_status | IN(401, 402, 403)))
  | .result // "API error \(.api_error_status)";

# The result text of a call that failed because its account is out of quota (an HTTP 429, or the
# limit's own wording together with a reset time), else nothing. The limit lifts, so a caller
# defers. The wording alone is not enough: it also turns up in an ordinary failure's message,
# and a failure that names no reset is one nothing says will lift. "Names a reset" is a
# rejected window in the transcript, or "resets <time>" in the text, whatever zone it is in:
# an unreadable zone still defers, on the caller's flat fallback.
def quota_hit:
  . as $call
  | last_event
  | select(.type == "result" and .is_error == true
           and (.api_error_status == 429
                or ((.result | tostring | test("hit your .*limit|usage limit"; "i"))
                    and ((.result | tostring | test("resets +[0-9]"; "i")) or ($call | quota_reset != null)))))
  | .result // "API error \(.api_error_status)";

# Either: the account cannot serve this call, for a reason a different model may not share.
def refused: quota_hit // auth_hit;
