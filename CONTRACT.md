# Integration contract

This is what a program built on top of these skills can rely on: a scheduler that reviews and ships unattended, a dashboard that reads the stores, or anything else that wraps the engine instead of forking it. Anything not listed here is internal and can change without notice.

`bin/review-skills test` runs `skills/peer-review/contract-test.sh`, which reads the block below and checks every item. Changing an item is a breaking change: it needs a line in the commit message saying what wrappers must do.

## Entry points

| Command | Run from | Does |
|---|---|---|
| `peer-review.sh <N>` | a clone of the PR's repo | Prepare: review, decide, freeze. Nothing is posted. |
| `peer-review.sh <N> --ship` | the same clone | Post exactly what was frozen, after re-checking the PR head. |
| `peer-review.sh <N> --decide <approve\|request-changes\|fix> [--body-file <f>]` | the same clone | Re-freeze a different decision without a new review. |
| `pr-review.sh <N> [flags]` | the same clone | The regular review on its own (see its `SKILL.md`). |
| `review_learn.py <profile\|stats\|distill>` | anywhere | The learned reviewer profile, as JSON on stdout. |

## Output

`peer-review.sh` prints `KEY=value` lines on stdout, and everything else goes to stderr. A wrapper should match the lines below and treat any other `STATUS` as a failure to retry.

- Prepare prints `ENGINE=`, then `STATUS=prepared` and `DECISION=`, plus a `LANE= STATUS=` line for each fix lane it prepared.
- Ship prints one bare `STATUS=` line for an approve or request-changes, or one `LANE= STATUS=` line per lane for a fix.
- Exit 0 means it settled. Exit 1 means it was refused (`stale`) or failed.

## Store

Each review lives in `<store>/<author>/<repo>/<N>/`. The store is `$PR_REVIEW_INTENSE_DIR` for the intense engine and `$PR_REVIEW_DIR` for the regular one; `ENGINE=` says which. The stacked lane freezes into `autofix/` itself, and every other lane into `autofix/<lane>/`. `decision/posted` is the decision's public URL, and `decision/posted.<lane>` is each lane's fix PR.

## Items

`<N>` stands for the PR number. Kinds:

- `out` is a stdout line, as an extended regex anchored at both ends.
- `file` is a path in the review directory.
- `pinned` is a literal that the named suite checks against the real code.
- `env` is a variable the engine reads.
- `api` is a `review_learn` function and the parameters wrappers pass to it.
- `cli` is a `review_learn.py` subcommand.

```contract
out     ENGINE=(intense|regular)
out     STATUS=prepared
out     DECISION=(approve|request-changes|fix)
out     STATUS=(approved|changes-requested|exists):https://[^ ]+
out     STATUS=stale
out     LANE=stacked STATUS=(opened|exists):https://[^ ]+
out     LANE=stacked STATUS=stale

file    meta.json
file    decision/decision
file    decision/sha
file    decision/why
file    decision/body.md
file    decision/review.json
file    decision/posted
file    decision/posted.stacked
file    decision/stale
file    autofix/fix.patch
file    autofix/title
file    autofix/body.md
file    autofix/base

pinned  skills/peer-review/offline-test.sh  LANE=trunk STATUS=prepared
pinned  skills/peer-review/offline-test.sh  autofix/trunk/fix.patch
pinned  skills/peer-review/offline-test.sh  /running"
pinned  skills/pr-review/render-test.sh     survived refutation
pinned  skills/pr-review/offline-test.sh    -explainer.md
pinned  skills/pr-review/diagram-test.sh    -diagram.mmd
pinned  skills/pr-review/diagram-test.sh    -diagram.json

env     PR_REVIEW_DIR
env     PR_REVIEW_INTENSE_DIR
env     PR_REVIEW_FIX_AUTHORS
env     PEER_REVIEW_SHIPPER

api     learn_dir()
api     load_profile()
api     view(profile)
api     stats(window)
api     update_rule(rid, text, pinned, target, effect, scope)
api     delete_rule(rid)

cli     profile
cli     stats
cli     distill
```

`PEER_REVIEW_SHIPPER=watch` marks a ship as unattended, so the learning engine does not read it as your preference.
