---
name: ollama-agents
description: Delegate's twin, routed at Ollama's hosted cloud API instead of Google's antigravity. Hands an approved plan to `claude` itself — pointed at Ollama's Anthropic-Messages-API compat layer — which implements it in an isolated git worktree and returns a reviewable patch. Also does one-shot structured extraction across many files via --map, with no agentic harness and no repo required. Use when delegate's quota is spent, when a task wants a different model family as a cross-check, or when the job is --map-shaped (the same extraction over many files). Use when the user says "/ollama-agents".
---

# Delegate implementation to Ollama's cloud

**File contents in this workspace leave the machine and go to Ollama's cloud API.** Say so
before running this against anything sensitive — this is a cloud-only skill, deliberately; there
is no `--local-only`.

Lives at `~/.claude/skills/ollama-agents/`, outside any repo. Run it from inside whatever repo
you're working on for `--task`/`--tasks`/`--ask` — `--root` is the repo it guards and the base
for every worktree. `--map` needs no repo at all.

This is `delegate`'s twin, not a replacement. Read [DESIGN.md](DESIGN.md) for why two API paths
exist and why `dsh` wasn't chosen. **Ollama's compat layer has no prompt caching** — `delegate`'s
measured 79% cache-read discount on `--ask` does not transfer here. Still worth it for the
reasons below, but not the same deal.

**Ignore the `cache_read` column in the ledger.** It is non-zero and it means nothing. Measured
live: `cache_creation_input_tokens` is `0` — flat field and the nested `ephemeral_{5m,1h}`
breakdown alike — while `cache_read_input_tokens` comes back *larger than `input_tokens`* (2944
against 1513; 2176 against 580 on a second run). The compat layer echoes the field without
honouring it. Column 12 records creation next to it so the contradiction is visible in the data.

## Prerequisite

```bash
export OLLAMA_API_KEY=...   # create one at https://ollama.com/settings/keys
```

`ollama-do` reads this from the environment; nobody else sees it. A missing key produces a
one-line remediation, not a stack trace.

`--transport anthropic` needs no key: the same worktree/patch/resume protocol runs on your own
Claude Code login (default model `claude-opus-5-5`, `--map` refused). See DESIGN.md *Decisions*.

## Run it

```bash
~/.claude/skills/ollama-agents/ollama-do --task plan.md --root . --keep
```

**Launch it with `run_in_background: true` and poll the log** — the default `--timeout` is 45m
and a real implementation can run past the foreground Bash cap.

Fan-out is the same command, plural:

```bash
~/.claude/skills/ollama-agents/ollama-do --tasks slices/ --root . --jobs 2
```

Slices must be **file-disjoint** — you decide that when you write them. `ollama-do` does not
enforce it but reports any path touched by more than one patch. `--jobs` defaults to **1**: Pro
tier is a request-rate budget with an undocumented ceiling, and a guessed high `--jobs` that
trips a rate limit mid-fan-out is exactly the silent-partial failure this skill exists to avoid.
Raise it once a real run has recorded headroom.

**`--task` implements; it does not investigate.** `implement.prompt` carries a legitimate
escape clause — conclude the task requires no change, make no edit, say so. Hand it a *finding*
or a "is this right?" question and the executor can land on that clause having checked nothing,
returning `OK` — the exact shape of a review slice reading as clean when it read nothing. Any
finding-shaped work goes through `--ask`, where answering requires opening the code.

**It never applies anything.** It writes a `.patch` and stops.

## What to read back

- `<work>/<id>.stat` first, then `<work>/<id>.patch`.
- **Do not `cat` the raw envelope.** `<id>.raw.json` is a JSON array of the executor's full
  turn-by-turn narration, kept for diagnosis, not for reading — it pours everything you just
  saved back into context.
- `<id>.err` only when a task did not settle.

## Asking instead of grepping

```bash
~/.claude/skills/ollama-agents/ollama-do --ask "where is the reconnect backoff computed?" --root .
```

`--tree` is optional — pass one after a slice is implemented and the executor still holds a warm
workspace; omit it and `--ask` cuts a clean worktree of its own. Unlike `delegate`, there is no
far-side cache discount here (measured, not assumed — see above): the saving that matters is still
the same one — the answer enters your context, not the codebase.

`--ask` runs read-only: no `--dangerously-skip-permissions`. **Verify anything you will act on**
— it's a model's claim about a repo you haven't read.

## One-shot extraction across many files: `--map`

```bash
~/.claude/skills/ollama-agents/ollama-do --map src/ --schema @schema.json
```

No worktree, no `--root`, no git repo required — this is a direct call to `/api/chat` per file
with a JSON-schema response format, not an agentic session. `delegate` has no equivalent; this
is where the economics are lopsided (one call per file, not a full agentic turn per file).

