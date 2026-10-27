#!/usr/bin/env python3
"""The learning engine: what you did with each decision peer-review froze, distilled into rules
the body writer follows.

  capture   record prepare|ship|rerun  -- passive, at three points in peer-review.sh
  metrics   stats                      -- edit ratio, agreement, keep rate, rerun rate, per arm
  profile   distill, seed, update_rule, delete_rule -- versioned rules; the LLM proposes ops,
                                          this code validates them and does every count
  writer    write-body                 -- restyles a request-changes body under the active
                                          writer rules; any lost CONFIRMED marker reverts it

Store (PR_REVIEW_LEARN_DIR, else $PR_REVIEW_STATE/learn, else ~/.local/state/pr-review/learn):
  events.jsonl  bodies/<event-id>.json  profile.json  history/profile-v<N>.json  errors.log

`record` and `write-body` are hooks: they always exit 0, never print to stdout (callers parse
peer-review's), and log failures to errors.log. PR_REVIEW_LEARN=off turns them into no-ops.
Stdlib only: peer-review.sh runs it on whatever python3 is first on PATH.
"""
import argparse
import contextlib
import copy
import difflib
import fcntl
import functools
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
HOME = Path.home()

HALF_LIFE_DAYS = 60
ACTIVE_SUPPORTS = 2      # one edit isn't a preference
ACTIVE_WEIGHT = 1.0
HOLDOUT_MOD = 5          # sha1(key) % 5 == 0 -> control, about 20%
TARGETS = ("writer", "finder")
EFFECTS = ("style", "emphasize", "rank")
MAX_RULE_CHARS = 300

_PR_URL = re.compile(r"github\.com/[^/\s]+/([^/\s]+)/pull/(\d+)")
# confirmed.jq's `file:line`. Ship posts an inline comment only while its marker is in the body.
_MARKER = re.compile(r"`([^`\s]+):(\d+)`")
_QUIET = re.compile(r"(?<![A-Za-z0-9])@(?=[A-Za-z0-9_])")
_FENCE = re.compile(r"^\s*```[A-Za-z]*\n(.*?)\n?```\s*$", re.S)
_SHA_TICK = re.compile(r"`([0-9a-f]{7,40})`")
TS_FMT = "%Y-%m-%dT%H:%M:%SZ"


# ---- paths and small helpers ------------------------------------------------------------------

def learn_dir():
    if os.environ.get("PR_REVIEW_LEARN_DIR"):
        return Path(os.environ["PR_REVIEW_LEARN_DIR"])
    return Path(os.environ.get("PR_REVIEW_STATE", HOME / ".local/state/pr-review")) / "learn"


def stores():
    """lib/common.sh's review_store and intense_store."""
    regular = Path(os.environ.get("PR_REVIEW_DIR") or HOME / ".reviews")
    return (("intense", Path(os.environ.get("PR_REVIEW_INTENSE_DIR") or regular / "_intense")),
            ("regular", regular))


def utcnow():
    return datetime.now(timezone.utc)


def fmt_ts(dt):
    return dt.astimezone(timezone.utc).strftime(TS_FMT)


def parse_ts(s):
    return datetime.strptime(s, TS_FMT).replace(tzinfo=timezone.utc)


def read(path):
    """A small text file's content, or None when it isn't there."""
    try:
        return Path(path).read_text()
    except (FileNotFoundError, NotADirectoryError):
        return None


def read_word(path):
    t = read(path)
    return t.strip() if t and t.strip() else None


def read_json(path, default=None):
    t = read(path)
    return json.loads(t) if t else default


def write_atomic(path, text):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix="." + path.name)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def log_error(msg):
    line = "%s %s\n" % (fmt_ts(utcnow()), msg)
    try:
        learn_dir().mkdir(parents=True, exist_ok=True)
        with open(learn_dir() / "errors.log", "a") as f:
            f.write(line)
    except OSError:
        sys.stderr.write("review_learn: " + line)


def quiet(s):
    """confirmed.jq's quiet: a word joiner after an @ that starts a word, so no one is pinged."""
    return _QUIET.sub("@⁠", s)


def arm_for(key):
    """Deterministic per repo#pr, so a re-run stays in its arm. Never hash(): it is salted."""
    return "control" if int(hashlib.sha1(key.encode()).hexdigest(), 16) % HOLDOUT_MOD == 0 else "treatment"


