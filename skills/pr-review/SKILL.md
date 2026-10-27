---
name: pr-review
description: Adversarial multi-model review of a GitHub PR — one or more finders (default Opus 5.5) find defects, a refuter (default Gemini 3.8 Flash) tries to refute each one against the PR-head source, and only what survives is reported. Also writes a plain-language brief of what the PR does, for the reviewer only. Use when the user asks to review a PR, validate review findings, explain what a PR is doing, or says "/pr-review <number>"; pass --sonnet when they ask for a cheaper run. For the uncapped two-finder preset, see /intense-review.
---

# Adversarial PR review

Lives at `~/.claude/skills/pr-review/`, outside any repo. It resolves its own prompts and
schema relative to itself, so **run it from inside whatever repo you are reviewing** —
`ROOT` and the output path come from your cwd, not from where the script lives.


Run `~/.claude/skills/pr-review/pr-review.sh`. It does the work; your job is to launch it,
read the result, and handle posting.

## Run it

```bash
~/.claude/skills/pr-review/pr-review.sh <PR-NUMBER> --keep
```

Before trusting a change to the toolkit itself, run `offline-test.sh` — it stubs every
model and checks the plumbing for free.

### Models

The finder and refuter are the best ones this machine can reach — claude signed in, agy signed
in, `OLLAMA_API_KEY` that ollama.com accepts — ranked in `lib/models.tsv`, with a refuter
of a different family from the finder whenever one is reachable. Model lists are cached a
day. `REVIEW_SKILLS_MODELS=manual` skips the probes and takes the first rows;
`PR_REVIEW_FINDERS` / `PR_REVIEW_REFUTER` pin either role. A same-family refuter is flagged
in the report, and the warning names agy or ollama when one was set up but did not answer
(each is asked twice). A run never fails for want of a second family. Without claude, the
brief is skipped.

### When Opus is unavailable

`PR_REVIEW_TRANSPORT=ollama` routes **stage 1 only** through ollama.com's Anthropic-compat
endpoint. Stage 2 is unaffected — the adversarial half of the review still runs.

```bash
PR_REVIEW_TRANSPORT=ollama PR_REVIEW_S1_MODEL=glm-5.3-flash \
  ~/.claude/skills/pr-review/pr-review.sh <PR-NUMBER> --keep
```

Needs `OLLAMA_API_KEY`. **The diff and every source file the model opens leave this machine**
and go to a third party; say so before pointing it at anything sensitive.

Treat its output as a lower tier of evidence, not a substitute:

| | measured |
|---|---|
| recall | **1 of 6** documented bugs on a 78KB slice of PR #2179 |
| precision | clean — the one hit was exact, with a correct traced mechanism |
| reading | 31 files opened; not a no-op |
| wall clock | ~11 min for one slice |

The hit was the highest-severity bug in the set, so it is not theater. But at ~17% recall an
empty result means almost nothing, which is why a zero-finding run on this transport prints a
warning instead of the usual "No findings" headline. **Re-run on the default transport before
treating a PR as reviewed.**

Two knobs behave differently there, both deliberately:

- **No `--max-budget-usd`.** The compat layer prices an unrecognized model at Anthropic rates
  and the flag *is* enforced against that fiction — a measured slice billed $4.16 of nothing.
  `PR_REVIEW_S1_TIMEOUT` (default 25m) is the ceiling instead.
- **No `Write` tool, so the model returns its findings on stdout.** `--allowedTools` is an
  intersection, not a union: under `CLAUDE_CODE_SIMPLE=1` grant flags are silently ignored.
  See `emit/README.md`.

Stage-1 slices are cached per **model, effort and transport**, so a flash run never gets served
back under an Opus run's name.

Stage 1 defaults to `claude-opus-5-5` at `--effort xhigh` (`PR_REVIEW_S1_MODEL`,
`PR_REVIEW_S1_EFFORT`). Effort is sent on the anthropic transport only.

`--sonnet` swaps the finder to `claude-sonnet-5-5` (`PR_REVIEW_SONNET_MODEL`) at the same
effort — half Opus 5.5's per-token price ($2/$10 per MTok against $4/$20), on Anthropic's own
transport rather than a third party's. Reach for it when the user says **"with sonnet"**, **"cheaper"**, or
balks at what a run cost; it overrides `PR_REVIEW_FINDERS` and warns that it did. Unlike
the ollama fallback above there is no measured recall figure for it, so treat a zero-finding
`--sonnet` run the same way: suggestive, not a clean bill of health.

