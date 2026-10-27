#!/usr/bin/env node
// Checks a brief's diagram the way a renderer sees it: mermaid 11.16.1's own parser
// (under jsdom, no browser), then grounding -- each identifier-like token in a label must
// appear in the PR's diff. Grounding annotates, never fails: generic context nodes are fine.
//
//   node mermaid-check.mjs <block.mmd> [pr.diff]
//   stdout {"ok": bool, "error": str|null, "ungrounded": [token, ...] | null (no diff given)}
//   exit   0 parsed · 1 parse error · 2 usage, or the deps in ./mermaid aren't installed
//
// Deps are pinned in ./mermaid/package.json (`review-skills install` installs them). Render
// with the same mermaid version and what passes here renders there.
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const [blockPath, diffPath] = process.argv.slice(2);
const die = (msg) => { process.stderr.write(`mermaid-check: ${msg}\n`); process.exit(2); };
if (!blockPath) die("usage: mermaid-check.mjs <block.mmd> [pr.diff]");

let block;
try { block = readFileSync(blockPath, "utf8"); } catch (e) { die(`can't read ${blockPath}: ${e.message}`); }
const diff = diffPath ? readFileSync(diffPath, "utf8") : null;

// -- grounding -------------------------------------------------------------------------------

const PATH = /\/|\.(dart|m?js|ts|py|sh|go|rs|java|kt|swift|json|ya?ml|md|toml|c|h|cc|cpp)$/;
const IDENT = /[a-z][A-Z]|[A-Za-z0-9]_[A-Za-z0-9]/;   // camelCase / CamelCase / snake_case

// Label text: quoted strings, then unquoted node shapes A[..] A(..) A{..} and subgraph titles.
function labels(src) {
  const out = [];
  const bare = src.replace(/"([^"]*)"/g, (_, s) => { out.push(s); return '""'; });
  for (const m of bare.matchAll(/\w\s*[[({]+([^\])}"]+)[\])}]+/g)) out.push(m[1]);
  for (const m of bare.matchAll(/^\s*subgraph\s+(.+)$/gm)) out.push(m[1]);
  return out.map((s) => s.replace(/<[^>]*>/g, " "));
}

function ungrounded(src, diff) {
  if (diff === null) return null;
  const seen = new Set();
  for (const label of labels(src)) {
    for (const raw of label.split(/[^A-Za-z0-9_./()]+/)) {
      const call = raw.includes("(");               // foo() is identifier-like whatever its case
      const tok = raw.replace(/\(.*$/, "").replace(/^\.+|\.+$/g, "");
      if (!tok || seen.has(tok)) continue;
      const parts = PATH.test(tok) ? [tok] : tok.split(".").filter((p) => p && (IDENT.test(p) || call));
      if (parts.some((p) => !diff.includes(p))) seen.add(tok);
    }
  }
  return [...seen];
}

// -- parse -----------------------------------------------------------------------------------

const req = createRequire(new URL("./mermaid/", import.meta.url));
let JSDOM, mermaid;
try {
  ({ JSDOM } = req("jsdom"));
  const dom = new JSDOM("<!doctype html><html><body></body></html>", { pretendToBeVisual: true });
  Object.assign(globalThis, { window: dom.window, document: dom.window.document });
  // mermaid logs parse failures itself; the error is reported once, in the JSON.
  for (const k of ["log", "warn", "error", "info", "debug"]) console[k] = () => {};
  mermaid = (await import(pathToFileURL(req.resolve("mermaid")).href)).default;
} catch (e) {
  die(`deps missing (run: review-skills install, or npm ci --prefix ${new URL("./mermaid", import.meta.url).pathname}): ${e.message}`);
}

let error = null;
try {
  mermaid.initialize({ startOnLoad: false, securityLevel: "strict" });
  await mermaid.parse(block);
} catch (e) {
  error = String(e?.message ?? e).trim().slice(0, 2000);
}
process.stdout.write(JSON.stringify({ ok: !error, error, ungrounded: ungrounded(block, diff) }) + "\n");
process.exit(error ? 1 : 0);