def edit_ratio(draft, shipped):
    if draft is None or shipped is None:
        return None
    sm = difflib.SequenceMatcher(None, draft.split(), shipped.split(), autojunk=False)
    return round(1 - sm.ratio(), 4)


def text_hash(text):
    return hashlib.sha1(" ".join(text.lower().split()).encode()).hexdigest()


# ---- a store dir: <store>/<author>/<repo>/<N> ----------------------------------------------------

def pr_info(d):
    """(key, repo, pr, author) for a store dir. Repo from meta.json's url, else the posted url,
    else the report's url line (zero-findings runs write no meta.json), else the store path."""
    d = Path(d)
    pr = int(d.name)
    texts = [(read_json(d / "meta.json", {}) or {}).get("url") or "",
             read(d / "decision" / "posted") or "",
             (read(d / ("pr%d-review.md" % pr)) or "")[:2000]]
    repo = d.parent.name
    for t in texts:
        m = _PR_URL.search(t)
        if m and int(m.group(2)) == pr:
            repo = m.group(1)
            break
    return "%s#%d" % (repo, pr), repo, pr, d.parent.parent.name


def engine_for(d):
    d = Path(d).resolve()
    for name, root in stores():
        try:
            d.relative_to(Path(root).resolve())
            return name
        except ValueError:
            continue
    return None


def public_body_path(d, decision):
    """What a decision posts: the fix PR's body, or the review body. A merged-PR fix freezes
    only a lane (autofix/trunk/), so a missing autofix/body.md falls back trunk, then stacked."""
    d = Path(d)
    if decision != "fix":
        return d / "decision" / "body.md"
    paths = [d / "autofix" / p / "body.md" for p in ("", "trunk", "stacked")]
    return next((p for p in paths if p.exists()), paths[0])


def confirmed_findings(d):
    merged = read_json(Path(d) / "merged.json", []) or []
    return [f for f in merged if (f.get("v") or {}).get("verdict") == "CONFIRMED"]


def marker(f):
    return "%s:%s" % (f.get("file"), f.get("line"))


def markers(text):
    return Counter("%s:%s" % m for m in _MARKER.findall(text or ""))


def dropped(findings, body):
    """CONFIRMED findings with no `file:line` left in body. Counted, not just looked up: two
    findings may share a marker, and losing one of the two entries is a drop. Lenient where a
    human writes by hand (#2891 kept `enroll_verb_handler.dart:345`): any backticked path that is
    the file or a /-suffix of it, at the same line, keeps the finding."""
    have = [(p, int(n)) for p, n in _MARKER.findall(body or "")]
    out = []
    for f in findings:
        path, line = str(f.get("file")), f.get("line")
        hit = next((i for i, (p, n) in enumerate(have)
                    if n == line and (p == path or path.endswith("/" + p))), None)
        if hit is not None:
            del have[hit]
        else:
            out.append({"fid": f.get("id"), "file": f.get("file"), "line": f.get("line"),
                        "severity": f.get("severity"), "claim": f.get("claim")})
    return out


# ---- events -----------------------------------------------------------------------------------

def read_events():
    out = []
    try:
        with open(learn_dir() / "events.jsonl") as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        out.append(json.loads(line))
                    except ValueError:
                        continue
    except (FileNotFoundError, NotADirectoryError):
        pass
    return out


def append_event(event, bodies=None):
    root = learn_dir()
    root.mkdir(parents=True, exist_ok=True)
    if bodies is not None:
        write_atomic(root / "bodies" / (event["id"] + ".json"), json.dumps(bodies))
    with open(root / "events.jsonl", "a") as f:
        f.write(json.dumps(event, sort_keys=True) + "\n")
    return event


def event_id(*parts):
    return "e" + hashlib.sha1("|".join(str(p) for p in parts).encode()).hexdigest()[:12]


def shipped_already(key, sha8):
    return any(e.get("kind") == "ship" and e.get("key") == key and e.get("sha8") == sha8
               for e in read_events())


def human_shipper():
    """An unattended shipper sets PEER_REVIEW_SHIPPER=watch: its ship expresses no preference."""
    return os.environ.get("PEER_REVIEW_SHIPPER", "") != "watch"


