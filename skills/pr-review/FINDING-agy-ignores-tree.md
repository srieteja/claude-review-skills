# The worktree pin has never held for stage 2

**Found:** 2026-08-27, while pointing `selftest.sh` at the extracted `refute` command.
**Status:** open. Predates the extraction — the code is byte-identical to what
`pr-review.sh` ran inline.

## What happens

`refute` (and `pr-review.sh` stage 2 before it) invokes the validator as:

```bash
( cd "$TREE" && agy --sandbox --model ... -p="$(cat prompt)" )
```

The `cd` accomplishes nothing. Asked directly:

```
(1) pwd                -> ~/.gemini/antigravity-cli/scratch
(2) resolves packages/at_auth/.../assurance.dart
                       -> <live checkout>/packages/at_auth/.../assurance.dart
```

agy does not inherit cwd. It runs in its own scratch dir and resolves relative paths
against its **persisted project root**, which is the real repo. Every relative path in
every claim has been read out of the working tree, at whatever commit and with whatever
uncommitted edits were sitting there.

## Why it matters

This is decision #1 of the plan inverted. Validating `file.dart:156` against the wrong
tree refutes correct findings **and is indistinguishable from a genuine refutation** —
the verdict is well-argued, cites real line numbers, and is wrong.

Caught by `selftest.sh`'s `TRUE_CLAIM` fixture, which cites the reserved-key set at
`assurance.dart:22` as it exists at the pinned SHA. The validator refuted it quoting
line 18 — the trunk version, where the set is a one-liner that *does* contain `'keys'`:

| tree | line | value |
|---|---|---|
| pin `41a4cc6` (what the fixture cites) | 22 | multi-line, no `'keys'` |
| working tree, trunk (what agy read) | 18 | `{'version', 'atsign', 'keys'}` |

Both readings are internally consistent. Only the fixture's known ground truth exposed it.

The two `REFUTED` fixtures "passed", but they are unverified rather than confirmed. In the
3-way concurrent run, `TRUE_CLAIM` was refuted with a *third* reason -- "the cited file does
not exist in the working directory" -- which is neither tree. `FAKE_MECH` cites that same
file, so its REFUTED may have been reached for a wrong reason and scored as a pass. Once
pinning works, check that its `reason` cites the invented mechanism, not a missing file.

## Scope of the damage

- **Stage 1 is unaffected** — `claude -p` honours cwd, so Opus reviewed the right tree.
- **Stage 2 is affected for every run to date.** Any REFUTED or CONFIRMED verdict was
  reached against the working tree, not the PR head. Reports are only accidentally
  correct where the two trees agree at the cited lines.
- The `--sha` regression-fixture feature is meaningless for stage 2 for the same reason.
- The escape guard is unaffected and, in hindsight, was the honest half of the design:
  it already assumed agy resolves its own root and ignores cwd. The stage-2 comment says
  exactly that. The conclusion drawn from it was too narrow — it was treated as a *write*
  hazard when it is equally a *read* hazard.

## Fix

`--add-dir "$TREE"` is enough on its own. It does not merely add the tree to the
workspace -- it re-roots agy onto it. The same probe, unchanged except for the flag:

```
(1) /.../refute-probe/tree
(2) /.../refute-probe/tree/packages/at_auth/lib/src/keys/serialization/assurance.dart
(3) 22:   static const _reservedTopLevelKeys = {
    23:     'version',
    24:     'atsign',
```

`pwd` is the tree instead of agy's scratch dir, the relative path resolves inside the
tree, and line 22 is the pinned multi-line set rather than trunk's line-18 one-liner.
`--project` and `--new-project` were not needed and were not tried.

It lives in `refute` -- the only place agy is invoked -- so `pr-review.sh` and
`selftest.sh` both inherit it, and so does anyone calling `refute` directly. `--tree` is
absolutised on the way in, because `--add-dir` is resolved by agy from *its* cwd, not ours.

---

## Addendum 2026-09-18: `--add-dir` does not hold reliably

**Status of the Fix above: insufficient, not wrong.** `--add-dir "$TREE"` is present
(`refute:108`) and `--tree` is absolutised (`refute:68`). The one-shot probe that
validated it still reproduces. But across repeated `selftest.sh` runs the pin holds
only sometimes.

Six consecutive runs, same command, same pinned SHA, no edits between them:

| runs | TRUE_CLAIM | tree the reason demonstrably read |
|---|---|---|
| 2 | CONFIRMED | pinned `41a4cc6` |
| 2 | REFUTED | live working tree -- self-identifying: the reason asserts `'keys'` is a
member of `_reservedTopLevelKeys` (one of them citing "lines 29-30") and quotes the
inline comment. Neither exists at the pin; both exist in the live tree. |
| 2 | REFUTED | tree inferred, not demonstrated -- these two runs' reasons were dropped
by the grep filter used to capture them, so only the verdict survives. |

The REFUTED reasons are self-identifying as wrong-tree, because they assert live-tree
facts that do not exist at the pin:

- "both `_reservedTopLevelKeys` ... explicitly contain `'keys'`" — true in the working
  tree, false at the pin (set is `assurance.dart:22-27`, four entries, no `'keys'`).
- A verbatim quote of the comment "leaving it in would refuse the first flush onto ..."
  — that string exists at `assurance.dart:300` in post-pin commits only.

The bug the fixture describes was **really fixed** after the pin, in
`0202694 fix(at_auth): a keyfile written by 3.3.0 could be read but never written`.
So the validator reading the live tree is reading a tree where TRUE_CLAIM is genuinely
false. The refutation is correct about the wrong tree — exactly the indistinguishability
this document warned about, now intermittent rather than constant.

**Consequence for the gate.** `selftest.sh` cannot currently certify stage 2. A green run
no longer means the validator discriminates; it means that run happened to re-root. And
because FAKE_FILE/FAKE_MECH are refutable against either tree, they pass either way and
the suite looks healthy while the only tree-sensitive fixture flaps.

**Not fixable in the fixtures.** Two rounds of fixture tightening were tried first
(citing the `addKey` -> `hasTypedContent` entry point; restating the reserved set by
positive enumeration with line spans instead of asserting `'keys'` is absent). Both are
improvements on their own terms and were kept, but neither changed the ratio — the
variable is which tree agy resolves, not how the claim is phrased.

**Next step:** make the tree resolution verifiable per run rather than assumed. Have the
validator report, as a schema field, the first line of the cited file it actually read,
and fail the run when it does not match the pin. Until then treat stage 2 verdicts as
unpinned.
