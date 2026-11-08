#!/usr/bin/env bash
# relay-loop runner: one project, many passes. Started by `relay start`; don't call it directly.
# Each pass is a fresh `claude -p` (clean context). State is handed over in .loop/BACKLOG.md.
# Repos marked executor=agy get their UI written by Antigravity (`agy -p`), launched by THIS
# script (never by Claude), so runs stay sequential and outlive Claude's tool timeouts.
# Written for bash 3.2 (macOS default): no associative arrays, no mapfile.

set -uo pipefail

PROJECT_DIR="$(cd "${1:?project dir}" && pwd)"
RELAY_HOME="${RELAY_HOME:-$HOME/.relay-loop}"
ENGINE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOOP_DIR="$PROJECT_DIR/.loop"
LOGS="$LOOP_DIR/logs"; mkdir -p "$LOGS" "$LOOP_DIR/state" "$RELAY_HOME"

# shellcheck source=/dev/null
. "$ENGINE_DIR/lib/common.sh"
load_config "$PROJECT_DIR"

# Keep the machine awake (a sleeping laptop turns a 5 min gap into an hour).
if [ -z "${RELAY_CAFFEINATED:-}" ] && [ -z "${RELAY_NO_CAFFEINATE:-}" ] && command -v caffeinate >/dev/null; then
  RELAY_CAFFEINATED=1 exec caffeinate -is "$0" "$@"
fi

log() { echo "[$(date '+%m-%d %H:%M:%S')] $*" | tee -a "$LOGS/loop.log"; }
echo $$ >"$LOOP_DIR/state/pid"
trap 'rm -f "$LOOP_DIR/state/pid"; lock_release' EXIT

# ─── workspace: where agents work ───────────────────────────────────────────
# stage mode: your own checkouts. branch mode: git worktrees on a loop/<stamp> branch under
# $RELAY_HOME/work/<project>, so reviewed work is committed there and never sits only in your index.
setup_workspace() {
  if [ "$MODE" = stage ]; then WORK="$PROJECT_DIR"; return 0; fi
  local branch; branch="$(cat "$LOOP_DIR/state/branch" 2>/dev/null || true)"
  [ -n "$branch" ] || { branch="loop/$(date '+%Y%m%d-%H%M')"; echo "$branch" >"$LOOP_DIR/state/branch"; }
  WORK="$RELAY_HOME/work/$PROJECT_NAME"; mkdir -p "$WORK"
  local i name path wt link
  for i in $(repo_indexes); do
    name="$(repo_field "$i" 1)"; path="$(repo_field "$i" 2)"; wt="$WORK/$path"
    if [ ! -e "$wt/.git" ]; then
      if git -C "$PROJECT_DIR/$path" show-ref --verify --quiet "refs/heads/$branch"; then
        git -C "$PROJECT_DIR/$path" worktree add "$wt" "$branch" >/dev/null 2>&1
      else
        git -C "$PROJECT_DIR/$path" worktree add -b "$branch" "$wt" >/dev/null 2>&1
      fi || { log "could not create worktree for $name at $wt"; return 1; }
      for link in ${WORKTREE_LINK[@]+"${WORKTREE_LINK[@]}"}; do
        [ -e "$PROJECT_DIR/$path/$link" ] && [ ! -e "$wt/$link" ] && ln -s "$PROJECT_DIR/$path/$link" "$wt/$link"
      done
      log "worktree $name → $wt ($branch)"
    fi
  done
  BRANCH="$branch"
}

repo_dir() { echo "$WORK/$(repo_field "$1" 2)"; }

# Fingerprint of a repo: HEAD + index + working tree. Used to detect commits and no-ops.
fingerprint() { local d="$1"; git -C "$d" rev-parse HEAD; git -C "$d" status --porcelain; git -C "$d" diff | shasum; git -C "$d" diff --cached | shasum; }
heads() { local i; for i in $(repo_indexes); do git -C "$(repo_dir "$i")" rev-parse HEAD; done; }

