# Finding ids name files (stage 2's per-claim files, stage 3's join), so an id is restricted to
# [A-Za-z0-9._-], at most 64 characters, with no leading dot and no "..". findings.schema.json
# states the same pattern to the finder; safe_id enforces it on whatever came back.
#
#   safe_id        any value -> a conforming id (anything outside the set becomes "_")
#   valid_id       does an id already conform, with room for a slice prefix up to 128 characters
def safe_id:
  tostring
  | gsub("[^A-Za-z0-9._-]"; "_")
  | gsub("\\.{2,}"; "_")
  | sub("^[.]"; "_")
  | .[0:64]
  | if . == "" then "_" else . end;

def valid_id:
  type == "string" and test("^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$") and (contains("..") | not);
