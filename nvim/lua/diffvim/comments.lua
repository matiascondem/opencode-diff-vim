-- Inline comments: a non-destructive overlay (virt_lines + a gutter bar) plus
-- the small floating input used to author them.
local State = require("diffvim.state")

local M = {}

-- A centered floating input. Calls cb(text) on Enter, cb(nil) on cancel.
function M.input(opts, default, cb)
  local width = opts.width or 66
  local seed = {}
  if default and default ~= "" then
    seed = vim.split(default, "\n", { plain = true })
  end
  local height = math.max(opts.height or 3, #seed + 1)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, seed)

  local ui_w = vim.o.columns
  local ui_h = vim.o.lines
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((ui_h - height) / 2 - 1),
    col = math.floor((ui_w - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. (opts.title or "Comment") .. "  (Enter send · S-Enter newline · Esc discard) ",
    title_pos = "center",
  })
  vim.wo[win].winhighlight = "Normal:DiffVimFloat,FloatBorder:DiffVimFloatBorder"
  vim.wo[win].wrap = true

  local done = false
  local function finish(text)
    if done then
      return
    end
    done = true
    -- leave insert mode before returning to the read-only diff buffer
    pcall(vim.cmd, "stopinsert")
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    vim.schedule(function()
      pcall(vim.cmd, "stopinsert")
    end)
    cb(text)
  end

  local function save()
    local body = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    body = body:gsub("^%s+", ""):gsub("%s+$", "")
    if body == "" then
      finish(nil)
    else
      finish(body)
    end
  end

  -- Enter sends the comment; Shift-Enter (or Ctrl-j) adds a newline.
  local function newline()
    local pos = vim.api.nvim_win_get_cursor(0)
    local r, c = pos[1], pos[2]
    vim.api.nvim_buf_set_text(buf, r - 1, c, r - 1, c, { "", "" })
    vim.api.nvim_win_set_cursor(0, { r + 1, 0 })
  end
  vim.keymap.set({ "i", "n" }, "<CR>", save, { buffer = buf })
  vim.keymap.set("i", "<S-CR>", newline, { buffer = buf })
  vim.keymap.set("i", "<C-j>", newline, { buffer = buf })
  -- A single Esc discards the whole comment.
  vim.keymap.set({ "i", "n" }, "<Esc>", function()
    finish(nil)
  end, { buffer = buf })
  vim.keymap.set({ "i", "n" }, "<C-c>", function()
    finish(nil)
  end, { buffer = buf })
  vim.keymap.set("n", "q", function()
    finish(nil)
  end, { buffer = buf })

  vim.cmd("startinsert")
  if #seed > 0 then
    vim.api.nvim_win_set_cursor(win, { #seed, #(seed[#seed] or "") })
  end
end

-- Finding anchored at a given diff buffer line (for edit/delete), or nil.
function M.find_at(bufline)
  local cursor = vim.api.nvim_win_get_cursor(State.diff_win)
  local anchor = require("diffvim.diff").anchor_at(bufline, cursor[2])
  if not anchor then
    return nil
  end
  local file = State:current_file()
  if not file then
    return nil
  end
  for _, f in ipairs(State.findings) do
    if f.file == file.path and f.side == anchor.side and anchor.file_line >= f.start_line and anchor.file_line <= f.end_line then
      return f
    end
  end
  return nil
end

local function bufline_for(side, file_line)
  return State.anchor_to_line[side .. ":" .. file_line]
end

-- Re-overlay every comment for the file currently in the diff pane.
function M.render()
  local buf = State.diff_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, State.ns_comment, 0, -1)

  local file = State:current_file()
  if not file then
    return
  end

  for _, f in ipairs(State:findings_for(file.path)) do
    -- gutter bar across the anchored range
    for fl = f.start_line, f.end_line do
      local bl = bufline_for(f.side, fl)
      if bl then
        vim.api.nvim_buf_set_extmark(buf, State.ns_comment, bl - 1, 0, {
          sign_text = "▌",
          sign_hl_group = "DiffVimCommentSign",
        })
      end
    end

    -- virt_lines comment block, anchored under the last line of the range
    local anchor_bl = bufline_for(f.side, f.end_line) or bufline_for(f.side, f.start_line)
    if anchor_bl then
      local virt = {}
      local body = vim.split(f.comment, "\n", { plain = true })
      local tag = f.existing and "  (prev)" or ""
      for i, line in ipairs(body) do
        local prefix = i == 1 and "  ▌ 💬 " or "  ▌    "
        local suffix = (i == #body) and tag or ""
        virt[#virt + 1] = { { prefix .. line .. suffix, "DiffVimComment" } }
      end
      vim.api.nvim_buf_set_extmark(buf, State.ns_comment, anchor_bl - 1, 0, {
        virt_lines = virt,
        virt_lines_above = false,
      })
    end
  end
end

local function refresh_after_change()
  M.render()
  require("diffvim.tree").refresh()
end

-- Add or edit a comment on the current cursor line.
function M.add_current()
  if State.diff_win ~= vim.api.nvim_get_current_win() then
    return
  end
  local bufline = vim.api.nvim_win_get_cursor(State.diff_win)[1]
  local existing = M.find_at(bufline)
  local cursor = vim.api.nvim_win_get_cursor(State.diff_win)
  local anchor = require("diffvim.diff").anchor_at(bufline, cursor[2])
  if not anchor then
    vim.notify("diff-vim: cannot comment on this line", vim.log.levels.WARN)
    return
  end

  local file = State:current_file()
  M.input({ title = existing and "Edit comment" or "Comment" }, existing and existing.comment or "", function(text)
    if not text then
      return
    end
    if existing then
      existing.comment = text
      existing.existing = false
    else
      table.insert(State.findings, {
        file = file.path,
        side = anchor.side,
        start_line = anchor.file_line,
        end_line = anchor.file_line,
        comment = text,
      })
    end
    refresh_after_change()
  end)
end

-- Add a comment spanning the current visual selection.
function M.add_visual()
  if State.diff_win ~= vim.api.nvim_get_current_win() then
    return
  end
  local a = vim.fn.line("v")
  local b = vim.fn.line(".")
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
  local lo, hi = math.min(a, b), math.max(a, b)

  -- Prefer additions; collect file_lines for the chosen side within range.
  local function collect(side)
    local fl = {}
    for bl = lo, hi do
      for _, anchor in ipairs(require("diffvim.diff").anchors_at(bl)) do
        if anchor.side == side and anchor.file_line then
          fl[#fl + 1] = anchor.file_line
        end
      end
    end
    return fl
  end

  local side = "additions"
  local fls = collect("additions")
  if #fls == 0 then
    side = "deletions"
    fls = collect("deletions")
  end
  if #fls == 0 then
    vim.notify("diff-vim: no commentable lines selected", vim.log.levels.WARN)
    return
  end
  table.sort(fls)
  local start_line, end_line = fls[1], fls[#fls]
  local file = State:current_file()

  vim.schedule(function()
    M.input({ title = string.format("Comment (lines %d-%d)", start_line, end_line) }, "", function(text)
      if not text then
        return
      end
      table.insert(State.findings, {
        file = file.path,
        side = side,
        start_line = start_line,
        end_line = end_line,
        comment = text,
      })
      refresh_after_change()
    end)
  end)
end

-- Delete the comment under the cursor.
function M.delete_current()
  if State.diff_win ~= vim.api.nvim_get_current_win() then
    return
  end
  local bufline = vim.api.nvim_win_get_cursor(State.diff_win)[1]
  local target = M.find_at(bufline)
  if not target then
    vim.notify("diff-vim: no comment here", vim.log.levels.INFO)
    return
  end
  for i, f in ipairs(State.findings) do
    if f == target then
      table.remove(State.findings, i)
      break
    end
  end
  refresh_after_change()
end

return M
