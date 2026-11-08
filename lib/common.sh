# shellcheck shell=bash disable=SC2034
# Shared helpers for relay-loop (sourced). bash 3.2 compatible.
# SC2034: config variables are set here and read by runner.sh / bin/relay.

RELAY_HOME="${RELAY_HOME:-$HOME/.relay-loop}"

die() { echo "relay: $*" >&2; exit 1; }

load_config() {   # $1 = project dir
  local cfg="$1/.loop/config.sh"
  [ -f "$cfg" ] || die "no $cfg (run: relay init $1)"
  # defaults
  PROJECT_NAME="$(basename "$1")"; REPOS=(); MODE=branch
  MAX_PASSES=12; WEEK_STOP=80; SESSION_STOP=85; GAP_SECONDS=300; CLAUDE_EFFORT=medium
  AGY_MODEL=gemini-4-argon-high; AGY_TIMEOUT=45m; HAZARDS=""; HAZARDS_REVIEWED=no
  EXTRA_DENY=(); AGY_EXTRA_ALLOW=(); WORKTREE_LINK=(node_modules); NOTIFY_CMD=""; AGY_MAX_FILES=10
  # personal defaults for every project on this machine (e.g. AGY_MODEL), then the project's own config
  # shellcheck source=/dev/null
  [ -f "$RELAY_HOME/defaults.sh" ] && . "$RELAY_HOME/defaults.sh"
  # shellcheck source=/dev/null
  . "$cfg"
  [ "${#REPOS[@]}" -gt 0 ] || die "REPOS is empty in $cfg"
  case "$MODE" in branch|stage) ;; *) die "MODE must be branch or stage" ;; esac
  local i exe path
  for i in $(repo_indexes); do
    exe="$(repo_field "$i" 3)"; path="$(repo_field "$i" 2)"
    case "$exe" in claude|agy) ;; *) die "repo $i: executor must be claude or agy, got '$exe'" ;; esac
    git -C "$1/$path" rev-parse --git-dir >/dev/null 2>&1 || die "repo $i: $1/$path is not a git repo"
    if [ "$path" = "." ] && [ "${#REPOS[@]}" -gt 1 ]; then die "path '.' only works when it's the only repo"; fi
  done
  [ "$(count_agy)" -le 1 ] || die "only one repo can have executor=agy"
}

repo_indexes() { local i=0; while [ "$i" -lt "${#REPOS[@]}" ]; do echo "$i"; i=$((i + 1)); done; }
repo_field() { echo "${REPOS[$1]}" | cut -d'|' -f"$2"; }   # 1 name, 2 path, 3 executor, 4 checks
count_agy() { local i n=0; for i in $(repo_indexes); do [ "$(repo_field "$i" 3)" = agy ] && n=$((n + 1)); done; echo "$n"; }

# One machine-wide lock: only one Claude pass or agy run at a time across all projects, so
# several projects share the usage budget instead of racing it.
lock_acquire() {
  local lock="$RELAY_HOME/lock" waited=0
  mkdir -p "$RELAY_HOME"
  while ! mkdir "$lock" 2>/dev/null; do
    local holder; holder="$(cat "$lock/pid" 2>/dev/null || true)"
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then rm -rf "$lock"; continue; fi
    [ "$waited" -eq 0 ] && type log >/dev/null 2>&1 && log "waiting for another project's pass to finish (lock held by pid ${holder:-?})"
    waited=1; sleep 20
  done
  echo $$ >"$lock/pid"; LOCK_HELD=1
}
lock_release() {
  [ "${LOCK_HELD:-}" = 1 ] || return 0
  [ "$(cat "$RELAY_HOME/lock/pid" 2>/dev/null)" = "$$" ] && rm -rf "$RELAY_HOME/lock"
  LOCK_HELD=0
}
