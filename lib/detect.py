#!/usr/bin/env python3
"""Inspect a project for `relay init`: repos, check commands, likely executor, hazards.

Prints JSON. Never prints secret values: hazards name the file and the variable only.
"""
import json
import os
import re
import shutil
import subprocess
import sys

FRONTEND_DEPS = {"next", "react", "vue", "svelte", "@angular/core", "nuxt", "astro", "solid-js"}
PAYMENT_DEPS = {"stripe", "paystack", "@paystack/inline-js", "flutterwave-node-v3", "braintree", "@adyen/api-library"}
ENV_PATTERNS = [
    (re.compile(r"mongodb(\+srv)?://[^\s]*@(?!localhost|127\.0\.0\.1)"), "a remote MongoDB connection string"),
    (re.compile(r"postgres(ql)?://[^\s]*@(?!localhost|127\.0\.0\.1)"), "a remote Postgres connection string"),
    (re.compile(r"mysql://[^\s]*@(?!localhost|127\.0\.0\.1)"), "a remote MySQL connection string"),
    (re.compile(r"rediss?://(?!localhost|127\.0\.0\.1)"), "a remote Redis URL"),
    (re.compile(r"sk_live_|rk_live_"), "a live payment secret key"),
    (re.compile(r"AKIA[0-9A-Z]{16}"), "an AWS access key"),
]
CRON_PATTERNS = re.compile(r"@Cron\(|@Interval\(|cron\.schedule\(|node-cron|schedule\.every|celery\.beat|beat_schedule|@scheduled")
SKIP_DIRS = {"node_modules", ".git", ".next", "dist", "build", ".venv", "venv", "__pycache__", "coverage", ".turbo", "target"}


def is_git(path):
    return subprocess.run(["git", "-C", path, "rev-parse", "--show-toplevel"], capture_output=True, text=True).returncode == 0 \
        and os.path.realpath(subprocess.run(["git", "-C", path, "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip()) == os.path.realpath(path)


def find_repos(root):
    if is_git(root):
        return ["."]
    return sorted(d for d in os.listdir(root) if not d.startswith(".") and os.path.isdir(os.path.join(root, d)) and is_git(os.path.join(root, d)))


def node_info(path):
    pj = os.path.join(path, "package.json")
    if not os.path.exists(pj):
        return None
    try:
        data = json.load(open(pj))
    except Exception:
        return None
    scripts = data.get("scripts", {})
    deps = set(data.get("dependencies", {})) | set(data.get("devDependencies", {}))
    runner = "pnpm" if os.path.exists(os.path.join(path, "pnpm-lock.yaml")) else "yarn" if os.path.exists(os.path.join(path, "yarn.lock")) else "npm"
    run = (lambda s: f"{runner} run {s}") if runner != "yarn" else (lambda s: f"yarn {s}")
    checks = []
    if "typecheck" in scripts:
        checks.append(run("typecheck"))
    elif os.path.exists(os.path.join(path, "tsconfig.json")):
        checks.append("npx tsc --noEmit")
    if "lint" in scripts:
        checks.append(run("lint"))
    if "test" in scripts and "no test specified" not in scripts["test"]:
        checks.append(run("test"))
    if "build" in scripts and deps & FRONTEND_DEPS:
        checks.append(run("build"))
    deny = []
    for s in ("dev", "start", "start:dev", "start:prod"):
        if s in scripts:
            deny.append(f"Bash({run(s)}:*)")
    if "prisma" in deps or "@prisma/client" in deps:
        deny += ["Bash(npx prisma migrate:*)", "Bash(npx prisma db:*)"]
    return {"checks": checks, "frontend": bool(deps & FRONTEND_DEPS), "payments": sorted(deps & PAYMENT_DEPS), "deny": deny}


def other_info(path):
    if os.path.exists(os.path.join(path, "go.mod")):
        return {"checks": ["go build ./...", "go test ./..."], "frontend": False, "payments": [], "deny": []}
    if os.path.exists(os.path.join(path, "Cargo.toml")):
        return {"checks": ["cargo check", "cargo test"], "frontend": False, "payments": [], "deny": []}
    if os.path.exists(os.path.join(path, "pyproject.toml")) or os.path.exists(os.path.join(path, "requirements.txt")):
        return {"checks": ["python -m pytest -q"], "frontend": False, "payments": [], "deny": []}
    return {"checks": [], "frontend": False, "payments": [], "deny": []}


def env_hazards(path, label):
    out = []
    for f in sorted(os.listdir(path)):
        if not f.startswith(".env") or f.endswith((".example", ".sample", ".template")) or not os.path.isfile(os.path.join(path, f)):
            continue
        try:
            lines = open(os.path.join(path, f), errors="ignore").read().splitlines()
        except Exception:
            continue
        for line in lines:
            if "=" not in line or line.lstrip().startswith("#"):
                continue
            key, val = line.split("=", 1)
            for pat, what in ENV_PATTERNS:
                if pat.search(val):
                    out.append(f"{label}/{f}: {key.strip()} is {what}. Anything that boots this app or runs its scripts touches it.")
    return out


def cron_hazards(path, label):
    hits = 0
    files = []
    for dirpath, dirnames, filenames in os.walk(path):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            if not fn.endswith((".ts", ".js", ".py", ".go", ".rb")) or ".spec." in fn or ".test." in fn:
                continue
            try:
                text = open(os.path.join(dirpath, fn), errors="ignore").read()
            except Exception:
                continue
            n = len(CRON_PATTERNS.findall(text))
            if n:
                hits += n
                files.append(os.path.relpath(os.path.join(dirpath, fn), path))
    if not hits:
        return []
    return [f"{label}: {hits} scheduled job(s) in {len(files)} file(s) (e.g. {', '.join(files[:3])}). A local boot runs them next to production."]


def main():
    root = os.path.abspath(sys.argv[1])
    repos = []
    hazards = []
    deny = set()
    have_agy = shutil.which("agy") is not None
    frontends = 0
    for rel in find_repos(root):
        path = os.path.join(root, rel)
        label = os.path.basename(root) if rel == "." else rel
        info = node_info(path) or other_info(path)
        if info["frontend"]:
            frontends += 1
        repos.append({"name": label, "path": rel, "checks": " && ".join(info["checks"]) or "true", "frontend": info["frontend"]})
        hazards += env_hazards(path, label) + cron_hazards(path, label)
        if info["payments"]:
            hazards.append(f"{label}: payment libraries ({', '.join(info['payments'])}). Never trigger real charges, refunds or payouts.")
        deny.update(info["deny"])
    # Antigravity takes the UI repo only when there is exactly one and agy is installed.
    for r in repos:
        r["executor"] = "agy" if have_agy and r["frontend"] and frontends == 1 else "claude"
    if any(h for h in hazards if "connection string" in h or "Redis" in h):
        deny.update(["Bash(mongosh:*)", "Bash(psql:*)", "Bash(mysql:*)", "Bash(redis-cli:*)"])
    print(json.dumps({"repos": repos, "hazards": hazards, "deny": sorted(deny), "agy": have_agy}))


if __name__ == "__main__":
    main()
