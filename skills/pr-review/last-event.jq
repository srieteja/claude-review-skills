# The event that carries a model call's result, from its --output-format json.
#
# That output is a bare result object on some CLI builds and a transcript array on others,
# and the array's result event is not guaranteed to be its last. Every read of model output
# starts here: jq -L "$HERE" 'include "last-event"; last_event | ...'
def last_event:
  if type == "array"
  then last(.[] | objects | select(.type == "result")) // .[-1]
  else . end;

# The result text of a call that failed because its account cannot serve it -- out of quota,
# unpaid, or signed out -- else nothing. Every further call on that account fails the same way.
def quota_hit:
  last_event
  | select(.is_error == true
           and ((.api_error_status | IN(401, 402, 403, 429))
                or (.result | tostring | test("hit your .*limit|usage limit"; "i"))))
  | .result // "API error \(.api_error_status)";
