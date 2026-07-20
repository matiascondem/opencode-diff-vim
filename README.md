# opencode-diff-vim

A keyboard-only, vim-native diff review for the [OpenCode](https://opencode.ai) TUI.

Run `/diff-vim` to open the current working-tree diff in a neighboring terminal tab. Review files with normal Vim motions, add line or range comments, write an optional final note, and submit. The feedback is sent to the active OpenCode session and starts the agent automatically.

Unlike an OpenCode prompt command, `/diff-vim` is a direct TUI command. It does not wait for a model to decide to call a tool before opening the review.

## Requirements

- OpenCode 1.18.3 or newer
- Kitty with remote control enabled, or WezTerm with its CLI on `PATH`
- Neovim 0.10 or newer
- `curl`
- Node.js and npm for local installation

### Kitty setup

Add the following to `~/.config/kitty/kitty.conf`, then fully restart Kitty:

```conf
allow_remote_control yes
listen_on unix:/tmp/kitty
```

### WezTerm setup

Run OpenCode inside WezTerm. The plugin uses `wezterm cli spawn` when `WEZTERM_PANE` is available; otherwise it uses Kitty.

## Install

```sh
git clone <your-fork-url> ~/projects/opencode-diff-vim
cd ~/projects/opencode-diff-vim
./install.sh
```

The installer runs `opencode plugin <repo> --global --force`, which adds the TUI-only package to `~/.config/opencode/tui.json`. It also removes the legacy server-plugin shim if present.

Restart OpenCode after installation, then select `/diff-vim` from slash-command autocomplete.

Uninstall with `./uninstall.sh`.

## Usage

```text
/diff-vim
```

The review always shows staged, unstaged, and untracked working-tree changes against `HEAD`. Terminal selection is automatic.

### Keybindings

Leader is `space`.

| Key | Where | Action |
| --- | --- | --- |
| `j` / `k` | Anywhere | Normal Vim movement |
| `<C-h>` / `<C-l>` | Anywhere | Focus tree / diff |
| `<CR>` | Tree | Open file |
| `]c` / `[c` | Anywhere | Next / previous file |
| `a` | Diff, normal | Comment current line |
| `v` then `a` | Diff, visual | Comment selected range |
| `<leader>ss` | Anywhere | Toggle unified / side-by-side view |
| `<CR>` | Input | Save comment or note |
| `<S-CR>` / `<C-j>` | Input | Insert newline |
| `q` / `<Esc>` | Input | Cancel input |
| `a` | On a comment | Edit comment |
| `<leader>x` | Diff | Delete comment under cursor |
| `<leader>s` | Anywhere | Edit final review note |
| `<leader>y` | Anywhere | Submit feedback and close |
| `<leader>q` | Anywhere | Close without submitting |

## How it works

```text
/diff-vim
  -> direct OpenCode TUI command
  -> collect working-tree changes
  -> write a temporary payload and start a local callback server
  -> launch Neovim in Kitty or WezTerm
  -> submit comments to the callback server
  -> delete temporary data
  -> add one review-feedback prompt to the active session
  -> agent continues automatically
```

The review runs with `NVIM_APPNAME=diff-vim`, so it does not load or modify the normal Neovim configuration. Review payloads only exist in the operating system's temporary directory while the review is open.

Submitted feedback appears as a new user message in the active session. The plugin preserves the latest user message's agent, model, and variant when starting the response.

## Development

```sh
npm install
npm run check
```

`npm run check` runs TypeScript typechecking and the TUI command tests.

## License

MIT
