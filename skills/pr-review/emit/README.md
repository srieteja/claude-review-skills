# emit/

How stage 1 returns its findings, swapped by each finder's transport into the two
`__EMIT_*__` markers in `review.prompt`.

| mode | used by | why |
|---|---|---|
| `file` | `anthropic` | the model writes `__OUT__` itself, via `Write` |
| `stdout` | `ollama` | the direct client (`lib/ollama_messages.py`) has no `Write` tool, so the model returns the object in its reply, which becomes `.result` |
| `schema` | `agy` | `--json-schema findings.schema.json` constrains the reply; the object is read from `.structured_output` |

`agy --json-schema` takes a **path**; `claude --json-schema` takes **inline JSON**. The
schema file is part of the finder's prompt checksum, so editing it invalidates cached slices.

The ollama finder is a direct client, not `claude`: its tools are `Read`, `Glob` and `Grep`,
confined to the clone, and there is no `Write` to hand the model. Asking for a file there
would yield 100% slice failure — a clean report over zero coverage, the pipeline's worst
output. (The ollama *refuter* still runs under `claude -p`, where `--allowedTools` is an
intersection, not a union, and `CLAUDE_CODE_SIMPLE=1` fixes a 2-tool surface; see
`lib/transport-env.sh`.)

`file.*` is byte-identical to what `review.prompt` carried inline before the split, so the
anthropic path is unperturbed. `stdout.*` is the exact text the discrimination gate ran with.
