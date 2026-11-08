#!/usr/bin/env python3
"""Mechanical checks on Antigravity's unstaged output, driven by per-project rules.

    agy-check.py --repo <agy repo dir> --rules <.loop/agy-check.json> <scope folder> [more]

Each unstaged file in scope is compared with its index version (the reviewed state).
Exit 1 when any hard rule fails; the reviewing pass must fix those before staging.

Rules file (all keys optional):
{
  "allowed_outside": ["eslint.config.mjs"],          // files that may change outside the scope
  "extensions": [".ts", ".tsx"],                     // files the content rules apply to
  "keep_count": [{"text": "—", "why": "keep empty-value em dashes"}],          // count must not drop
  "banned_added": [{"pattern": "role=\\"button\\"", "why": "..."}],             // regex; count must not rise
  "banned_anywhere": [{"pattern": "text-\\\\[15px\\\\]", "why": "..."}],        // regex; none may remain
  "banned_in_tags": [{"tags": ["Input"], "attr": "id", "why": "..."}],        // attr on these JSX tags must not rise
  "line_needs_prev": [{"line": "<button", "prev": "eslint-disable-next-line", "why": "..."}],
  "warn_changed": ["fetch\\\\(", "router\\\\.push"]  // changed lines matching these are listed for review
}
"""
import argparse
import json
import os
import re
import subprocess
import sys


def git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=".")
    ap.add_argument("--rules", required=True)
    ap.add_argument("scopes", nargs="+")
    a = ap.parse_args()
    rules = json.load(open(a.rules)) if os.path.exists(a.rules) else {}
    scopes = [s.rstrip("/") for s in a.scopes]
    exts = tuple(rules.get("extensions") or [""])
    allowed = set(rules.get("allowed_outside", []))
    status = git(a.repo, "status", "--porcelain").stdout.splitlines()
    changed = [l[3:].strip().strip('"') for l in status if len(l) > 3 and l[1] in "MA?"]
    hard, warn = [], []
    for path in changed:
        if not any(path == s or path.startswith(s + "/") for s in scopes):
            if path not in allowed:
                hard.append(f"{path}: changed outside the batch scope")
            continue
        if not path.endswith(exts) or not os.path.isfile(os.path.join(a.repo, path)):
            continue
        shown = git(a.repo, "show", f":{path}")
        old = shown.stdout if shown.returncode == 0 else ""
        new = open(os.path.join(a.repo, path), encoding="utf-8", errors="ignore").read()
        for r in rules.get("keep_count", []):
            if new.count(r["text"]) < old.count(r["text"]):
                hard.append(f"{path}: {r['text']!r} {old.count(r['text'])} → {new.count(r['text'])} ({r.get('why', '')})")
        for r in rules.get("banned_added", []):
            o, n = len(re.findall(r["pattern"], old, re.S)), len(re.findall(r["pattern"], new, re.S))
            if n > o:
                hard.append(f"{path}: +{n - o} × /{r['pattern']}/ ({r.get('why', '')})")
        for r in rules.get("banned_anywhere", []):
            n = len(re.findall(r["pattern"], new, re.S))
            if n:
                hard.append(f"{path}: {n} × /{r['pattern']}/ left ({r.get('why', '')})")
        for r in rules.get("banned_in_tags", []):
            tag_re = r"<(?:%s)\b[^>]*?>" % "|".join(r["tags"])
            attr_re = r"\s%s=" % re.escape(r["attr"])
            count = lambda src: sum(1 for t in re.findall(tag_re, src, re.S) if re.search(attr_re, t))
            if count(new) > count(old):
                hard.append(f"{path}: +{count(new) - count(old)} × {r['attr']}= on <{'/'.join(r['tags'])}> ({r.get('why', '')})")
        lines = new.splitlines()
        for r in rules.get("line_needs_prev", []):
            for i, line in enumerate(lines):
                if r["line"] in line and (i == 0 or r["prev"] not in lines[i - 1]):
                    hard.append(f"{path}:{i + 1}: {r['line']!r} without {r['prev']!r} above it ({r.get('why', '')})")
        pats = rules.get("warn_changed", [])
        if pats:
            diff = git(a.repo, "diff", "--", path).stdout.splitlines()
            hits = [l for l in diff if l[:1] in "+-" and not l.startswith(("+++", "---")) and any(re.search(p, l) for p in pats)]
            if hits:
                warn.append(f"{path}: {len(hits)} changed line(s) to check by hand:")
                warn += [f"    {l.strip()[:140]}" for l in hits[:12]]
    print(f"agy-check: {len(changed)} changed file(s), {len(hard)} hard failure(s), {len(warn)} warning(s)")
    for h in hard:
        print(f"FAIL  {h}")
    for w in warn:
        print(f"warn  {w}")
    sys.exit(1 if hard else 0)


if __name__ == "__main__":
    main()
