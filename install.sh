#!/usr/bin/env bash
# Wire opencode-diff-vim into the opencode TUI for local development.
# Idempotent: safe to re-run.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEGACY_SHIM="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/plugins/diff-vim.ts"

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
ok() { printf "  \033[32m✓\033[0m %s\n" "$1"; }
warn() { printf "  \033[33m!\033[0m %s\n" "$1"; }

bold "opencode-diff-vim installer"
echo "repo: $REPO_DIR"

# 1. dependencies
bold "Installing dependencies (npm install)…"
(cd "$REPO_DIR" && npm install)
ok "dependencies present"

# 2. TUI plugin registration
if ! command -v opencode >/dev/null 2>&1; then
  warn "opencode not found on PATH — install it before running this installer"
  exit 1
fi
opencode plugin "$REPO_DIR" --global --force
ok "TUI plugin registered"

# Remove the old server plugin so /diff-vim no longer enters the model loop.
if [ -f "$LEGACY_SHIM" ]; then
  rm -f "$LEGACY_SHIM"
  ok "legacy server plugin removed: $LEGACY_SHIM"
fi

# 3. preflight checks (non-fatal)
bold "Preflight checks"

if command -v nvim >/dev/null 2>&1; then
  ver="$(nvim --version | head -1)"
  ok "neovim: $ver"
else
  warn "neovim not found on PATH — required to render the review"
fi

if command -v kitty >/dev/null 2>&1; then
  ok "kitty on PATH"
elif command -v wezterm >/dev/null 2>&1; then
  ok "wezterm on PATH"
else
  warn "neither kitty nor wezterm found on PATH — the review tab cannot be launched"
fi

if command -v curl >/dev/null 2>&1; then
  ok "curl on PATH"
else
  warn "curl not found — needed to submit the review back to opencode"
fi

KITTY_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/kitty/kitty.conf"
if [ -f "$KITTY_CONF" ] && grep -Eq '^\s*allow_remote_control\s+(yes|socket-only)' "$KITTY_CONF"; then
  ok "kitty allow_remote_control enabled"
else
  warn "set 'allow_remote_control yes' and a 'listen_on unix:/tmp/kitty' in $KITTY_CONF"
fi

if [ -n "${KITTY_LISTEN_ON:-}" ]; then
  ok "KITTY_LISTEN_ON=$KITTY_LISTEN_ON"
else
  warn "KITTY_LISTEN_ON is empty — the plugin will scan /tmp for a Kitty socket"
fi

if [ -n "${WEZTERM_PANE:-}" ]; then
  ok "WEZTERM_PANE=$WEZTERM_PANE"
elif command -v wezterm >/dev/null 2>&1; then
  warn "WEZTERM_PANE is empty — automatic terminal selection will use Kitty"
fi

echo
bold "Done."
echo "Restart opencode, then select:  /diff-vim"
echo "Uninstall with:                 $REPO_DIR/uninstall.sh"
