# Marks agreement between finders in merged.json (an array of findings joined with verdicts).
# Ids are "<finder>.<slice>-<id>", e.g. "anthropic.c01-F1".
# Output: the same array, each finding with .also = ids of the other finders' findings on the
# same file within 3 lines of it (empty array when there are none).

def finder: .id | split(".")[0];

. as $all
| map(. as $f
  | .also = [
      $all[]
      | select(.file == $f.file and finder != ($f | finder))
      # A finding with no line agrees with nothing: numbers yields empty, not an error,
      # so one malformed claim cannot fail the merge after the review has been paid for.
      | select((.line | numbers) - ($f.line | numbers) | . >= -3 and . <= 3)
      | .id
    ])
