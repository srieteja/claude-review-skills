# emit/

How stage 1 returns its findings, swapped by each finder's transport into the two
`__EMIT_*__` markers in `review.prompt`.

| mode | used by | why |
|---|---|---|
| `file` | `anthropic` | the model writes `__OUT__` itself, via `Write` |
| `stdout` | `ollama` | the model has no `Write`, so it returns the object in `.result` |
| `schema` | `agy` | `--json-schema findings.schema.json` constrains the reply; the object is read from `.structured_output` |

`agy --json-schema` takes a **path**; `claude --json-schema` takes **inline JSON**. The
schema file is part of the finder's prompt checksum, so editing it invalidates cached slices.

The split exists because `--allowedTools` is an **intersection, not a union**. Under
`CLAUDE_CODE_SIMPLE=1` — load-bearing for auth on the ollama transport, not cosmetic —
the harness ships a fixed 2-tool surface. Grant-shaped flags are silently ignored;
only `--disallowedTools` subtracts. Measured live: `--allowedTools Read Grep Glob Write
"Bash(git diff:*)"` produced `tools: ['Bash','Read']`. So on that transport there is no
`Write` to hand the model, and asking for one yields 100% slice failure — a clean report
over zero coverage, the pipeline's worst output.

`file.*` is byte-identical to what `review.prompt` carried inline before the split, so the
anthropic path is unperturbed. `stdout.*` is the exact text the discrimination gate ran with.