def _base_event(d, kind, ts, human):
    d = Path(d)
    key, repo, pr, author = pr_info(d)
    learn = read_json(d / "decision" / "learn.json", {}) or {}
    sha = read_word(d / "decision" / "sha") or ""
    return {"id": event_id(kind, key, sha, ts), "ts": ts, "kind": kind, "key": key, "repo": repo,
            "pr": pr, "author": author, "sha8": sha[:8], "human": human,
            "engine": learn.get("engine") or engine_for(d), "arm": learn.get("arm"),
            "profile_version": learn.get("profile_version")}


def record_prepare(d):
    """At the end of a prepare's freeze(): snapshot what the pipeline proposed and the body it
    drafted (after the writer), write-once, so a later --decide or edit never overwrites them."""
    d = Path(d)
    dec = d / "decision"
    decision = read_word(dec / "decision")
    if decision is None:
        raise FileNotFoundError("no decision in %s" % dec)
    if not (dec / "proposed").exists():
        write_atomic(dec / "proposed", decision + "\n")
    draft = read(public_body_path(d, decision))
    if draft is not None and not (dec / "draft.md").exists():
        write_atomic(dec / "draft.md", draft)
    _merge_learn(d, {})


def _merge_learn(d, fields):
    """decision/learn.json: {arm, engine, profile_version, ...}, set once at the first write;
    ship reads it back, since $ENGINE isn't known on the ship path."""
    path = Path(d) / "decision" / "learn.json"
    learn = read_json(path, {}) or {}
    key = pr_info(d)[0]
    learn.setdefault("arm", arm_for(key))
    learn.setdefault("engine", engine_for(d))
    if "profile_version" not in learn:
        learn["profile_version"] = load_profile()["version"]
    learn.update(fields)
    write_atomic(path, json.dumps(learn, sort_keys=True) + "\n")
    return learn


def _ship_event(d, ts, human, proposed):
    d = Path(d)
    dec = d / "decision"
    shipped = read_word(dec / "decision")
    body = read(public_body_path(d, shipped))
    draft = read(dec / "draft.md")
    findings = confirmed_findings(d)
    drops = dropped(findings, body) if body is not None else []
    e = _base_event(d, "ship", ts, human)
    e.update({"proposed": proposed, "shipped": shipped,
              "agreement": (proposed == shipped) if proposed else None,
              "edit_ratio": edit_ratio(draft, body),
              "confirmed": [f.get("id") for f in findings], "dropped": drops})
    return e, {"draft": draft, "shipped": body}


def record_ship(d, now=None):
    """After --ship wrote decision/posted. Once per repo#pr at a head."""
    d = Path(d)
    if not d.is_dir():
        raise FileNotFoundError("no review dir %s" % d)
    dec = d / "decision"
    if not read_word(dec / "posted") or not read_word(dec / "decision"):
        return None
    key = pr_info(d)[0]
    if shipped_already(key, (read_word(dec / "sha") or "")[:8]):
        return None
    e, bodies = _ship_event(d, fmt_ts(now or utcnow()), human_shipper(), read_word(dec / "proposed"))
    return append_event(e, bodies)


def record_rerun(dirs, head=None, now=None):
    """At prepare start, before the old decision is cleared: each unshipped decision being
    abandoned. A re-run at a moved head is the author pushing, not a vote against the review."""
    out = []
    for d in dirs:
        d = Path(d)
        dec = d / "decision"
        decided = read_word(dec / "decision")
        if decided is None or read_word(dec / "posted"):
            continue
        sha = read_word(dec / "sha") or ""
        e = _base_event(d, "rerun", fmt_ts(now or utcnow()), human_shipper())
        e.update({"proposed": read_word(dec / "proposed") or decided, "decided": decided,
                  "shipped": None, "head_moved": (head != sha) if head else None})
        out.append(append_event(e))
    return out


# ---- metrics ----------------------------------------------------------------------------------

def _mean(xs):
    xs = [x for x in xs if x is not None]
    return {"value": round(sum(xs) / len(xs), 4) if xs else None, "n": len(xs)}


def _ratio(num, den):
    return {"value": round(num / den, 4) if den else None, "n": den}


