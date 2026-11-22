#!/usr/bin/env python3
"""SOUL.md doctrine loader, section printer and atomic proposal applier.

Stdlib only, Python 3.8+. The doctrine is the human-readable contract: this module
reads it, never rewrites prose it did not target, and refuses the immutable core.

    python3 lib/soul.py parse <file> [--json]
    python3 lib/soul.py sections <file> --only "Evidence standard,Severity,Checks"
    python3 lib/soul.py apply --proposal <json> --soul <file> --state-dir <dir>
"""
import argparse
import datetime as _dt
import fcntl
import json
import os
import re
import sys
import tempfile

MAX_BYTES = 64 * 1024
MAX_CHANGES = 5
REQUIRED_SECTIONS = (
    "Purpose",
    "Evidence standard",
    "Severity",
    "Checks",
    "Delivery",
    "Review shape",
    "Response protocol",
    "Closure",
    "Learning",
)
# Purpose and Evidence standard are the immutable core even if an edited header loses
# its suffix: the doctrine must not be able to erase its own evidence bar.
CORE_SECTIONS = frozenset(("purpose", "evidence standard"))
RULE_ID_RE = re.compile(r"^S-[A-Z][0-9]+$")
RULE_RE = re.compile(r"^- \*\*(S-[A-Z][0-9]+)\*\*(.*)$")
NOTE_SPLIT_RE = re.compile(r"\s+—\s+(?=(?:evidence:|owner ruling\b))")
DATE_RE = re.compile(r"\b(\d{4}-\d{2}-\d{2})\b")
EVIDENCE_RE = re.compile(r"evidence:\s*(\d+)")
GATE_RE = re.compile(r"\b(?:SE|SEC)-\d+", re.IGNORECASE)
# A doctrine rule is about review behaviour, not about the machinery that runs it.
# Only unambiguous tool and proper names are refused. Ordinary command words a rule may
# legitimately use -- timeout, node, sed, bash, awk, python, shell, curl -- are vocabulary,
# so matching them only refused honest rules.
TOOL_RE = re.compile(
    r"\b(?:agy|claude|gemini|glm|deepseek|ollama|pr[_-]gate|github|gh|jq|"
    r"shellcheck|mcp)\b"
    r"|\b(?:claude|gemini|glm|deepseek)-",
    re.IGNORECASE,
)
CHANGELOG_ENTRY_RE = re.compile(r"^- \*\*\d{4}-\d{2}-\d{2} · ")


class SoulError(Exception):
    """A refused read or proposal."""


def _norm(name):
    return " ".join(name.split()).casefold()


def _split_header(line):
    """Return (name, immutable) from a '## ...' line; suffixes are display text."""
    parts = [p.strip() for p in line[3:].split(" — ")]
    name = parts[0]
    immutable = any(p.casefold() == "immutable core" for p in parts[1:])
    return name, immutable


class Rule:
    __slots__ = ("id", "text", "evidence_count", "updated", "section", "start", "end")

    def __init__(self, rid, text, evidence_count, updated, section, start, end):
        self.id = rid
        self.text = text
        self.evidence_count = evidence_count
        self.updated = updated
        self.section = section
        self.start = start  # 0-based line index of the rule's first line
        self.end = end      # exclusive

    def as_dict(self):
        return {
            "id": self.id,
            "text": self.text,
            "evidence_count": self.evidence_count,
            "updated": self.updated,
            "section": self.section,
        }


class Section:
    __slots__ = ("name", "immutable", "body", "rules", "header", "body_start", "body_end")

    def __init__(self, name, immutable, body, rules, header, body_start, body_end):
        self.name = name
        self.immutable = immutable
        self.body = body
        self.rules = rules
        self.header = header          # 0-based line index of '## name'
        self.body_start = body_start  # first non-blank body line
        self.body_end = body_end      # one past the last non-blank body line

    def as_dict(self):
        return {
            "name": self.name,
            "immutable": self.immutable,
            "body": self.body,
            "rules": [r.as_dict() for r in self.rules],
        }


class Document:
    __slots__ = ("text", "lines", "sections", "rules", "by_norm")

    def __init__(self, text, lines, sections):
        self.text = text
        self.lines = lines
        self.sections = sections
        self.rules = [r for section in sections for r in section.rules]
        self.by_norm = {}
        for section in sections:
            self.by_norm.setdefault(_norm(section.name), section)


