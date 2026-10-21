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
