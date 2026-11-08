# relay-loop

Run unattended work loops on your projects with [Claude Code](https://docs.claude.com/en/docs/claude-code) and, optionally, the Antigravity CLI (`agy`).

Each **pass** is a fresh `claude -p` with a clean context. It reads a backlog file, does exactly one item, runs your checks, stages what passes, updates the backlog and returns a structured verdict. The next pass picks up from the backlog, not from the previous pass's memory. When a pass needs UI work, it writes a prompt for Antigravity and the runner launches it. The next Claude pass reviews what Antigravity produced.

```
 BACKLOG.md ──► claude pass ──► verdict ─┬─ CONTINUE ─► next pass
     ▲         (one item, checks,        ├─ AGY ──────► agy run ─► next pass reviews it
     └──────── stages reviewed work)     └─ BLOCKED / DONE ─► stop
                     │
            runner commits staged work to loop/<date> (branch mode)
```

## Why it's built this way

These rules come from running loops like this one on a real two-repo product (NestJS API plus Next.js web) over many passes:

- **Fresh context per pass, state in a file.** Long sessions drift. A backlog that each pass must update is reviewable, resumable and cheap.
- **Agents never commit. The runner does.** `git add` means "reviewed and checks pass". In branch mode the runner commits that staged work on a `loop/` branch in a separate worktree. Your checkout and your branches stay untouched until you merge. The loop stops if an agent moves a HEAD.
- **One writer per repo.** Each repo has an `executor`. `claude` means Claude passes write the code. `agy` means Antigravity writes the UI, and Claude writes its prompts, reviews the output and makes small fixes.
- **Hazards are declared, not guessed.** `relay init` detects some hazards: remote database URLs in `.env` files (it never prints their values), scheduled jobs and payment libraries. You add the ones it can't know about. The loop won't start until you set `HAZARDS_REVIEWED=yes`. Every pass reads the list.
- **Safe failure over silent success.** Headless Antigravity runs on an allow-list of commands. Anything unlisted aborts the run. If an agy run changes nothing, the loop stops and logs the command it tried, so you can allow it. A missing structured verdict also stops the loop.
- **One usage budget across all projects.** A machine-wide lock means only one pass or agy run happens at a time, whatever the number of projects. Every step checks `/usage` first: the loop pauses near your session limit and stops at your weekly threshold.
- **The machine stays awake.** On macOS the runner runs under `caffeinate`, so a five-minute gap between passes stays five minutes.

## Requirements

- bash (3.2 works, so the macOS default is fine), git, python3
- `claude` CLI, logged in
- optional: `agy` (Antigravity CLI) for repos with `executor=agy`

## Install

```sh
git clone https://github.com/RichGod93/relay-loop.git
cd relay-loop && ./install.sh          # links `relay` into ~/.local/bin, adds the /relay-init skill
```

## Use

```sh
cd ~/code/my-project
relay init                 # scaffolds .loop/ and prints detected repos, checks, hazards
$EDITOR .loop/config.sh    # fix repos/checks, read HAZARDS, set HAZARDS_REVIEWED=yes
$EDITOR .loop/BACKLOG.md   # one pass-sized item per line, tagged with its repo
relay start                # runs in the background; survives closing the terminal
relay logs                 # follow .loop/logs/loop.log
relay status               # every registered project
relay stop                 # stop after the current step
relay finish               # what the loop committed, plus review/merge commands
relay finish --remove      # drop the worktrees once merged
```

In Claude Code, `/relay-init` walks you through the same setup interactively.

To begin with an Antigravity run you've already written: `relay start --agy 01-settings-page.md`.

## Project layout

```
my-project/.loop/
  config.sh      repos, executors, checks, mode, limits, hazards
  BACKLOG.md     the work list; the source of truth
  project.md     project conventions every pass enforces
  agy/           Antigravity prompts written by passes
  logs/          loop.log, pass-NN-*.json/.md, agy-*.log (gitignored)
  state/         pid, loop branch, generated agy settings (gitignored)
```

`config.sh` repo lines look like `"name|path|executor|checks"`:

```sh
REPOS=(
  "api|api|claude|npx tsc --noEmit && npm test"
  "web|web|agy|npx tsc --noEmit && npm run lint && npm run build"
)
```

## Modes

- **branch** (default): worktrees under `~/.relay-loop/work/<project>` on `loop/<date>`. The runner commits each pass's staged work there. Untracked paths in `WORKTREE_LINK` (default `node_modules`) are symlinked from your checkout. `.env` files are not copied, which is usually what you want.
- **stage**: agents work in your own checkout and reviewed work stays staged. Use this when you have uncommitted work the loop must build on. Be careful: staged-only work is one `git stash` away from gone.

## Limits

- A pass reviews code, not pixels. Nothing here opens a browser. Check UI work yourself before merging.
- Claude passes run with `--permission-mode bypassPermissions` plus a deny list (git history commands, `rm -rf`, `agy`, subagents, and your `EXTRA_DENY`). That deny list is a guardrail, not a sandbox. Don't point the loop at a machine or account you can't afford to have an agent misuse. Your declared hazards are the real contract.
- Antigravity's allow-list matches command prefixes. A rule like `command(find)` also allows `find -delete`.
- The usage check parses the text output of `claude -p /usage`. If that format changes, the loop stops rather than guess.
- Antigravity model names, flags and permission syntax change. The defaults here were current when this was written.

## Test

```sh
bash test/smoke.sh   # stub claude + agy; no tokens, no network
```

## License

MIT