# ─── usage gate (shared by every project on this machine) ───────────────────
check_usage() {   # 0 = ok to run, 1 = stop
  while :; do
    local out ss wk
    out="$(cd "$RELAY_HOME" && claude -p "/usage" --no-session-persistence 2>/dev/null)"
    ss="$(echo "$out" | sed -nE 's/^Current session: ([0-9]+)% used.*/\1/p' | head -1)"
    wk="$(echo "$out" | sed -nE 's/^Current week \(all models\): ([0-9]+)% used.*/\1/p' | head -1)"
    if [ -z "$wk" ] || [ -z "$ss" ]; then log "usage: could not parse /usage output; stopping to be safe"; return 1; fi
    log "usage: session ${ss}% · week ${wk}%"
    [ "$wk" -ge "$WEEK_STOP" ] && { log "weekly usage ${wk}% >= ${WEEK_STOP}%: stopping"; return 1; }
    if [ "$ss" -ge "$SESSION_STOP" ]; then
      log "session usage ${ss}% >= ${SESSION_STOP}%: waiting 30 min for the window to reset"
      lock_release; sleep 1800; [ -f "$LOOP_DIR/STOP" ] && return 1; lock_acquire; continue
    fi
    return 0
  done
}

# ─── prompt assembly ────────────────────────────────────────────────────────
build_pass_prompt() {
  local i name path exe checks
  {
    sed -e "s#__LOOP_DIR__#$LOOP_DIR#g" -e "s#__WORK__#$WORK#g" -e "s#__MODE__#$MODE#g" "$ENGINE_DIR/templates/pass-prompt.md"
    echo; echo "## Repos in this workspace (cwd = \`$WORK\`)"
    for i in $(repo_indexes); do
      name="$(repo_field "$i" 1)"; path="$(repo_field "$i" 2)"; exe="$(repo_field "$i" 3)"; checks="$(repo_field "$i" 4)"
      if [ "$exe" = agy ]; then
        echo "- \`$path\` ($name): **UI is written by Antigravity.** You write the agy prompt, review its output, stage it, make small fixes. Checks: \`$checks\`"
      else
        echo "- \`$path\` ($name): **you write the code yourself.** Checks: \`$checks\`"
      fi
    done
    echo; echo "## Declared hazards (from .loop/config.sh; obey them)"; echo "$HAZARDS"
    if [ -f "$LOOP_DIR/project.md" ]; then echo; echo "## Project rules"; cat "$LOOP_DIR/project.md"; fi
  }
}

VERDICT_SCHEMA='{"type":"object","properties":{"verdict":{"type":"string","enum":["CONTINUE","AGY","BLOCKED","DONE"]},"agy_prompt":{"type":"string","description":"file name in .loop/agy/ when verdict is AGY"},"commit_message":{"type":"string","description":"one line, imperative, what this pass reviewed or changed"},"report":{"type":"string","description":"short plain report for the human"}},"required":["verdict","commit_message","report"]}'

