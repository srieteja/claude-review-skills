#!/usr/bin/env python3
"""map.py -- ollama-agents' --map mode: one direct /api/chat call per file, JSON-schema response
format, no agentic harness. Deliberately not routed through `claude`: an agentic loop is the
wrong tool for 200 one-shot structured-extraction calls, and this transport has no prompt
caching to lose by skipping it. No git repo required -- this must work from ~/work itself.

Structured extraction is honest work for a one-shot schema call ("what does this file say");
classification is not ("is this good") -- a small model can hit the schema syntactically while
being semantically wrong (observed live: qwen2.5-coder:1.5b, see the plan's probe table). Keep
--map prompts to extraction. Judgment calls belong in --task/--tasks/--ask, where a full agentic
turn can look things up before deciding.

429 + Retry-After is handled here, per call, with exponential backoff -- unlike the --task/
--tasks/--ask path, where retry is the `claude` harness's job, not ours.

Offline/test path: set OLLAMA_MAP_STUB to skip the network entirely (see offline-test.sh).
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

HERE = os.path.dirname(os.path.abspath(__file__))


def call_ollama(model, api_key, prompt, schema):
    req = urllib.request.Request(
        "https://ollama.com/api/chat",
        data=json.dumps(
            {
                "model": model,
                "messages": [{"role": "user", "content": prompt}],
                "format": json.loads(schema),
                "stream": False,
            }
        ).encode("utf-8"),
        headers={
            # Ollama's cloud API rejects x-api-key / ANTHROPIC_API_KEY-style auth -- the same
            # Bearer requirement as the /v1/messages compat layer used by --task/--tasks/--ask.
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    backoff = 1
    for _ in range(6):
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                body = json.loads(resp.read())
                return json.loads(body["message"]["content"])
        except urllib.error.HTTPError as e:
            if e.code == 429:
                wait = int(e.headers.get("Retry-After", backoff))
                time.sleep(wait)
                backoff = min(backoff * 2, 60)
                continue
            raise RuntimeError(f"HTTP {e.code}: {e.read().decode('utf-8', 'replace')}") from e
    raise RuntimeError("exhausted retries against ollama.com (repeated 429)")


def stub_call(mode, name):
    if mode == "extract":
        return {"stub": True, "file": name}
    if mode == "schema_invalid":
        if name == "a.txt":
            raise ValueError("stub: schema-invalid response")
        return {"stub": True, "file": name}
    return {"stub": True, "file": name}


def process(path, model, api_key, prompt_template, schema, stub):
    name = os.path.basename(path)
    with open(path, encoding="utf-8", errors="replace") as fh:
        contents = fh.read()
    prompt = prompt_template.replace("__FILE__", contents)
    try:
        data = stub_call(stub, name) if stub else call_ollama(model, api_key, prompt, schema)
        return name, {"status": "ok", "data": data}
    except Exception as e:  # noqa: BLE001 -- one file's failure must not sink the batch
        return name, {"status": "failed", "error": str(e)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--schema", required=True, help="JSON schema (inline string) or @path to a file")
    ap.add_argument("--model", default="glm-5.3-flash")
    ap.add_argument("--work", required=True)
    ap.add_argument("--jobs", type=int, default=8)
    args = ap.parse_args()

    stub = os.environ.get("OLLAMA_MAP_STUB", "")
    api_key = os.environ.get("OLLAMA_API_KEY", "")
    if not stub and not api_key:
        print(
            "map.py: OLLAMA_API_KEY is not set. Create one at https://ollama.com/settings/keys",
            file=sys.stderr,
        )
        sys.exit(1)

    schema = args.schema
    if schema.startswith("@"):
        with open(schema[1:], encoding="utf-8") as fh:
            schema = fh.read()

    prompt_path = os.path.join(HERE, "map.prompt")
    with open(prompt_path, encoding="utf-8") as fh:
        prompt_template = fh.read()

    if not os.path.isdir(args.dir):
        print(f"map.py: not a directory: {args.dir}", file=sys.stderr)
        sys.exit(1)
    files = sorted(
        os.path.join(args.dir, n)
        for n in os.listdir(args.dir)
        if os.path.isfile(os.path.join(args.dir, n))
    )
    if not files:
        print(f"map.py: no files in {args.dir}", file=sys.stderr)
        sys.exit(1)

    os.makedirs(args.work, exist_ok=True)
    results = {}
    with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        futures = [
            pool.submit(process, f, args.model, api_key, prompt_template, schema, stub)
            for f in files
        ]
        for fut in as_completed(futures):
            name, result = fut.result()
            results[name] = result

    out_path = os.path.join(args.work, "results.json")
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(results, fh, indent=2, sort_keys=True)

    failed = sorted(n for n, r in results.items() if r["status"] == "failed")
    if failed:
        print(f"map.py: {len(failed)} file(s) failed: {', '.join(failed)}", file=sys.stderr)
    print(f"map.py: wrote {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