def _metrics(evs):
    ships = [e for e in evs if e.get("kind") == "ship"]
    reruns = [e for e in evs if e.get("kind") == "rerun" and e.get("head_moved") is not True]
    conf = sum(len(e.get("confirmed") or []) for e in ships)
    kept = conf - sum(len(e.get("dropped") or []) for e in ships)
    agree = [e["agreement"] for e in ships if e.get("agreement") is not None]
    decided = {e.get("key") for e in evs if e.get("kind") in ("ship", "rerun")}
    return {"ships": len(ships),
            "edit_ratio": _mean(e.get("edit_ratio") for e in ships),
            "agreement": _ratio(sum(agree), len(agree)),
            "keep_rate": _ratio(kept, conf),
            "rerun_rate": _ratio(len(reruns), len(decided))}


def stats(window=30, now=None):
    """Human events only, split by arm. Events from before v3 have no arm and
    are the `baseline`: the before half of before/after."""
    now = now or utcnow()
    evs = [e for e in read_events() if e.get("human")]
    if window:
        since = now - timedelta(days=window)
        evs = [e for e in evs if parse_ts(e["ts"]) >= since]
    arms = {}
    for e in evs:
        arms.setdefault(e.get("arm") or "baseline", []).append(e)
    return {"window_days": window, "all": _metrics(evs),
            "arms": {a: _metrics(es) for a, es in sorted(arms.items())}}


# ---- profile ----------------------------------------------------------------------------------

def empty_profile():
    return {"version": 0, "updated": None, "change": None, "deleted": [], "imported": [],
            "distilled": [], "next_id": 1, "rules": []}


def load_profile():
    p = read_json(learn_dir() / "profile.json", None) or {}
    base = empty_profile()
    base.update(p)
    return base


