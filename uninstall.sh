#!/usr/bin/env bash
# Remove the opencode-diff-vim plugin shim from opencode.
set -euo pipefail

PLUGINS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/plugins"
SHIM="$PLUGINS_DIR/diff-vim.ts"

if [ -f "$SHIM" ]; then
  rm -f "$SHIM"
  echo "Removed $SHIM"
else
  echo "Nothing to remove (no shim at $SHIM)"
fi
echo "Restart opencode to unload the plugin."
