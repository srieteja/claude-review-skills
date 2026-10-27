"""peer-review/review_learn.py -- capture, metrics, profile, distill and writer. Every
test runs against temp stores and a temp learn dir; the LLM is always a stub, never claude."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import review_learn as rl  # noqa: E402

SHA = "a" * 40
NOW = datetime(2026, 10, 24, 12, 0, 0, tzinfo=timezone.utc)
URL = "https://github.com/acme/%s/pull/%s"

F_A = {"id": "anthropic.t01-F1", "file": "lib/a.dart", "line": 10, "severity": "medium",
       "claim": "a breaks", "title": "a breaks", "v": {"verdict": "CONFIRMED"}}
F_B = {"id": "anthropic.c02-F1", "file": "lib/b.dart", "line": 20, "severity": "low",
       "claim": "b breaks", "title": "b breaks", "v": {"verdict": "CONFIRMED"}}
F_R = {"id": "agy.c03-F1", "file": "lib/c.dart", "line": 30, "severity": "low",
       "claim": "c refuted", "v": {"verdict": "REFUTED"}}
# #2387: two finders, one defect, the same marker twice.
F_A2 = {"id": "agy.t01-F1", "file": "lib/a.dart", "line": 10, "severity": "medium",
        "claim": "a breaks, again", "v": {"verdict": "CONFIRMED"}}


# Off the diff: review_body() writes it in full, since it has no inline comment.
F_C = {"id": "anthropic.t02-F1", "file": "lib/c.dart", "line": 5, "severity": "low", "title": "c leaks",
       "claim": "The socket is never closed when @override fires.", "repro": "Call stop() twice.",
       "v": {"verdict": "CONFIRMED"}}


def body(*findings, sha=SHA, full=()):
    """confirmed.jq's review_body: a verdict line, a one-liner per finding, `full` ones in full."""
    lines = ["Requesting changes at `%s`: %d confirmed defects, each inline below." % (sha[:12], len(findings)), ""]
    lines += ["- `%s:%s` — %s" % (f["file"], f["line"], f["claim"]) for f in findings]
    for f in full:
        lines += ["", "**%s** (`%s:%s`)" % (f["title"], f["file"], f["line"]), "", rl.quiet(f["claim"]),
                  "", "**Repro.** " + rl.quiet(f["repro"])]
    return "\n".join(lines) + "\n"


TEMPLATE = body(F_A, F_B)
SEED = """---
name: pr-review-posting-style
description: "Posted PR reviews must be terse inline comments with one-click suggestion blocks, not long wall-of-text bodies"
metadata:
  type: feedback
---

When posting a review to a PR, use a one-line review body and short inline comments.
"""


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.intense = self.tmp / "reviews-intense"
        self.regular = self.tmp / "reviews"
        self.learn = self.tmp / "state" / "learn"
        self.seed = self.tmp / "pr-review-posting-style.md"
        self.seed.write_text(SEED)
        self.env = {"PR_REVIEW_LEARN_DIR": str(self.learn), "PR_REVIEW_INTENSE_DIR": str(self.intense),
                    "PR_REVIEW_DIR": str(self.regular), "PR_REVIEW_LEARN_SEED": str(self.seed),
                    "PR_REVIEW_STATE": str(self.tmp / "state")}
        self.saved = {k: os.environ.get(k) for k in list(self.env) + ["PEER_REVIEW_SHIPPER"]}
        os.environ.update(self.env)
        os.environ.pop("PEER_REVIEW_SHIPPER", None)

    def tearDown(self):
        for k, v in self.saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def review(self, pr=2387, repo="widgets", author="bob", store=None,
               decision="request-changes", findings=(F_A, F_B, F_R), text=TEMPLATE, sha=SHA,
               meta=True):
        d = (store or self.intense) / author / repo / str(pr)
        (d / "decision").mkdir(parents=True)
        (d / ("pr%s-review.md" % pr)).write_text(
            "# PR #%s — t\n\n%s · reviewed at head `%s`\n" % (pr, URL % (repo, pr), sha))
        if meta:
            (d / "meta.json").write_text(json.dumps(
                {"url": URL % (repo, pr), "headRefOid": sha, "author": {"login": author}}))
            (d / "merged.json").write_text(json.dumps(list(findings)))
        (d / "decision" / "sha").write_text(sha + "\n")
        (d / "decision" / "body.md").write_text(text)
        (d / "decision" / "decision").write_text(decision + "\n")
        return d

    def ship(self, d, decision=None, text=None, posted="https://github.com/x/pull/1#r"):
        if decision:
            (d / "decision" / "decision").write_text(decision + "\n")
        if text is not None:
            (d / "decision" / "body.md").write_text(text)
        (d / "decision" / "posted").write_text(posted + "\n")
        return rl.record_ship(d)

    def events(self):
        return rl.read_events()