@contextlib.contextmanager
def profile_lock():
    """Held over every read-modify-write of the profile: the page edits it while a distill job
    may be applying ops. Not reentrant -- flock blocks a second open file in the same process."""
    d = learn_dir()
    d.mkdir(parents=True, exist_ok=True)
    with open(d / "profile.lock", "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        yield


def _locked(fn):
    @functools.wraps(fn)
    def run(*args, **kwargs):
        with profile_lock():
            return fn(*args, **kwargs)
    return run


def rule_state(rule, events_by_id, now):
    """(weight, state). Weight: sum of 0.5^(age/60d) over supporting events minus the same over
    contradicting ones. Computed at read time, so decay never waits for a write."""
    def decayed(ids):
        total = 0.0
        for i in set(ids or []):
            e = events_by_id.get(i)
            if e:
                age = max((now - parse_ts(e["ts"])).total_seconds() / 86400, 0)
                total += 0.5 ** (age / HALF_LIFE_DAYS)
        return total
    weight = decayed(rule.get("support")) - decayed(rule.get("contra"))
    if rule.get("pinned"):
        return weight, "active"
    if len(set(rule.get("support") or [])) < ACTIVE_SUPPORTS:
        return weight, "candidate"
    return weight, "active" if weight >= ACTIVE_WEIGHT else "dormant"


def view(profile, events=None, now=None):
    """The profile with weight, state and last_evidence as of now."""
    now = now or utcnow()
    by_id = {e["id"]: e for e in (read_events() if events is None else events)}
    p = copy.deepcopy(profile)
    for r in p["rules"]:
        w, r["state"] = rule_state(r, by_id, now)
        r["weight"] = round(w, 4)
        seen = [by_id[i]["ts"] for i in (r.get("support") or []) + (r.get("contra") or []) if i in by_id]
        r["last_evidence"] = max(seen) if seen else None
    return p


def save_profile(profile, change, now=None):
    """Every write is a new version, kept in history/, so any change can be reverted."""
    now = now or utcnow()
    p = view(profile, now=now)
    p["version"] = profile["version"] + 1
    p["updated"] = fmt_ts(now)
    p["change"] = change
    text = json.dumps(p, indent=2, sort_keys=True) + "\n"
    write_atomic(learn_dir() / "history" / ("profile-v%d.json" % p["version"]), text)
    write_atomic(learn_dir() / "profile.json", text)
    return p


def new_rule(profile, text, target, effect, scope, source, now, pinned=False, support=()):
    r = {"id": "r%d" % profile["next_id"], "text": text, "target": target, "effect": effect,
         "scope": scope or {}, "support": list(support), "contra": [], "pinned": pinned,
         "source": source, "created": fmt_ts(now), "weight": 0.0, "state": "candidate",
         "last_evidence": None}
    profile["next_id"] += 1
    profile["rules"].append(r)
    return r


def _find(profile, rid):
    for r in profile["rules"]:
        if r["id"] == rid:
            return r
    raise KeyError(rid)


def _tombstone(profile, text, now):
    h = text_hash(text)
    if h not in {t["text_hash"] for t in profile["deleted"]}:
        profile["deleted"].append({"text_hash": h, "at": fmt_ts(now)})


@_locked
def update_rule(rid, text=None, pinned=None, target=None, effect=None, scope=None, now=None):
    """An edit on the page. A new text is yours: pinned, source user, and the old wording is
    tombstoned so distill doesn't bring it back. KeyError for an unknown id (the route's 404)."""
    now = now or utcnow()
    p = load_profile()
    r = _find(p, rid)
    if text is not None and text.strip() and text.strip() != r["text"]:
        _tombstone(p, r["text"], now)
        r.update(text=text.strip(), pinned=True, source="user")
    if pinned is not None:
        r["pinned"] = bool(pinned)
    if target is not None:
        if target not in TARGETS:
            raise ValueError("target must be one of %s" % (TARGETS,))
        r["target"] = target
    if effect is not None:
        if effect not in EFFECTS:
            raise ValueError("effect must be one of %s" % (EFFECTS,))
        r["effect"] = effect
    if scope is not None:
        r["scope"] = _scope(scope)
    return _find(save_profile(p, "edit %s" % rid, now), rid)


@_locked
def delete_rule(rid, now=None):
    """Deletion is a tombstone: distill may never re-add a matching text."""
    now = now or utcnow()
    p = load_profile()
    r = _find(p, rid)
    p["rules"].remove(r)
    _tombstone(p, r["text"], now)
    return save_profile(p, "delete %s" % rid, now)


def seed_path():
    """The Markdown file import_seed pins as a writer rule, or None for no seed:
    PR_REVIEW_LEARN_SEED, else posting-style.md beside config.env if one is there."""
    if os.environ.get("PR_REVIEW_LEARN_SEED"):
        return Path(os.environ["PR_REVIEW_LEARN_SEED"])
    conf = Path(os.environ.get("XDG_CONFIG_HOME") or Path(os.environ.get("HOME", HOME)) / ".config")
    p = conf / "review-skills" / "posting-style.md"
    return p if p.is_file() else None


@_locked
def import_seed(path=None, now=None):
    """One-way import of a Claude memory file as a pinned writer rule, once. Keyed by source, so
    an edited or deleted seed is never re-imported. ~/.claude/projects is never written."""
    path = path or seed_path()
    if not path:
        return None
    path = Path(path)
    source = "memory:" + path.stem
    p = load_profile()
    if source in p["imported"] or any(r.get("source") == source for r in p["rules"]):
        return None
    raw = read(path)
    if not raw:
        return None
    text = None
    m = re.match(r"^---\n(.*?)\n---\n(.*)$", raw, re.S)
    front, body = (m.group(1), m.group(2)) if m else ("", raw)
    d = re.search(r'^description:\s*"?(.*?)"?\s*$', front, re.M)
    if d and d.group(1).strip():
        text = d.group(1).strip()
    else:
        paras = [x.strip() for x in body.split("\n\n") if x.strip()]
        text = paras[0] if paras else None
    if not text:
        return None
    now = now or utcnow()
    p["imported"].append(source)
    if text_hash(text) not in {t["text_hash"] for t in p["deleted"]}:
        new_rule(p, text, "writer", "style", {}, source, now, pinned=True)
    return save_profile(p, "import %s" % source, now)


def ensure_seed():
    try:
        import_seed()
    except Exception as exc:  # a read-only store must not stop the writer
        log_error("seed: %r" % exc)


# ---- the LLM --------------------------------------------------------------------------------

def last_event(out):
    """pr-review/last-event.jq: the CLI's json output is a result object or a transcript array."""
    if isinstance(out, list):
        results = [x for x in out if isinstance(x, dict) and x.get("type") == "result"]
        return results[-1] if results else (out[-1] if out else {})
    return out


def claude(prompt, model, effort, timeout):
    """One tool-less claude -p, flags as pr-review.sh's brief: no settings, hooks, CLAUDE.md or
    MCP in a prompt that gains nothing from them."""
    argv = [os.environ.get("PR_REVIEW_LEARN_CLAUDE", "claude"), "-p", prompt,
            "--model", model, "--effort", effort, "--output-format", "json",
            "--strict-mcp-config", "--setting-sources", "",
            "--disallowedTools", "Bash", "Read", "Grep", "Glob", "Write", "Edit", "NotebookEdit",
            "Task", "WebSearch", "WebFetch"]
    p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout,
                       cwd=tempfile.gettempdir(), stdin=subprocess.DEVNULL)
    if p.returncode != 0:
        raise RuntimeError("claude exited %d: %s" % (p.returncode, p.stderr.strip()[-300:]))
    ev = last_event(json.loads(p.stdout))
    if ev.get("is_error") or not isinstance(ev.get("result"), str):
        raise RuntimeError("claude returned no result")
    return ev["result"]