### Finders, refuter, burden

| env | default | shape |
|---|---|---|
| `PR_REVIEW_FINDERS` | the single default finder above | space-separated `transport:model[@effort]`, one per transport (`anthropic`, `ollama`, `agy`) |
| `PR_REVIEW_REFUTER` | `agy:gemini-3.8-flash-high` | `agy:<model>` or `ollama:<model>` |
| `PR_REVIEW_REFUTER_FALLBACK` | `gemini-3.1-pro-high claude-opus-4-6-thinking` | agy only: models tried in order when the refuter's is out of quota (429). `""` pins the refuter. Each verdict records its `.model` |
| `PR_REVIEW_BURDEN` | `strict` | `strict` or `evidence` — the files under `burden/` |
| `PR_REVIEW_BUDGET_USD` | `8.00` per anthropic slice — a runaway guard; measured slices cost ~$3 | `none` removes the cap; `PR_REVIEW_S1_TIMEOUT` becomes the only ceiling |

With more than one finder, every slice runs once per finder, ids are prefixed with the
transport (`anthropic.c01-F1`), coverage gaps are reported per finder, and findings two
finders placed on the same file within 3 lines cite each other as **Also reported as**
(`agree.jq`).
`agy` finders return findings as structured output (`emit/schema.*`) and take no `@effort`.
`/intense-review` is the preset that sets all four.

Stage 1 reviews the diff in parallel byte-capped slices plus one cross-cutting pass, then a
**test pass**: files matching `PR_REVIEW_TEST_RE` (default `(^|/)tests?/|_test\.dart$`) are
held out of the feature slices and reviewed afterwards in `t01`, `t02`… slices, handed the
feature findings and the brief, asking whether the tests actually test what the PR claims.
Findings from it carry `t`-prefixed ids.
It still runs past the foreground Bash cap — **launch it in the background** (Claude Code:
`run_in_background: true`) and
poll the log. `--keep` preserves the work dir so a bad run is diagnosable.

Slices are cached against the head SHA, so a run interrupted by a rate limit resumes
where it stopped; re-running is cheap. Pass `--no-cache` to force a clean review.

Output lands in `~/.reviews/<pr-author>/<repo>/<N>/` — the report as `pr<N>-review.md`, plus
`merged.json` (findings joined with verdicts) and `meta.json` (the head SHA the line numbers
were resolved against) so the review is a self-contained record rather than a lone markdown
file. `PR_REVIEW_DIR` moves the store. Read the report before saying anything about it.

## The brief

Stage 0.5 writes `pr<N>-explainer.md` beside the report: a plain-language account of what the
PR is trying to do, with a Mermaid diagram of the part of the system it touches, written from
the diff and the author's description alone. It is for the human about to read the review —
lead with it when reporting back, so the user knows what the PR *is* before hearing what is
wrong with it.

It runs **before** stage 1 deliberately. A brief written afterwards is lost to a stage-1 death,
and the no-findings path exits before the report is ever assembled.

- **It is never posted.** `--post` sends `pr<N>-review.md` and `--inline` sends `inline.json`;
  neither references the brief. Summarising an author's own PR back at them is noise on their
  PR — the brief is a reviewer's aid, not review output.
- **It has read no source.** It cannot claim a defect, and nothing in it is a finding. If it
  and the review disagree, the review is the one that looked.
- `--no-brief` skips it. It is non-fatal throughout: a PR whose brief failed is still reviewed.
- Cached per head SHA, prompt and model, so a re-run does not re-pay for it.

`claude-sonnet-5-5` at `--effort medium` (`PR_REVIEW_BRIEF_MODEL`, `PR_REVIEW_BRIEF_EFFORT`).
Summarising a diff is not reasoning over a codebase; xhigh here buys thinking tokens billed at
output rates for no gain. `PR_REVIEW_BRIEF_BUDGET_USD` (default `1.00`) is a runaway guard, not
a budget — `--max-budget-usd` is checked *between* turns, so on a single-turn call it cannot
prevent the spend, only discard what it paid for. `CHUNK_BYTES` is the real cost control: it
bounds the input deterministically, and the brief sees exactly one slice of diff.

## Refuting on its own

Stage 2 is a separate command. `refute` takes a findings file and a tree, dispatches one
validator call per claim, and writes `<work>/verdicts/<id>.json`:

