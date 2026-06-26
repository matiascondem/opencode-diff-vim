# opencode-diff-vim

A keyboard-only, **vim-native diff review** for [opencode](https://opencode.ai).

When an agent finishes work, run `/diff-vim`. It opens a **new Kitty tab** right
next to your chat with a two-pane review UI rendered in **Neovim**: a changed-files
tree on the left, a unified GitHub-style diff on the right. You move with real vim
motions, drop inline comments on lines or ranges (non-destructively), write one
final review note, and submit — the structured comments flow straight back into
the opencode session for the agent to act on.

It's a focused reimagining of the excellent
[`opencode-diffs`](https://github.com/oorestisime/opencode-diffs) plugin: the git
collection, blocking handshake, and round exports are kept; the browser +
`@pierre/diffs` front-end is replaced with Neovim.

---

## Why

- **No mouse, no browser.** Review in the same terminal, with the same motions
  and muscle memory you already have.
- **Non-destructive comments.** Comments render as `virt_lines` *below* a line —
  the diff content is never altered.
- **Round-trips to the agent.** Submitting returns a structured findings summary
  to opencode so the agent can propose a fix plan.

---

## Requirements

- **Kitty** with remote control enabled (see below).
- **Neovim ≥ 0.10** (uses `vim.system`, `vim.diff`, extmark `virt_lines`).
- **curl** (submits the review back to opencode).
- **opencode** running *inside* Kitty (so the plugin can find the Kitty socket).
- A **Nerd Font** is optional — only used for the tree status glyphs.

### Kitty setup

Add to `~/.config/kitty/kitty.conf`:

```conf
allow_remote_control yes
listen_on unix:/tmp/kitty
```

Kitty exposes a per-window socket as `$KITTY_LISTEN_ON` (e.g.
`unix:/tmp/kitty-40543`). The plugin reads that env var to open the review tab in
the **same** OS window as your opencode session. Fully restart Kitty after
changing the config.

---

## Install (local dev)

```sh
git clone <your-fork-url> ~/projects/opencode-diff-vim
cd ~/projects/opencode-diff-vim
./install.sh        # npm install + writes the opencode plugin shim + preflight checks
```

`install.sh` writes a tiny shim to `~/.config/opencode/plugins/diff-vim.ts` that
re-exports this repo's `plugin/index.ts`. Because the repo carries its own
`node_modules`, `@opencode-ai/plugin` resolves correctly. The Neovim app is found
relative to the plugin file — nothing is copied into `~/.config`.

Restart opencode, then run `/diff-vim`.

Uninstall: `./uninstall.sh`.

---

## Usage

In opencode:

```
/diff-vim                          # review the working-tree diff (vs HEAD)
/diff-vim --base origin/dev        # review this branch vs its merge-base with origin/dev
/diff-vim --files a.ts,b.ts        # only these files
```

A Kitty tab opens with the review. When you submit, opencode receives the
comments and you continue the conversation.

### Keybindings

Leader is `space`.

| Key            | Where        | Action                                            |
| -------------- | ------------ | ------------------------------------------------- |
| `j` / `k`, etc | anywhere     | normal vim motions                                |
| `<C-h>` `<C-l>`| anywhere     | focus tree / focus diff                           |
| `<CR>`         | tree         | open file in the diff pane (also auto-previews)   |
| `]c` / `[c`    | anywhere     | next / previous file                              |
| `a`            | diff, normal | comment the **current line**                      |
| `v` then `a`   | diff, visual | comment the **selected line range**               |
| `<leader>ss`   | anywhere     | toggle unified / side-by-side diff view           |
| `<CR>`         | input box    | save the comment / note                           |
| `<S-CR>`/`<C-j>`| input box   | insert a newline                                  |
| `q` / `<Esc>`  | input box    | cancel                                            |
| `a`            | on a comment | edit it                                           |
| `<leader>x`    | diff         | delete the comment under the cursor               |
| `<leader>s`    | anywhere     | write the **final review comment**                |
| `<leader>y`    | anywhere     | **submit everything** and close the tab           |
| `<leader>q`    | anywhere     | quit without submitting                           |

Comments are intentionally minimal: just a message anchored to a line or range.

---

## How it works

```
/diff-vim ─▶ diff_vim tool (plugin/index.ts)
   ├─ collect git diff (working tree vs HEAD, or --base ref)
   ├─ write payload to .opencode/reviews/<session>/vim-payload.json
   ├─ start a local 127.0.0.1 server (random port + token)
   ├─ kitty @ launch --type=tab … nvim -u nvim/init.lua
   │        env: DIFF_VIM_PAYLOAD, DIFF_VIM_SUBMIT_URL, NVIM_APPNAME=diff-vim
   │            │
   │            └─ Neovim review app (nvim/lua/diffvim/*)
   │               tree │ unified diff · a / v+a comments · <leader>s note
   │               └─ <leader>y → curl POST /submit → :qa
   │
   └─ await /submit ─▶ write round-NNN.json ─▶ return comments to the agent
```

- **Isolation:** the review runs under `NVIM_APPNAME=diff-vim`, so it never loads
  your daily config and writes its state to `~/.local/share/diff-vim`.
- **Never hangs:** closing the tab without submitting posts a `cancel`, so the
  waiting tool always resolves.
- **State & exports:** internal round state lives in
  `.opencode/reviews/<session>/state.json`; each submit writes one
  `round-NNN.json` export. Prior submitted comments are not reloaded into the
  next review.

---

## Publishing (future)

The package follows the opencode plugin naming convention. Once published to npm,
users skip the shim entirely and just add it to their config:

```json
{ "plugin": ["opencode-diff-vim"] }
```

`nvim/` ships via the package `files` field and is resolved relative to the
installed plugin.

---

## License

MIT