def _parse_rules(lines, start, end, section_name):
    """Rules start with '- **S-XX**' and continue on indented lines."""
    rules = []
    i = start
    while i < end:
        m = RULE_RE.match(lines[i])
        if not m:
            i += 1
            continue
        j = i + 1
        while (j < end and lines[j].strip()
               and lines[j][:1] in (" ", "\t")
               and not RULE_RE.match(lines[j])
               and not lines[j].startswith("## ")):
            j += 1
        chunk = " ".join(line.strip() for line in lines[i:j])
        m = RULE_RE.match(chunk)
        rid = m.group(1)
        rest = m.group(2)
        pieces = NOTE_SPLIT_RE.split(rest, maxsplit=1)
        text = " ".join(pieces[0].split())
        note = pieces[1] if len(pieces) > 1 else ""
        ev = EVIDENCE_RE.search(note)
        evidence_count = int(ev.group(1)) if ev else None
        dates = DATE_RE.findall(note)
        updated = dates[-1] if dates else None
        rules.append(Rule(rid, text, evidence_count, updated, section_name, i, j))
        i = j
    return rules


def parse_text(text, source="<text>"):
    """Parse SOUL.md text into sections and rules, refusing an over-size file."""
    if len(text.encode("utf-8")) > MAX_BYTES:
        raise SoulError("%s is over the 64 KiB (65536-byte) limit" % source)
    lines = text.split("\n")
    headers = []
    for i, line in enumerate(lines):
        if line.startswith("## "):
            name, immutable = _split_header(line)
            if not name:
                raise SoulError("empty section header at line %d of %s" % (i + 1, source))
            headers.append((i, name, immutable))

    sections = []
    for pos, (i, name, immutable) in enumerate(headers):
        end = headers[pos + 1][0] if pos + 1 < len(headers) else len(lines)
        body_start, body_end = i + 1, end
        while body_start < body_end and not lines[body_start].strip():
            body_start += 1
        while body_end > body_start and not lines[body_end - 1].strip():
            body_end -= 1
        body = "\n".join(lines[body_start:body_end])
        is_core = immutable or _norm(name) in CORE_SECTIONS
        sections.append(Section(name, is_core, body,
                                _parse_rules(lines, i + 1, end, name),
                                i, body_start, body_end))

    present = {_norm(s.name) for s in sections}
    for required in REQUIRED_SECTIONS:
        if _norm(required) not in present:
            raise SoulError("missing required section: %s" % required)
    return Document(text, lines, sections)


def parse(path):
    """Read and parse a SOUL.md file."""
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError as exc:
        raise SoulError("cannot read %s: %s" % (path, exc.strerror or exc))
    if len(raw) > MAX_BYTES:
        raise SoulError("%s is %d bytes, over the 64 KiB (65536-byte) limit"
                        % (path, len(raw)))
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise SoulError("%s is not UTF-8: %s" % (path, exc))
    return parse_text(text, path)


parse_file = parse


def _doc_json(doc, path):
    return {
        "file": path,
        "sections": [s.as_dict() for s in doc.sections],
        "rules": [r.as_dict() for r in doc.rules],
    }


# ------------------------------------------------------------------ proposal input
def _load_proposal(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except OSError as exc:
        raise SoulError("cannot read proposal %s: %s" % (path, exc.strerror or exc))
    except ValueError as exc:
        raise SoulError("proposal is not valid JSON: %s" % exc)
    if not isinstance(data, dict):
        raise SoulError("proposal must be a JSON object")
    return data


def _nonempty(value, field):
    if not isinstance(value, str) or not value.strip():
        raise SoulError("proposal %s must be a non-empty string" % field)
    return value.strip()


def _integer(value, field):
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise SoulError("proposal %s must be an integer" % field)
    return value


def _guard_rule_text(text):
    gate = GATE_RE.search(text)
    if gate:
        raise SoulError("proposed rule text names a gate id: %s" % gate.group(0))
    if re.search(r"pr[_-]gate", text, re.IGNORECASE):
        raise SoulError("proposed rule text names pr_gate")
    tool = TOOL_RE.search(text)
    if tool:
        raise SoulError("proposed rule text names a tool: %s" % tool.group(0))


def _journal_has(path, proposal_id):
    """True if the id was already applied. Accept both a bare id line and a JSON record."""
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                if line == proposal_id:
                    return True
                try:
                    record = json.loads(line)
                except ValueError:
                    continue
                if isinstance(record, dict) and record.get("id") == proposal_id:
                    return True
                if record == proposal_id:
                    return True
    except OSError:
        return False
    return False


def _changelog_has(doc, proposal_id):
    """True when the Changelog already has the exact entry '- **<date> · <id>**'."""
    section = doc.by_norm.get("changelog")
    if section is None:
        return False
    for line in section.body.split("\n"):
        match = CHANGELOG_ENTRY_RE.match(line)
        if match and line[match.end():].startswith(proposal_id + "**"):
            return True
    return False


def _append_journal(path, record):
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(record, sort_keys=True) + "\n")
        f.flush()
        os.fsync(f.fileno())