```bash
~/.claude/skills/pr-review/refute --findings f.json --tree <dir> --root <repo> --work <dir> \
  [--transport agy|ollama] [--model <id>] [--burden strict|evidence]
```

Reach for it directly when findings already exist and you only want them challenged — a
hand-written claim, a report someone else produced, a re-check after the branch moved.
`--root` is required and is the repo it guards. Both transports start in the tree, but only
`claude -p` (ollama) reliably honours that; agy's re-root onto the tree is intermittent
(`FINDING-agy-ignores-tree.md`), so the escape check is still what stands between a
validator's scratch code and your working tree. Exit 3 means every claim got a verdict but scratch was
quarantined into `<work>/escaped` — the verdicts are still good.
**The quarantine moves any new untracked file in `--root`, whoever wrote it, and `<work>` is
deleted at the end of the run** — don't run stage 2 while another session is writing into the
repo (DESIGN.md, Open issues).

It never returns fewer verdicts than claims. A validator that failed twice yields `ERROR`,
because a missing verdict is an unchecked claim, not a passing one.

## Report back

In this order:

1. **The brief** — what the PR does, from `pr<N>-explainer.md`. Condensed, diagram included.
2. **Bucket counts** — confirmed / disputed / refuted / error.
3. **Confirmed findings** as a table.
4. **The exact payload** that would be posted, if the user is deciding whether to post.
   Show `inline.json`'s anchors — file, line, bucket — not a paraphrase of them.

Two things to actually look at, not just relay:

- **ERROR verdicts** mean a claim was never checked — say so plainly. They are not
  a soft pass.
- **Refuted findings** are in the collapsed section. Skim them. If a refutation
  looks wrong, that is the one failure mode the pipeline cannot self-detect —
  flag it rather than trusting the bucket.
- **An incomplete-coverage banner** means slices failed — feature or test slices — and
  those files were never reviewed. Lead with it. A short clean report over partial coverage is the most
  misleading output this pipeline can produce — re-run to fill the gap.

## Auto-fix PRs

For trusted authors (`PR_REVIEW_FIX_AUTHORS`, alias `PEER_REVIEW_FIX_AUTHORS`, default none;
space- or comma-separated, case-insensitive, empty for none), a confirmed finding goes one step
further than a report: a companion PR with the fix, against that author's own branch.

- **`/pr-review` and `/intense-review`: stage 5, automatic.** After the report (and stage 4,
  if `--post`), `autofix.sh` runs one-shot once per lane with something to fix (`lanes.jq`):
  `stacked` for what the PR introduced, `trunk` for what was already on its base (everything,
  once merged), and `lint` too with `AUTOFIX_LINT=1`. Each lane's lines come out as
  `LANE=<lane> STATUS=…`. `--no-fix` skips it; so does `--sha`, which reviews a pinned commit
  rather than the head.
  - `opened:<url>`, `exists:<url>`, `none` or `dropped` in every lane -> exit 0.
  - **Anything else in any lane -> exit 4** with a `NO fix PR` warning: the head moved
    (`stale`), a guard refused, or the test gate went red. The report still stands; re-run, or fix by hand.
- **`/peer-review`: its own decision.** It passes `--no-fix` to its engine and runs
  `autofix.sh` in prepare mode, so the fix is frozen for a human; `--ship` opens it.

`autofix.sh <pr-number> <sha> <repo-dir> <outdir>` does the work:

1. **Only this review's record.** `pr-review.sh` writes `merged.json` and `meta.json` only when it finds something, so a record whose `meta.json` `headRefOid` isn't `<sha>` (the full SHA) is an earlier review's. That, no record at all, or no CONFIRMED finding -> `STATUS=none`, exit clean, before any `gh` call.
2. **Guards, before anything is spent.** Each refuses with exit 1 and no STATUS:
   - `origin`'s push URL isn't the PR's repo. The PR can't see a branch pushed to a personal fork.
   - The PR comes from a fork. A PR from `contributor:main` would otherwise get a fix PR against this repo's `main`.
   - The PR is no longer open.
3. A fix PR already exists for this reviewed head (branch `fix/pr<N>-review-findings-<sha12>`, any state) -> `STATUS=exists:<url>`, exit clean.
   - Open, merged or closed, it is these same findings: already proposed, already taken, or a human's no.
   - A fix PR for an earlier head never blocks, open or not. A re-review after a new push that confirms findings opens its own fix PR.
