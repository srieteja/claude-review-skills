#!/usr/bin/env python3
"""Turn a merged.json review into a GitHub pull-request review payload.

GitHub rejects the whole `comments` array with a 422 if a single entry names a line
that is not on the right-hand side of a diff hunk. So every finding is bucketed here,
before anything is posted:

  inline   line falls inside a hunk    -> a comment anchored exactly there
  nearest  file is in the diff, line is within CLAMP_LIMIT of a hunk
                                       -> anchored to the closest in-hunk line, with
                                          the true location stated in the body
  body     file is not in the diff, the nearest hunk is further than CLAMP_LIMIT,
           or the claim was never checked (ERROR)
                                       -> the review's top-level body, never inline

An anchor far from the defect points the reader at unrelated code even when the body
says so, which is why the clamp has a limit rather than always taking the nearest line.

usage: inline.py --merged merged.json --meta meta.json --repo owner/name [--out payload.json]
"""
import argparse, json, re, subprocess, sys

HUNK = re.compile(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@')
ICON = {"high": "🔴", "medium": "🟠", "low": "🟡"}
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


def body_for(f, kind, true_line):
    v = f["v"]
    head = f'**{ICON.get(f["severity"], "⚪")} {f["severity"]} · {f["id"]} — {f["claim"]}**'
    parts = [head, ""]
    if kind == "nearest":
        parts += [f'> Anchored here because it is the nearest line in the diff. '
                  f'The defect is at `{f["file"]}:{true_line}`.', ""]
    parts += [f'**Mechanism.** {f["mechanism"]}', "",
              f'**Repro.** {f["repro"]}', "",
              f'**Independent check ({v["verdict"]}).** {v["reason"]}']
    if v.get("correction"):
        parts += ["", f'**Correction.** {v["correction"]}']
    if v.get("evidence"):
        parts += ["", "<details><summary>evidence</summary>", "",
                  "```", v["evidence"].rstrip(), "```", "", "</details>"]
    return "\n".join(parts)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--merged", required=True)
    ap.add_argument("--meta", required=True)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--out")
    a = ap.parse_args()

    findings = json.load(open(a.merged))
    meta = json.load(open(a.meta))
    pr, sha = meta["number"], meta["headRefOid"]
    spans = right_side_ranges(a.repo, pr)

    comments, deferred, dropped = [], [], []
    for f in findings:
        verdict = f["v"]["verdict"]
        if verdict == "REFUTED":
            dropped.append(f)
            continue
        # An ERROR verdict is an unchecked claim. It never goes inline on someone
        # else's PR; it is named in the body so the gap stays visible.
        if verdict == "ERROR" or f["file"] not in spans:
            deferred.append((f, "unchecked" if verdict == "ERROR" else "off-diff"))
            continue
        line, exact = anchor(spans[f["file"]], f["line"])
        if line is None:
            deferred.append((f, "off-diff"))
            continue
        comments.append({"path": f["file"], "line": line, "side": "RIGHT",
                         "body": body_for(f, "inline" if exact else "nearest", f["line"])})

    n_conf = sum(1 for f in findings if f["v"]["verdict"] == "CONFIRMED")
    body = [f'## Adversarial review of `{sha[:8]}`', "",
            f'{len(findings)} finding(s) raised; {n_conf} survived independent refutation. '
            f'{len(comments)} anchored inline below.', ""]
    if deferred:
        body += ["Not anchorable to a diff line:", ""]
        for f, why in deferred:
            note = "**never checked — no verdict was produced**" if why == "unchecked" \
                   else f'`{f["file"]}:{f["line"]}` is not on a line this PR changed'
            body += [f'- **{f["id"]}** ({f["severity"]}, {f["v"]["verdict"]}) — {f["claim"]} — {note}']
        body += [""]
    if dropped:
        body += [f'<sub>{len(dropped)} further finding(s) were refuted against the source '
                 f'at this commit and are not reported.</sub>']

    payload = {"commit_id": sha, "event": "COMMENT",
               "body": "\n".join(body).rstrip(), "comments": comments}
    text = json.dumps(payload, indent=2)
    if a.out:
        open(a.out, "w").write(text + "\n")
        print(f"{len(comments)} inline · {len(deferred)} in body · {len(dropped)} refuted -> {a.out}",
              file=sys.stderr)
    else:
        print(text)


if __name__ == "__main__":
    main()
