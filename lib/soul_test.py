#!/usr/bin/env python3
"""Tests for lib/soul.py.

Each test's docstring is its Gherkin scenario title from
features/review-doctrine/soul-and-refuter.feature, character for character.
All state lives in temporary directories; nothing under ~/.reviews is read or written.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SOUL_PY = os.path.join(HERE, "soul.py")
sys.path.insert(0, HERE)

import soul  # noqa: E402


FIXTURE = '''# Test doctrine

Intro prose that must survive.

## Purpose — immutable core

Keep reviews useful and cheap.

## Evidence standard — immutable core

- **S-E1** A finding needs a reachable path and a named harm. — evidence: 407 findings · 2026-11-22
- **S-E2** Cite `file:line`. If no anchor exists, say `unanchored`; never
  present prose as if it were located. — evidence: 70% unanchored · 2026-11-22

## Severity

- **S-V1** Use the author's vocabulary. — evidence: 75 labels · 2026-11-22

## Checks — review in this order

Section prose stays.
- **S-C1** **Docs drift**: docs describe the old behaviour. — evidence: 91 findings / 29 PRs · 2026-11-22
- **S-C2** **Test bite**: demonstrate by mutation. — owner ruling 2026-11-22

## Delivery

- **S-D1** Prefer a suggestion. — owner ruling 2026-11-22

## Review shape

- **S-R1** Findings are rows.

## Response protocol

- **S-P1** Reply after the push.

## Closure

- **S-X1** Record the outcome.

## Learning

- **S-L1** A daily job analyses the process.

## Changelog

- **2026-11-22 · v0** — Initial doctrine.
  reasoning: Test fixture.
  evidence: 1.
'''


def proposal(**over):
    p = {
        "id": "p-20261122-1",
        "section": "Checks",
        "what": "Add the docs-drift rule",
        "reasoning": "Docs drift accounts for many findings.",
        "evidence_count": 12,
        "changes": [
            {"rule_id": "S-C1", "text": "Docs drift is a finding.", "evidence_count": 12},
        ],
    }
    p.update(over)
    return p


class SoulTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name
        self.soul_path = os.path.join(self.dir, "SOUL.md")
        with open(self.soul_path, "w", encoding="utf-8") as f:
            f.write(FIXTURE)
        self.state = os.path.join(self.dir, "state")

    def tearDown(self):
        self.tmp.cleanup()

    def write_proposal(self, data, name="proposal.json"):
        path = os.path.join(self.dir, name)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f)
        return path

    def run_cli(self, *args):
        return subprocess.run([sys.executable, SOUL_PY] + list(args),
                              capture_output=True, text=True)

    def text(self):
        with open(self.soul_path, encoding="utf-8") as f:
            return f.read()

    def test_parses_sections_and_rules(self):
        """The doctrine is parsed into sections and rules"""
        doc = soul.parse(self.soul_path)
        names = [s.name for s in doc.sections]
        for required in soul.REQUIRED_SECTIONS:
            self.assertIn(required, names)
        by_name = {s.name: s for s in doc.sections}
        self.assertTrue(by_name["Purpose"].immutable)
        self.assertTrue(by_name["Evidence standard"].immutable)
        self.assertFalse(by_name["Checks"].immutable)

        rules = {r.id: r for r in doc.rules}
        e1 = rules["S-E1"]
        self.assertEqual(e1.text, "A finding needs a reachable path and a named harm.")
        self.assertEqual(e1.evidence_count, 407)
        self.assertEqual(e1.updated, "2026-11-22")
        e2 = rules["S-E2"]
        self.assertEqual(
            e2.text,
            "Cite `file:line`. If no anchor exists, say `unanchored`; never "
            "present prose as if it were located.",
        )
        self.assertEqual(e2.evidence_count, 70)
        self.assertEqual(e2.updated, "2026-11-22")
        c2 = rules["S-C2"]
        self.assertIsNone(c2.evidence_count)
        self.assertEqual(c2.updated, "2026-11-22")
        self.assertIsNone(rules["S-R1"].evidence_count)
        self.assertEqual(c2.section, "Checks")

        # Prose outside rule lines is preserved.
        self.assertIn("Intro prose that must survive.", doc.text)
        self.assertIn("Section prose stays.", by_name["Checks"].body)

        # parse --json returns the sections and the rules.
        r = self.run_cli("parse", self.soul_path, "--json")
        self.assertEqual(r.returncode, 0, r.stderr)
        data = json.loads(r.stdout)
        self.assertEqual([x["id"] for x in data["rules"]][:2], ["S-E1", "S-E2"])
        self.assertTrue({s["name"] for s in data["sections"]} >= set(soul.REQUIRED_SECTIONS))

        # sections --only prints the requested bodies in the requested order.
        r = self.run_cli("sections", self.soul_path, "--only",
                         "Evidence standard,Severity,Checks")
        self.assertEqual(r.returncode, 0, r.stderr)
        out = r.stdout
        self.assertIn("## Evidence standard", out)
        self.assertIn("## Severity", out)
        self.assertIn("## Checks", out)
        self.assertNotIn("## Delivery", out)
        self.assertNotIn("## Response protocol", out)
        self.assertLess(out.index("## Evidence standard"), out.index("## Severity"))
        self.assertLess(out.index("## Severity"), out.index("## Checks"))
        self.assertIn("S-E1", out)
        self.assertIn("S-C1", out)

        # A file over 64 KiB is refused, naming the limit.
        big = os.path.join(self.dir, "big.md")
        with open(big, "w", encoding="utf-8") as f:
            f.write(FIXTURE + "\n" + ("x" * (64 * 1024)))
        with self.assertRaises(soul.SoulError) as cm:
            soul.parse(big)
        self.assertRegex(str(cm.exception), r"64 KiB")
        r = self.run_cli("parse", big)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("64 KiB", r.stderr)

    def test_missing_required_section_is_refused(self):
        """A missing required section is refused"""
        broken = os.path.join(self.dir, "no-evidence.md")
        text = FIXTURE.replace("## Evidence standard — immutable core",
                               "## Evidence notes — immutable core")
        with open(broken, "w", encoding="utf-8") as f:
            f.write(text)
        with self.assertRaises(soul.SoulError) as cm:
            soul.parse(broken)
        self.assertIn("Evidence", str(cm.exception))
        r = self.run_cli("parse", broken)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("Evidence", r.stderr)

    def test_immutable_core_cannot_be_edited(self):
        """The immutable core cannot be edited by the learning job"""
        before = self.text()

        def refused(data, *fragments):
            with self.assertRaises(soul.SoulError) as cm:
                soul.apply(self.write_proposal(data), self.soul_path, self.state)
            for fragment in fragments:
                self.assertIn(fragment, str(cm.exception))
            self.assertEqual(self.text(), before, "a refused proposal changed SOUL.md")

        refused(proposal(section="Purpose",
                         changes=[{"rule_id": "S-E1", "text": "x", "evidence_count": 1}]),
                "Purpose")
        refused(proposal(section="Evidence standard",
                         changes=[{"rule_id": "S-E1", "text": "x", "evidence_count": 1}]),
                "Evidence standard")
        refused(proposal(section="Nope",
                         changes=[{"rule_id": "S-C1", "text": "x", "evidence_count": 1}]),
                "Nope")
        refused(proposal(changes=[
            {"rule_id": "S-C%d" % n, "text": "rule %d" % n, "evidence_count": 1}
            for n in range(1, 7)]), "5")
        for field in ("id", "what", "reasoning"):
            refused(proposal(**{field: "   "}), field)
        refused(proposal(evidence_count="12"), "evidence_count")
        refused(proposal(evidence_count=True), "evidence_count")
        refused(proposal(changes=[{"rule_id": "S-C1", "text": "x",
                                   "evidence_count": 1.5}]), "evidence_count")
        for forged in ("Use SE-12 for this.", "The SEC-3 gate is red.",
                       "Set pr_gate before shipping.", "The pr-gate flag.",
                       "Run agy here."):
            refused(proposal(changes=[{"rule_id": "S-C1", "text": forged,
                                       "evidence_count": 1}]), "rule text")

        # Nothing was recorded for any refusal.
        self.assertFalse(os.path.exists(os.path.join(self.state, "soul", "applied.jsonl")))
        history = os.path.join(self.state, "soul", "history")
        self.assertFalse(os.path.isdir(history) and os.listdir(history))

        # An edit that would push a file that is under the limit over 64 KiB is refused.
        big = os.path.join(self.dir, "big.md")
        pad = soul.MAX_BYTES - len(FIXTURE.encode("utf-8")) - 16
        with open(big, "w", encoding="utf-8") as f:
            f.write(FIXTURE + "\n" + ("x" * pad))
        self.assertLessEqual(os.path.getsize(big), soul.MAX_BYTES)
        with self.assertRaises(soul.SoulError) as cm:
            soul.apply(self.write_proposal(proposal(
                changes=[{"rule_id": "S-C1", "text": "y" * (2 * 1024),
                          "evidence_count": 1}])), big, self.state)
        self.assertIn("refusing to write", str(cm.exception))
        self.assertIn("64 KiB", str(cm.exception))

    def test_rule_text_guard_refuses_tools_not_command_words(self):
        """A rule names a tool, not the commands a reviewer happens to run"""
        for ordinary in (
            "A call that hits its timeout is retried.",
            "A rule may mention bash without naming the machinery.",
            "node, sed, awk, python, shell and curl are ordinary words here.",
        ):
            soul._guard_rule_text(ordinary)

        for forged in (
            "Run agy before judging.",
            "The pr_gate hook blocks it.",
            "The pr-gate hook blocks it.",
            "Check github before merging.",
            "Pipe the result through gh.",
            "Pipe the result through jq.",
            "Run shellcheck first.",
            "An mcp server answers it.",
            "claude-opus-4-6-thinking judged it.",
            "gemini-3.8-flash-high judged it.",
            "glm-x judged it.",
            "deepseek-chat judged it.",
        ):
            with self.assertRaises(soul.SoulError) as cm:
                soul._guard_rule_text(forged)
            self.assertIn("rule text", str(cm.exception))

    def test_applied_change_is_atomic_and_recorded(self):
        """An applied change is atomic and recorded"""
        before = self.text()
        path = self.write_proposal(proposal(changes=[
            {"rule_id": "S-C1", "text": "Docs drift is a finding.", "evidence_count": 12},
            {"rule_id": "S-C9",
             "text": "Workflow: a red check is a finding.", "evidence_count": 12},
        ]))
        self.assertEqual(soul.apply(path, self.soul_path, self.state), "applied")
        after = self.text()

        self.assertIn("- **S-C1** Docs drift is a finding.", after)
        self.assertIn("- **S-C9** Workflow: a red check is a finding.", after)
        self.assertIn("Section prose stays.", after)
        self.assertIn("Keep reviews useful and cheap.", after)
        self.assertIn("Intro prose that must survive.", after)
        self.assertNotIn("docs describe the old behaviour", after)

        # A snapshot of the previous file exists.
        history = os.path.join(self.state, "soul", "history")
        snaps = sorted(os.listdir(history))
        self.assertEqual(len(snaps), 1)
        self.assertIn("p-20261122-1", snaps[0])
        with open(os.path.join(history, snaps[0]), encoding="utf-8") as f:
            self.assertEqual(f.read(), before)

        # The applied id is journalled once.
        journal = os.path.join(self.state, "soul", "applied.jsonl")
        with open(journal, encoding="utf-8") as f:
            entries = [json.loads(line) for line in f if line.strip()]
        self.assertEqual([e["id"] for e in entries], ["p-20261122-1"])

        # One changelog entry with what, reasoning and the evidence count.
        self.assertEqual(after.count("· p-20261122-1"), 1)
        self.assertIn("- **", after)
        self.assertIn("— Add the docs-drift rule", after)
        self.assertIn("reasoning: Docs drift accounts for many findings.", after)
        self.assertIn("evidence: 12", after)
        self.assertGreater(after.index("· p-20261122-1"), after.index("## Changelog"))

        # No temp file survived the rename.
        self.assertEqual([f for f in os.listdir(self.dir) if f.startswith(".soul-")], [])

        # The CLI applies a proposal too.
        cli_soul = os.path.join(self.dir, "cli.md")
        with open(cli_soul, "w", encoding="utf-8") as f:
            f.write(FIXTURE)
        cli_prop = self.write_proposal(
            proposal(id="p-20261122-cli",
                     changes=[{"rule_id": "S-C2",
                               "text": "Test bite is a finding.", "evidence_count": 3}]),
            "cli.json")
        r = self.run_cli("apply", "--proposal", cli_prop, "--soul", cli_soul,
                         "--state-dir", os.path.join(self.dir, "clistate"))
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(cli_soul, encoding="utf-8") as f:
            self.assertIn("Test bite is a finding.", f.read())

        # Two concurrent appliers serialise on the lock: both changes survive.
        conc = os.path.join(self.dir, "concurrent.md")
        with open(conc, "w", encoding="utf-8") as f:
            f.write(FIXTURE)
        cstate = os.path.join(self.dir, "concstate")
        pa = self.write_proposal(proposal(id="p-a",
                                          changes=[{"rule_id": "S-C3", "text": "A rule.",
                                                    "evidence_count": 1}]), "a.json")
        pb = self.write_proposal(proposal(id="p-b",
                                          changes=[{"rule_id": "S-C4", "text": "B rule.",
                                                    "evidence_count": 1}]), "b.json")
        procs = [subprocess.Popen([sys.executable, SOUL_PY, "apply", "--proposal", p,
                                   "--soul", conc, "--state-dir", cstate],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                 for p in (pa, pb)]
        for proc in procs:
            out, err = proc.communicate()
            self.assertEqual(proc.returncode, 0, err.decode())
        with open(conc, encoding="utf-8") as f:
            final = f.read()
        self.assertIn("A rule.", final)
        self.assertIn("B rule.", final)
        self.assertIn("· p-a", final)
        self.assertIn("· p-b", final)
        soul.parse(conc)  # still a consistent, parseable file

    def test_replayed_apply_does_not_duplicate(self):
        """A replayed apply does not duplicate"""
        path = self.write_proposal(proposal())
        self.assertEqual(soul.apply(path, self.soul_path, self.state), "applied")
        after_first = self.text()

        self.assertEqual(soul.apply(path, self.soul_path, self.state), "already applied")
        self.assertEqual(self.text(), after_first)
        self.assertEqual(after_first.count("· p-20261122-1"), 1)

        journal = os.path.join(self.state, "soul", "applied.jsonl")
        with open(journal, encoding="utf-8") as f:
            self.assertEqual(len([line for line in f if line.strip()]), 1)
        history = os.path.join(self.state, "soul", "history")
        self.assertEqual(len(os.listdir(history)), 1)

        r = self.run_cli("apply", "--proposal", path, "--soul", self.soul_path,
                         "--state-dir", self.state)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("already applied", r.stdout)
        self.assertEqual(self.text(), after_first)

    def test_crash_window_replay_is_healed(self):
        """An applied id already in the changelog is not applied again"""
        proposal_id = "p-20261122-1"
        entry = (
            "- **2026-11-22 · %s** — Add the docs-drift rule\n"
            "  reasoning: Docs drift accounts for many findings.\n"
            "  evidence: 12 observations · 2026-11-22\n"
            % proposal_id
        )
        crashed = FIXTURE.replace("## Changelog\n\n",
                                  "## Changelog\n\n" + entry, 1)
        self.assertIn(entry, crashed)
        with open(self.soul_path, "w", encoding="utf-8") as f:
            f.write(crashed)
        with open(self.soul_path, "rb") as f:
            before = f.read()

        # The crash happened after SOUL.md was written and before the journal line.
        journal = os.path.join(self.state, "soul", "applied.jsonl")
        os.makedirs(os.path.dirname(journal), exist_ok=True)
        open(journal, "w", encoding="utf-8").close()

        path = self.write_proposal(proposal())
        self.assertEqual(soul.apply(path, self.soul_path, self.state), "already applied")
        with open(self.soul_path, "rb") as f:
            self.assertEqual(f.read(), before, "a healed replay changed SOUL.md")
        with open(journal, encoding="utf-8") as f:
            entries = [json.loads(line) for line in f if line.strip()]
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["id"], proposal_id)
        self.assertIs(entries[0]["healed"], True)

        # With the id now journalled, a second apply is the ordinary replay no-op.
        self.assertEqual(soul.apply(path, self.soul_path, self.state), "already applied")
        with open(self.soul_path, "rb") as f:
            self.assertEqual(f.read(), before)
        with open(journal, encoding="utf-8") as f:
            self.assertEqual(len([line for line in f if line.strip()]), 1)
        history = os.path.join(self.state, "soul", "history")
        self.assertFalse(os.path.isdir(history) and os.listdir(history))


if __name__ == "__main__":
    unittest.main(verbosity=2)