json_field() { python3 -c "import sys,json
try:
  d=json.load(open(sys.argv[1])); s=d.get('structured_output') or {}
  print(s.get(sys.argv[2],'') if isinstance(s,dict) else '')
except Exception: print('')" "$1" "$2"; }

# ─── agy ────────────────────────────────────────────────────────────────────
agy_refused_command() {   # best effort: last command agy tried before a headless denial
  local t; t="$(ls -t "$HOME"/.gemini/antigravity-cli/brain/*/.system_generated/logs/transcript.jsonl 2>/dev/null | head -1)"
  [ -n "$t" ] || return 0
  python3 - "$t" <<'PY' 2>/dev/null
import json,sys
last=''
for line in open(sys.argv[1]):
    try: d=json.loads(line)
    except Exception: continue
    for c in d.get('tool_calls') or []:
        if c.get('name')=='run_command': last=str((c.get('args') or {}).get('CommandLine','')).strip('"')
print(last[:200])
PY
}

agy_settings() {   # scoped allow/deny; headless agy aborts on anything unlisted (safe failure)
  local i allow="" dir a
  for i in $(repo_indexes); do
    [ "$(repo_field "$i" 3)" = agy ] || continue
    dir="$(repo_dir "$i")"; allow="$allow\"read_file($dir)\",\"write_file($dir)\","
    # its check commands, as prefixes: "npx tsc --noEmit" → command(npx tsc), "npm run lint" → command(npm run lint)
    while IFS= read -r a; do [ -n "$a" ] && allow="$allow\"command($a)\","; done <<EOF
$(repo_field "$i" 4 | awk -F'&&|;' '{ for (k = 1; k <= NF; k++) { n = split($k, w, " "); if (n == 0) continue;
     if (w[2] == "run" || w[2] == "exec") print w[1] " " w[2] " " w[3]; else if (n > 1) print w[1] " " w[2]; else print w[1] } }')
EOF
  done
  for a in ${AGY_EXTRA_ALLOW[@]+"${AGY_EXTRA_ALLOW[@]}"}; do allow="$allow\"$a\","; done
  sed -e "s#\"__ALLOW__\",#$allow#" "$ENGINE_DIR/templates/agy-settings.json" >"$LOOP_DIR/state/agy-settings.json"
}

run_agy() {   # $1 = prompt file name in .loop/agy/, $2 = stamp. Returns 1 when the loop must stop.
  local pf="$LOOP_DIR/agy/$1" alog i agy_dir="" before after other_before other_after
  [ -f "$pf" ] || { log "agy prompt $pf not found: stopping"; return 1; }
  for i in $(repo_indexes); do [ "$(repo_field "$i" 3)" = agy ] && { agy_dir="$(repo_dir "$i")"; break; }; done
  [ -n "$agy_dir" ] || { log "verdict asked for agy but no repo has executor=agy: stopping"; return 1; }
  check_usage || return 1
  alog="$LOGS/agy-$(basename "$pf" .md)-$2.log"; agy_settings
  before="$(fingerprint "$agy_dir")"
  other_before="$(for i in $(repo_indexes); do [ "$(repo_dir "$i")" = "$agy_dir" ] || fingerprint "$(repo_dir "$i")"; done)"
  log "agy ($AGY_MODEL) in $agy_dir → $alog"
  ( cd "$agy_dir" && agy -p "$(cat "$ENGINE_DIR/templates/agy-rules.md" "$pf")" --model "$AGY_MODEL" \
      --settings "$LOOP_DIR/state/agy-settings.json" --print-timeout "$AGY_TIMEOUT" ) >"$alog" 2>&1
  log "agy exit $?"
  after="$(fingerprint "$agy_dir")"
  other_after="$(for i in $(repo_indexes); do [ "$(repo_dir "$i")" = "$agy_dir" ] || fingerprint "$(repo_dir "$i")"; done)"
  [ "$other_after" = "$other_before" ] || { log "agy touched a repo it doesn't own. Stopping so you can check."; return 1; }
  [ "$(echo "$after" | head -1)" = "$(echo "$before" | head -1)" ] || { log "agy committed. Stopping: only the runner commits."; return 1; }
  [ "$(echo "$after" | tail -1)" = "$(echo "$before" | tail -1)" ] || { log "agy changed the index (staged = reviewed). Stopping so you can check."; return 1; }
  if grep -q "no output produced\|auto-denied" "$alog" || [ "$after" = "$before" ]; then
    log "agy changed nothing (permission abort or no-op). Refused command: $(agy_refused_command). Allow it in AGY_EXTRA_ALLOW if it's safe. Log: $alog"
    return 1
  fi
}

