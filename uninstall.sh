#!/usr/bin/env bash
# Remove opencode-diff-vim from the opencode TUI config.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
TUI_CONFIG="$CONFIG_DIR/tui.json"
LEGACY_SHIM="$CONFIG_DIR/plugins/diff-vim.ts"

if [ -f "$TUI_CONFIG" ]; then
  TUI_CONFIG="$TUI_CONFIG" REPO_DIR="$REPO_DIR" node --input-type=module <<'NODE'
import { readFile, rm, writeFile } from "node:fs/promises"

const file = process.env.TUI_CONFIG
const repo = process.env.REPO_DIR
const source = await readFile(file, "utf8")
let config
try {
  config = JSON.parse(source)
} catch {
  console.error(`Could not update ${file} because it contains JSONC. Remove ${repo} from its plugin array manually.`)
  process.exit(1)
}

const plugins = Array.isArray(config.plugin) ? config.plugin : []
config.plugin = plugins.filter((item) => (Array.isArray(item) ? item[0] : item) !== repo)
if (config.plugin.length === 0) delete config.plugin

if (Object.keys(config).length === 0) await rm(file)
else await writeFile(file, `${JSON.stringify(config, null, 2)}\n`)
NODE
  echo "Removed TUI plugin registration from $TUI_CONFIG"
fi

rm -f "$LEGACY_SHIM"
echo "Restart opencode to unload the plugin."