4. **The PR head moved since the review -> `STATUS=stale`, exit 1, in every mode.** The findings describe code the PR no longer is, and after a rebase a fix on the old head would bring the commits the author dropped back into their branch. A watcher should mark the reviewed head seen, so its next tick reviews the new one.
   - Only then: `dart` not on `PATH` -> exit 1, no STATUS. The gate can't run, so the implementer isn't paid for.
5. **`claude -p` implements every confirmed finding as one task**, in a throwaway `--shared` clone at the reviewed SHA. Only a patch comes back, and this script re-applies it itself.
   - A clone, not a worktree: a worktree shares refs and the stash with your clone, so anything it committed or branched would land there. Its `origin` is removed, so a push from inside has nowhere to go.
   - Unattended: `--permission-mode acceptEdits`, tools limited to `Read Edit Write Glob Grep` plus `dart test`, `dart pub get` and `dart analyze` (no direct git, no `dart format .` across the repo), and `--setting-sources "" --strict-mcp-config`, so your own settings, hooks and MCP stay out. The prompt says no one will answer, because a print-mode model otherwise ends on "shall I proceed?" with nothing edited.
   - Fails closed. A non-zero exit, a result event with `is_error` (a budget or turn cap still exits 0, with half an edit on disk), or no change at all means no PR.
   - The patch is everything against `<sha>`, committed or not, minus `pubspec.lock` and `.dart_tool/` from its own `pub get`.
   - `AUTOFIX_MODEL` (default `claude-opus-5-5`), `AUTOFIX_EFFORT` (default `high`) and `AUTOFIX_BUDGET` (USD, default `8.00`, a runaway guard like `PR_REVIEW_BUDGET_USD`; `none` uncaps) set the run, and `AUTOFIX_CLAUDE` swaps the binary. The model comes out as `IMPLEMENTER=` and is frozen as `model` for ship.
6. **The patch goes onto a fresh worktree at the reviewed SHA, staged with `git apply --index`, and is gated.**
   - Every changed file, new ones included, must sit under a `pubspec.yaml`. A file outside any package is refused, since no test covers it.
   - A package without `test/` (a pub workspace root) is never `dart test`ed -- that fails on "no test files". Its docs pass ungated; its Dart code and its `pubspec*.yaml`/`analysis_options.yaml` are refused, since every package below depends on them and none of their tests ran here.
   - Anything under `.github/` is refused outright. No test run vouches for a CI change.
   - A rename counts as both its paths. The package a file leaves is gated too, and a workflow can't leave `.github/` under its new name.
   - Each touched package with `test/` gets `dart pub get && dart test`, logged to its own file. A docs-only patch gates nothing and says so.
   - Except a package matching `AUTOFIX_ANALYZE_ONLY` (space-separated globs on its dir, default `tests/*`): its tests need a live rig, so it gets `dart pub get && dart analyze --fatal-infos`. The PR body names each such package, and the implementer's prompt says not to run its tests. Set it empty to `dart test` every package.
   - Any failure, or a patch that doesn't apply cleanly, stops here with no PR.
