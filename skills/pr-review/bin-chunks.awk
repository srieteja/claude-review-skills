# Pack an index.tsv ("id<TAB>bytes<TAB>path", path-sorted) into review chunks.
#   awk -v cap=80000 -v excl='REGEX' [-v pfx=t] -f bin-chunks.awk index.tsv
# Emits "chunk<TAB>id<TAB>path" on stdout, chunks named pfx01, pfx02... (pfx defaults to c);
# excluded paths go to chunk "_skip".
# Path-sorted input means a bin's members are directory-adjacent, so a chunk stays
# topically coherent without any explicit directory grouping.
BEGIN { FS = "\t"; OFS = "\t"; bin = 1; if (pfx == "") pfx = "c" }
{
  if (excl != "" && $3 ~ excl) { print "_skip", $1, $3; next }
  # An oversize single file gets its own bin rather than dragging neighbours over cap.
  if (used > 0 && used + $2 > cap) { bin++; used = 0 }
  printf "%s%02d\t%s\t%s\n", pfx, bin, $1, $3
  used += $2
}