class TestSnapshot(Base):
    """Plan test 1 at module level; the shell version goes in offline-test.sh with the hooks."""

    def test_prepare_snapshots_proposed_and_draft_once(self):
        d = self.review()
        rl.record_prepare(d)
        self.assertEqual((d / "decision" / "proposed").read_text().strip(), "request-changes")
        self.assertEqual((d / "decision" / "draft.md").read_text(), TEMPLATE)
        # a human --decide afterwards changes decision and body, never the snapshots
        (d / "decision" / "decision").write_text("approve\n")
        (d / "decision" / "body.md").write_text("lgtm\n")
        rl.record_prepare(d)
        self.assertEqual((d / "decision" / "proposed").read_text().strip(), "request-changes")
        self.assertEqual((d / "decision" / "draft.md").read_text(), TEMPLATE)

    def test_prepare_records_arm_engine_and_profile_version(self):
        d = self.review()
        rl.record_prepare(d)
        learn = json.loads((d / "decision" / "learn.json").read_text())
        self.assertEqual(learn["arm"], rl.arm_for("widgets#2387"))
        self.assertEqual(learn["engine"], "intense")
        self.assertIn("profile_version", learn)

    def test_a_fix_snapshots_the_fix_body(self):
        d = self.review(decision="fix")
        (d / "decision" / "body.md").unlink()
        (d / "autofix").mkdir()
        (d / "autofix" / "body.md").write_text("fixes it\n")
        rl.record_prepare(d)
        self.assertEqual((d / "decision" / "draft.md").read_text(), "fixes it\n")

    def test_a_lane_only_fix_snapshots_the_lane_body_trunk_first(self):
        """A merged-PR fix freezes only autofix/trunk/; a lane is read when autofix/body.md is absent."""
        for lanes, want in ((("stacked",), "stacked\n"), (("trunk", "stacked"), "trunk\n")):
            d = self.review(decision="fix", pr=2387 + len(lanes))
            (d / "decision" / "body.md").unlink()
            for lane in lanes:
                (d / "autofix" / lane).mkdir(parents=True)
                (d / "autofix" / lane / "body.md").write_text(lane + "\n")
            rl.record_prepare(d)
            self.assertEqual((d / "decision" / "draft.md").read_text(), want, lanes)