def _section_for(doc, name):
    section = doc.by_norm.get(_norm(name))
    if section is None:
        raise SoulError("unknown section: %s" % name)
    return section


def _atomic_write(path, data):
    directory = os.path.dirname(os.path.abspath(path)) or "."
    fd, tmp = tempfile.mkstemp(prefix=".soul-", dir=directory)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        try:
            os.chmod(tmp, os.stat(path).st_mode & 0o7777)
        except OSError:
            pass
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _append_changelog(lines, date, proposal_id, what, reasoning, evidence_count):
    entry = [
        "- **%s · %s** — %s" % (date, proposal_id, " ".join(what.split())),
        "  reasoning: %s" % " ".join(reasoning.split()),
        "  evidence: %d observations · %s" % (evidence_count, date),
    ]
    doc = parse_text("\n".join(lines), "<soul>")
    section = doc.by_norm.get("changelog")
    if section is None:
        while lines and not lines[-1].strip():
            lines.pop()
        if lines:
            lines.append("")
        lines.extend(["## Changelog", ""] + entry + [""])
        return lines
    lines[section.body_end:section.body_end] = entry
    return lines


def _replace_rule(lines, section_name, rule_id, text, evidence_count, date):
    """Replace one rule's line(s) or append a new rule, preserving every other line."""
    doc = parse_text("\n".join(lines), "<soul>")
    section = _section_for(doc, section_name)
    rule = next((r for r in doc.rules if r.id == rule_id), None)
    new_line = "- **%s** %s — evidence: %d · %s" % (rule_id, text, evidence_count, date)
    if rule is not None:
        if _norm(rule.section) != _norm(section.name):
            raise SoulError("rule %s is not in section %s" % (rule_id, section.name))
        lines[rule.start:rule.end] = [new_line]
    else:
        lines.insert(section.body_end, new_line)
    return lines


def _apply_locked(proposal, proposal_id, soul_path, soul_state, history_dir, journal):
    section_name = _nonempty(proposal.get("section"), "section")
    what = _nonempty(proposal.get("what"), "what")
    reasoning = _nonempty(proposal.get("reasoning"), "reasoning")
    evidence_count = _integer(proposal.get("evidence_count"), "evidence_count")

    changes = proposal.get("changes")
    if not isinstance(changes, list):
        raise SoulError("proposal changes must be a list")
    if len(changes) > MAX_CHANGES:
        raise SoulError("proposal has %d changes; the limit is %d"
                        % (len(changes), MAX_CHANGES))

    # A proposal edits a doctrine section, never the changelog or an invented one.
    if _norm(section_name) not in {_norm(name) for name in REQUIRED_SECTIONS}:
        raise SoulError("unknown section: %s" % section_name)

    prepared = []
    for index, change in enumerate(changes, 1):
        if not isinstance(change, dict):
            raise SoulError("change %d must be an object" % index)
        rule_id = change.get("rule_id")
        if not isinstance(rule_id, str) or not RULE_ID_RE.match(rule_id):
            raise SoulError("change %d rule_id must look like S-<SECTION><n>" % index)
        text = _nonempty(change.get("text"), "change %d text" % index)
        text = " ".join(text.split())
        if "evidence_count" in change:
            count = _integer(change["evidence_count"], "change %d evidence_count" % index)
        else:
            count = evidence_count
        _guard_rule_text(text)
        prepared.append((rule_id, text, count))

    try:
        with open(soul_path, "rb") as f:
            raw = f.read()
    except OSError as exc:
        raise SoulError("cannot read %s: %s" % (soul_path, exc.strerror or exc))
    if len(raw) > MAX_BYTES:
        raise SoulError("%s is %d bytes, over the 64 KiB (65536-byte) limit"
                        % (soul_path, len(raw)))
    try:
        original = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise SoulError("%s is not UTF-8: %s" % (soul_path, exc))

    doc = parse_text(original, soul_path)
    section = _section_for(doc, section_name)
    # A crash between the rename and the journal leaves the changelog entry without the
    # applied id. Heal that window: the soul already carries the change, so record it and
    # report the replay rather than appending a second entry.
    if _changelog_has(doc, proposal_id):
        now = _dt.datetime.now(_dt.timezone.utc)
        _append_journal(journal, {
            "id": proposal_id,
            "at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "section": section.name,
            "snapshot": None,
            "healed": True,
        })
        return "already applied"
    if section.immutable:
        raise SoulError("section %s is immutable core; refusing to edit it" % section.name)

    too_big = ("refusing to write %s: the edit exceeds the 64 KiB "
               "(65536-byte) limit" % soul_path)
    now = _dt.datetime.now(_dt.timezone.utc)
    date = now.date().isoformat()
    lines = list(doc.lines)
    for rule_id, text, count in prepared:
        lines = _replace_rule(lines, section.name, rule_id, text, count, date)
        if len("\n".join(lines).encode("utf-8")) > MAX_BYTES:
            raise SoulError(too_big)
    lines = _append_changelog(lines, date, proposal_id, what, reasoning, evidence_count)
    updated = "\n".join(lines)
    encoded = updated.encode("utf-8")
    if len(encoded) > MAX_BYTES:
        raise SoulError(too_big)

    stamp = now.strftime("%Y%m%dT%H%M%SZ")
    safe_id = re.sub(r"[^A-Za-z0-9._-]", "_", proposal_id)
    snapshot_name = "%s-%s.md" % (stamp, safe_id)
    snapshot_path = os.path.join(history_dir, snapshot_name)
    with open(snapshot_path, "wb") as f:
        f.write(raw)
        f.flush()
        os.fsync(f.fileno())

    _atomic_write(soul_path, encoded)

    _append_journal(journal, {
        "id": proposal_id,
        "at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "section": section.name,
        "snapshot": snapshot_name,
    })
    return "applied"


