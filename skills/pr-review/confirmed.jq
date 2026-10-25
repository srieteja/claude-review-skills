# Findings as text: the order and grouping every reader sees (report.jq), and the markdown the
# public bodies carry -- the fix PR's (autofix.sh), a change request's and inline.py's.
#   jq -L "$dir" -r 'include "confirmed"; confirmed_md' merged.json
#
# The finding text is LLM output about someone else's code: a word joiner after each @
# that starts a word keeps "@override" or "@org/team" from pinging anyone. "_" starts one
# too, since "_@x_" renders as emphasis around a bare "@x". Public text only: the report
# is local, and quotes each field verbatim.
def quiet: gsub("(?<![A-Za-z0-9])@(?=[A-Za-z0-9_])"; "@⁠");
# The claim's first sentence: a stop, then space and a capital or quote. "e.g. foo" or
# "stop() returns" never ends one.
def headline: sub("(?<=[.!?])\\s+[A-Z`'\"(][\\s\\S]*$"; "");
def plural($n; $word): "\($n) \($word)\(if $n == 1 then "" else "s" end)";

# Worst first. An unknown severity is rated nothing, and sorts last.
def severities: ["high", "medium", "low"];
def sev: .severity as $s | if severities | index($s) then $s else "unrated" end;
def rank: sev as $s | (severities | index($s)) // 3;
def icon: {"high": "🔴", "medium": "🟠", "low": "🟡"}[sev] // "⚪";
# "3 medium, 3 low" (sep ", ") or "3 🟠 medium · 3 🟡 low" (icons, sep " · "), worst first.
def tally($icons; $sep):
  group_by(rank) | map("\(length) \(if $icons then (.[0] | icon) + " " else "" end)\(.[0] | sev)") | join($sep);

# A finding is located by its marker. Ship keys inline comments on it, and learning-engine
# its dropped-finding check, so every public text names each CONFIRMED id's marker.
def marker: "`\(.file):\(.line)`";
# What breaks, in a few words: the finder's title, or the claim's first sentence.
def what: if (.title // "") != "" then .title else .claim | headline end;

# The surviving findings as groups, worst first: [[primary, also...], ...]. Two finders
# reporting the same defect (.also, from agree.jq) are one group when both are CONFIRMED --
# a disputed half isn't the same defect until someone checked it. merged.json keeps both.
def groups:
  reduce (map(select(.v.verdict != "REFUTED")) | sort_by(rank) | .[]) as $f ([];
    (if $f.v.verdict == "CONFIRMED" then
       [to_entries[] | select(any(.value[]; .v.verdict == "CONFIRMED"
          and (any(.also[]?; . == $f.id) or (.id as $id | any($f.also[]?; . == $id))))) | .key][0]
     else null end) as $i
    | if $i == null then . + [[$f]] else .[$i] += [$f] end);
# The group's other markers, when the second finder put it somewhere else.
def also_at: (.[0] | marker) as $m | [.[1:][] | marker | select(. != $m)] | unique;
def where: "\(.[0] | marker)\(also_at | if length > 0 then " (also \(join(", ")))" else "" end)";
def unconfirmed: .[0].v.verdict | if . == "CONFIRMED" then "" elif . == "ERROR" then " — ⚠️ never checked"
                                  else " — ⚠️ \(.)" end;

# One group per line: its marker, then what breaks. For bodies whose substance is elsewhere --
# the fix PR's diff, a change request's inline comments.
def one_liner: "- \(where) — \(.[0] | what | quiet)\(unconfirmed)";
# One group in full: what breaks, where, the claim and its repro. Never the mechanism: that
# reasoning stays in the local report.
def in_full:
  .[0] as $p
  | (if ($p.title // "") != "" then "**\($p.title | quiet)** (\(where))\(unconfirmed)\n\n\($p.claim | quiet)"
     else "**\($p.claim | quiet)** (\(where))\(unconfirmed)" end)
    + (if ($p.repro // "") != "" then "\n\n**Repro.** \($p.repro | quiet)" else "" end);

def confirmed: map(select(.v.verdict == "CONFIRMED"));
def confirmed_md:   confirmed | groups[] | one_liner;
def confirmed_full: confirmed | groups[] | in_full, "";

# A review's top-level body: a verdict line, then a bullet per group with an inline comment,
# and in full each group whose primary id is in $full -- those have nowhere else to go.
# Input: the findings to post (a change request passes only the CONFIRMED ones).
def review_body($sha; $event; $full):
  groups as $g
  | [$g[] | select(.[0].id as $id | $full | index($id))] as $long
  | ($g - $long) as $short
  | [$g[] | select(.[0].v.verdict == "CONFIRMED")] as $c
  | ([$c[] | select(.[0].id as $id | $full | index($id) | not)] | length) as $inline
  | (if $inline == 0 then "" elif $inline < ($c | length) then ", inline below where the diff has the line"
     elif $inline == 1 then ", inline below" else ", each inline below" end) as $where
  | "\({"REQUEST_CHANGES": "Requesting changes", "APPROVE": "Approving"}[$event] // "Adversarial review") at `\($sha[:12])`: "
    + (if ($c | length) == 0 then "nothing confirmed."
       else "\(plural($c | length; "confirmed defect")) (\($c | map(.[0]) | tally(false; ", ")))\($where)." end),
    ($short | if length > 0 then "", (.[] | one_liner) else empty end),
    ($long[] | "", in_full);