class TestShip(Base):
    def test_disagreement(self):
        """Plan test 2, first half."""
        d = self.review(decision="approve", text="ok\n")
        rl.record_prepare(d)
        e = self.ship(d, decision="request-changes", text=TEMPLATE)
        self.assertEqual((e["proposed"], e["shipped"], e["agreement"]), ("approve", "request-changes", False))
        self.assertEqual((e["key"], e["repo"], e["pr"], e["author"], e["sha8"]),
                         ("widgets#2387", "widgets", 2387, "bob", SHA[:8]))
        self.assertTrue(e["human"])

    def test_one_removed_marker_is_exactly_one_drop(self):
        """Plan test 2, second half."""
        d = self.review()
        rl.record_prepare(d)
        e = self.ship(d, text=body(F_A))
        self.assertTrue(e["agreement"])
        self.assertEqual(e["confirmed"], [F_A["id"], F_B["id"]])
        self.assertEqual([x["fid"] for x in e["dropped"]], [F_B["id"]])
        self.assertEqual(e["dropped"][0]["file"], "lib/b.dart")
        self.assertEqual(e["dropped"][0]["line"], 20)

    def test_a_shared_marker_counts_each_finding(self):
        """#2387 had two CONFIRMED findings on one line; dropping one of the two entries is a drop."""
        d = self.review(findings=(F_A, F_A2, F_B), text=body(F_A, F_A2, F_B))
        rl.record_prepare(d)
        e = self.ship(d, text=body(F_A, F_B))
        self.assertEqual([x["fid"] for x in e["dropped"]], [F_A2["id"]])
        e2 = self.review(pr=2388, findings=(F_A, F_A2), text=body(F_A, F_A2))
        rl.record_prepare(e2)
        self.assertEqual(self.ship(e2)["dropped"], [])

    def test_a_hand_written_basename_marker_keeps_the_finding(self):
        """#2891: the shipped body named `enroll_verb_handler.dart:345`, not the full path."""
        d = self.review(findings=(F_A, F_B))
        e = self.ship(d, text="Request changes.\n\n**a** (`a.dart:10`) and see `lib/b.dart:20`.\n")
        self.assertEqual(e["dropped"], [])
        d2 = self.review(pr=2389, findings=(F_A,))
        self.assertEqual(len(self.ship(d2, text="`xa.dart:10` `a.dart:11`\n")["dropped"]), 1)

    def test_bodies_are_kept_beside_the_event(self):
        d = self.review()
        rl.record_prepare(d)
        e = self.ship(d, text=TEMPLATE + "\nthanks\n")
        kept = json.loads((self.learn / "bodies" / (e["id"] + ".json")).read_text())
        self.assertEqual(kept["draft"], TEMPLATE)
        self.assertEqual(kept["shipped"], TEMPLATE + "\nthanks\n")
        self.assertGreater(e["edit_ratio"], 0)

    def test_watch_ships_are_not_human_and_stats_ignore_them(self):
        """Plan test 3."""
        d = self.review()
        rl.record_prepare(d)
        os.environ["PEER_REVIEW_SHIPPER"] = "watch"
        e = self.ship(d)
        self.assertFalse(e["human"])
        s = rl.stats(window=None, now=NOW)
        self.assertEqual(s["all"]["ships"], 0)

    def test_ship_is_recorded_once_per_head(self):
        d = self.review()
        rl.record_prepare(d)
        self.ship(d)
        self.assertIsNone(rl.record_ship(d))
        self.assertEqual(len(self.events()), 1)

    def test_no_posted_no_event(self):
        d = self.review()
        self.assertIsNone(rl.record_ship(d))
        self.assertEqual(self.events(), [])

    def test_repo_from_the_report_when_there_is_no_meta(self):
        d = self.review(pr=2373, repo="widgets", author="alice", decision="approve",
                        findings=(), text="clean\n", meta=False, store=self.regular)
        e = self.ship(d)
        self.assertEqual((e["key"], e["engine"]), ("widgets#2373", "regular"))
        self.assertIsNone(e["proposed"])
        self.assertIsNone(e["edit_ratio"])

    def test_repo_from_the_store_path_when_nothing_names_it(self):
        d = self.review(pr=12, repo="gadgets", meta=False)
        (d / "pr12-review.md").write_text("# PR #12 — t\n")
        self.assertEqual(rl.pr_info(d), ("gadgets#12", "gadgets", 12, "bob"))


class TestRerun(Base):
    """Plan test 4 at module level."""

    def test_unshipped_decision_appends_one_rerun_with_the_old_proposal(self):
        d = self.review()
        rl.record_prepare(d)
        (d / "decision" / "decision").write_text("approve\n")  # a --decide in between
        missing = self.regular / "bob" / "2387"
        rl.record_rerun([missing, d], head=SHA)
        (e,) = self.events()
        self.assertEqual((e["kind"], e["proposed"], e["shipped"]), ("rerun", "request-changes", None))
        self.assertEqual(e["decided"], "approve")
        self.assertFalse(e["head_moved"])

    def test_posted_dir_appends_nothing(self):
        d = self.review()
        (d / "decision" / "posted").write_text("u\n")
        rl.record_rerun([d])
        self.assertEqual(self.events(), [])

    def test_head_moved_is_recorded(self):
        d = self.review()
        rl.record_rerun([d], head="b" * 40)
        self.assertTrue(self.events()[0]["head_moved"])


