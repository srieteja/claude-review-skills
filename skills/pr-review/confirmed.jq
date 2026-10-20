# The CONFIRMED findings of a merged.json, as the markdown both public bodies carry -- the
# fix PR's (autofix.sh) and a change request's (peer-review.sh). Used as:
#   jq -L "$dir" -r 'include "confirmed"; confirmed_md' merged.json
#
# The finding text is LLM output about someone else's code: a word joiner after each @
# that starts a word keeps "@override" or "@org/team" from pinging anyone. "_" starts one
# too, since "_@x_" renders as emphasis around a bare "@x".
def quiet: gsub("(?<![A-Za-z0-9])@(?=[A-Za-z0-9_])"; "@⁠");
def confirmed_md:
  .[] | select(.v.verdict == "CONFIRMED")
  | "\n**\(.claim | quiet)** (`\(.file):\(.line)`) — \(.mechanism | quiet)";