def default_llm(kind):
    model = os.environ.get("PR_REVIEW_LEARN_MODEL", "claude-sonnet-5-5")
    effort = os.environ.get("PR_REVIEW_LEARN_EFFORT", "medium")
    timeout = 180 if kind == "write" else 600
    return lambda prompt: claude(prompt, model, effort, timeout)


def unfence(text):
    m = _FENCE.match(text)
    return m.group(1) if m else text


def parse_ops(text):
    text = unfence(text.strip())
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end < start:
        raise ValueError("no JSON object in the reply")
    ops = json.loads(text[start:end + 1]).get("ops")
    if not isinstance(ops, list):
        raise ValueError("reply has no ops list")
    return ops


# ---- distill ----------------------------------------------------------------------------------

def _scope(scope):
    if not isinstance(scope, dict):
        raise ValueError("scope must be an object")
    return {k: v for k, v in scope.items() if k in ("repo", "author") and isinstance(v, str) and v}


def _event_for_prompt(e):
    kept = read_json(learn_dir() / "bodies" / (e["id"] + ".json"), {}) or {}
    draft, shipped = kept.get("draft"), kept.get("shipped")
    diff = None
    if draft is not None and shipped is not None:
        diff = "".join(difflib.unified_diff(draft.splitlines(True), shipped.splitlines(True),
                                            "draft", "shipped", n=1))[:4000]
    return {"id": e["id"], "repo": e.get("repo"), "author": e.get("author"),
            "proposed": e.get("proposed"), "shipped": e.get("shipped"),
            "edit_ratio": e.get("edit_ratio"), "body_diff": diff,
            "shipped_body": None if diff is not None else (shipped or "")[:2000],
            "dropped": [{"severity": x.get("severity"), "claim": (x.get("claim") or "")[:300]}
                        for x in e.get("dropped") or []]}


def distill(llm=None, now=None):
    """One LLM call maps new human ship events to add/support/contradict ops. Code validates each
    op and does all the counting; an op that cites an unknown, old or unattended event, touches a
    pinned rule, or re-adds a tombstoned text is rejected."""
    now = now or utcnow()
    ensure_seed()
    p = load_profile()
    done = set(p["distilled"])
    new = [e for e in read_events() if e.get("kind") == "ship" and e.get("human") and e["id"] not in done]
    if not new:
        return {"events": 0, "applied": 0, "rejected": 0, "version": p["version"]}
    rules = "\n".join(json.dumps({k: r.get(k) for k in ("id", "text", "target", "effect", "scope", "pinned")})
                      for r in p["rules"]) or "(none yet)"
    prompt = (read(HERE / "distill.prompt") or "").replace("__RULES__", rules).replace(
        "__EVENTS__", "\n".join(json.dumps(_event_for_prompt(e)) for e in new))
    try:
        ops = parse_ops((llm or default_llm("distill"))(prompt))
    except Exception as exc:
        log_error("distill: %r" % exc)
        return {"events": len(new), "error": str(exc), "version": p["version"]}

    # The call took minutes: apply to the profile as it is now, not as it was read, so an edit
    # made on the page meanwhile -- a pin, a delete -- holds.
    with profile_lock():
        p = load_profile()
        done = set(p["distilled"])
        valid = {e["id"] for e in new} - done
        tombs = {t["text_hash"] for t in p["deleted"]}
        applied, rejected = 0, []
        for op in ops:
            why = _apply(p, op, valid, tombs, now)
            if why:
                rejected.append({"op": op, "why": why})
            else:
                applied += 1
        p["distilled"] = sorted(done | valid)
        saved = save_profile(p, "distill: %d applied, %d rejected" % (applied, len(rejected)), now)
    for r in rejected:
        log_error("distill rejected %s: %s" % (r["why"], json.dumps(r["op"])[:300]))
    return {"events": len(new), "applied": applied, "rejected": len(rejected),
            "rejections": rejected, "version": saved["version"]}


