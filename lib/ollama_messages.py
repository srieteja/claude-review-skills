#!/usr/bin/env python3
"""Direct multi-turn caller for ollama.com's Anthropic-compatible /v1/messages API with tool loop.

Credential: OLLAMA_API_KEY only, from the environment. The bash caller runs this under
ollama_api_env (lib/transport-env.sh), which is what loads config.env and strips every other key.
Prints one result envelope on stdout, shaped like `claude -p --output-format json`; on success its
"result" is the findings object as JSON when the reply holds one, else the raw reply text.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import subprocess
import sys
import threading
import urllib.error
import urllib.request
from typing import Any, Dict, List, Optional, Sequence, Set, Tuple

# This client names no URL: the caller passes --endpoint "$OLLAMA_ORIGIN/v1/messages"
# (lib/transport-env.sh) and the environment is never consulted, so no inherited variable can
# move the Bearer key to another host.
GLOB_LIMIT = 50
# Bound on what one tool call returns, and on the bytes a Read takes from disk.
MAX_OUTPUT = 60000
# Bound on one API response body: a hostile or broken endpoint cannot stream this process out of memory.
MAX_RESPONSE = 8 * 1024 * 1024
# An error body is logged, never parsed: read at most this much, then sanitise it.
MAX_ERROR_BODY = 64 * 1024
# Grep output the model sees; the process is killed once it has produced more than this.
GREP_LIMIT = 5000
GREP_TIMEOUT = 30
TRUNCATED = "\n...[truncated]..."


TOOLS_SCHEMA = [
    {
        "name": "Read",
        "description": "Read the contents of a file in the repository",
        "input_schema": {
            "type": "object",
            "properties": {
                "file_path": {"type": "string", "description": "Path of the file to read, relative to the repository root"}
            },
            "required": ["file_path"],
        },
    },
    {
        "name": "Glob",
        "description": "Find files matching a pattern in the repository",
        "input_schema": {
            "type": "object",
            "properties": {
                "pattern": {"type": "string", "description": "The glob pattern, e.g. **/*.dart"}
            },
            "required": ["pattern"],
        },
    },
    {
        "name": "Grep",
        "description": "Search file contents for a regular expression pattern",
        "input_schema": {
            "type": "object",
            "properties": {
                "pattern": {"type": "string", "description": "The regex pattern to search for"},
                "path": {"type": "string", "description": "Optional subdirectory or file path to search"}
            },
            "required": ["pattern"],
        },
    },
]


def call_messages_api(api_key: str, payload: Dict[str, Any], endpoint: str) -> Dict[str, Any]:
    req = urllib.request.Request(
        endpoint,
        headers={
            "Authorization": f"Bearer {api_key}",
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
        data=json.dumps(payload).encode("utf-8"),
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        raw = resp.read(MAX_RESPONSE + 1)
    if len(raw) > MAX_RESPONSE:
        raise ValueError(f"response exceeds {MAX_RESPONSE} bytes")
    return json.loads(raw.decode("utf-8"))


def _confined(path: str, cwd: str, allow: Sequence[str] = ()) -> str:
    """Return the real path of `path` (relative to cwd) if it lies inside cwd or an `allow` root.

    Every root is resolved with realpath, as is the target, so a symlink cannot leave one. A
    `.git` component below the matching root is refused. Raises ValueError otherwise.
    """
    root = os.path.realpath(cwd)
    target = os.path.realpath(os.path.join(root, path))
    for base in (root, *(os.path.realpath(a) for a in allow)):
        if target == base or target.startswith(base + os.sep):
            if ".git" in os.path.relpath(target, base).split(os.sep):
                raise ValueError(f"path is inside .git, which finders do not read: {path}")
            return target
    raise ValueError(f"path is outside the repository: {path}")


def _grep(pattern: str, target: str) -> str:
    """grep -rn output, read at most GREP_LIMIT bytes (plus one to tell it was cut), then killed."""
    proc = subprocess.Popen(
        ["grep", "-rn", "--exclude-dir=.git", "-e", pattern, "--", target],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        env={"PATH": os.environ.get("PATH", "/usr/bin:/bin")},
    )
    timer = threading.Timer(GREP_TIMEOUT, proc.kill)
    timer.start()
    try:
        raw = proc.stdout.read(GREP_LIMIT + 1)
        if len(raw) > GREP_LIMIT:
            proc.kill()
    finally:
        timer.cancel()
        if proc.stdout:
            proc.stdout.close()
        proc.wait()
    return raw[:GREP_LIMIT].decode("utf-8", errors="replace")


def _printable(text: str) -> str:
    """text without control characters (newline and tab kept), safe to put on a terminal."""
    return "".join(c for c in text if c in "\n\t" or (c >= " " and c != "\x7f" and not 0x80 <= ord(c) < 0xa0))


def _bound(output: str) -> str:
    if len(output) <= MAX_OUTPUT:
        return output
    half = MAX_OUTPUT // 2
    return output[:half] + TRUNCATED + "\n" + output[-half:]


def _read_capped(target: str) -> str:
    """At most MAX_OUTPUT bytes of the file, never the whole of a larger one."""
    with open(target, "rb") as f:
        data = f.read(MAX_OUTPUT + 1)
    if len(data) <= MAX_OUTPUT:
        return data.decode("utf-8", errors="replace")
    return data[: MAX_OUTPUT - len(TRUNCATED)].decode("utf-8", errors="replace") + TRUNCATED


def run_tool(name: str, tool_input: Any, cwd: str, files_read: Optional[Set[str]] = None,
             allow: Sequence[str] = ()) -> str:
    """Run one finder tool. Reads only the clone at `cwd` and the read-only `allow` roots; never
    raises, never spawns a shell."""
    if not isinstance(tool_input, dict):
        tool_input = {}
    root = os.path.realpath(cwd)
    try:
        if name in ("Read", "read"):
            path = str(tool_input.get("file_path") or "")
            target = _confined(path, cwd, allow)
            if files_read is not None:
                inside = target == root or target.startswith(root + os.sep)
                files_read.add(os.path.relpath(target, root) if inside else target)
            return _read_capped(target)
        if name in ("Glob", "glob"):
            pattern = str(tool_input.get("pattern") or "*")
            matched: List[str] = []
            # The clone first, paths relative to it; then each allow root, paths absolute.
            for base, absolute in [(root, False)] + [(os.path.realpath(a), True) for a in allow]:
                for dirpath, dirs, files in os.walk(base, followlinks=False):
                    dirs[:] = [d for d in dirs if d != ".git"]
                    for file in files:
                        full = os.path.join(dirpath, file)
                        rel = os.path.relpath(full, base)
                        if fnmatch.fnmatch(rel, pattern) or (absolute and fnmatch.fnmatch(full, pattern)):
                            matched.append(full if absolute else rel)
                            if len(matched) >= GLOB_LIMIT:
                                break
                    if len(matched) >= GLOB_LIMIT:
                        break
                if len(matched) >= GLOB_LIMIT:
                    break
            return _bound("\n".join(matched))
        if name in ("Grep", "grep"):
            pattern = str(tool_input.get("pattern") or "")
            target = _confined(str(tool_input.get("path") or "."), cwd, allow)
            return _grep(pattern, target)
    except Exception as e:
        return f"Tool error: {e}"
    return f"Unsupported tool: {name}"


def extract_findings(text: str, files_read: Set[str]) -> Optional[Dict[str, Any]]:
    """The LAST JSON object in `text` that carries a "findings" list, else None.

    Last, not first: a model that quotes the schema back at itself mid-reasoning emits a decoy
    before the real answer. An empty or missing "read" is filled from the files the tools opened.
    """
    best = None
    decoder = json.JSONDecoder()
    idx = 0
    while idx < len(text):
        idx = text.find("{", idx)
        if idx < 0:
            break
        try:
            obj, _ = decoder.raw_decode(text, idx)
            if isinstance(obj, dict) and isinstance(obj.get("findings"), list):
                best = obj
        except ValueError:
            pass
        idx += 1
    if best is not None and (not isinstance(best.get("read"), list) or not best["read"]):
        best["read"] = sorted(files_read) if files_read else ["."]
    return best


def _text_of(content: List[Dict[str, Any]]) -> List[str]:
    out = []
    for block in content:
        if block.get("type") == "text":
            out.append(block.get("text", ""))
        elif block.get("type") == "thinking":
            out.append(block.get("thinking", ""))
    return out


def run_conversation(api_key: str, endpoint: str, model: str, prompt: str, cwd: str,
                     max_tokens: int, max_turns: int, allow: Sequence[str] = ()) -> Tuple[str, int]:
    """Drive the tool loop; returns (the result text, turns taken). Raises on an API failure."""
    messages: List[Dict[str, Any]] = [{"role": "user", "content": prompt}]
    accumulated: List[str] = []
    files_read: Set[str] = set()
    turns_taken = 0
    tool_uses: List[Dict[str, Any]] = []

    for turn in range(max_turns):
        turns_taken = turn + 1
        data = call_messages_api(api_key, {
            "model": model,
            "max_tokens": max_tokens,
            "messages": messages,
            "tools": TOOLS_SCHEMA,
            "thinking": {"type": "enabled", "budget_tokens": 1024},
        }, endpoint)
        content = data.get("content", [])
        messages.append({"role": "assistant", "content": content})
        accumulated.extend(_text_of(content))
        tool_uses = [b for b in content if b.get("type") == "tool_use"]
        # No tool calls: the model has completed its analysis.
        if not tool_uses:
            break

        tool_results: List[Dict[str, Any]] = [{
            "type": "tool_result",
            "tool_use_id": tu.get("id", ""),
            "content": _bound(run_tool(tu.get("name", ""), tu.get("input", {}), cwd, files_read, allow)),
        } for tu in tool_uses]
        # Approaching the turn limit: ask the model to wrap up with the findings JSON.
        if turn >= max_turns - 2:
            tool_results.append({
                "type": "text",
                "text": "You have gathered sufficient source context. Now output ONLY the final JSON object according to the schema: {\"findings\":[...], \"read\":[...]}",
            })
        messages.append({"role": "user", "content": tool_results})

    # The loop ended with tool calls still pending (max turns): one last call, without tools.
    if tool_uses:
        turns_taken += 1
        messages.append({"role": "user", "content": (
            "You have reached the tool execution limit. Synthesize your analysis and output "
            "ONLY the final findings JSON object conforming to schema: {\"findings\": [...], \"read\": [...]}.")})
        final = call_messages_api(api_key, {
            "model": model,
            "max_tokens": max_tokens,
            "messages": messages,
            "thinking": {"type": "disabled"},
        }, endpoint)
        accumulated.extend(_text_of(final.get("content", [])))

    raw_text = "\n".join(accumulated).strip()
    found = extract_findings(raw_text, files_read)
    return (json.dumps(found) if found is not None else raw_text), turns_taken


def positive_int(text: str) -> int:
    try:
        value = int(text)
    except ValueError:
        raise argparse.ArgumentTypeError(f"must be an integer >= 1, got {text!r}")
    if value < 1:
        raise argparse.ArgumentTypeError(f"must be >= 1, got {value}")
    return value


def _emit(envelope: Dict[str, Any]) -> None:
    json.dump(envelope, sys.stdout)
    sys.stdout.write("\n")


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Call ollama.com messages API with tool execution loop")
    parser.add_argument("--model", required=True, help="Model name (e.g. deepseek-v4.1-flash)")
    parser.add_argument("--prompt-file", help="File containing prompt (defaults to stdin)")
    parser.add_argument("--cwd", default=".", help="Working directory for tool execution")
    parser.add_argument("--allow-read", action="append", default=[], metavar="DIR",
                        help="Extra read-only root for Read, Glob and Grep, besides --cwd (repeatable)")
    parser.add_argument("--endpoint", required=True, help="Messages API URL")
    parser.add_argument("--max-tokens", type=positive_int, default=8192, help="Max tokens per turn")
    parser.add_argument("--max-turns", type=positive_int, default=25, help="Max tool execution turns")
    args = parser.parse_args(argv)
    if not os.path.isdir(args.cwd):
        parser.error(f"--cwd {args.cwd!r} is not a directory")
    for extra in args.allow_read:
        if not os.path.isdir(extra):
            parser.error(f"--allow-read {extra!r} is not a directory")
    prompt = None
    if args.prompt_file:
        try:
            with open(args.prompt_file, "r", encoding="utf-8") as f:
                prompt = f.read()
        except (OSError, UnicodeDecodeError) as e:
            parser.error(f"--prompt-file {args.prompt_file!r} is not readable: {e}")

    api_key = os.environ.get("OLLAMA_API_KEY", "").strip()
    if not api_key:
        sys.stderr.write("ollama_messages: OLLAMA_API_KEY is not set in the environment\n")
        return 1

    if prompt is None:
        prompt = sys.stdin.read()

    base = {"type": "result", "total_cost_usd": 0.0}
    try:
        result, turns = run_conversation(api_key, args.endpoint, args.model, prompt,
                                         os.path.abspath(args.cwd), args.max_tokens, args.max_turns,
                                         [os.path.abspath(a) for a in args.allow_read])
    except urllib.error.HTTPError as e:
        err_body = _printable(e.read(MAX_ERROR_BODY + 1)[:MAX_ERROR_BODY].decode("utf-8", errors="replace"))
        _emit({**base, "subtype": "error", "is_error": True, "api_error_status": e.code,
               "result": f"HTTP {e.code}: {err_body}", "num_turns": 0})
        sys.stderr.write(f"ollama_messages error {e.code}: {err_body}\n")
        return 1
    except Exception as e:
        _emit({**base, "subtype": "error", "is_error": True, "result": str(e), "num_turns": 0})
        sys.stderr.write(f"ollama_messages exception: {e}\n")
        return 1
    _emit({**base, "subtype": "success", "is_error": False, "result": result, "num_turns": turns})
    return 0


if __name__ == "__main__":
    sys.exit(main())
