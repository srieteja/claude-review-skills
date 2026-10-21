---
name: intense-review
description: Maximum-effort adversarial review of a GitHub PR. Opus 5.5 at max effort and Gemini 3.8 Flash (high) review the PR in parallel, then glm-5.3-flash over ollama tries to refute every finding under an evidence burden. There is no dollar cap. Use when the user says "/intense-review <number>" or asks for the deepest or most thorough review of a PR.
---

# Intense PR review

A thin preset over `~/.claude/skills/pr-review/pr-review.sh`. It uses the same stages, cache, report
format and posting rules. Read `~/.claude/skills/pr-review/SKILL.md` for everything that isn't
covered here.

## What it runs

| | intense | default `/pr-review` |
|---|---|---|
| finders (stage 1) | `claude-opus-5-5` **@max** and `gemini-3.8-flash-high` (via agy), run in parallel | `claude-opus-5-5` @xhigh |
| refuter (stage 2) | `glm-5.3-flash` via ollama.com | `gemini-3.8-flash-high` via agy |
| burden | **evidence**: REFUTED needs quoted counter-evidence; an unresolved claim stays in as UNVERIFIABLE | **strict**: an unconfirmed claim counts as refuted |
| dollar cap | **none** | $8.00 per slice |
| per-slice ceiling | `PR_REVIEW_S1_TIMEOUT`, default **60m** | 25m |
| stage-1 parallelism | 4 | 3 |
| report store | `~/.reviews/_intense/<author>/<repo>/<N>/` | `~/.reviews/<author>/<repo>/<N>/` |

The two stores are separate, so an intense run never overwrites a default review of the same PR.

## Run it

```bash
~/.claude/skills/intense-review/intense-review.sh <PR-NUMBER> --keep
```

- **Launch in the background** (Claude Code: `run_in_background: true`), then poll the log. With 2 finders, each slice runs twice, and max-effort Opus slices can take most of an hour.
- **Run from inside the repo under review.** `ROOT` comes from cwd.
- **Wants `OLLAMA_API_KEY`** for its glm refuter: put it in `~/.config/review-skills/config.env` (mode 600), which every entry point reads. Without it a refuter of another reachable family is used.
- **Any `pr-review.sh` option passes through:** `--no-cache`, `--sha`, `--findings`, `--post`, `--inline`, `--no-fix`.
- **Stage 5 opens a fix PR** on top of a `PR_REVIEW_FIX_AUTHORS` author's PR (default: none) when a finding is CONFIRMED. Exit 4 means it owed one and opened none -- see pr-review's "Auto-fix PRs".

## Before you run it, tell the user

- **Cost is uncapped.** The timeout is the only ceiling. It applies per slice, per finder. A large PR means many slices × 2 finders at the top effort tier.
- **Egress.** Every claim, plus every source file the refuter opens, is sent to ollama.com.
  - The refuter is limited to `Read`, but `Read` can still open absolute paths outside the review tree.
  - So a PR that injects instructions into it could make it read local files, such as `config.env` or SSH keys.
  - Don't point this at a PR you have reason to distrust.

## Reading the report

- **Finding ids carry the finder**, e.g. `anthropic.c01-F1` or `agy.c03-F2`.
  - When both finders flagged the same spot, the finding lists the other finder's id under **Also reported as**.
  - That is the strongest signal in the report.
- **UNVERIFIABLE lands in the disputed bucket and stays in the report.** It is the cost of the evidence burden:
  - Stage 2 no longer silently drops a real bug it couldn't trace.
  - It also lets through claims nobody could check.
  - Read the refuter's reason, which says what it could not establish.
- **Treat Gemini findings against their cited line with suspicion.**
  - Across repeated runs, agy sometimes resolves paths against the live working tree instead of the PR head (`~/.claude/skills/pr-review/FINDING-agy-ignores-tree.md`).
  - The glm refuter runs through `claude -p`, which honours cwd, so it checks each claim against the pinned tree.
- **ERROR verdicts, gap banners and refuted findings** get the same handling as in `/pr-review`.

## Overrides

| env | default |
|---|---|
| `PR_REVIEW_INTENSE_FINDERS` | the best reachable per transport, at most two, from `lib/models.tsv` — `anthropic:claude-opus-5-5@max agy:gemini-3.8-flash-high` with every backend reachable |
| `PR_REVIEW_INTENSE_REFUTER` | the best reachable of a family no finder is from — `ollama:glm-5.3-flash` with every backend reachable |
| `PR_REVIEW_INTENSE_DIR` | `~/.reviews/_intense` |
| `PR_REVIEW_S1_TIMEOUT` | `60m` |
| `PR_REVIEW_STAGE1_JOBS` | `4` |

The burden and the missing budget cap are fixed. Without them the preset is just a two-finder `/pr-review`.

## Before trusting a change to the refuter

```bash
PR_REVIEW_REFUTER=ollama:glm-5.3-flash PR_REVIEW_BURDEN=evidence ~/.claude/skills/pr-review/selftest.sh
```

- **Both fakes must come back REFUTED.** Under the evidence burden, the true claim may come back UNVERIFIABLE.
- **A fake that comes back UNVERIFIABLE means the burden has stopped discriminating.** Don't trust intense reports until it passes again.

## Posting

Posting follows the same rules as `/pr-review`: never unprompted, and ask every time. The report is at
`~/.reviews/_intense/<author>/<repo>/<N>/pr<N>-review.md`.
