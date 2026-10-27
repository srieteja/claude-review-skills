# Security

## Reporting

Report vulnerabilities privately through [GitHub security advisories](https://github.com/srieteja/claude-review-skills/security/advisories/new). Don't open a public issue. Expect a first reply within a week.

## Threat model

Every review feeds **untrusted input** to LLM agents: the PR's diff, its description and the source files it touches. Assume that input can carry prompt injection. Here is what limits the damage:

| Agent | Can | Cannot |
|---|---|---|
| Finders (`pr-review.sh`) | read the PR-head clone, `git diff` / `git log`, write their findings file | edit files, run other commands, reach the web, spawn agents |
| Refuter (`refute`) | read the PR-head clone | Bash, write, edit, web, agents |
| Fix implementer (`autofix.sh`) | read and edit the clone, `dart pub get` / `analyze` / `test` | other commands; it never gets `gh` or a push |

- **Nothing posts unseen.** `peer-review` freezes the exact text in `prepare`, and only `--ship` posts it, pinned to the reviewed commit. A moved PR head is refused as stale.
- **Fix PRs are opt-in.** They open only for logins in `PR_REVIEW_FIX_AUTHORS`, which is empty by default. The scripts push and call `gh`, not the model.
- **Running a PR's tests runs the PR's code.** `autofix.sh`'s gate executes `dart test` on the patched tree. Set `PR_REVIEW_FIX_AUTHORS` only for authors whose code you'd run on your machine.
- **Secrets.** `config.env` must be mode 600. Each transport gets only its own key, and no agent with Bash is handed one. See `lib/transport-env.sh`.
- **Data egress.** With ollama in use, the diff and the files it opens go to ollama.com (README, "Cost and data").

## In scope

Ways an untrusted PR could make these skills post, push, leak a key, write outside their clone or worktree, or report a finding that the refuter never checked.
