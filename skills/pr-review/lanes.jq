# Which fix lane takes a CONFIRMED finding -- one rule for pr-review.sh's stage 5, which picks
# the lanes to run, and autofix.sh, which picks a lane's findings.
#   jq -L "$dir" --arg lane trunk --arg state OPEN 'include "lanes"; lane_findings($lane; $state)'
#
# stacked  what the PR introduced (route's label; an unrouted finding, from before route, too)
# trunk    what was already at its base -- every finding, once the PR has merged
def lane_findings($lane; $state): [.[] | select(.v.verdict == "CONFIRMED")
  | select(if $lane == "stacked" then $state != "MERGED" and .route != "pre-existing"
           else $state == "MERGED" or .route == "pre-existing" end)];

# The lanes with something to fix, in run order.
def fix_lanes($state): . as $f | ["stacked", "trunk"] | map(select(. as $l | $f | lane_findings($l; $state) | length > 0));
