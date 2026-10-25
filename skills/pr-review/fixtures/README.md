Fixtures for `selftest.sh`. All three cite `at_auth` code as it exists at the commit
`selftest.sh` checks out -- `PIN_SHA` there is the single source of truth for that, not
this file. The cited lines must be re-checked against the tree whenever it moves.

| file | truth | expected verdict |
|---|---|---|
| `true-claim.json` | real bug, documented in `reviews/pr2179-bugs.md` #2 | CONFIRMED |
| `fake-file.json` | cites a file that does not exist | REFUTED |
| `fake-mechanism.json` | **real file, real line, invented mechanism** | REFUTED |

`fake-mechanism.json` is the one that matters. A validator that pattern-matches
plausible-sounding claims will confirm it; one that reads the source will see the set
is `const` and that the code calls `.contains()`, never `.add()`.

Fixtures for `render-test.sh` (report, review body, inline comments; no models, no network):

| file | what it is | why |
|---|---|---|
| `merged-2382.json` | real merged.json, at_client_sdk #2382 | 6 confirmed, long write-ups: the clarity and no-loss baseline |
| `merged-2387.json` | real merged.json, #2387 | two finders agreeing on one defect (`.also`): one comment, one section |
| `merged-synthetic.json` | hand-made, 6 findings | edge cases: no severity, `\|` and `@` in text, a fenced evidence block, a REFUTED and an UNVERIFIABLE pair, an off-diff test gap |