class TestCli(Base):
    """Plan test 5 at CLI level: record never fails, never prints."""

    def run_cli(self, *args, env=None):
        e = dict(os.environ, **(env or {}))
        return subprocess.run([sys.executable, str(HERE / "review_learn.py")] + list(args),
                              capture_output=True, text=True, env=e)

    def test_unwritable_store_exits_0_with_empty_stdout(self):
        d = self.review()
        (d / "decision" / "posted").write_text("u\n")
        unposted = self.review(pr=2400)
        blocker = self.tmp / "file"
        blocker.write_text("not a dir")
        for args in (("record", "prepare", str(d)), ("record", "ship", str(d)),
                     ("record", "rerun", str(unposted)), ("write-body", str(d))):
            p = self.run_cli(*args, env={"PR_REVIEW_LEARN_DIR": str(blocker / "learn"),
                                         "PR_REVIEW_LEARN_CLAUDE": "/nonexistent"})
            self.assertEqual((p.returncode, p.stdout), (0, ""), args)

    def test_bad_arguments_still_exit_0(self):
        for args in (("record",), ("record", "nope"), ("record", "ship"), ("write-body",)):
            p = self.run_cli(*args)
            self.assertEqual((p.returncode, p.stdout), (0, ""), args)

    def test_errors_are_logged(self):
        self.run_cli("record", "ship", str(self.tmp / "nowhere"))
        self.assertTrue((self.learn / "errors.log").exists())

    def test_off_switch_is_a_no_op(self):
        d = self.review()
        p = self.run_cli("record", "prepare", str(d), env={"PR_REVIEW_LEARN": "off"})
        self.assertEqual(p.returncode, 0)
        self.assertFalse((d / "decision" / "proposed").exists())

    def test_record_ship_via_cli(self):
        d = self.review()
        self.assertEqual(self.run_cli("record", "prepare", str(d)).returncode, 0)
        (d / "decision" / "posted").write_text("u\n")
        self.assertEqual(self.run_cli("record", "ship", str(d)).stdout, "")
        self.assertEqual(len(self.events()), 1)

    def test_stats_prints_json(self):
        p = self.run_cli("stats")
        self.assertEqual(p.returncode, 0)
        self.assertIn("all", json.loads(p.stdout))


class TestStats(Base):
    """Plan test 6."""

    def test_edit_ratio_bounds(self):
        self.assertEqual(rl.edit_ratio("a b c", "a b c"), 0.0)
        self.assertEqual(rl.edit_ratio("a b c", "x y z"), 1.0)
        self.assertIsNone(rl.edit_ratio(None, "x"))

    def shipped(self, pr, arm, draft, final, proposed="request-changes", shipped="request-changes"):
        d = self.review(pr=pr, decision=proposed, text=draft)
        rl.record_prepare(d)
        learn = json.loads((d / "decision" / "learn.json").read_text())
        learn["arm"] = arm
        (d / "decision" / "learn.json").write_text(json.dumps(learn))
        return self.ship(d, decision=shipped, text=final)

    def test_split_by_arm_each_with_n(self):
        self.shipped(1, "treatment", TEMPLATE, TEMPLATE)
        self.shipped(2, "treatment", TEMPLATE, body(F_A), proposed="approve")
        self.shipped(3, "control", "a b c", "x y z")
        s = rl.stats(window=None, now=NOW)
        t, c = s["arms"]["treatment"], s["arms"]["control"]
        self.assertEqual(t["edit_ratio"]["n"], 2)
        self.assertEqual(t["agreement"], {"value": 0.5, "n": 2})
        self.assertEqual(t["keep_rate"], {"value": 0.75, "n": 4})
        self.assertEqual(c["edit_ratio"], {"value": 1.0, "n": 1})
        self.assertEqual(s["all"]["ships"], 3)

    def test_no_arm_is_baseline_and_null_metrics_are_left_out(self):
        d = self.review(pr=5)
        e = self.ship(d)  # no prepare snapshot: nothing to compare
        self.assertIsNone(e["arm"])
        b = rl.stats(window=None, now=NOW)["arms"]["baseline"]
        self.assertEqual(b["edit_ratio"], {"value": None, "n": 0})
        self.assertEqual(b["agreement"], {"value": None, "n": 0})
        self.assertEqual(b["ships"], 1)

    def test_rerun_rate_counts_same_head_reruns_over_decided_prs(self):
        a = self.review(pr=1)
        rl.record_prepare(a)
        rl.record_rerun([a], head=SHA)
        rl.record_rerun([a], head="b" * 40)  # the author pushed: not a vote against the review
        self.ship(a)
        s = rl.stats(window=None, now=NOW)["all"]
        self.assertEqual(s["rerun_rate"], {"value": 1.0, "n": 1})

    def test_window_excludes_old_events(self):
        d = self.review(pr=1)
        rl.record_prepare(d)
        self.ship(d)
        later = datetime.now(timezone.utc) + timedelta(days=60)
        self.assertEqual(rl.stats(window=30, now=later)["all"]["ships"], 0)


class TestArm(Base):
    """Plan test 10."""

    def test_stable_and_about_a_fifth(self):
        self.assertEqual({rl.arm_for("gadgets#2894") for _ in range(5)}, {rl.arm_for("gadgets#2894")})
        n = sum(rl.arm_for("repo%d#%d" % (i % 7, i)) == "control" for i in range(1000))
        self.assertTrue(150 <= n <= 250, n)