**This is honest for extraction, not for classification.** "What does this file say" is a
verifiable, one-shot job a schema can constrain correctly. "Is this file good" is not — a schema
guarantees shape, never truth, and a small model can hit the schema while being semantically
wrong (observed live against `qwen2.5-coder:1.5b` during this skill's own probing). Keep `--map`
prompts to extraction; route judgment calls through `--task`/`--tasks`/`--ask` instead, where a
full agentic turn can look things up before deciding.

Writes `<work>/results.json`: one entry per file, `{"status": "ok"|"failed", "data"|"error": …}`.
A `429` backs off and retries per file; one file's schema-invalid response is marked `failed`
without sinking its siblings.

## Correction rounds

`<id>.resume` holds the executor's `session_id`. Resuming re-sends nothing — it still has the
codebase and the original task, so send only the delta:

```bash
~/.claude/skills/ollama-agents/ollama-do --resume "$(cat <work>/<id>.resume)" \
    --tree <work>/tree/<id> --task delta.md --root .
```

## Verdicts

| Verdict | Meaning |
|---|---|
| `OK` | Review the patch. |
| `PARTIAL` | Did not finish but **wrote files**. Read every hunk; never bucket with `FAILED`. |
| `NO-OP` | Reported success and changed nothing. A failure, not a pass. |
| `FAILED` | Read `<id>.err`. Includes rate-limited turns — a turn can carry `is_error:true` next to `subtype:"success"`; that is `FAILED`, never a silent `NO-OP`. |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Every task settled, `--root` untouched. |
| 3 | Settled, but the executor wrote scratch into `--root`. Quarantined in `<work>/escaped`. |
| 1 | Refused: the executor modified tracked files or git metadata in `--root`. |

`--map` never touches git and always exits 0 for a completed batch — check `results.json` for
per-file failures instead.

## Design notes

- **Executor is `claude` itself, pointed at Ollama.** `ANTHROPIC_BASE_URL=https://ollama.com`,
  `ANTHROPIC_AUTH_TOKEN=$OLLAMA_API_KEY` — **never** `ANTHROPIC_API_KEY`, which sends
  `x-api-key`; ollama.com's cloud rejects that header (ollama/ollama#16922).
- **A nested `claude -p` does not inherit your world.** `--strict-mcp-config` and
  `--setting-sources ""` keep this session from pulling in your own ~70 skills, MCP servers,
  hooks, and `CLAUDE.md` — a leak here is a silent path back to your own Anthropic subscription.
- **Patches are taken against a recorded base SHA, not `--cached`** — an executor that commits
  inside its worktree leaves nothing staged.
- **The guard snapshots `HEAD`, all refs, and the stash**, not just `status --porcelain` — a
  worktree's `.git` is a pointer into `--root`'s `.git/worktrees/`, so a `git stash` or
  `branch -f` run inside it is invisible to porcelain alone.
- **`--dangerously-skip-permissions` is more load-bearing here than in `delegate`.** If it's ever
  passed on `--ask` too, or if worktree isolation is ever dropped, this guard becomes the entire
  confinement boundary rather than a backstop — see the confinement section in `DESIGN.md`.
- **The envelope is a JSON array, not a flat object**, and is parsed with Python
  (`json.loads(strict=False)`), not `jq` — `claude`'s stdout has carried raw control characters
  inside JSON strings, which strict JSON rejects.
- **No `--print-timeout` on the real `claude` CLI** — `ollama-do` wraps every invocation in
  `timeout`/`gtimeout` externally instead.

## Testing the toolkit itself

| Script | Cost | What it pins |
|---|---|---|
| `offline-test.sh` | free — stubs the executor, no key, no network | Every guard and verdict boundary, the credential-isolation contract (no `ANTHROPIC_API_KEY`, `CLAUDE_CODE_SIMPLE=1`, `--strict-mcp-config`, empty `--setting-sources`, no permission bypass on `--ask`), and the capability gate |
| `selftest.sh` | one live call | Model naming (bare `glm-5.3` vs a `:cloud` suffix) and that `ANTHROPIC_AUTH_TOKEN` clears the cloud gate — **through `lib/transport-env.sh`, the same environment `ollama-do` builds**, so it cannot pass under an env the tool never uses |
| `bakeoff.sh` | three live calls | Compares `glm-5.3` / `kimi-k3` / `deepseek-v4-pro:0813` on one `--ask` |

Run `offline-test.sh` before trusting any change to the toolkit. It is free; there is no reason
not to.

`lib/transport-env.sh` holds `ollama_env()` — the credential-isolation contract — and reaches both
`ollama-do` and `selftest.sh` through `lib/common.sh`. It was inline in `ollama-do` while `selftest.sh` kept a shorter
hand-rolled copy; the copy drifted, lost `CLAUDE_CODE_SIMPLE=1`, and failed a live call `ollama-do`
was passing with the same model on the same machine. **Change the environment there, not in a
caller** — a second copy makes the live pin test something other than the tool.

## Reading the ledger

`~/.local/state/ollama-do/ledger`, one tab-separated row per task, 12 columns:

```
timestamp  root  id  model  verdict  status  in  out  cache_read  secs  files  cache_creation
```

`awk -F'\t' '{i+=$7; o+=$8} END {print i, o}'` totals input/output tokens. Columns 1–11 are
stable — `cache_creation` was appended, never inserted. **`cache_read` (column 9) is not a real
discount** — see the note at the top.
