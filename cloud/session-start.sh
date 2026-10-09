#!/usr/bin/env bash
# SessionStart hook: sets up KiCad and the assistant's tools in a fresh cloud container.
# Does nothing on a maintainer's own computer (only Claude Code on the web sets
# CLAUDE_CODE_REMOTE). Setup output goes to a log; Claude sees a one-line status.
[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="${POWERLAB_HOME:-$HOME/.local/share/PowerLabKiCadAssistant}/setup.log"
mkdir -p "$(dirname "$LOG")"
if bash "$ROOT/cloud/setup.sh" >"$LOG" 2>&1; then
    echo "PowerLab cloud setup ready: KiCad $(kicad-cli version 2>/dev/null), kicad MCP server, Freerouting. See CLAUDE.md > Cloud mode."
else
    echo "PowerLab cloud setup failed; see $LOG (rerun: bash cloud/setup.sh)."
fi
