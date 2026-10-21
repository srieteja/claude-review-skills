---
name: delegate
description: Hand an approved plan to antigravity, which implements it in an isolated git worktree and returns a reviewable patch — the read-edit-test loop never enters Claude's context. Also answers whole-repo questions without the codebase entering context, warm worktree or cold. Use when implementing from a plan, fanning work out across slices, when a question would otherwise mean a Grep-and-Read sweep, or when the user says "/delegate".
---

# Delegate implementation to antigravity

Lives at `~/.claude/skills/delegate/`, outside any repo. It resolves its own assets relative to
itself, so **run it from inside whatever repo you are working on** — `--root` is the repo it
guards and the base for every worktree.

The whole point is token economy. The executor reads files, edits, builds and retries inside
its own worktree; the only things that come back are a patch and a stat. Undoing that
discipline undoes the skill.

## Run it

```bash
~/.claude/skills/delegate/agy-do --task plan.md --root . --keep
```

**Launch it with `run_in_background: true` and poll the log.** An implementation that builds
and tests runs well past the foreground Bash cap — the default `--print-timeout` is 45m.

Fan-out is the same command, plural. One worktree per slice, `--jobs` in flight at once:

```bash
~/.claude/skills/delegate/agy-do --tasks slices/ --root . --jobs 3
```

Slices must be **file-disjoint** — you decide that when you write them. The script does not
enforce it, but it reports any path touched by more than one patch. Apply those in sequence and
re-check, never blind.

**`--task` implements; it does not investigate.** `implement.prompt` carries a legitimate
escape clause — conclude the task requires no change, make no edit, say so. Hand it a *finding*
or a "is this right?" question and the executor can land on that clause having checked nothing,
returning `OK` — the exact shape of a review slice reading as clean when it read nothing. Any
finding-shaped work goes through `--ask`, where answering requires opening the code.

**It never applies anything.** It prints the `git apply` command and stops.

## What to read back

- `<work>/<id>.stat` first, then `<work>/<id>.patch`.
- **Do not `cat` the raw envelope.** `<id>.raw.json` holds the executor's full narration and
  exists to be diagnosable, not to be read. Reading it pours everything you just saved back
  into context.
- `<id>.err` only when a task did not settle.

## Asking instead of grepping

```bash
~/.claude/skills/delegate/agy-do --ask "where is the reconnect backoff computed?" --root .
```

`--tree` is optional. Pass one after a slice is implemented and the executor is still holding a
warm, indexed view of that workspace; omit it and `--ask` cuts a clean worktree of its own. The
warm tree is cheaper on the far side, but that is the smaller half — see below.

**Reach for `--ask` before grepping locally.** A question answered by the executor costs you the
answer; the same question answered by your own Grep-and-Read sweep costs thousands of tokens and
lands whole files in context. That saving is yours and does not depend on anything Google does.

The far-side discount is a bonus on top: measured **219,489 of 276,875 input tokens (79%)** from
cache on a repo-sized workspace. The cache is keyed on the `--add-dir` workspace, not on
conversation history, so a fresh `--ask` against an already-used tree gets it without resuming.

**Verify anything you will act on.** The answer is a model's claim about a repo you have not
read. It has already earned its keep — one `--ask` found a public function in `atchops/rsa.h`
declared and implemented nowhere — but that finding was worth a one-line `grep` to confirm
before anyone acted on it. Ask to *locate* and to *rule out*; confirm before you edit.

`--ask` runs read-only: no edit mode, no permission bypass. The `--root` guard still applies,
because a read-only *intent* is not a read-only *capability*.

The question is wrapped in `ask.prompt` for the same reason implementations are wrapped — an
unprompted executor asks *you* a clarifying question, and that comes back `SUCCESS` too. There
is no `NO-OP` equivalent on this side to catch it: an answer and a question are both prose. So
**read `<id>.answer` before you act on it.** If it asks you something instead of answering, the
question was underspecified — name files or symbols and re-ask. That is the one failure mode
`--ask` cannot detect for you.

## Correction rounds

`<id>.conv` holds the executor's `conversation_id`. Resuming re-sends nothing — it still has
the codebase and the original task, so you send only what is wrong:

```bash
~/.claude/skills/delegate/agy-do --conversation "$(cat <work>/<id>.conv)" \
    --tree <work>/tree/<id> --task delta.md --root .
```

This is what makes delegation cheaper than implementing directly. A correction that costs a
full re-brief is where the economics invert.

## Verdicts

