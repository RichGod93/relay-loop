#!/usr/bin/env bash
# Links `relay` into ~/.local/bin (or $1) and optionally installs the Claude Code skill.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="${1:-$HOME/.local/bin}"
mkdir -p "$BIN"
ln -sf "$HERE/bin/relay" "$BIN/relay"
echo "linked $BIN/relay → $HERE/bin/relay"
case ":$PATH:" in *":$BIN:"*) ;; *) echo "note: $BIN is not on your PATH" ;; esac

for dep in git python3 claude; do command -v "$dep" >/dev/null || echo "missing: $dep (required)"; done
command -v agy >/dev/null || echo "optional: agy (Antigravity CLI) not found; repos can still use executor=claude"

if [ -d "$HOME/.claude/skills" ] && [ ! -e "$HOME/.claude/skills/relay-init" ]; then
  ln -s "$HERE/skills/relay-init" "$HOME/.claude/skills/relay-init"
  echo "installed Claude Code skill: /relay-init"
fi
