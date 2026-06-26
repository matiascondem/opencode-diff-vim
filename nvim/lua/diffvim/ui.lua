-- Window layout, highlight groups, and key bindings.
local State = require("diffvim.state")

local M = {}

-- Catppuccin Mocha palette (matches the author's terminal).
local C = {
  base = "#1e1e2e",
  mantle = "#181825",
  surface0 = "#313244",
  surface1 = "#45475a",
  text = "#cdd6f4",
  subtext0 = "#a6adc8",
  overlay0 = "#6c7086",
  green = "#a6e3a1",
  red = "#f38ba8",
  blue = "#89b4fa",
  yellow = "#f9e2af",
  mauve = "#cba6f7",
  add_bg = "#21302a",
  del_bg = "#332128",
}

function M.setup_highlights()
  local set = vim.api.nvim_set_hl
  set(0, "DiffVimAdd", { bg = C.add_bg })
  set(0, "DiffVimDel", { bg = C.del_bg })
  set(0, "DiffVimHeader", { fg = C.blue, italic = true })
  set(0, "DiffVimTitle", { fg = C.blue, bold = true })
  set(0, "DiffVimSubtitle", { fg = C.overlay0 })
  set(0, "DiffVimComment", { fg = C.yellow })
  set(0, "DiffVimCommentSign", { fg = C.mauve })
  set(0, "DiffVimTreeSel", { bg = C.surface0, bold = true })
  set(0, "DiffVimTreeDir", { fg = C.blue })
  set(0, "DiffVimTreeAdd", { fg = C.green })
  set(0, "DiffVimTreeDel", { fg = C.red })
  set(0, "DiffVimFloat", { bg = C.mantle, fg = C.text })
  set(0, "DiffVimFloatBorder", { bg = C.mantle, fg = C.blue })
  set(0, "DiffVimWinbar", { bg = C.surface0, fg = C.subtext0 })
  set(0, "Normal", { bg = C.base, fg = C.text })
  set(0, "NormalFloat", { bg = C.mantle, fg = C.text })
  set(0, "CursorLine", { bg = C.surface0 })
  set(0, "WinSeparator", { fg = C.surface1 })
end

local function map(buf, modes, lhs, fn, desc)
  vim.keymap.set(modes, lhs, fn, { buffer = buf, silent = true, nowait = true, desc = desc })
end

local function bind(buf, is_tree)
  local comments = require("diffvim.comments")
  local tree = require("diffvim.tree")
  local diff = require("diffvim.diff")
  local submit = require("diffvim.submit")

  -- pane navigation
  map(buf, "n", "<C-h>", function()
    tree.focus()
  end, "focus tree")
  map(buf, "n", "<C-l>", function()
    if State.diff_win and vim.api.nvim_win_is_valid(State.diff_win) then
      vim.api.nvim_set_current_win(State.diff_win)
    end
  end, "focus diff")

  -- file cycling
  map(buf, "n", "]c", function()
    tree.cycle(1)
  end, "next file")
  map(buf, "n", "[c", function()
    tree.cycle(-1)
  end, "prev file")

  -- submit flow (available from both panes)
  map(buf, "n", "<leader>s", function()
    submit.edit_notes()
  end, "final review comment")
  map(buf, "n", "<leader>ss", function()
    diff.toggle_view()
  end, "toggle side-by-side diff")
  map(buf, "n", "<leader>y", function()
    submit.submit()
  end, "submit review")
  map(buf, "n", "<leader>q", function()
    require("diffvim.payload").cancel()
    vim.cmd("qa!")
  end, "quit without submitting")

  if is_tree then
    map(buf, "n", "<CR>", function()
      tree.open_under_cursor()
      if State.diff_win and vim.api.nvim_win_is_valid(State.diff_win) then
        vim.api.nvim_set_current_win(State.diff_win)
      end
    end, "open & focus file")
  else
    map(buf, "n", "a", function()
      comments.add_current()
    end, "comment line")
    map(buf, "x", "a", function()
      comments.add_visual()
    end, "comment selection")
    map(buf, "n", "<leader>x", function()
      comments.delete_current()
    end, "delete comment")
    -- swallow edit operators on the read-only diff
    for _, k in ipairs({ "i", "I", "o", "O", "A", "c", "p", "P", "r", "x", "s" }) do
      map(buf, "n", k, function() end, "noop")
    end
  end
end

local function make_buf(name)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_set_name(buf, name)
  return buf
end

function M.build()
  M.setup_highlights()

  State.ns_diff = vim.api.nvim_create_namespace("diffvim_diff")
  State.ns_comment = vim.api.nvim_create_namespace("diffvim_comment")
  State.ns_tree = vim.api.nvim_create_namespace("diffvim_tree")

  State.diff_buf = make_buf("diff-vim://diff")
  State.tree_buf = make_buf("diff-vim://changes")

  -- current window becomes the diff pane
  State.diff_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(State.diff_win, State.diff_buf)

  -- carve the tree out on the left
  vim.cmd("topleft vsplit")
  State.tree_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(State.tree_win, State.tree_buf)
  vim.api.nvim_win_set_width(State.tree_win, 40)

  -- window options
  vim.wo[State.tree_win].number = false
  vim.wo[State.tree_win].relativenumber = false
  vim.wo[State.tree_win].signcolumn = "no"
  vim.wo[State.tree_win].cursorline = true
  vim.wo[State.tree_win].winfixwidth = true
  vim.wo[State.tree_win].wrap = false
  vim.wo[State.tree_win].winbar = "%#DiffVimWinbar# Changes "

  vim.wo[State.diff_win].number = false
  vim.wo[State.diff_win].relativenumber = false
  vim.wo[State.diff_win].signcolumn = "yes:1"
  vim.wo[State.diff_win].cursorline = true
  vim.wo[State.diff_win].wrap = false

  bind(State.tree_buf, true)
  bind(State.diff_buf, false)

  -- preview-on-move in the tree
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = State.tree_buf,
    callback = function()
      require("diffvim.tree").open_under_cursor()
    end,
  })

  -- make sure the waiting tool never hangs if the tab is closed
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      require("diffvim.payload").cancel()
    end,
  })

  -- initial paint
  require("diffvim.tree").render()
  require("diffvim.diff").render()

  -- land in the diff, ready to read
  vim.api.nvim_set_current_win(State.diff_win)
end

return M
