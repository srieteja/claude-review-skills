#!/usr/bin/env python3
"""Offline tests for the ollama finder's tool dispatch: it reads only the clone."""

import builtins
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
import urllib.error
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ollama_messages as om  # noqa: E402


class RunToolTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR"))
        base = os.path.realpath(self.tmp.name)
        self.cwd = os.path.join(base, "clone")
        os.makedirs(os.path.join(self.cwd, "src"))
        with open(os.path.join(self.cwd, "src", "a.txt"), "w") as f:
            f.write("hello needle\n")
        self.outside = os.path.join(base, "secret.txt")
        with open(self.outside, "w") as f:
            f.write("TOPSECRET needle\n")
        os.symlink(self.outside, os.path.join(self.cwd, "link.txt"))
        os.symlink(base, os.path.join(self.cwd, "linkdir"))
        self.addCleanup(self.tmp.cleanup)

    def test_bash_unsupported_and_no_subprocess(self):
        with mock.patch("subprocess.run") as run, mock.patch("subprocess.Popen") as popen:
            for name in ("Bash", "bash"):
                out = om.run_tool(name, {"command": "echo hi"}, self.cwd)
                self.assertIn("Unsupported tool", out)
            out = om.run_tool("Mystery", {"command": "echo hi"}, self.cwd)
            self.assertIn("Unsupported tool", out)
            run.assert_not_called()
            popen.assert_not_called()
        self.assertNotIn("Bash", [t["name"] for t in om.TOOLS_SCHEMA])

    def test_read_absolute_outside_refused(self):
        out = om.run_tool("Read", {"file_path": self.outside}, self.cwd)
        self.assertNotIn("TOPSECRET", out)
        self.assertIn("outside", out)

    def test_read_dotdot_refused(self):
        out = om.run_tool("Read", {"file_path": "../secret.txt"}, self.cwd)
        self.assertNotIn("TOPSECRET", out)
        self.assertIn("outside", out)

    def test_read_symlink_out_refused(self):
        out = om.run_tool("Read", {"file_path": "link.txt"}, self.cwd)
        self.assertNotIn("TOPSECRET", out)
        self.assertIn("outside", out)

    def test_read_relative_ok(self):
        self.assertIn("hello needle", om.run_tool("Read", {"file_path": "src/a.txt"}, self.cwd))

    def test_read_in_clone_absolute_ok(self):
        p = os.path.join(self.cwd, "src", "a.txt")
        self.assertIn("hello needle", om.run_tool("read", {"file_path": p}, self.cwd))

    def test_grep_dotdot_refused(self):
        out = om.run_tool("Grep", {"pattern": "needle", "path": ".."}, self.cwd)
        self.assertNotIn("TOPSECRET", out)
        self.assertIn("outside", out)

    def test_grep_symlinked_dir_refused(self):
        out = om.run_tool("Grep", {"pattern": "needle", "path": "linkdir"}, self.cwd)
        self.assertNotIn("TOPSECRET", out)

    def test_grep_dash_pattern_is_pattern(self):
        out = om.run_tool("Grep", {"pattern": "-f/etc/passwd"}, self.cwd)
        self.assertNotIn("root:", out)
        out = om.run_tool("Grep", {"pattern": "needle"}, self.cwd)
        self.assertIn("hello needle", out)

    def test_grep_minimal_env(self):
        with mock.patch("subprocess.Popen") as popen:
            popen.return_value.stdout.read.return_value = b""
            popen.return_value.wait.return_value = 1
            with mock.patch.dict(os.environ, {"OLLAMA_API_KEY": "k"}):
                om.run_tool("Grep", {"pattern": "x"}, self.cwd)
            env = popen.call_args.kwargs["env"]
            self.assertEqual(list(env), ["PATH"])
            argv = popen.call_args.args[0]
            self.assertEqual(argv[:6], ["grep", "-rn", "--exclude-dir=.git", "-e", "x", "--"])

    def _dot_git(self):
        os.makedirs(os.path.join(self.cwd, ".git", "objects"))
        with open(os.path.join(self.cwd, ".git", "config"), "w") as f:
            f.write("[remote] needle-url\n")
        os.makedirs(os.path.join(self.cwd, "sub", ".git"))
        os.symlink(os.path.join(self.cwd, ".git"), os.path.join(self.cwd, "gitlink"))

    def test_read_inside_dot_git_refused(self):
        self._dot_git()
        for p in (".git/config", "sub/.git/x", "gitlink/config", os.path.join(self.cwd, ".git", "config")):
            out = om.run_tool("Read", {"file_path": p}, self.cwd)
            self.assertNotIn("needle-url", out)
            self.assertIn(".git", out, p)
            self.assertTrue(out.startswith("Tool error"), p)

    def test_grep_of_dot_git_refused(self):
        self._dot_git()
        for p in (".git", "gitlink", "sub/.git"):
            out = om.run_tool("Grep", {"pattern": "needle", "path": p}, self.cwd)
            self.assertTrue(out.startswith("Tool error"), p)

    def test_grep_of_the_root_skips_dot_git(self):
        self._dot_git()
        out = om.run_tool("Grep", {"pattern": "needle"}, self.cwd)
        self.assertIn("hello needle", out)
        self.assertNotIn("needle-url", out)

    def test_grep_passes_exclude_dir_dot_git(self):
        with mock.patch("subprocess.Popen", side_effect=om.subprocess.Popen) as p:
            om.run_tool("Grep", {"pattern": "needle"}, self.cwd)
        self.assertIn("--exclude-dir=.git", p.call_args[0][0])

    def test_grep_output_is_bounded_at_the_source_and_grep_is_killed(self):
        with open(os.path.join(self.cwd, "big.txt"), "w") as f:
            f.write("needle line\n" * 2_000_000)
        procs = []
        real = om.subprocess.Popen

        def spy(*a, **kw):
            procs.append(real(*a, **kw))
            return procs[-1]

        with mock.patch("subprocess.Popen", side_effect=spy):
            out = om.run_tool("Grep", {"pattern": "needle", "path": "big.txt"}, self.cwd)
        self.assertLessEqual(len(out), om.GREP_LIMIT)
        self.assertIn("needle line", out)
        self.assertEqual(len(procs), 1)
        self.assertLess(procs[0].returncode, 0)  # killed, not run to completion

    def test_glob_only_in_clone(self):
        out = om.run_tool("Glob", {"pattern": "*"}, self.cwd).splitlines()
        self.assertIn(os.path.join("src", "a.txt"), out)
        self.assertFalse([l for l in out if l.startswith("linkdir") or l.startswith("..")])
        self.assertNotIn("secret.txt", out)

    def test_glob_skips_dot_git(self):
        os.makedirs(os.path.join(self.cwd, ".git", "objects"))
        for p in (os.path.join(".git", "HEAD"), os.path.join(".git", "objects", "ab")):
            with open(os.path.join(self.cwd, p), "w") as f:
                f.write("x")
        out = om.run_tool("Glob", {"pattern": "*"}, self.cwd).splitlines()
        self.assertIn(os.path.join("src", "a.txt"), out)
        self.assertEqual([l for l in out if l.startswith(".git")], [])

    def test_glob_stops_walking_at_fifty_matches(self):
        for i in range(300):
            with open(os.path.join(self.cwd, "src", "f%03d.txt" % i), "w") as f:
                f.write("x")
        seen = []
        real = om.fnmatch.fnmatch

        def counting(name, pat):
            seen.append(name)
            return real(name, pat)

        with mock.patch.object(om.fnmatch, "fnmatch", counting):
            out = om.run_tool("Glob", {"pattern": "*.txt"}, self.cwd).splitlines()
        self.assertEqual(len(out), 50)
        self.assertLessEqual(len(seen), 50)

    def test_files_read_relative(self):
        seen = set()
        om.run_tool("Read", {"file_path": os.path.join(self.cwd, "src", "a.txt")}, self.cwd, seen)
        self.assertEqual(seen, {os.path.join("src", "a.txt")})


    def test_read_takes_at_most_the_bound(self):
        big = os.path.join(self.cwd, "big.txt")
        with open(big, "w") as f:
            f.write("x" * (om.MAX_OUTPUT * 5))
        sizes = []
        real_open = builtins.open

        def spy(path, *a, **kw):
            fh = real_open(path, *a, **kw)
            if os.fspath(path) == os.path.realpath(big):
                real_read = fh.read
                fh_read = lambda n=-1: (sizes.append(n), real_read(n))[1]
                return mock.Mock(__enter__=lambda s: mock.Mock(read=fh_read), __exit__=lambda *x: None)
            return fh

        with mock.patch("builtins.open", spy):
            out = om.run_tool("Read", {"file_path": "big.txt"}, self.cwd)
        self.assertEqual(sizes, [om.MAX_OUTPUT + 1])
        self.assertLessEqual(len(out), om.MAX_OUTPUT)
        self.assertTrue(out.endswith(om.TRUNCATED))

    def test_read_at_the_bound_is_whole(self):
        p = os.path.join(self.cwd, "exact.txt")
        with open(p, "w") as f:
            f.write("y" * om.MAX_OUTPUT)
        out = om.run_tool("Read", {"file_path": "exact.txt"}, self.cwd)
        self.assertEqual(out, "y" * om.MAX_OUTPUT)


