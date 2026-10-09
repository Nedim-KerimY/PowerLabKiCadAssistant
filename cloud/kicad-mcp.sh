#!/usr/bin/env bash
# Starts the KiCad MCP server for Claude Code (.mcp.json). Runs cloud/setup.sh first
# if this container hasn't been set up yet. Only stdout carries the MCP protocol, so
# everything else goes to stderr.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POWERLAB_HOME="${POWERLAB_HOME:-$HOME/.local/share/PowerLabKiCadAssistant}"
[ -f "$POWERLAB_HOME/ready" ] || bash "$ROOT/cloud/setup.sh" >&2
# shellcheck source=/dev/null
. "$POWERLAB_HOME/env"
unset PYTHONHOME PYTHONPATH  # as common.clean_env(): the server picks KiCad's own paths
exec node "$KICAD_MCP_DIR/dist/index.js"
