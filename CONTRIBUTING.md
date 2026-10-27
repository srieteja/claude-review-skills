# Contributing

## Before a PR

```bash
npm ci --prefix skills/pr-review/mermaid   # once; the diagram suites need it
bin/review-skills test                     # every offline suite: stubbed models, no spend, no GitHub
```

- **Test first.** A behaviour change comes with the failing check that proves it, in the suite beside the script (`*-test.sh`, `test_*.py`).
- **Hermetic.** Suites run under a scratch `HOME` with no API keys. A test that passes only because of your login, keys or `~/.reviews` is a bug. CI runs on ubuntu and macOS.
- **Portable shell.** bash 3.2, BSD and GNU userlands, mawk. `shellcheck -S error` must stay clean.
- **No personal data.** Use `alice`/`bob`/`acme`/`widgets` in tests. CI rejects home-directory paths and maintainer handles.

## Live tests (maintainers)

`skills/pr-review/selftest.sh` calls real models and costs money. It is pinned to a public `atsign-foundation/at_client_sdk` PR and is not part of `bin/review-skills test`.

## Design changes

Each skill's `DESIGN.md` records why the pipeline is built the way it is. If your change contradicts it, update the doc in the same PR.

Changing an item in [CONTRACT.md](CONTRACT.md) is a breaking change for wrappers. Update the `contract` block and say what wrappers must do in the commit message.
