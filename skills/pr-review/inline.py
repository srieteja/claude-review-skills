#!/usr/bin/env python3
"""Turn a merged.json review into a GitHub pull-request review payload.

GitHub rejects the whole `comments` array with a 422 if a single entry names a line
that is not on the right-hand side of a diff hunk. So every finding is bucketed here,
before anything is posted:

  inline   line falls inside a hunk    -> a comment anchored exactly there
  nearest  file is in the diff, line is within CLAMP_LIMIT of a hunk
                                       -> anchored to the closest in-hunk line, with
                                          the true location stated in the comment
  body     file is not in the diff, the nearest hunk is further than CLAMP_LIMIT,
           or the claim was never checked (ERROR)
                                       -> in full in the review's top-level body

An anchor far from the defect points the reader at unrelated code even when the body
says so, which is why the clamp has a limit rather than always taking the nearest line.

The text is confirmed.jq's: its groups (one defect two finders reported is one comment)
and its review_body, so the body here and a hand-built one never drift. A comment is the
claim and the repro, quieted; the mechanism and evidence stay in the local report.

Each comment carries "marker", its finding's `file:line` as the body names it. It is not a
GitHub field: whoever posts deletes it, and peer-review's ship first drops each comment
whose marker the (edited) body no longer holds.

An event other than COMMENT posts only CONFIRMED findings: a change request or an approval
never carries a claim no one could verify.

usage: inline.py --merged merged.json --meta meta.json [--repo owner/name]
                 [--event COMMENT|REQUEST_CHANGES] [--out payload.json]
       --repo defaults to the one in meta.json's url.
"""
import argparse, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
HUNK = re.compile(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@')
CLAMP_LIMIT = 20   # lines; beyond this a "nearest" anchor is noise, not a hint


def right_side_ranges(repo, pr):
    """{path: [(first, last), ...]} of lines addressable on the RIGHT side."""
    # --slurp wraps the pages in one array. Without it, --paginate concatenates raw
    # arrays and the caller has to split them by regex -- which a diff containing
    # "] [" silently truncates.
    raw = subprocess.run(
        ["gh", "api", f"repos/{repo}/pulls/{pr}/files", "--paginate", "--slurp"],
        capture_output=True, text=True, check=True).stdout
    files = [f for page in json.loads(raw) for f in page]
    out = {}
    for f in files:
        spans = []
        for line in (f.get("patch") or "").splitlines():
            m = HUNK.match(line)
            if m:
                start, count = int(m.group(1)), int(m.group(2) or 1)
                if count:
                    spans.append((start, start + count - 1))
        out[f["filename"]] = spans
    return out


def anchor(spans, line):
    """Exact hit, else the nearest addressable line within CLAMP_LIMIT, else None."""
    for lo, hi in spans:
        if lo <= line <= hi:
            return line, True
    if not spans:
        return None, False
    cands = [lo for lo, _ in spans] + [hi for _, hi in spans]
    best = min(cands, key=lambda c: abs(c - line))
    return (best, False) if abs(best - line) <= CLAMP_LIMIT else (None, False)


def jq(findings, program, *args):
    """Run a confirmed.jq program over findings; its raw output."""
    return subprocess.run(["jq", "-L", HERE, "-r", *args, f'include "confirmed"; {program}'],
                          input=json.dumps(findings), capture_output=True, text=True,
                          check=True).stdout


def comment_bodies(groups):
    """One comment body per group, rendered by confirmed.jq's helpers."""
    return json.loads(jq(groups, 'map(.[0] as $p | "**\\($p | icon) \\($p | sev)'
                                 '\\(unconfirmed) — \\($p.claim | quiet)**"'
                                 ' + (if ($p.repro // "") != "" then "\\n\\n\\($p.repro | quiet)" else "" end)'
                                 ' + (also_at | if length > 0 then "\\n\\nAlso reported at \\(join(", "))." else "" end))',
                         "-c"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--merged", required=True)
    ap.add_argument("--meta", required=True)
    ap.add_argument("--repo")
    ap.add_argument("--event", default="COMMENT", choices=["COMMENT", "REQUEST_CHANGES"])
    ap.add_argument("--out")
    a = ap.parse_args()

    findings = json.load(open(a.merged))
    meta = json.load(open(a.meta))
    pr, sha = meta["number"], meta["headRefOid"]
    repo = a.repo or re.search(r"github\.com/([^/]+/[^/]+)/pull/", meta["url"]).group(1)
    if a.event != "COMMENT":
        findings = [f for f in findings if f["v"]["verdict"] == "CONFIRMED"]
    spans = right_side_ranges(repo, pr)

    groups = json.loads(jq(findings, "groups", "-c"))
    bodies = comment_bodies(groups)
    comments, full = [], []
    for g, body in zip(groups, bodies):
        f = g[0]
        # An ERROR verdict is an unchecked claim. It never goes inline on someone
        # else's PR; it goes in the body so the gap stays visible.
        line = None
        if f["v"]["verdict"] != "ERROR" and f["file"] in spans:
            line, exact = anchor(spans[f["file"]], f["line"])
        if line is None:
            full.append(f["id"])
            continue
        marker = f'`{f["file"]}:{f["line"]}`'
        if not exact:
            body += (f'\n\n> Anchored here because it is the nearest line in the diff. '
                     f'The defect is at {marker}.')
        comments.append({"path": f["file"], "line": line, "side": "RIGHT",
                         "body": body, "marker": marker})

    text = jq(findings, "review_body($sha; $event; $full)", "--arg", "sha", sha,
              "--arg", "event", a.event, "--argjson", "full", json.dumps(full))
    payload = {"commit_id": sha, "event": a.event, "body": text.rstrip(), "comments": comments}
    out = json.dumps(payload, indent=2, ensure_ascii=False)
    if a.out:
        open(a.out, "w").write(out + "\n")
        print(f"{len(comments)} inline · {len(full)} in body -> {a.out}", file=sys.stderr)
    else:
        print(out)


if __name__ == "__main__":
    main()