| Verdict | Meaning |
|---|---|
| `OK` | Review the patch. |
| `PARTIAL` | The executor did not finish but **wrote files**. The most dangerous output this produces — a half-implemented change that still applies cleanly. Read every hunk; never bucket it with `FAILED`. |
| `NO-OP` | Reported success and changed nothing. A failure, not a pass. Usually the task was too vague to act on, or it decided the work was already done — check which before re-running. |
| `FAILED` | Read `<id>.err`. |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Every task settled, `--root` untouched. |
| 3 | Settled, but the executor wrote scratch into `--root`. Quarantined in `<work>/escaped`; the patches are still good. |
| 1 | Refused: the executor modified tracked files or git metadata in `--root`. Left in place — inspect before doing anything else. |

## When it goes wrong

| Symptom | Cause |
|---|---|
| Everything `NO-OP` | Read `<id>.answer`. If it ends by asking to proceed, the preamble is not reaching the model — check `implement.prompt` is being applied. Otherwise the task is too abstract: the executor needs file paths and concrete changes, not intent. |
| `PARTIAL` on every slice | Slices are too big for `--timeout`. Split them or raise it. |
| Patch does not apply to `--root` | `--root` moved since the worktree was cut. Re-run against current `HEAD`. |
| Exit 1 on a clean-looking run | Something ran `git commit`/`stash`/`branch` inside the worktree. Shared git metadata is not isolated by worktrees — see the design notes. |
| `FAILED` with an empty `.err` | Usually a timeout. Check `<id>.raw.json` for a truncated envelope. |

## Design notes

Three of these were paid for once already, in `~/.claude/skills/pr-review/`. Do not re-derive them.

- **`agy` does not inherit cwd.** A `cd` before invoking accomplishes nothing; it runs in its
  own scratch dir and resolves relative paths against its *persisted project root*. Only
  `--add-dir <absolute path>` re-roots it. Without it, every read and write silently lands in
  the live repo and the result is indistinguishable from a correct one. See
  `pr-review/FINDING-agy-ignores-tree.md`. **The resume path passes it too.** Verified: with
  `--add-dir` supplied, a resumed session reported `pwd` inside the worktree and resolved a
  repo-relative path there. Keep passing it — it costs nothing and the failure would be silent.
- **The executor must be told it is unattended, or it answers conversationally.** Observed
  twice on real runs: it read the code, produced a correct and specific plan, and ended with
  *"let me know if you approve"*. Print mode returned that as `SUCCESS` with an empty diff.
  `--mode accept-edits` and `--dangerously-skip-permissions` do not prevent it — they grant
  permission the model never asks for. `implement.prompt` is what does, and `agy-do` wraps every
  implementation task in it, because a caller cannot be relied on to remember. This is the
  failure `NO-OP` exists to catch.
- **`--sandbox` is terminal restrictions, not filesystem confinement.** Escape is detected, not
  prevented. The guard snapshots `status --porcelain` **plus `HEAD`, all refs, and the stash**,
  because `$TREE/.git` is a pointer into `$ROOT/.git/worktrees/` — porcelain alone cannot see a
  `git stash` or `branch -f` run from inside the worktree.
- **`--dangerously-skip-permissions` is load-bearing, and conditional.** With
  `tools.shell.default: "ask"` in `~/.gemini/settings.json` and no build tools on its allowList,
  print mode has nobody to ask, so any build hangs until the timeout. It is acceptable *only* because the blast
  radius is a throwaway worktree plus that guard. **If the worktree isolation is ever removed,
  the flag must go with it.**
- **Patches are taken against a recorded base SHA, not `--cached`.** An executor that commits
  inside its worktree leaves nothing staged, and `--cached` would report a finished multi-file
  implementation as `NO-OP`.
- **The envelope is parsed with Python, not jq.** `agy` has emitted stdout containing raw
  control characters inside JSON strings, which `jq` rejects outright — taking the
  `conversation_id` down with it, which silently costs the correction round its cheap path.
  `json.loads(strict=False)` accepts it.
- **No `--json-schema`; answers come from `.response`.** The plan called for a schema so
  `--ask` could read the clean `.structured_output` instead of the field `refute` warns carries
  stray tool-narration. Dropped deliberately: schema-shaped output is worth having when a
  *program* consumes it, as in `refute`, but here the consumer is me reading prose, and a schema
  would constrain the answer's shape without making it more trustworthy. The cost is that
  narration can bleed into `<id>.answer`. Revisit if `--ask` ever feeds something automated.

## Reading the ledger

Rows written before `implement.prompt` existed record `NO-OP`s that were conversational
failures, not vague tasks — the first two rows against `at_c`. They are indistinguishable from
real no-ops in the file. Discount them when judging whether delegation pays; every row after
2026-09-07 is honest.

Before trusting a change to the toolkit itself, run `offline-test.sh` — it stubs the executor
and checks the plumbing for free, including every guard and every verdict boundary.
