#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables are read inside the eval'd check strings
# End-to-end test with stub `claude` and `agy` binaries: no tokens spent, no network.
# Covers: init detection, branch-mode worktrees, structured verdicts, the agy hand-off,
# runner commits, the agy no-op stop, and the "agent committed" stop.
set -uo pipefail
ENGINE="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export RELAY_HOME="$T/home" RELAY_NO_CAFFEINATE=1 PATH="$T/stubs:$PATH"
fails=0
ok()   { echo "  ok   $1"; }
bad()  { echo "  FAIL $1"; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

mkdir -p "$T/stubs"
cat >"$T/stubs/claude" <<'EOF'
#!/usr/bin/env bash
case "$*" in *"/usage"*) printf 'Current session: 10%% used\nCurrent week (all models): 20%% used\n'; exit 0 ;; esac
n=$(( $(cat "$STUB_STATE/count" 2>/dev/null || echo 0) + 1 )); echo $n >"$STUB_STATE/count"
v() { printf '{"type":"result","structured_output":{"verdict":"%s","agy_prompt":"%s","commit_message":"%s","report":"stub pass %s"}}\n' "$1" "$2" "$3" "$n"; }
case "${STUB_SCENARIO}:$n" in
  happy:1) echo a >api/a.txt; git -C api add a.txt; v AGY ui.md "Add a" ;;
  happy:2) git -C web add -A; sed -i.bak 's/- \[ \]/- [x]/' "$LOOP_BACKLOG" && rm -f "$LOOP_BACKLOG.bak"; v DONE "" "Stage ui" ;;
  noop:1)  v AGY ui.md "nothing" ;;
  rogue:1) echo r >api/r.txt; git -C api add r.txt; git -C api commit -qm rogue; v CONTINUE "" "rogue" ;;
  *) v BLOCKED "" "unexpected" ;;
esac
EOF
cat >"$T/stubs/agy" <<'EOF'
#!/usr/bin/env bash
[ "${STUB_SCENARIO}" = noop ] && { echo "did nothing"; exit 0; }
echo ui >ui.txt; echo "edited ui.txt"
EOF
chmod +x "$T/stubs/claude" "$T/stubs/agy"

make_project() {   # $1 = dir
  local p="$1" r
  for r in api web; do
    mkdir -p "$p/$r"; git -C "$p/$r" init -q -b main; git -C "$p/$r" config user.email t@t; git -C "$p/$r" config user.name t
    echo "# $r" >"$p/$r/README.md"; git -C "$p/$r" add -A; git -C "$p/$r" commit -qm init
  done
  echo '{"dependencies":{"next":"16.0.0","react":"19.0.0"},"scripts":{"lint":"eslint","build":"next build","dev":"next dev"}}' >"$p/web/package.json"
  echo '{"scripts":{"lint":"eslint \"src/**/*.ts\" --fix","test":"jest"}}' >"$p/api/package.json"
  echo 'MONGO_URI=mongodb+srv://user:pw@cluster0.example.net/db' >"$p/api/.env"
  echo '@Cron("* * * * *")' >"$p/api/jobs.ts"
  git -C "$p/web" add -A; git -C "$p/web" commit -qm pkg
}

configure() {   # $1 = project dir
  sed -i.bak -e 's/^HAZARDS_REVIEWED=no/HAZARDS_REVIEWED=yes/' -e 's/^GAP_SECONDS=300/GAP_SECONDS=0/' \
    -e 's/|web|claude|/|web|agy|/' "$1/.loop/config.sh" && rm -f "$1/.loop/config.sh.bak"
  printf '# t\n\n## Open\n- [ ] **1. [web] do ui.**\n\n## Needs the human\n' >"$1/.loop/BACKLOG.md"
  echo "do the ui" >"$1/.loop/agy/ui.md"
}