def _apply(p, op, valid, tombs, now):
    """None when op was applied, else why it wasn't."""
    if not isinstance(op, dict):
        return "not an object"
    ids = op.get("events")
    if not isinstance(ids, list) or not ids or not all(isinstance(i, str) for i in ids):
        return "no events"
    if not set(ids) <= valid:
        return "cites events not in this batch: %s" % sorted(set(ids) - valid)
    ids = list(dict.fromkeys(ids))
    kind = op.get("op")
    if kind == "add":
        text = op.get("text")
        if not isinstance(text, str) or not text.strip() or len(text) > MAX_RULE_CHARS:
            return "bad text"
        if op.get("target") not in TARGETS or op.get("effect") not in EFFECTS:
            return "bad target or effect"
        try:
            scope = _scope(op.get("scope") or {})
        except ValueError as exc:
            return str(exc)
        h = text_hash(text)
        if h in tombs:
            return "tombstoned"
        same = [r for r in p["rules"] if text_hash(r["text"]) == h]
        if same:
            return _cite(same[0], "support", ids)
        new_rule(p, text.strip(), op["target"], op["effect"], scope, "distill", now, support=ids)
        return None
    if kind in ("support", "contradict"):
        try:
            r = _find(p, op.get("rule"))
        except KeyError:
            return "unknown rule"
        return _cite(r, "support" if kind == "support" else "contra", ids)
    return "unknown op"


def _cite(rule, field, ids):
    if rule.get("pinned"):
        return "pinned"
    other = rule["contra" if field == "support" else "support"]
    rule[field] = list(dict.fromkeys(rule[field] + [i for i in ids if i not in other]))
    return None


# ---- the writer -------------------------------------------------------------------------------

def write_body(template, findings, rules, arm, llm, inline=()):
    """(text, info). Restyle a request-changes body under `rules` (none in the control arm).
    The template -- whatever freeze() wrote from confirmed.jq -- is the fallback whenever the
    output loses a CONFIRMED marker, the reviewed sha or an off-diff finding's detail, or adds an
    untested suggestion block. `inline`: the file:line markers review.json has a comment for;
    every other finding is off the diff."""
    confirmed = [f for f in findings if (f.get("v") or {}).get("verdict") == "CONFIRMED"]
    used = list(rules) if arm == "treatment" else []
    info = {"arm": arm, "rules": len(used), "writer": "template", "fallback": None}
    block = "\n".join("- " + r for r in used) or "(none)"
    listed = "\n".join("- `%s` %s: %s" % (marker(f), f.get("severity"), f.get("title") or f.get("claim"))
                       for f in confirmed) or "(none)"
    prompt = (read(HERE / "write.prompt") or "").replace("__RULES__", block) \
        .replace("__FINDINGS__", quiet(listed)).replace("__BODY__", template)
    try:
        out = unfence(llm(prompt)).strip() + "\n"
    except Exception as exc:
        info["fallback"] = "writer failed: %s" % str(exc)[:200]
        return template, info
    why = _invalid(template, confirmed, out, set(inline))
    if why:
        info["fallback"] = why
        return template, info
    info["writer"] = "llm"
    return quiet(out), info


def _invalid(template, confirmed, out, inline):
    if not out.strip():
        return "empty output"
    if "```suggestion" in out:
        return "an untested suggestion block"
    first = (template.splitlines() or [""])[0]
    sha = _SHA_TICK.search(first)
    if sha and sha.group(1) not in out:
        return "lost the reviewed sha %s" % sha.group(1)
    need = Counter(marker(f) for f in confirmed)
    in_template, in_out = markers(template), markers(out)
    lost = [m for m in need if in_out[m] < min(need[m], max(in_template[m], 1))]
    if lost:
        return "lost CONFIRMED marker(s): %s" % ", ".join(lost)
    # A finding off the diff has no inline comment: its claim and repro, in full in the
    # template, are all its author gets. They stay verbatim; only the wrapping may change.
    flat, flat_out = _flat(template), _flat(out)
    cut = [f.get("id") for f in confirmed if marker(f) not in inline for k in ("claim", "repro")
           if f.get(k) and _flat(quiet(f[k])) in flat and _flat(quiet(f[k])) not in flat_out]
    return "lost off-diff detail: %s" % ", ".join(dict.fromkeys(cut)) if cut else None