# ─── commit reviewed work (branch mode only) ────────────────────────────────
commit_staged() {   # $1 = message
  [ "$MODE" = branch ] || return 0
  local i d
  for i in $(repo_indexes); do
    d="$(repo_dir "$i")"
    case "$(git -C "$d" rev-parse --abbrev-ref HEAD)" in loop/*) ;; *) log "refusing to commit: $d is not on a loop/ branch"; return 1 ;; esac
    git -C "$d" diff --cached --quiet && continue
    git -C "$d" commit -q -m "$1" -m "Reviewed by a relay-loop pass ($PROJECT_NAME). Staged = reviewed and checks passed." \
      && log "committed $(repo_field "$i" 1): $1" || { log "commit failed in $d"; return 1; }
  done
}

notify() {
  [ -n "${NOTIFY_CMD:-}" ] && sh -c "$NOTIFY_CMD \"\$1\"" _ "$1" 2>/dev/null
  command -v osascript >/dev/null && osascript -e "display notification \"$1\" with title \"relay-loop: $PROJECT_NAME\"" 2>/dev/null
  return 0
}

# ─── main ───────────────────────────────────────────────────────────────────
[ "$HAZARDS_REVIEWED" = yes ] || { log "HAZARDS_REVIEWED is not yes in .loop/config.sh. Read and edit HAZARDS first."; exit 1; }
lock_acquire
setup_workspace || exit 1
DENY=("Bash(git commit:*)" "Bash(git push:*)" "Bash(git reset:*)" "Bash(git checkout:*)" "Bash(git switch:*)"
      "Bash(git restore:*)" "Bash(git clean:*)" "Bash(git stash:*)" "Bash(git rebase:*)" "Bash(git merge:*)"
      "Bash(git worktree:*)" "Bash(rm -rf:*)" "Bash(agy:*)" "Agent" ${EXTRA_DENY[@]+"${EXTRA_DENY[@]}"})

pass=0
log "loop start ($MODE${BRANCH:+ on $BRANCH}): max $MAX_PASSES passes, week stop $WEEK_STOP%, session pause $SESSION_STOP%${START_AGY:+, starting with agy $START_AGY}"
if [ -n "${START_AGY:-}" ]; then
  run_agy "$START_AGY" "$(date '+%m%d-%H%M')" || { notify "stopped: see loop.log"; exit 1; }
  lock_release; sleep "$GAP_SECONDS"; lock_acquire
fi
while [ "$pass" -lt "$MAX_PASSES" ]; do
  [ -f "$LOOP_DIR/STOP" ] && { log "STOP file found: stopping"; rm -f "$LOOP_DIR/STOP"; break; }
  grep -q '^- \[ \]' "$LOOP_DIR/BACKLOG.md" || { log "no open items in BACKLOG.md: done"; break; }
  check_usage || break

  pass=$((pass + 1)); stamp="$(date '+%m%d-%H%M')"; plog="$LOGS/pass-$(printf %02d $pass)-$stamp"
  heads_before="$(heads)"
  log "pass $pass: claude → $plog.json"
  ( cd "$WORK" && claude -p "$(build_pass_prompt)" --permission-mode bypassPermissions --effort "$CLAUDE_EFFORT" \
      --disallowedTools "${DENY[@]}" --no-session-persistence --output-format json --json-schema "$VERDICT_SCHEMA" ) >"$plog.json" 2>"$plog.err"
  verdict="$(json_field "$plog.json" verdict)"; json_field "$plog.json" report >"$plog.md"
  log "pass $pass verdict: ${verdict:-<none>} $( [ "$verdict" = AGY ] && json_field "$plog.json" agy_prompt )"

  [ "$(heads)" = "$heads_before" ] || { log "a HEAD moved during the pass (an agent committed). Stopping: only the runner commits."; break; }
  case "$verdict" in CONTINUE|AGY|BLOCKED|DONE) commit_staged "$(json_field "$plog.json" commit_message)" || break ;; esac

  case "$verdict" in
    AGY) run_agy "$(json_field "$plog.json" agy_prompt)" "$stamp" || break ;;
    CONTINUE) ;;
    BLOCKED|DONE) log "stopping on verdict $verdict"; break ;;
    *) log "no structured verdict (pass crashed or ran out?). See $plog.json / $plog.err"; break ;;
  esac
  lock_release; sleep "$GAP_SECONDS"; lock_acquire
done
log "loop end after $pass pass(es)"
notify "stopped after $pass pass(es): see .loop/logs/loop.log"