7. **On a clean gate, it commits exactly the staged patch** (none of `pub get`'s debris) on a detached HEAD, so no `fix/…` branch appears in your clone.
   - The commit message is the PR title, then `Reviewed at <sha12>; the PR description carries each finding.` No finding text goes into history.
   - It pushes `fix/pr<N>-review-findings-<sha12>` to origin's push URL, never forced and with no tags, and opens a PR against the reviewed PR's own head branch.
   - The body is one line of context, then one bullet per finding: `file:line` — the claim's first sentence.
   - No walls of text: no headings, no footer, no mechanism. The diff shows the fix; the reasoning stays in the local review.
   - An `@` that starts a word in the finding text gets a word joiner (U+2060) after it, so `@override` or `@org/team` pings no one. An `@` after `_` counts, since `_@x_` renders as emphasis around a live mention. Email addresses are left alone. GitHub's own renderer (`gh api markdown`) links none of these.
8. **When origin already has the fix branch but no PR** (a run whose `pr create` failed):
   - If it holds one commit on `<sha>` with this exact tree, the PR is opened on it without pushing. The lookup goes to the push URL, where the push would.
   - Anything else is refused with exit 1, naming the `git push origin --delete` to run once you've looked.
   - In the one-shot mode a re-run re-implements, so its tree will usually differ and the left-over branch is refused. Its `pr create` failure says so: open the PR by hand or delete the branch. Ship re-applies the frozen patch, so a re-run of ship resumes.

stdout is a machine-readable protocol. Progress goes to stderr:

| line | meaning | exit |
|---|---|---|
| `STATUS=none` | no record for `<sha>`, or no confirmed findings in this lane; lint: nothing at `AUTOFIX_LINT_LEVEL` in the packages the PR touches | 0 |
| `STATUS=exists:<url>` | a fix PR is already there | 0 |
| `STATUS=prepared` | frozen, nothing pushed (prepare mode) | 0 |
| `STATUS=opened:<url>` | fix PR is open | 0 |
| `STATUS=dropped` | trunk lane: the implementer found nothing to fix on trunk -- the defect is the PR's own | 0 |
| `STATUS=stale` | stacked lane: head moved since the review | 1 |
| `STATUS=retarget` | stacked lane, ship: the PR merged after prepare -- re-run for the trunk lane | 1 |
| `REVIEWER=requested\|skipped\|failed:<login>` | after `opened`, when `AUTOFIX_REVIEWER` is set | 0 even if `failed` |
| `IMPLEMENTER=<model>\|dart fix\|unknown` | before `prepared`/`opened`: the model that wrote the patch. Ship repeats the one frozen at prepare (`unknown` for a freeze older than `model`). `/peer-review` relays it | — |

Guard, implementer, test-gate, push and `pr create` failures, and a fix branch that isn't this fix, print no STATUS and exit 1.

`AUTOFIX_MODE` splits the one shot in two, so a human can read the fix before it goes public. `/peer-review` drives this.

| env | effect |
|---|---|
| *(unset)* | one shot: implement, gate, push, open. Nothing calls this mode any more; peer-review uses prepare and ship. |
| `AUTOFIX_MODE=prepare AUTOFIX_FROZEN=<dir>` | implement and gate, then freeze `fix.patch`, `title`, `body.md` and `sha` into `<dir>`. Nothing is pushed. |
| `AUTOFIX_MODE=ship AUTOFIX_FROZEN=<dir>` | re-apply the frozen patch (claude is not re-run), re-gate, then push and open with the frozen title and body. Edits to `body.md` are what gets posted. A blank `title` is refused before anything is pushed. |
| `AUTOFIX_REVIEWER=<login>` | once the PR is open, request `<login>`'s review. Skipped for yourself and for bots, which GitHub would reject with a 422. |
| `AUTOFIX_LANE=stacked\|trunk` | `stacked` (default): findings `route` labelled introduced, on the PR's head branch. `trunk`: the `pre-existing` ones -- all of them once the PR merged -- on the tip of its `baseRefName`, branch `fix/pr<N>-preexisting-<sha12>`. The trunk lane skips the stale and fork guards, asks the PR's author to review, and names who last touched each line (no `@`). Prepare freezes `base` = `<branch> <sha>`; ship commits on it. A closed, unmerged PR is refused in both. |
| `AUTOFIX_TRUNK_REVIEWER=blame` | trunk lane: request whoever last touched the first cited line instead of the PR's author (the author when blame finds no one). |
| `AUTOFIX_LANE=lint` | no findings needed: on the trunk lane's base, `dart fix --apply --code=…` for the analyzer codes at `AUTOFIX_LINT_LEVEL` in each package the PR's files fall in, then the model only for what's left (`IMPLEMENTER=dart fix` when it never ran). The gate adds: every targeted issue gone, none added. Branch `fix/pr<N>-lint-<sha12>`, PR's author asked. |
| `AUTOFIX_LINT_LEVEL=warning\|info` | lint lane: the lowest severity it clears (default `warning`: errors and warnings). |

- **Every stacked-lane mode refuses with `STATUS=stale` if the PR head moved since the review** (step 4). For ship, that means since prepare.
- **Ship reads only the frozen files,** not the review record. Re-running the review between prepare and ship can't change what posts.

`AUTOFIX_DRY_RUN=1` runs everything through the test gate and stops, with no push and no PR. Use it to validate the pipeline against a real PR without touching GitHub:

```bash
AUTOFIX_DRY_RUN=1 ~/.claude/skills/pr-review/autofix.sh <N> <sha> <repo-dir> ~/.reviews/<author>/<repo>/<N>
```

`autofix-test.sh` covers every path above against a throwaway repo, with `gh`, `claude` and `dart` stubbed. It costs nothing and never touches GitHub. `refute-test.sh` does the same for the refuter's quota fallback, with `agy` stubbed.


## Posting

### What touches GitHub

| Stage | Call | Writes? |
|---|---|---|
| 0 | `gh pr view`, `gh pr diff` | no |
| report | `gh repo view`; `inline.py` runs `gh api repos/…/pulls/N/files` every run | no |
| 4 | `gh api …/reviews` (`--inline`) or `gh pr comment` | **only with `--post`**, and it asks first unless `--yes` |
| 5 (autofix) | `git push`, `gh pr create`, `gh pr edit --add-reviewer` | **only for authors in `PR_REVIEW_FIX_AUTHORS`** (empty by default); `--no-fix` skips it |

Without `--post`, and with `PR_REVIEW_FIX_AUTHORS` empty or `--no-fix`, a run only reads.

### Posting a report

Never post unprompted. The file always exists first; posting is a separate decision.

```bash
~/.claude/skills/pr-review/pr-review.sh <PR-NUMBER> --post
```

`--post` re-runs the pipeline. To post a report that already exists, use the file
directly and confirm with the user first — this is a public comment on an upstream
repo, so ask every time, and a yes on one PR never carries to the next:

```bash
gh pr comment <PR-NUMBER> --body-file ~/.reviews/<author>/<repo>/<N>/pr<N>-review.md
```

### Inline

`--inline` posts one review with each finding anchored to its own line instead of a single
wall-of-text comment. Every run writes the payload to `<OUTDIR>/inline.json` whether or not
you post it, so the thing you show the user is the thing that gets sent:

```bash
gh api repos/<owner>/<repo>/pulls/<N>/reviews --input ~/.reviews/<author>/<repo>/<N>/inline.json
```

`inline.py` builds it, and the bucketing is the part that matters. GitHub rejects the whole
`comments` array with a 422 if one entry names a line outside a diff hunk, so each finding is
sorted first:

| Bucket | When | Where it lands |
|---|---|---|
| inline | line falls inside a right-side hunk | anchored exactly there |
| nearest | file is in the diff, line is not, but a hunk is within 20 lines (`CLAMP_LIMIT` in `inline.py`) | nearest in-hunk line, **with the true location stated in the body** |
| body | file not in the diff, no hunk within 20 lines, or verdict is `ERROR` | the review's top-level body |

Never let a line number move silently — a clamped anchor with no note is what makes a reader
distrust the whole report. `ERROR` verdicts never go inline: an unchecked claim anchored to
someone else's code is this pipeline's worst output. The event is `COMMENT`, not
`REQUEST_CHANGES`, and `commit_id` is pinned to the reviewed SHA so anchors cannot drift if
the branch moves.

## When it goes wrong

| Symptom | Cause |
|---|---|
| `stage 1: every slice failed` | Usually a rate limit — check `$WORK/chunks/*.json` for a 429. Re-run later; cached slices are not re-paid for. |
| One slice `FAILED` | Its files went unreviewed and the report says so. Re-run to retry just that slice. |
| `stage 1: no findings.json was written` | Opus answered in prose instead of writing the file. Rerun; if it repeats, `~/.claude/skills/pr-review/review.prompt` needs tightening. |
| Everything CONFIRMED | The refutation prompt has stopped discriminating. Re-run the T1b fixture (a fabricated mechanism on a real line) before trusting any output. |
| Everything REFUTED | Usually a tree mismatch — check the head SHA in the report matches the PR. |
| `ERROR` verdicts | Read `$WORK/claims/<id>.err.<attempt>` in the kept work dir. Usually a validator timeout; raise `PR_REVIEW_REFUTE_TIMEOUT`. |
| `one finder per transport` | `PR_REVIEW_FINDERS` names a transport twice. Finder ids are tagged by transport, so two finders on one transport would collide. |
| Many `UNVERIFIABLE` | Evidence burden only. The refuter could neither confirm nor disprove — often a mechanism through a dependency or server. Read each reason; they are unchecked claims, not confirmed ones. |

## Design notes

- Every model reads a **clone at the PR head SHA**, never the local working tree —
  otherwise line numbers resolve against the wrong code and refutations are meaningless.
- **One validator call per claim.** A validator shown a list of findings pattern-matches
  "these are real bugs" instead of checking each.
- The refuter is prompted to **refute**. Asking it to "validate" returns near-100%
  CONFIRMED and the whole second pass becomes theater. Under the `strict` burden an
  unverifiable claim counts as REFUTED; under `evidence` a refutation needs quoted
  counter-evidence and an unresolved claim stays in as UNVERIFIABLE.
