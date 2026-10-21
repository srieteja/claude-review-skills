# Design: `ollama-agents`

Source plan: `~/.claude/plans/can-you-come-up-snuggly-eclipse.md`.

## Why this exists

`delegate` dispatches to antigravity: one executor, one worktree, a patch back. It's the default
executor and it's good, but it's a single funnel — one vendor, one quota, one concurrency
ceiling, and every byte of the repo it reads goes to Google. This is a sibling that fans work out
to Ollama's **hosted** API instead (the user has Ollama Pro and asked specifically for the cloud
route, not the local daemon).

## The premise that turned out to be false

The plan started from *"Ollama is a model server, not an agentic CLI, so the tool loop has to be
written."* That's wrong, and finding out was the most valuable thing the probes did: Ollama ships
an **Anthropic Messages API compatibility layer** (v0.14.0+) at `https://ollama.com/v1/messages`.
The agentic harness — tool loop, compaction, permission enforcement, resume — is already written,
and it's `claude` itself. This skill is `agy-do`'s twin, not a bespoke agent loop.

## What the probes established

| Probe | Finding | Consequence |
|---|---|---|
| `POST /v1/messages` unauth | `401`, Anthropic-shaped error envelope | Route exists, real compat layer, not a catch-all |
| `POST /anthropic/v1/messages` | `404` | Confirms the 401 above is a real route, not a wildcard |
| Docs + ollama/ollama#16922 | Tools, streaming, system prompts, thinking supported. No prompt caching, no `count_tokens`, no `tool_choice`. Cloud rejects `x-api-key`, accepts `Authorization: Bearer` | Harness is viable; caching is not |
| Live `--ask` × 2, reading the result event's full `usage` | `cache_creation_input_tokens` **0** (and nested `ephemeral_5m`/`ephemeral_1h` both 0) while `cache_read_input_tokens` reads 2944 against `input_tokens` 1513, and 2176 against 580 | Confirms "no prompt caching" **by measurement**, and exposes the trap below: the field is echoed, not honoured |
| `GET /api/tags`, `/api/show`, `/v1/models` | Public, no key | Capability gate is free |
| `POST /api/chat` unauth | `401` | Key is a hard prerequisite for actual inference |
| `/api/show` × 19 models | All 19 advertise `tools`; contexts 131k–1,048,576 | Weak-model tiering is moot |
| `ollama launch` | 19 integrations incl. `claude` and `dsh` | Ollama treats agentic CLIs as the front end |
| `dsh` on PATH | v0.1.2-rc.1, only `web` profile provisioned | See *Why not dsh* |
| `qwen2.5-coder:1.5b` + JSON schema `format` | Schema-valid, semantically wrong output | Constrained decoding guarantees shape, never truth — governs `--map`'s scope |

That last row shapes `--map`: **extraction** (find the string, cite the line — verifiable
downstream) is honest work for a one-shot schema call; **classification** (assign a severity) is
silently not. `--map` stays extraction-only.

## Decisions

- **Executor is `claude` pointed at Ollama.** `ANTHROPIC_BASE_URL=https://ollama.com`,
  `ANTHROPIC_AUTH_TOKEN=$OLLAMA_API_KEY`, `--model <ollama model>`. Same shape as `agy-do`, so
  the worktree/guard/patch/verdict machinery ports almost mechanically — with two real
  corrections, below.
- **Two API paths, deliberately.** Loop modes (`--task`/`--tasks`/`--ask`) go through the
  harness at `/v1/messages`. `--map` goes direct to `/api/chat` with `format: <json schema>` —
  200 one-shot structured calls through a full agentic harness is the wrong tool. This is a
  decision, not an inconsistency to "unify" later.