def _flat(s):
    return " ".join(str(s).split())


def writer_rules(profile, repo, author):
    out = []
    for r in view(profile)["rules"]:
        scope = r.get("scope") or {}
        if (r["state"] == "active" and r.get("target") == "writer"
                and scope.get("repo", repo) == repo and scope.get("author", author) == author):
            out.append(r)
    return out


def write_body_dir(d, llm=None):
    """freeze()'s writer stage: body.md in place, decision/learn.json. The caller gates it to a
    request-changes with no --body-file; decision/decision is written after this runs, so on a
    --decide it still holds the old call and can't be consulted."""
    d = Path(d)
    dec = d / "decision"
    template = read(dec / "body.md")
    if template is None:
        raise FileNotFoundError("no body.md in %s" % dec)
    key, repo, _, author = pr_info(d)
    arm = arm_for(key)
    ensure_seed()
    profile = load_profile()
    rules = writer_rules(profile, repo, author)
    # No review.json: inline.py failed and the body carries every finding in full.
    inline = [str(c.get("marker", "")).strip("`")
              for c in (read_json(dec / "review.json", {}) or {}).get("comments") or []]
    text, info = write_body(template, read_json(d / "merged.json", []) or [],
                            [r["text"] for r in rules], arm, llm or default_llm("write"), inline)
    if info["writer"] == "llm":
        write_atomic(dec / "body.md", text)
    if info["fallback"]:
        log_error("write-body %s: fell back to the template: %s" % (key, info["fallback"]))
    return _merge_learn(d, {"arm": arm, "profile_version": profile["version"], "writer": info["writer"],
                            "fallback": info["fallback"],
                            "rules": [r["id"] for r in rules] if arm == "treatment" else []})


# ---- CLI --------------------------------------------------------------------------------------

def _parser():
    ap = argparse.ArgumentParser(prog="review_learn.py", description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    rec = sub.add_parser("record").add_subparsers(dest="what", required=True)
    rec.add_parser("prepare").add_argument("dir")
    rec.add_parser("ship").add_argument("dir")
    rr = rec.add_parser("rerun")
    rr.add_argument("--head")
    rr.add_argument("dirs", nargs="+")
    sub.add_parser("write-body").add_argument("dir")
    st = sub.add_parser("stats")
    st.add_argument("--window", type=int, default=30, help="days; 0 for all time")
    sub.add_parser("distill")
    sub.add_parser("seed")
    sub.add_parser("profile")
    return ap


HOOKS = ("record", "write-body")


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] and argv[0] in HOOKS:
        # A hook: never fails peer-review.sh, never writes to its stdout.
        if os.environ.get("PR_REVIEW_LEARN") == "off":
            return 0
        try:
            stdout, sys.stdout = sys.stdout, sys.stderr
            try:
                a = _parser().parse_args(argv)
                if a.cmd == "write-body":
                    write_body_dir(a.dir)
                elif a.what == "prepare":
                    record_prepare(a.dir)
                elif a.what == "ship":
                    record_ship(a.dir)
                else:
                    record_rerun(a.dirs, head=a.head)
            finally:
                sys.stdout = stdout
        except BaseException as exc:  # SystemExit from argparse included
            log_error("%s: %r" % (" ".join(argv), exc))
        return 0
    a = _parser().parse_args(argv)
    if a.cmd == "stats":
        out = stats(window=a.window or None)
    elif a.cmd == "distill":
        out = distill()
    elif a.cmd == "seed":
        out = import_seed() or load_profile()
    else:
        out = view(load_profile())
    print(json.dumps(out, indent=2, sort_keys=True))
    return 1 if isinstance(out, dict) and out.get("error") else 0


if __name__ == "__main__":
    sys.exit(main())
