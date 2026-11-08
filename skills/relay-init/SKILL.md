---
name: relay-init
description: Set up a relay-loop (unattended Claude Code + Antigravity work loop) in the current project. Runs `relay init`, reviews the detected repos, checks and hazards with the user, and writes the first backlog items. Use when the user says "set up the loop here", "relay init", or wants unattended passes on a project.
---

# Set up relay-loop in this project

1. Run `relay init .` and show the user the detected REPOS and HAZARDS.
2. Go through `.loop/config.sh` with the user, one decision at a time:
   - **Repos and executors.** `claude` = Claude passes write the code. `agy` = Antigravity writes the UI and Claude reviews it (at most one repo). Ask which repo, if any, Antigravity should own.
   - **Checks.** Make each repo's check command one the user trusts as "this is safe to commit" (typecheck, lint, tests, build). Run it once now and show the result; a check that already fails will block every pass.
   - **Hazards.** Detection only finds remote connection strings, scheduled jobs and payment libraries. Ask about the rest: production data, money movement, emails or notifications to real people, anything customer-facing. Write each as one line saying what must never happen. Then set `HAZARDS_REVIEWED=yes`. Never set it yourself without the user reading the list.
   - **Mode.** `branch` (default) commits reviewed work to a `loop/<date>` branch in a worktree. `stage` leaves it staged in the user's checkout. If the user already has uncommitted work, explain that branch mode starts from HEAD and won't see it.
3. Write `.loop/BACKLOG.md` items with the user: one pass-sized item each, tagged with its repo, each with a concrete "done" (files, checks, output). Order them; the loop takes the first open one.
4. Put project conventions reviewers must enforce in `.loop/project.md` (short).
5. Tell the user how to start (`relay start`, or `relay start --agy <prompt>.md` to begin with an Antigravity run), watch (`relay logs`), stop (`relay stop`) and collect the work (`relay finish`).