- **Two endpoints, one protocol: `--transport ollama|anthropic`.** The worktree/guard/patch/
  resume contract never depended on Ollama, so a caller that needs a model only Anthropic serves
  (standup's fix button, on `claude-opus-5-5`) reuses this driver instead of a third copy of the
  guard. `anthropic` swaps `ollama_env` for `anthropic_env` — the mirror contract: it strips
  `ANTHROPIC_BASE_URL`/`AUTH_TOKEN`/`CUSTOM_HEADERS`/`MODEL`, `CLAUDE_CODE_SIMPLE` and an inherited
  `ANTHROPIC_API_KEY` (kept only under `ANTHROPIC_USE_API_KEY=1`) so the call lands on the caller's
  own Claude login, never on ollama.com or API billing by inheritance — and skips the
  `OLLAMA_API_KEY` and `/api/show` gates. It refuses `--map` (an ollama.com `/api/chat` call with
  no Anthropic counterpart). Default stays `ollama`. The script name now names only its first
  endpoint; renaming it is deferred, not forgotten.
- **Model default from a bake-off, not a guess.** Seeded with `glm-5.3`; see *Models* below.
  `bakeoff.sh` measures the three seeds; none of the rankings here are measured yet.
- **Cloud only, loud about it.** `SKILL.md` states in its first paragraph that file contents
  leave the machine. There is no `--local-only` — meaningless against a cloud-only endpoint.
- **Startup gate is `/api/show` capabilities.** Refuse if `tools` is absent. One unauthenticated
  call, no key spent checking before paying for inference.
- **Reuse `delegate`'s contract wholesale.** `OK`/`PARTIAL`/`NO-OP`/`FAILED`, exit `0`/`3`/`1`,
  `.stat`/`.patch`/`.answer`/`.err`, never auto-apply, never `cat` the raw envelope.
- **`--map` does not require a repo.** A plain directory of checkouts isn't one and must still support `--map`.
  Only the loop modes cut worktrees.

## Why not dsh (the DeepSeek Harness)

No material advantage, and it costs more. Both harnesses reach the *same 19 models* through the
*same ollama.com endpoint*, so the harness determines reliability, not quality — and on
reliability `claude` is 2.1.265 and already installed, while `dsh` is v0.1.2-rc.1 with an
unprovisioned `headless` profile. Choosing it means re-deriving envelope shape, resume semantics,
cwd handling, and permission model from scratch — precisely the cost `delegate`'s own design
notes exist to stop paying twice.

One argument survives: `dsh` is DeepSeek's own harness, tuned for DeepSeek models. Revisit only
if the bake-off puts `deepseek-v4-pro` decisively ahead.

## Models — seeded candidates for a measured bake-off

Rankings are from published metadata (params, context, capabilities) and family track record.
**Not measured** — `bakeoff.sh` is step 1. `selftest.sh` has confirmed `glm-5.3` and
`deepseek-v4-pro:0813` both resolve and complete live, exactly as tagged below; `kimi-k3` and the
`--map`-tier models are still unverified.

| Role | Model | Ctx | Params | Why |
|---|---|---:|---:|---|
| Driver default | `glm-5.3` | 1,048,576 | 753B | Best capability-per-size balance; strongest track record on coding agents |
| Heavyweight | `kimi-k3` | 1,048,576 | 2,812B | Largest available; vision + thinking, for hard slices |
| Cross-check | `deepseek-v4-pro:0813` | 1,048,576 | 1,650B | Independent family — a genuine second opinion |
| `--map` fan-out | `glm-5.3-flash` | 1,048,576 | 321B | Same family as the driver |
| `--map` floor | `nemotron-3-nano:30b` | 262,144 | 32B | ~10× cheaper; fan-out is where the economics live |
| Code specialist | `kimi-k2.7-code` | 262,144 | 1,042B | Alternative driver if code-tuned models win the bake-off |

## Two corrections found during implementation, not in the original plan

The plan's own draft was styled after `agy-do`'s bash and predated verification against the real
`claude` CLI and a live envelope capture. Two things changed, not just flag renames:

1. **No `--conversation` flag exists.** The real resume mechanism is `-r/--resume <session-id>`.
   `ollama-do` uses `--resume`, and the id comes from the result event's `session_id`
   (`<id>.resume`), not a `conversation_id` field.
2. **The envelope is a JSON array of typed events, not a flat object**, verified via a live
   `claude -p ... --output-format json` call. The final `{"type":"result",...}` element carries
   `is_error` — and `is_error` is the only trustworthy success signal. A captured real response
   showed `"subtype":"success"` sitting right next to `"is_error":true` on a rate-limited turn.
   `parse_envelope` in `ollama-do` checks `is_error`, never `subtype`. Test 15 in
   `offline-test.sh` exists specifically to pin this down — a mechanical port of `agy-do`'s
   `status == "SUCCESS"` check would have turned a rate-limited, failed turn with an empty diff
   into a silent `NO-OP`.

## Traps encoded in code, not comments

1. **`Authorization: Bearer`, never `x-api-key`.** `ANTHROPIC_AUTH_TOKEN`, not
   `ANTHROPIC_API_KEY` — the latter sends `x-api-key`, which ollama.com rejects
   (ollama/ollama#16922).
2. **A nested `claude -p` inherits the user's whole world** unless isolated —
   `--strict-mcp-config` plus `--setting-sources ""` keep ~70 `gsd-*` skills, every MCP server,
   hooks, and `CLAUDE.md` out of the nested session.
3. **Model naming is unverified against a live call.** `selftest.sh` pins bare `glm-5.3` vs. a
   possible `:cloud` suffix before anything else runs live.
4. Patches are taken against a **recorded base SHA, not `--cached`**.
5. The guard snapshots `HEAD`, all refs, and the stash alongside `status --porcelain`.
6. `implement.prompt` wraps every task, because an unattended model that ends with "let me know
   if you approve" comes back as success with an empty diff — `NO-OP` exists to catch exactly
   this.
7. The envelope is parsed with Python `json.loads(strict=False)`, not `jq` — raw control
   characters inside JSON strings break strict JSON.
8. **`CLAUDE_CODE_SIMPLE=1` is load-bearing, not cosmetic.** A nested `claude` with an active
   OAuth login prefers the Keychain-stored `Claude Code-credentials` session over
   `ANTHROPIC_AUTH_TOKEN` and silently sends that Bearer token to ollama.com instead — a 401
   that looks like a bad key, not a crash. Confirmed by capturing the actual outbound request:
   without the flag the body ran ~135KB with a longer `anthropic-beta` list; with it, ~4KB.
   `claude --help` documents the flag as making Anthropic auth "strictly `ANTHROPIC_API_KEY` or
   `apiKeyHelper`" — it never mentions `ANTHROPIC_AUTH_TOKEN` by name, so this is empirically
   verified (both `--ask` and `--task` return real results under it) but silently regressible on
   a CLI upgrade. **Pinned in both places.** Offline: `stub-claude` dumps its own `env` and
   argv to `$OLLAMA_DO_STUB_TRACE`, and `offline-test.sh` poisons the caller's environment
   (`ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_CUSTOM_HEADERS`, a haiku
   `ANTHROPIC_SMALL_FAST_MODEL`) before asserting none of it survives into the executor. Free, and
   it catches the regression on the run that introduces it rather than on a live 401. Live:
   `selftest.sh` now sources the same `lib/transport-env.sh` the tool does, so its call cannot pass
   under an environment `ollama-do` never builds.

   **Reproducer** — drop the flag and change nothing else:

   ```bash
   ANTHROPIC_BASE_URL=https://ollama.com ANTHROPIC_AUTH_TOKEN=$OLLAMA_API_KEY \
     claude -p ping --model glm-5.3 --output-format json
   ```

   The result event comes back `is_error: true` beside `subtype: "success"` with
   `result: "Failed to authenticate. API Error: 401 Unauthorized"` — trap #2's shape (a
   truthful `is_error` beside a lying `subtype`), reached here from the auth path rather than
   from a rate limit. The init event's tool list is the full harness; with the flag it is
   `["Bash","Edit","Read"]` and the same call returns `pong`.

   What that establishes: **the flag is load-bearing for auth, not merely for shrinking the tool
   surface.** What it does *not* establish is the Keychain mechanism described above — that
   remains the working hypothesis. A Keychain credential is not an environment variable, so
   confirming `ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` are unset (they were) neither
   confirms nor refutes it. Do not upgrade the confidence of the first paragraph on the strength
   of this reproducer.

9. **`run_claude` `cd`s into the worktree before invoking `claude`.** `--add-dir` alone grants an
   *additional* allowed path — it does not change cwd or the model's sense of "the current repo".
   Verified live: an explicit "read tracked.txt" request failed to find a file that existed only
   in `--add-dir`'d worktree, and an open-ended "list every file" prompt described the invoking
   shell's own directory instead. The `cd` is the actual confinement mechanism for path
   resolution; `--add-dir` is a second grant on top of it, not a substitute.

10. **The small/fast model tier is pinned to `$MODEL`, not unset.** Unsetting
   `ANTHROPIC_SMALL_FAST_MODEL`/`ANTHROPIC_DEFAULT_HAIKU_MODEL` restores `claude`'s built-in
   default, which is a `claude-haiku-*` id ollama.com does not serve — so a nested background call
   404s against a key that is otherwise fine. Overriding both to the driver model costs marginally
   more per background call and always resolves. `ANTHROPIC_MODEL` *is* unset, because `--model`
   on argv is the single source of truth; `ANTHROPIC_CUSTOM_HEADERS` is stripped because a header
   configured for the user's own Anthropic account has no business on an ollama.com request.

11. **`cache_read_input_tokens` from this endpoint is not evidence of caching.** Measured twice
   live: creation 0, read larger than `input_tokens`. Ledger column 12 records creation beside it
   so the next reader sees the contradiction in the data instead of trusting column 9. Don't
   "optimize" against that number.

12. **The envelope salvage scan runs backwards, with a budget.** The result event is the last
   element, so a forward unbounded `raw.find('{', i+1)` + `json.loads(raw[i:])` per offset is
   O(n²) on exactly the crashed-run envelope that most needs a fast failure — measured at 5.3s
   over 4MB, versus 0.045s scanning the tail with a 200-attempt cap.

13. **The capability gate reads `capabilities`, not the response body.** `/api/show` returns
   `{capabilities, details, model_info, modified_at}`; `details` and `model_info` are free-form
   vendor metadata, so a substring test for `"tools"` anywhere in the body passes a model that
   never advertised the capability. Pinned by a decoy fixture in `offline-test.sh`.
## Confinement — what the claim actually is

The old `delegate`-adjacent framing claimed *enforced* confinement because the tool
implementations were owned end to end. That's not true here — `claude`'s tool loop is not this
skill's code:

> Confinement is enforced by the **explicit `cd` into the worktree before invoking `claude`**
> (path resolution — including an open-ended prompt's whole sense of "this repo" — happens
> against cwd, not `--add-dir`; verified live, see trap #9) **plus the harness's own permission
> layer** (deny-rules on writes outside the tree) **and the escape guard**. Stronger than `agy`,
> where `delegate` itself concedes escape is *detected, not prevented*. Weaker than owning the
> tool implementations.

**`--dangerously-skip-permissions` is therefore more load-bearing here than in `delegate`**: if
it's ever passed, the harness's deny-rules are gone and the worktree plus guard is the *entire*
boundary. If worktree isolation is ever removed, the flag must go with it.

## Retry responsibility differs by API path

`--task`/`--tasks`/`--ask` go through `claude`'s own harness — rate-limit retry there is the
harness's job, not `ollama-do`'s. `--map` bypasses the harness entirely, so `map.py` owns its own
`429` + `Retry-After` backoff per call. Don't conflate the two: "every call honours 429" is true
of `--map` only, not of the loop modes.

## Honest positioning

This does **not** displace `delegate` for implementation. The real wins:

- **`--map`** — the same prompt over many files, one call each. `delegate` has no equivalent.
- **Quota independence** — runs when antigravity's quota is spent.
- **Model choice** — three frontier families behind one flag, including a genuine cross-check.

The cost, stated plainly: **Ollama's compat layer has no prompt caching.** `delegate`'s measured
219,489/276,875 input tokens (79%) from cache on `--ask` does not transfer. Still worth it — the
local saving (answer costs you the answer, not a grep-and-read sweep) still holds — but not the
same deal.

This was inherited from the docs and is now **measured**: two live `--ask` runs report
`cache_creation_input_tokens: 0` with a non-zero `cache_read_input_tokens` *exceeding*
`input_tokens`. The number in the ledger is an echo, not a discount. See trap #11.
