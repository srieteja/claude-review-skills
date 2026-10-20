# The event that carries a model call's result, from its --output-format json.
#
# That output is a bare result object on some CLI builds and a transcript array on others,
# and the array's result event is not guaranteed to be its last. Every read of model output
# starts here: jq -L "$HERE" 'include "last-event"; last_event | ...'
def last_event:
  if type == "array"
  then last(.[] | objects | select(.type == "result")) // .[-1]
  else . end;
