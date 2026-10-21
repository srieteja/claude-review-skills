# Split a unified diff into one file per changed path, and index them.
#   awk -v outdir=DIR -f split-diff.awk pr.diff
# Writes DIR/NNNN.diff per path and DIR/index.tsv of "NNNN<TAB>bytes<TAB>path".
# Byte-exact: every line of the input lands in exactly one part.
/^diff --git / {
  if (n) { close(part); printf "%04d\t%d\t%s\n", n, bytes, path > (outdir "/index.tsv") }
  n++; bytes = 0
  path = $3; sub(/^a\//, "", path)
  part = sprintf("%s/%04d.diff", outdir, n)
}
n { print > part; bytes += length($0) + 1 }
END {
  if (n) { close(part); printf "%04d\t%d\t%s\n", n, bytes, path > (outdir "/index.tsv") }
}