def apply(proposal_path, soul_path, state_dir):
    """Apply a proposal atomically. A replayed id is a no-op."""
    proposal = _load_proposal(proposal_path)
    proposal_id = _nonempty(proposal.get("id"), "id")

    os.makedirs(state_dir, exist_ok=True)
    soul_state = os.path.join(state_dir, "soul")
    history_dir = os.path.join(soul_state, "history")
    os.makedirs(history_dir, exist_ok=True)
    journal = os.path.join(soul_state, "applied.jsonl")
    lock_path = os.path.join(state_dir, "soul.lock")

    # The lock is held across the replay check, the snapshot, the rename and the journal,
    # so two appliers cannot interleave and a replayed id sees the first apply's journal.
    with open(lock_path, "a+") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        try:
            if _journal_has(journal, proposal_id):
                return "already applied"
            return _apply_locked(proposal, proposal_id, soul_path,
                                 soul_state, history_dir, journal)
        finally:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)


# --------------------------------------------------------------------------- CLI
def _print_doc(doc):
    for section in doc.sections:
        suffix = " (immutable core)" if section.immutable else ""
        print("## %s%s" % (section.name, suffix))
        for rule in section.rules:
            notes = []
            if rule.evidence_count is not None:
                notes.append("evidence: %d" % rule.evidence_count)
            if rule.updated is not None:
                notes.append("updated: %s" % rule.updated)
            tail = " [%s]" % ", ".join(notes) if notes else ""
            print("  %s %s%s" % (rule.id, rule.text, tail))
        if not section.rules and section.body.strip():
            for line in section.body.split("\n"):
                print("  " + line)


def main(argv=None):
    parser = argparse.ArgumentParser(prog="soul.py", description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)

    p_parse = sub.add_parser("parse", help="print sections and rules")
    p_parse.add_argument("file")
    p_parse.add_argument("--json", action="store_true")

    p_sections = sub.add_parser("sections", help="print selected section bodies")
    p_sections.add_argument("file")
    p_sections.add_argument("--only", required=True,
                            help="comma-separated section names, in output order")

    p_apply = sub.add_parser("apply", help="apply a proposal atomically")
    p_apply.add_argument("--proposal", required=True)
    p_apply.add_argument("--soul", required=True)
    p_apply.add_argument("--state-dir", required=True)

    args = parser.parse_args(argv)
    try:
        if args.command == "parse":
            doc = parse(args.file)
            if args.json:
                json.dump(_doc_json(doc, args.file), sys.stdout, indent=2,
                          ensure_ascii=False)
                sys.stdout.write("\n")
            else:
                _print_doc(doc)
        elif args.command == "sections":
            doc = parse(args.file)
            blocks = []
            for name in (n.strip() for n in args.only.split(",")):
                if not name:
                    continue
                section = doc.by_norm.get(_norm(name))
                if section is None:
                    raise SoulError("missing section: %s" % name)
                block = "## %s" % section.name
                if section.body:
                    block += "\n" + section.body
                blocks.append(block)
            sys.stdout.write("\n\n".join(blocks) + "\n")
        else:
            print(apply(args.proposal, args.soul, args.state_dir))
    except SoulError as exc:
        sys.stderr.write("soul: %s\n" % exc)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