class AllowReadTest(unittest.TestCase):
    """--allow-read: extra read-only roots, same realpath and .git rules as the clone."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR"))
        self.addCleanup(self.tmp.cleanup)
        base = os.path.realpath(self.tmp.name)
        self.cwd = os.path.join(base, "clone")
        self.work = os.path.join(base, "work")
        self.sibling = os.path.join(base, "sibling")
        for d in (self.cwd, self.work, self.sibling, os.path.join(self.work, ".git")):
            os.makedirs(d)
        for p, text in ((os.path.join(self.work, "d.diff"), "DIFF needle\n"),
                        (os.path.join(self.sibling, "s.txt"), "SIBLING needle\n"),
                        (os.path.join(self.work, ".git", "config"), "GITCFG needle\n"),
                        (os.path.join(self.cwd, "a.txt"), "CLONE needle\n")):
            with open(p, "w") as f:
                f.write(text)
        os.symlink(self.sibling, os.path.join(self.work, "escape"))
        self.allow = [self.work]

    def run_tool(self, name, inp):
        return om.run_tool(name, inp, self.cwd, None, self.allow)

    def test_allowed_root_is_readable_and_the_clone_still_is(self):
        self.assertIn("DIFF needle", self.run_tool("Read", {"file_path": os.path.join(self.work, "d.diff")}))
        self.assertIn("CLONE needle", self.run_tool("Read", {"file_path": "a.txt"}))

    def test_without_the_option_the_root_is_refused(self):
        out = om.run_tool("Read", {"file_path": os.path.join(self.work, "d.diff")}, self.cwd)
        self.assertNotIn("DIFF", out)
        self.assertIn("outside the repository", out)

    def test_sibling_outside_both_is_refused(self):
        out = self.run_tool("Read", {"file_path": os.path.join(self.sibling, "s.txt")})
        self.assertNotIn("SIBLING", out)
        self.assertIn("outside the repository", out)

    def test_symlink_escaping_the_allowed_root_is_refused(self):
        out = self.run_tool("Read", {"file_path": os.path.join(self.work, "escape", "s.txt")})
        self.assertNotIn("SIBLING", out)
        self.assertIn("outside the repository", out)
        out = self.run_tool("Grep", {"pattern": "needle", "path": os.path.join(self.work, "escape")})
        self.assertNotIn("SIBLING", out)

    def test_dot_git_under_the_allowed_root_is_refused(self):
        for tool, inp in (("Read", {"file_path": os.path.join(self.work, ".git", "config")}),
                          ("Grep", {"pattern": "needle", "path": os.path.join(self.work, ".git")})):
            self.assertNotIn("GITCFG", self.run_tool(tool, inp))
        self.assertIn(".git", self.run_tool("Read", {"file_path": os.path.join(self.work, ".git", "config")}))

    def test_grep_into_the_allowed_root(self):
        out = self.run_tool("Grep", {"pattern": "needle", "path": self.work})
        self.assertIn("DIFF needle", out)
        self.assertNotIn("GITCFG", out)

    def test_glob_lists_the_allowed_root_by_absolute_path_without_dot_git(self):
        out = self.run_tool("Glob", {"pattern": "*.diff"}).splitlines()
        self.assertEqual(out, [os.path.join(self.work, "d.diff")])
        self.assertNotIn("GITCFG", "\n".join(self.run_tool("Glob", {"pattern": "*"}).splitlines()))
        self.assertNotIn(os.path.join(self.work, ".git", "config"), self.run_tool("Glob", {"pattern": "*"}))

    def test_relative_paths_still_resolve_against_cwd(self):
        self.assertIn("outside the repository", self.run_tool("Read", {"file_path": "../sibling/s.txt"}))
        self.assertIn("DIFF needle", self.run_tool("Read", {"file_path": "../work/d.diff"}))

    def test_missing_root_is_rejected_naming_the_flag(self):
        prompt = os.path.join(self.cwd, "p.txt")
        with open(prompt, "w") as f:
            f.write("x")
        for bad in (os.path.join(self.work, "nope"), os.path.join(self.work, "d.diff")):
            err = io.StringIO()
            with mock.patch.dict(os.environ, {"OLLAMA_API_KEY": "k"}, clear=True), \
                 contextlib.redirect_stderr(err), self.assertRaises(SystemExit) as cm:
                om.main(["--model", "m", "--prompt-file", prompt, "--cwd", self.cwd,
                         "--endpoint", "http://127.0.0.1:9/v1/messages", "--allow-read", bad])
            self.assertEqual(cm.exception.code, 2, bad)
            self.assertIn("--allow-read", err.getvalue())

    def test_option_is_repeatable_and_reaches_the_tools(self):
        prompt = os.path.join(self.cwd, "p.txt")
        with open(prompt, "w") as f:
            f.write("x")
        queue = [reply({"type": "tool_use", "id": "t1", "name": "Read",
                        "input": {"file_path": os.path.join(self.sibling, "s.txt")}}),
                 reply({"type": "tool_use", "id": "t2", "name": "Read",
                        "input": {"file_path": os.path.join(self.work, "d.diff")}}),
                 reply({"type": "text", "text": json.dumps(FINDINGS)})]
        sent = []

        def fake_urlopen(req, timeout=None):
            sent.append(json.loads(req.data.decode("utf-8")))
            return FakeResponse(queue.pop(0))

        with mock.patch("urllib.request.urlopen", fake_urlopen), \
             mock.patch.dict(os.environ, {"OLLAMA_API_KEY": "k"}, clear=True), \
             contextlib.redirect_stdout(io.StringIO()):
            rc = om.main(["--model", "m", "--prompt-file", prompt, "--cwd", self.cwd,
                          "--endpoint", "http://127.0.0.1:9/v1/messages",
                          "--allow-read", self.work, "--allow-read", self.sibling])
        self.assertEqual(rc, 0)
        self.assertIn("SIBLING needle", sent[1]["messages"][-1]["content"][0]["content"])
        self.assertIn("DIFF needle", sent[2]["messages"][-1]["content"][0]["content"])


class FakeResponse:
    def __init__(self, body):
        self.body = json.dumps(body).encode("utf-8")

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def read(self, n=-1):
        return self.body if n is None or n < 0 else self.body[:n]


def reply(*blocks):
    return {"content": list(blocks)}


ENDPOINT = "http://127.0.0.1:9/v1/messages"  # a test double: nothing is ever dialled
FINDINGS = {"findings": [{"id": "F1"}], "read": ["src/a.txt"]}


class ConversationTest(unittest.TestCase):
    """The turn loop, the HTTP call and the envelope, with urlopen replaced: no network."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR"))
        self.addCleanup(self.tmp.cleanup)
        self.cwd = os.path.realpath(self.tmp.name)
        os.makedirs(os.path.join(self.cwd, "src"))
        with open(os.path.join(self.cwd, "src", "a.txt"), "w") as f:
            f.write("hello needle\n")
        self.prompt = os.path.join(self.cwd, "prompt.txt")
        with open(self.prompt, "w") as f:
            f.write("review this")
        self.requests = []

    def run_main(self, responses, *extra, key="k-ollama", env=None, no_endpoint=False):
        queue = list(responses)

        def fake_urlopen(req, timeout=None):
            self.requests.append(req)
            item = queue.pop(0)
            if isinstance(item, Exception):
                raise item
            return FakeResponse(item)

        out, err = io.StringIO(), io.StringIO()
        environ = {"OLLAMA_API_KEY": key} if key else {}
        environ.update(env or {})
        argv = ["--model", "m", "--prompt-file", self.prompt, "--cwd", self.cwd, *extra]
        if "--endpoint" not in extra and not no_endpoint:
            argv += ["--endpoint", ENDPOINT]
        with mock.patch("urllib.request.urlopen", fake_urlopen), \
             mock.patch.dict(os.environ, environ, clear=True), \
             contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                rc = om.main(argv)
            except SystemExit as e:
                rc = e.code
        env_json = json.loads(out.getvalue()) if out.getvalue().strip() else None
        return rc, env_json, err.getvalue()

    def body(self, i):
        return json.loads(self.requests[i].data.decode("utf-8"))

    def test_tool_turn_then_findings(self):
        tool = reply({"type": "tool_use", "id": "t1", "name": "Read", "input": {"file_path": "src/a.txt"}})
        final = reply({"type": "text", "text": "done " + json.dumps({"findings": [{"id": "F1"}], "read": []})})
        rc, env, _ = self.run_main([tool, final])
        self.assertEqual(rc, 0)
        self.assertEqual((env["type"], env["subtype"], env["is_error"], env["num_turns"]),
                         ("result", "success", False, 2))
        result = json.loads(env["result"])
        self.assertEqual(result["findings"], [{"id": "F1"}])
        self.assertEqual(result["read"], ["src/a.txt"])  # empty "read" is filled from the tools' reads
        # the second request carries the tool result
        result_block = self.body(1)["messages"][-1]["content"][0]
        self.assertEqual((result_block["type"], result_block["tool_use_id"]), ("tool_result", "t1"))
        self.assertIn("hello needle", result_block["content"])

    def test_a_no_tool_reply_reports_read_as_empty(self):
        # No Read/Grep/Glob ever ran. Whatever the model says, "read" is the evidence of
        # what it opened, and it opened nothing.
        final = reply({"type": "text", "text": json.dumps(
            {"findings": [{"id": "F1"}], "read": ["src/a.txt"]})})
        rc, env, _ = self.run_main([final])
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(env["result"])["read"], [])

    def test_read_after_reads_is_exactly_the_relative_paths_opened(self):
        queue = [
            reply({"type": "tool_use", "id": "t1", "name": "Read", "input": {"file_path": "src/a.txt"}}),
            reply({"type": "tool_use", "id": "t2", "name": "Glob", "input": {"pattern": "*.txt"}}),
            reply({"type": "text", "text": json.dumps({"findings": [{"id": "F1"}]})}),
        ]
        rc, env, _ = self.run_main(queue)
        self.assertEqual(rc, 0)
        # Read records the file; Glob's listing is not a read. Sorted, relative, and no ".".
        self.assertEqual(json.loads(env["result"])["read"], ["src/a.txt"])

    def test_request_carries_only_the_ollama_key_to_the_endpoint(self):
        rc, _, _ = self.run_main([reply({"type": "text", "text": json.dumps(FINDINGS)})],
                                 env={"ANTHROPIC_API_KEY": "sk-ant-SECRET", "ANTHROPIC_AUTH_TOKEN": "auth-SECRET",
                                      "CLAUDE_CODE_OAUTH_TOKEN": "oauth-SECRET", "GEMINI_API_KEY": "gem-SECRET"})
        self.assertEqual(rc, 0)
        req = self.requests[0]
        self.assertEqual(req.full_url, ENDPOINT)
        self.assertEqual(req.get_header("Authorization"), "Bearer k-ollama")
        sent = repr(req.headers) + req.data.decode("utf-8")
        for secret in ("sk-ant-SECRET", "auth-SECRET", "oauth-SECRET", "gem-SECRET"):
            self.assertNotIn(secret, sent)

    def test_endpoint_is_a_setting(self):
        self.run_main([reply({"type": "text", "text": json.dumps(FINDINGS)})],
                      "--endpoint", "http://127.0.0.1:9/v1/messages")
        self.assertEqual(self.requests[0].full_url, "http://127.0.0.1:9/v1/messages")

    def test_endpoint_is_required_and_the_environment_is_not_consulted(self):
        rc, env, err = self.run_main([], env={"OLLAMA_ORIGIN": "http://evil.example"}, no_endpoint=True)
        self.assertEqual(rc, 2)
        self.assertIsNone(env)
        self.assertEqual(self.requests, [])
        self.assertIn("--endpoint", err)

    def test_origin_in_the_environment_loses_to_the_flag(self):
        self.run_main([reply({"type": "text", "text": json.dumps(FINDINGS)})],
                      "--endpoint", ENDPOINT, env={"OLLAMA_ORIGIN": "http://evil.example"})
        self.assertEqual(self.requests[0].full_url, ENDPOINT)

    def test_unreadable_prompt_file_is_refused_naming_the_flag(self):
        for path in (os.path.join(self.cwd, "missing.txt"), self.cwd):
            rc, env, err = self.run_main([], "--prompt-file", path)
            self.assertEqual(rc, 2, path)
            self.assertIn("--prompt-file", err)
            self.assertNotIn("Traceback", err)
            self.assertEqual(self.requests, [])

    def test_cwd_that_is_not_a_directory_is_refused_naming_the_flag(self):
        for path in (os.path.join(self.cwd, "missing"), self.prompt):
            rc, env, err = self.run_main([], "--cwd", path)
            self.assertEqual(rc, 2, path)
            self.assertIn("--cwd", err)
            self.assertNotIn("Traceback", err)
            self.assertEqual(self.requests, [])

    def test_ollama_key_only_no_auth_token_fallback(self):
        rc, env, err = self.run_main([], key="", env={"ANTHROPIC_AUTH_TOKEN": "tok"})
        self.assertEqual(rc, 1)
        self.assertIsNone(env)
        self.assertIn("OLLAMA_API_KEY", err)
        self.assertEqual(self.requests, [])

    def test_key_is_not_read_from_a_config_file(self):
        cfg = os.path.join(self.cwd, "config.env")
        with open(cfg, "w") as f:
            f.write("OLLAMA_API_KEY=from-file\n")
        rc, _, err = self.run_main([], key="", env={"REVIEW_SKILLS_CONFIG": cfg})
        self.assertEqual(rc, 1)
        self.assertEqual(self.requests, [])

    def test_http_error_envelope(self):
        err = urllib.error.HTTPError(ENDPOINT, 429, "Too Many", {}, io.BytesIO(b"slow down"))
        rc, env, stderr = self.run_main([err])
        self.assertEqual(rc, 1)
        self.assertEqual((env["subtype"], env["is_error"], env["api_error_status"]), ("error", True, 429))
        self.assertIn("HTTP 429: slow down", env["result"])
        self.assertIn("429", stderr)

    def test_http_error_body_is_capped_and_control_characters_stripped(self):
        body = b"bad\x1b[31m\x00\r\nline2\ttab" + b"x" * (om.MAX_ERROR_BODY * 4)
        err = urllib.error.HTTPError(ENDPOINT, 500, "Boom", {}, io.BytesIO(body))
        rc, env, stderr = self.run_main([err])
        self.assertEqual(rc, 1)
        for text in (env["result"], stderr):
            self.assertNotIn("\x1b", text)
            self.assertNotIn("\x00", text)
            self.assertNotIn("\r", text)
            self.assertIn("line2\ttab", text)
            self.assertLess(len(text), om.MAX_ERROR_BODY + 200)

    def test_http_error_body_read_is_bounded(self):
        class Body(io.BytesIO):
            asked = None

            def read(self, n=-1):
                Body.asked = n
                return super().read(n)

        err = urllib.error.HTTPError(ENDPOINT, 500, "Boom", {}, Body(b"x" * 10))
        self.run_main([err])
        self.assertIsNotNone(Body.asked)
        self.assertGreater(Body.asked, 0)
        self.assertLessEqual(Body.asked, om.MAX_ERROR_BODY + 1)

    def test_oversized_response_is_an_error_not_a_read_to_the_end(self):
        big = reply({"type": "text", "text": "x" * 500})
        with mock.patch.object(om, "MAX_RESPONSE", 100):
            rc, env, _ = self.run_main([big])
        self.assertEqual(rc, 1)
        self.assertTrue(env["is_error"])
        self.assertIn("exceeds", env["result"])

    def test_response_at_the_cap_is_read(self):
        ok = reply({"type": "text", "text": json.dumps(FINDINGS)})
        with mock.patch.object(om, "MAX_RESPONSE", len(json.dumps(ok))):
            rc, _, _ = self.run_main([ok])
        self.assertEqual(rc, 0)

    def test_network_error_envelope(self):
        rc, env, _ = self.run_main([urllib.error.URLError("unreachable")])
        self.assertEqual(rc, 1)
        self.assertTrue(env["is_error"])
        self.assertNotIn("api_error_status", env)

    def test_max_turns_wrap_up(self):
        tool = reply({"type": "tool_use", "id": "t", "name": "Glob", "input": {"pattern": "*"}})
        final = reply({"type": "text", "text": json.dumps(FINDINGS)})
        rc, env, _ = self.run_main([tool, tool, final], "--max-turns", "2")
        self.assertEqual(rc, 0)
        self.assertEqual(len(self.requests), 3)
        self.assertEqual(env["num_turns"], 3)
        self.assertIn("tools", self.body(0))
        self.assertNotIn("tools", self.body(2))  # the wrap-up call offers no tools
        self.assertEqual(self.body(2)["thinking"], {"type": "disabled"})
        # The wrap-up rides in the last user turn, not a second one after it.
        last = self.body(2)["messages"][-1]
        self.assertEqual(last["role"], "user")
        last_text = " ".join(b.get("text", "") for b in last["content"] if isinstance(b, dict))
        self.assertIn("tool execution limit", last_text)
        # the last in-loop turn already asked the model to wrap up
        self.assertEqual(self.body(1)["messages"][-1]["content"][-1]["type"], "text")
        self.assertEqual(json.loads(env["result"])["findings"], [{"id": "F1"}])
        # Both wrap-ups ask for "checked": a compliant no-findings reply that omitted it
        # would then fail the shell's coverage gate.
        self.assertIn("checked", self.body(1)["messages"][-1]["content"][-1]["text"])
        self.assertIn("checked", last_text)

    def test_max_turns_one_never_sends_two_user_turns_in_a_row(self):
        # max_turns=1 leaves the tool result as the final user turn; appending a second user
        # message for the wrap-up is an HTTP 400 from the Messages API.
        tool = reply({"type": "tool_use", "id": "t", "name": "Glob", "input": {"pattern": "*"}})
        final = reply({"type": "text", "text": json.dumps(FINDINGS)})
        rc, env, _ = self.run_main([tool, final], "--max-turns", "1")
        self.assertEqual(rc, 0)
        self.assertEqual(len(self.requests), 2)
        messages = self.body(1)["messages"]
        for before, after in zip(messages, messages[1:]):
            self.assertFalse(before["role"] == after["role"] == "user", messages)
        last = messages[-1]
        self.assertEqual(last["role"], "user")
        self.assertEqual(last["content"][0]["type"], "tool_result")
        text = " ".join(b.get("text", "") for b in last["content"] if isinstance(b, dict))
        self.assertIn("tool execution limit", text)

    def test_max_turns_one_makes_one_call_when_the_model_answers(self):
        final = reply({"type": "text", "text": json.dumps(FINDINGS)})
        rc, env, _ = self.run_main([final], "--max-turns", "1")
        self.assertEqual((rc, env["num_turns"]), (0, 1))

    def test_unparseable_reply_is_passed_through_raw(self):
        rc, env, _ = self.run_main([reply({"type": "text", "text": "no json here"})])
        self.assertEqual((rc, env["is_error"], env["result"]), (0, False, "no json here"))

    def test_flags_below_one_are_refused_naming_the_flag(self):
        for flag in ("--max-turns", "--max-tokens"):
            for value in ("0", "-3", "x"):
                rc, env, err = self.run_main([], flag, value)
                self.assertEqual(rc, 2, (flag, value))
                self.assertIn(flag, err)
                self.assertEqual(self.requests, [])


class ExtractFindingsTest(unittest.TestCase):
    def test_last_object_with_a_findings_list_wins(self):
        text = 'decoy {"findings": [1]} then {"other": 1} and {"findings": [2], "read": ["a"]} tail'
        self.assertEqual(om.extract_findings(text, set())["findings"], [2])

    def test_findings_must_be_a_list(self):
        self.assertIsNone(om.extract_findings('{"findings": "no"}', set()))

    def test_read_is_always_what_the_tools_opened(self):
        self.assertEqual(om.extract_findings('{"findings": []}', {"b", "a"})["read"], ["a", "b"])
        # Nothing read is reported as nothing read -- never ".": the shell gate rejects
        # "no findings and nothing read", and a placeholder would make that impossible.
        self.assertEqual(om.extract_findings('{"findings": []}', set())["read"], [])

    def test_a_claimed_read_does_not_replace_the_files_actually_read(self):
        self.assertEqual(
            om.extract_findings('{"findings": [], "read": ["claimed.dart"]}', {"a.dart"})["read"],
            ["a.dart"])


if __name__ == "__main__":
    unittest.main()