def ev(i, days_ago=1, human=True, kind="ship"):
    ts = (NOW - timedelta(days=days_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {"id": "e%d" % i, "ts": ts, "kind": kind, "key": "r#%d" % i, "repo": "r", "pr": i,
            "author": "a", "sha8": "aaaaaaaa", "human": human, "proposed": "request-changes",
            "shipped": "request-changes", "arm": None, "edit_ratio": 0.5,
            "confirmed": [], "dropped": []}


class Profile(Base):
    def put_events(self, *evs):
        self.learn.mkdir(parents=True, exist_ok=True)
        with open(self.learn / "events.jsonl", "a") as f:
            for e in evs:
                f.write(json.dumps(e) + "\n")


class TestDistill(Profile):
    """Plan test 7."""

    def stub(self, ops):
        calls = []

        def llm(prompt):
            calls.append(prompt)
            return json.dumps({"ops": ops})
        llm.calls = calls
        return llm

    def test_ops_validated_and_counted_by_code(self):
        self.put_events(ev(1), ev(2), ev(3, human=False))
        llm = self.stub([
            {"op": "add", "text": "One line per finding.", "target": "writer", "effect": "style",
             "events": ["e1"], "support": 9},
            {"op": "add", "text": "Cites a ghost.", "target": "writer", "effect": "style", "events": ["e99"]},
            {"op": "add", "text": "Cites a watcher ship.", "target": "writer", "effect": "style",
             "events": ["e3"]},
            {"op": "add", "text": "Bad target.", "target": "refuter", "effect": "style", "events": ["e1"]},
            {"op": "explode", "events": ["e1"]},
        ])
        out = rl.distill(llm=llm, now=NOW)
        self.assertEqual(out["applied"], 1)
        self.assertEqual(out["rejected"], 4)
        p = rl.load_profile()
        mine = [r for r in p["rules"] if r["source"] == "distill"]
        self.assertEqual([r["text"] for r in mine], ["One line per finding."])
        self.assertEqual(mine[0]["support"], ["e1"])  # the LLM's "support: 9" is ignored
        self.assertEqual(rl.view(p, now=NOW)["rules"][-1]["state"], "candidate")
        self.assertNotIn("e3", llm.calls[0])  # a watcher ship never reaches the prompt

    def test_a_page_edit_during_the_call_survives_it(self):
        self.put_events(ev(1), ev(2))
        rl.distill(llm=self.stub([{"op": "add", "text": "Terse.", "target": "writer",
                                   "effect": "style", "events": ["e1"]}]), now=NOW)
        rid = rl.load_profile()["rules"][-1]["id"]
        self.put_events(ev(3))

        def llm(prompt):  # the page deletes the rule while claude thinks
            rl.delete_rule(rid, now=NOW)
            return json.dumps({"ops": [{"op": "support", "rule": rid, "events": ["e3"]}]})
        out = rl.distill(llm=llm, now=NOW)
        p = rl.load_profile()
        self.assertEqual(out["applied"], 0)
        self.assertNotIn(rid, [r["id"] for r in p["rules"]])
        self.assertIn(rl.text_hash("Terse."), [t["text_hash"] for t in p["deleted"]])

    def test_second_support_makes_it_active_and_the_cursor_moves(self):
        self.put_events(ev(1))
        rl.distill(llm=self.stub([{"op": "add", "text": "Terse.", "target": "writer",
                                   "effect": "style", "events": ["e1"]}]), now=NOW)
        rid = [r for r in rl.load_profile()["rules"] if r["source"] == "distill"][0]["id"]
        self.put_events(ev(2))
        llm = self.stub([{"op": "support", "rule": rid, "events": ["e2", "e2"]},
                         {"op": "support", "rule": rid, "events": ["e1"]}])  # e1 is old news
        out = rl.distill(llm=llm, now=NOW)
        self.assertNotIn('"id": "e1"', llm.calls[0])
        self.assertEqual(out["rejected"], 1)
        r = [r for r in rl.view(rl.load_profile(), now=NOW)["rules"] if r["id"] == rid][0]
        self.assertEqual((r["support"], r["state"]), (["e1", "e2"], "active"))

    def test_pinned_rules_are_untouched(self):
        rl.import_seed()
        seed = rl.load_profile()["rules"][0]
        self.put_events(ev(1))
        out = rl.distill(llm=self.stub([{"op": "contradict", "rule": seed["id"], "events": ["e1"]}]), now=NOW)
        self.assertEqual(out["rejected"], 1)
        self.assertEqual(rl.load_profile()["rules"][0], seed)

    def test_tombstoned_text_is_not_readded(self):
        self.put_events(ev(1))
        rl.distill(llm=self.stub([{"op": "add", "text": "Terse.", "target": "writer",
                                   "effect": "style", "events": ["e1"]}]), now=NOW)
        rid = [r for r in rl.load_profile()["rules"] if r["source"] == "distill"][0]["id"]
        rl.delete_rule(rid)
        self.put_events(ev(2))
        out = rl.distill(llm=self.stub([{"op": "add", "text": "  terse. ", "target": "writer",
                                         "effect": "style", "events": ["e2"]}]), now=NOW)
        self.assertEqual((out["applied"], out["rejected"]), (0, 1))
        self.assertFalse([r for r in rl.load_profile()["rules"] if r["source"] == "distill"])

    def test_same_text_add_is_a_support(self):
        self.put_events(ev(1))
        rl.distill(llm=self.stub([{"op": "add", "text": "Terse.", "target": "writer",
                                   "effect": "style", "events": ["e1"]}]), now=NOW)
        self.put_events(ev(2))
        rl.distill(llm=self.stub([{"op": "add", "text": "terse.", "target": "writer",
                                   "effect": "style", "events": ["e2"]}]), now=NOW)
        mine = [r for r in rl.load_profile()["rules"] if r["source"] == "distill"]
        self.assertEqual([r["support"] for r in mine], [["e1", "e2"]])

    def test_nothing_new_makes_no_call(self):
        llm = self.stub([])
        self.assertEqual(rl.distill(llm=llm, now=NOW)["events"], 0)
        self.assertEqual(llm.calls, [])

    def test_unparseable_output_changes_nothing(self):
        self.put_events(ev(1))
        out = rl.distill(llm=lambda p: "sorry, no json", now=NOW)
        self.assertIn("error", out)
        self.assertFalse((self.learn / "profile.json").exists()
                         and rl.load_profile().get("cursor"))


class TestDecay(Profile):
    """Plan test 8."""

    def test_old_support_goes_dormant_unless_pinned(self):
        self.put_events(*(ev(i, days_ago=200) for i in (1, 2, 3)))
        rule = {"id": "r9", "text": "x", "target": "writer", "effect": "style", "scope": {},
                "support": ["e1", "e2", "e3"], "contra": [], "pinned": False, "source": "distill"}
        events = {e["id"]: e for e in rl.read_events()}
        self.assertEqual(rl.rule_state(rule, events, NOW)[1], "dormant")
        self.assertEqual(rl.rule_state(dict(rule, pinned=True), events, NOW)[1], "active")

    def test_recent_support_is_active_and_contra_subtracts(self):
        self.put_events(ev(1), ev(2), ev(3))
        events = {e["id"]: e for e in rl.read_events()}
        rule = {"support": ["e1", "e2"], "contra": [], "pinned": False}
        w, state = rl.rule_state(rule, events, NOW)
        self.assertEqual(state, "active")
        self.assertAlmostEqual(w, 2 * 0.5 ** (1 / 60), places=6)
        self.assertEqual(rl.rule_state(dict(rule, contra=["e3"]), events, NOW)[1], "dormant")


class TestProfileCrud(Profile):
    """Plan test 11 at module level; the HTTP routes reuse these in phase 2."""

    def test_update_bumps_version_writes_history_and_pins(self):
        rl.import_seed()
        p = rl.load_profile()
        rid = p["rules"][0]["id"]
        rl.update_rule(rid, text="One-line body.")
        q = rl.load_profile()
        self.assertEqual(q["version"], p["version"] + 1)
        self.assertTrue((self.learn / "history" / ("profile-v%d.json" % q["version"])).exists())
        self.assertEqual((q["rules"][0]["text"], q["rules"][0]["pinned"], q["rules"][0]["source"]),
                         ("One-line body.", True, "user"))

    def test_delete_tombstones(self):
        rl.import_seed()
        r = rl.load_profile()["rules"][0]
        rl.delete_rule(r["id"])
        p = rl.load_profile()
        self.assertEqual(p["rules"], [])
        self.assertEqual(p["deleted"][0]["text_hash"], rl.text_hash(r["text"]))

    def test_unknown_id_raises_keyerror(self):
        with self.assertRaises(KeyError):
            rl.update_rule("r404", pinned=True)
        with self.assertRaises(KeyError):
            rl.delete_rule("r404")


class TestSeed(Profile):
    """Plan test 12."""

    def test_imported_once_pinned(self):
        rl.import_seed()
        p = rl.load_profile()
        (r,) = p["rules"]
        self.assertEqual((r["pinned"], r["source"], r["target"], r["state"]),
                         (True, "memory:pr-review-posting-style", "writer", "active"))
        self.assertIn("terse inline comments", r["text"])
        rl.import_seed()
        self.assertEqual(rl.load_profile()["version"], p["version"])

    def test_a_deleted_seed_stays_deleted(self):
        rl.import_seed()
        rl.delete_rule(rl.load_profile()["rules"][0]["id"])
        v = rl.load_profile()["version"]
        rl.import_seed()
        self.assertEqual((rl.load_profile()["version"], rl.load_profile()["rules"]), (v, []))

    def test_no_seed_unless_configured(self):
        """Nobody else has the author's Claude memory: an unset PR_REVIEW_LEARN_SEED imports
        nothing, whatever lies under ~/.claude."""
        home = self.tmp / "home"
        (home / ".claude/projects/-home-x-work-skills/memory").mkdir(parents=True)
        (home / ".claude/projects/-home-x-work-skills/memory/pr-review-posting-style.md").write_text(SEED)
        os.environ.pop("PR_REVIEW_LEARN_SEED")
        with mock.patch.dict(os.environ, {"HOME": str(home), "XDG_CONFIG_HOME": str(home / ".config")}), \
                mock.patch.object(rl, "HOME", home):
            self.assertIsNone(rl.import_seed())
        self.assertEqual(rl.load_profile()["rules"], [])

    def test_posting_style_beside_config_is_the_default_seed(self):
        conf = self.tmp / "config"
        (conf / "review-skills").mkdir(parents=True)
        (conf / "review-skills/posting-style.md").write_text(SEED)
        os.environ.pop("PR_REVIEW_LEARN_SEED")
        with mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": str(conf)}):
            rl.import_seed()
        self.assertEqual(rl.load_profile()["rules"][0]["source"], "memory:posting-style")

    def test_missing_seed_file_is_fine(self):
        self.seed.unlink()
        rl.import_seed()
        self.assertEqual(rl.load_profile()["rules"], [])


class TestWriteBody(Base):
    """Plan test 9."""

    FINDINGS = [F_A, F_B, F_R]

    @staticmethod
    def write(*args, inline=(rl.marker(F_A), rl.marker(F_B))):
        """TEMPLATE's findings each have an inline comment, as review.json would say."""
        return rl.write_body(*args, inline=inline)

    def test_accepts_output_that_keeps_every_marker(self):
        out = "Requesting changes at `%s`.\n\n- `lib/a.dart:10` a\n- `lib/b.dart:20` b\n" % SHA[:12]
        text, info = self.write(TEMPLATE, self.FINDINGS, ["Terse."], "treatment", lambda p: out)
        self.assertEqual((text, info["writer"]), (out, "llm"))

    def test_a_re_wrapped_marker_falls_back(self):
        """Ship keys each inline comment on the exact `file:line` string."""
        out = "Requesting changes at `%s`.\n\n- lib/a.dart:10 a\n- `lib/b.dart:20` b\n" % SHA[:12]
        _, info = self.write(TEMPLATE, self.FINDINGS, [], "treatment", lambda p: out)
        self.assertEqual(info["writer"], "template")

    def test_off_diff_detail_must_survive_verbatim(self):
        tmpl = body(F_A, full=[F_C])
        keep = tmpl.replace("Requesting changes", "Changes requested")
        on_diff = [rl.marker(F_A)]
        _, info = self.write(tmpl, [F_A, F_C], [], "treatment", lambda p: keep, inline=on_diff)
        self.assertEqual(info["writer"], "llm")
        for cut in (rl.quiet(F_C["repro"]), "never closed"):
            _, info = self.write(tmpl, [F_A, F_C], [], "treatment", lambda p: keep.replace(cut, "x"),
                                 inline=on_diff)
            self.assertEqual(info["writer"], "template", cut)
            self.assertIn(F_C["id"], info["fallback"])

    def test_one_liner_claims_may_be_reworded(self):
        """A finding with an inline comment is a one-liner: only its marker is load-bearing."""
        out = TEMPLATE.replace("a breaks", "a is broken")
        _, info = self.write(TEMPLATE, self.FINDINGS, [], "treatment", lambda p: out)
        self.assertEqual(info["writer"], "llm")

    def test_a_missing_marker_falls_back_to_the_template(self):
        out = "Requesting changes at `%s`.\n\n- `lib/a.dart:10` a\n" % SHA[:12]
        text, info = self.write(TEMPLATE, self.FINDINGS, [], "treatment", lambda p: out)
        self.assertEqual((text, info["writer"]), (TEMPLATE, "template"))
        self.assertIn("lib/b.dart:20", info["fallback"])

    def test_one_of_a_shared_marker_missing_falls_back(self):
        tmpl = body(F_A, F_A2)
        out = "Requesting changes at `%s`.\n- `lib/a.dart:10` a\n" % SHA[:12]
        text, info = self.write(tmpl, [F_A, F_A2], [], "treatment", lambda p: out)
        self.assertEqual(info["writer"], "template")

    def test_bare_at_user_is_quieted(self):
        out = "Requesting changes at `%s` @carol _@bob_ me@x.io.\n- (`lib/a.dart:10`) (`lib/b.dart:20`)\n" % SHA[:12]
        text, _ = self.write(TEMPLATE, self.FINDINGS, [], "treatment", lambda p: out)
        self.assertIn("@⁠carol", text)
        self.assertIn("_@⁠bob_", text)
        self.assertIn("me@x.io", text)
        self.assertEqual(rl.quiet(rl.quiet("@a")), rl.quiet("@a"))

    def test_control_arm_gets_an_empty_rules_block(self):
        seen = []
        self.write(TEMPLATE, self.FINDINGS, ["Terse."], "control", lambda p: seen.append(p) or TEMPLATE)
        self.write(TEMPLATE, self.FINDINGS, ["Terse."], "treatment", lambda p: seen.append(p) or TEMPLATE)
        self.assertNotIn("Terse.", seen[0])
        self.assertIn("Terse.", seen[1])

    def test_fenced_output_is_unwrapped(self):
        out = "```markdown\n" + TEMPLATE + "```\n"
        text, info = self.write(TEMPLATE, self.FINDINGS, [], "treatment", lambda p: out)
        self.assertEqual((text.strip(), info["writer"]), (TEMPLATE.strip(), "llm"))

    def test_a_suggestion_block_or_lost_sha_falls_back(self):
        for out in (TEMPLATE + "\n```suggestion\nx\n```\n", TEMPLATE.replace(SHA[:12], "")):
            text, info = self.write(TEMPLATE, self.FINDINGS, [], "treatment", lambda p: out)
            self.assertEqual(info["writer"], "template", out)

    def test_llm_failure_falls_back(self):
        def boom(p):
            raise RuntimeError("no claude")
        text, info = self.write(TEMPLATE, self.FINDINGS, [], "treatment", boom)
        self.assertEqual((text, info["writer"]), (TEMPLATE, "template"))

    def test_write_body_dir_uses_active_writer_rules_and_records_learn_json(self):
        rl.import_seed()
        d = self.review(pr=7, repo="gadgets")
        seen = []
        arm = rl.arm_for("gadgets#7")
        rl.write_body_dir(d, llm=lambda p: seen.append(p) or TEMPLATE)
        learn = json.loads((d / "decision" / "learn.json").read_text())
        self.assertEqual((learn["arm"], learn["writer"]), (arm, "llm"))
        self.assertEqual(learn["profile_version"], rl.load_profile()["version"])
        self.assertEqual("terse inline comments" in seen[0], arm == "treatment")

    def test_write_body_dir_reads_inline_markers_from_review_json(self):
        d = self.review()
        (d / "decision" / "review.json").write_text(json.dumps(
            {"body": TEMPLATE, "comments": [{"path": "lib/a.dart", "line": 10, "marker": "`lib/a.dart:10`"}]}))
        for old, writer in (("a breaks", "llm"), ("b breaks", "template")):
            (d / "decision" / "body.md").write_text(TEMPLATE)
            rl.write_body_dir(d, llm=lambda p: TEMPLATE.replace(old, "it is broken"))
            self.assertEqual(json.loads((d / "decision" / "learn.json").read_text())["writer"], writer, old)
        (d / "decision" / "review.json").unlink()
        rl.write_body_dir(d, llm=lambda p: TEMPLATE.replace("a breaks", "it is broken"))
        self.assertEqual(json.loads((d / "decision" / "learn.json").read_text())["writer"], "template")

    def test_write_body_dir_runs_before_decide_rewrites_the_decision(self):
        """freeze() order on `--decide request-changes` over an approve: body.md is new, the
        decision file still says approve until after the writer."""
        d = self.review(decision="approve", text=TEMPLATE)
        out = TEMPLATE + "\nThanks.\n"
        rl.write_body_dir(d, llm=lambda p: out)
        self.assertEqual((d / "decision" / "body.md").read_text(), out)


if __name__ == "__main__":
    unittest.main()
