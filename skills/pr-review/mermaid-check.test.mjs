// node --test mermaid-check.test.mjs -- the brief diagram's parse and grounding check.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const here = new URL(".", import.meta.url).pathname;
const fx = (name) => join(here, "fixtures", name);
const tmp = mkdtempSync(join(tmpdir(), "mermaid-check-"));

function check(block, diff = fx("diagram-grounding.diff")) {
  const file = join(tmp, `b${Math.random().toString(36).slice(2)}.mmd`);
  writeFileSync(file, block);
  const r = spawnSync(process.execPath, [join(here, "mermaid-check.mjs"), file, diff], { encoding: "utf8" });
  return { code: r.status, out: r.stdout ? JSON.parse(r.stdout) : null, err: r.stderr };
}

const unquoted = readFileSync(fx("diagram-subgraph-unquoted.mmd"), "utf8");

test("an unquoted subgraph label with § fails with a lexical error", () => {
  const r = check(unquoted);
  assert.equal(r.code, 1);
  assert.equal(r.out.ok, false);
  assert.match(r.out.error, /Lexical error/);
});

test("the same block with that label quoted parses", () => {
  const r = check(unquoted.replace("subgraph Envelope §9.4", 'subgraph Envelope["Envelope §9.4"]'));
  assert.equal(r.code, 0, r.err);
  assert.deepEqual([r.out.ok, r.out.error], [true, null]);
});

test("identifiers in labels are grounded against the diff; plain words are not checked", () => {
  const r = check(`flowchart LR
  A["serveHttpOn()"] --> B["handleFoo"]
  B --> C["Client TLS connection"]
  C --> D["at_root_server_impl.dart"]
  D --> E["lib/src/missing_file.dart"]
  E --> F["RootServerImpl.acceptSocket"]
`);
  assert.equal(r.code, 0, r.err);
  assert.deepEqual(r.out.ungrounded, ["handleFoo", "lib/src/missing_file.dart"]);
});

test("without a diff grounding is not checked, which differs from all grounded", () => {
  const r = check('flowchart LR\n  A["handleFoo"]\n', "");
  assert.equal(r.code, 0, r.err);
  assert.equal(r.out.ungrounded, null);
});

test("a missing block is a usage error, not a parse failure", () => {
  const r = spawnSync(process.execPath, [join(here, "mermaid-check.mjs"), join(tmp, "nope.mmd")], { encoding: "utf8" });
  assert.equal(r.status, 2);
});
