# Renders merged.json (findings joined with verdicts) as the review markdown: the outcome
# first, a table of what breaks, then one section per finding with the refuter's reasoning
# folded one click away. Every field of every surviving finding appears verbatim.
# Run with -L <this dir>. Args: $pr $title $url $sha $om (finders) $gm (refuter)
#       $same (1: refuter of a finder's family) $burden (strict|evidence)
#       $gaps (unreviewed slices) $gap_notes (one "> - `key`: why" line per gap)
#
# Frozen, because peer-review.sh gates an approval on them and pr-review-ops/ledger.py
# parses the first: the "**N survived refutation · N disputed · N refuted.**" prefix and the
# "**Incomplete.**" banner. dashboard-shared/markdown.js links a table row to the "## <id> — "
# heading its first cell opens.
include "confirmed";

def rule: if $burden == "evidence"
          then "A refutation needed quoted counter-evidence; a claim that could be neither confirmed nor disproved stays in as UNVERIFIABLE."
          else "A claim that could not be confirmed counts as refuted." end;
def bucket: if .v.verdict == "CONFIRMED" then "confirmed"
            elif .v.verdict == "REFUTED" then "refuted"
            else "disputed" end;
# Code defect or test gap, by path: a deterministic split, no model asked.
def is_test: .file | test("(^|/)test/|_test\\.");
def oneline: gsub("\\s*\\n\\s*"; " ");
def cell: oneline | gsub("\\|"; "\\|");
def basename: split("/") | last;
# dashboard-shared/markdown.js's heading id, so an in-page link lands on it.
def slug: ascii_downcase | gsub("[^\\p{L}\\p{N}]+"; "-") | .[0:64] | gsub("^-+|-+$"; "");
def flag: if .v.verdict == "CONFIRMED" then "" else "⚠️ \(.v.verdict) · " end;
def titled: (.title // "") != "";
def heading: if titled then .title else .claim end | oneline;
def meta_line: "\(icon) \(sev) · `\(.file):\(.line)` · **\(.v.verdict)**\(if .route then " · \(.route)" else "" end)";

# A fence longer than any backtick run inside, so evidence quoting code stays one block.
def fenced: ([scan("`+") | length] | max // 0) as $n
            | ("`" * ([3, $n + 1] | max)) as $f | $f, ., $f;
def verification:
  .v as $v
  | ($v.evidence // "") as $e
  | "<details><summary>Verification — \(if ($v.model // "") != "" then "\($v.model): " else "" end)\($v.verdict)\(
       if $e != "" then " · \(plural($e | split("\n") | map(select(test("\\S"))) | length; "quoted line"))" else "" end)</summary>",
    "",
    (if ($v.reason // "") != "" then $v.reason, "" else empty end),
    (if $e != "" then ($e | fenced), "" else empty end),
    "</details>";
# Claim (unless $heading_is_claim), mechanism, repro and correction visible; then the fold.
def fields($heading_is_claim):
  (if $heading_is_claim then empty else "**Claim.** \(.claim)", "" end),
  (if (.mechanism // "") != "" then "**Mechanism.** \(.mechanism)", "" else empty end),
  (if (.repro // "") != "" then "**Repro.** \(.repro)", "" else empty end),
  (if (.v.correction // "") != "" then "**Refuter's correction.** \(.v.correction)", "" else empty end),
  verification;

# One group: the primary in full, naming the others. Each other keeps its own heading (its
# table row links there) and points back, with its own write-up folded.
def section:
  .[0] as $p
  | "## \($p.id) — \($p | heading)",
    "",
    "\($p | meta_line)\(if length > 1 then " · Also found by \(.[1:] | map("`\(.id)`") | join(", "))" else "" end)",
    "",
    ($p | fields((titled | not) and (.claim | test("\\n") | not))),
    "",
    (.[1:][]
     | "## \(.id) — Same defect as [\($p.id)](#\("\($p.id) — \($p | heading)" | slug)), found independently",
       "",
       meta_line,
       "",
       "<details><summary>\(.id)'s own write-up</summary>",
       "",
       (if titled then "**\(.title)**", "" else empty end),
       fields(false),
       "",
       "</details>",
       ""),
    "---",
    "";

. as $all
| [.[] | select(bucket == "confirmed")] as $conf
| ($conf | length) as $c
| ([.[] | select(bucket == "disputed")] | length) as $d
| ([.[] | select(bucket == "refuted")] | length) as $r
| ($conf | map(select(is_test)) | length) as $tests
| groups as $groups
|
"# PR #\($pr) — \($title)",
"",
"**\($c) survived refutation · \($d) disputed · \($r) refuted.**"
  + (if $c > 0 then " \($conf | tally(true; " · ")) · \(
       [(if $c > $tests then plural($c - $tests; "code defect") else empty end),
        (if $tests > 0 then plural($tests; "test gap") else empty end)] | join(", "))"
     else "" end),
"",
(if $same == "1" then
  ("> ⚠️ **Same-family refuter.** \($gm) is from the same model family as a finder, so it shares that finder's blind spots: a confirmation by it is weaker evidence. Sign agy in or add OLLAMA_API_KEY for a refuter from another family.", "")
 else empty end),

(if ($gaps | ascii_downcase | test("[a-z0-9]")) then
  ("> ⚠️ **Incomplete.** These review slices produced nothing:\($gaps). The files in them were **not reviewed** — absence of a finding there means absence of a reviewer, not absence of a bug.",
   ">\($gap_notes)", "")
 else empty end),

"`\($sha[:12])` · [PR](\($url)) · found by \($om) · refuted by \($gm) ([method](#method))",
"",

(if $c + $d == 0 then
  ("Every finding was refuted. Read the collapsed section below before trusting that — a wrong refutation looks exactly like a right one.",
   "")
 else
  ("| # | Sev | Where | What breaks |",
   "|---|---|---|---|",
   ($groups[] | .[0].id as $pid | .[]
    | "| \(.id) | \(icon) | `\(.file | basename):\(.line)` | \(flag)\(if .id == $pid then heading | cell else "Same as \($pid)" end) |"),
   "",
   "---",
   "",
   ($groups[] | section))
 end),

(if $r > 0 then
  ("<details><summary><b>\($r) finding(s) refuted by \($gm)</b> — kept so a wrong refutation stays visible</summary>",
   "",
   (.[] | select(bucket == "refuted")
    | "**\(.id)** `\(.file):\(.line)` — \(.claim)",
      "",
      "> \(.v.reason)",
      ""),
   "</details>",
   "")
 else empty end),

"### Method",
"",
"\($om) found \($all | length) finding(s); \($gm) was asked to refute each one independently against the source at `\($sha)`. \(rule)",
"",
"Generated by `pr-review` (adversarial multi-model review). Findings are model output that survived an adversarial second pass — read the mechanism before acting."