echo "init detection"
P="$T/proj"; make_project "$P"
"$ENGINE/bin/relay" init "$P" >/dev/null
check "config created" '[ -f "$P/.loop/config.sh" ]'
check "detects both repos" 'grep -q "\"api|api|" "$P/.loop/config.sh" && grep -q "\"web|web|" "$P/.loop/config.sh"'
check "flags remote Mongo without printing it" 'grep -q "MONGO_URI is a remote MongoDB" "$P/.loop/config.sh" && ! grep -q "user:pw" "$P/.loop/config.sh"'
check "flags scheduled jobs" 'grep -q "scheduled job" "$P/.loop/config.sh"'
check "turns a --fix lint into a read-only check" 'grep -q "\"api|api|claude|npx eslint .*src/\*\*/\*.ts.* && npm run test\"" "$P/.loop/config.sh" && ! grep "api|api" "$P/.loop/config.sh" | grep -q -- "--fix"'
check "denies dev server" 'grep -q "Bash(npm run dev:\*)" "$P/.loop/config.sh"'
check "refuses to start before hazards reviewed" '! "$ENGINE/bin/relay" start "$P" 2>/dev/null'

echo "happy path (branch mode, agy hand-off, runner commits)"
configure "$P"
export STUB_STATE="$T/s1" STUB_SCENARIO=happy LOOP_BACKLOG="$P/.loop/BACKLOG.md"; mkdir -p "$STUB_STATE"
"$ENGINE/lib/runner.sh" "$P" >/dev/null 2>&1
L="$P/.loop/logs/loop.log"; W="$RELAY_HOME/work/proj"; B="$(cat "$P/.loop/state/branch")"
check "pass 1 asked for agy" 'grep -q "pass 1 verdict: AGY ui.md" "$L"'
check "agy ran in the web worktree" 'grep -q "agy (.*) in $W/web" "$L" && [ -f "$W/web/ui.txt" ]'
check "agy settings scoped to web worktree + its checks" 'grep -q "write_file($W/web)" "$P/.loop/state/agy-settings.json" && grep -q "command(npm run lint)" "$P/.loop/state/agy-settings.json" && python3 -m json.tool "$P/.loop/state/agy-settings.json" >/dev/null'
check "runner committed api work on the loop branch" '[ "$(git -C "$W/api" log -1 --format=%s "$B")" = "Add a" ]'
check "runner committed reviewed ui on the loop branch" '[ "$(git -C "$W/web" log -1 --format=%s "$B")" = "Stage ui" ]'
check "your checkout is untouched" '[ ! -e "$P/api/a.txt" ] && [ ! -e "$P/web/ui.txt" ] && [ "$(git -C "$P/api" rev-parse --abbrev-ref HEAD)" = main ]'
check "stopped on DONE" 'grep -q "stopping on verdict DONE" "$L"'
check "lock released" '[ ! -d "$RELAY_HOME/lock" ]'
fin="$("$ENGINE/bin/relay" finish "$P")"
check "finish lists the commit" 'echo "$fin" | grep -q "Add a"'
check "finish --remove drops worktrees" '"$ENGINE/bin/relay" finish "$P" --remove >/dev/null && [ ! -e "$W/api" ]'

echo "agy no-op stops the loop"
P2="$T/proj2"; make_project "$P2"; "$ENGINE/bin/relay" init "$P2" >/dev/null; configure "$P2"
export STUB_STATE="$T/s2" STUB_SCENARIO=noop LOOP_BACKLOG="$P2/.loop/BACKLOG.md"; mkdir -p "$STUB_STATE"
"$ENGINE/lib/runner.sh" "$P2" >/dev/null 2>&1
check "logged agy changed nothing" 'grep -q "agy changed nothing" "$P2/.loop/logs/loop.log"'

echo "an agent commit stops the loop"
P3="$T/proj3"; make_project "$P3"; "$ENGINE/bin/relay" init "$P3" >/dev/null; configure "$P3"
export STUB_STATE="$T/s3" STUB_SCENARIO=rogue LOOP_BACKLOG="$P3/.loop/BACKLOG.md"; mkdir -p "$STUB_STATE"
"$ENGINE/lib/runner.sh" "$P3" >/dev/null 2>&1
check "logged the HEAD move" 'grep -q "a HEAD moved during the pass" "$P3/.loop/logs/loop.log"'
check "only one pass ran" '[ "$(cat "$T/s3/count")" = 1 ]'

echo
[ "$fails" -eq 0 ] && echo "all checks passed" || { echo "$fails check(s) failed"; exit 1; }
