-- Render a single file as either a unified or side-by-side diff in the diff buffer,
-- and build the bufline <-> (side, file_line) mapping used to anchor comments.
local State = require("diffvim.state")

local M = {}

local function parse_header(line)
  -- @@ -oldStart[,oldCount] +newStart[,newCount] @@ ...
  local old_start, new_start = line:match("@@ %-(%d+),?%d* %+(%d+),?%d* @@")
  return tonumber(old_start), tonumber(new_start)
end

local function truncated(text, width)
  text = text or ""
  if #text <= width then
    return text .. string.rep(" ", width - #text)
  end
  return text:sub(1, math.max(0, width - 1)) .. "~"
end

local function split_unified(file)
  local before = file.before or ""
  local after = file.after or ""

  if before == after then
    return nil
  end

  local unified = vim.diff(before, after, { result_type = "unified", ctxlen = 3 }) or ""
  if unified == "" then
    return nil
  end

  return vim.split(unified, "\n", { plain = true })
end

local function push_file_header(lines, meta, file)
  lines[#lines + 1] = string.format("  %s", file.path)
  meta[#meta + 1] = { kind = "title" }
  lines[#lines + 1] = string.format("  +%d  -%d   %s", file.additions or 0, file.deletions or 0, file.status or "modified")
  meta[#meta + 1] = { kind = "subtitle" }
  lines[#lines + 1] = ""
  meta[#meta + 1] = { kind = "blank" }
end

local function unified_line(old_no, new_no, prefix, text)
  return string.format("%6s | %6s | %s%s", old_no or "", new_no or "", prefix, text or "")
end

local function build_unified(file)
  local unified = split_unified(file)

  local lines = {}
  local meta = {}
  local function push(text, m)
    lines[#lines + 1] = text
    meta[#meta + 1] = m
  end

  push_file_header(lines, meta, file)

  if not unified then
    push("  (no textual changes)", { kind = "blank" })
    return lines, meta
  end

  local old_ln, new_ln = 0, 0
  for _, raw in ipairs(unified) do
    local first = raw:sub(1, 1)
    if raw == "" then
      -- trailing empty from split; skip
    elseif first == "@" then
      local o, n = parse_header(raw)
      old_ln = o or old_ln
      new_ln = n or new_ln
      push(raw, { kind = "header" })
    elseif first == "+" then
      push(unified_line(nil, new_ln, "+", raw:sub(2)), { kind = "add", side = "additions", file_line = new_ln })
      new_ln = new_ln + 1
    elseif first == "-" then
      push(unified_line(old_ln, nil, "-", raw:sub(2)), { kind = "del", side = "deletions", file_line = old_ln })
      old_ln = old_ln + 1
    else
      -- context line (leading space) or "\ No newline at end of file"
      if first == "\\" then
        push(raw, { kind = "note" })
      else
        push(unified_line(old_ln, new_ln, " ", raw:sub(2)), { kind = "context", side = "additions", file_line = new_ln })
        old_ln = old_ln + 1
        new_ln = new_ln + 1
      end
    end
  end

  return lines, meta
end

local function side_width()
  local total = 120
  if State.diff_win and vim.api.nvim_win_is_valid(State.diff_win) then
    total = vim.api.nvim_win_get_width(State.diff_win)
  end
  return math.max(24, math.floor((total - 25) / 2))
end

local function build_side_by_side(file)
  local unified = split_unified(file)

  local lines = {}
  local meta = {}
  push_file_header(lines, meta, file)

  if not unified then
    lines[#lines + 1] = "  (no textual changes)"
    meta[#meta + 1] = { kind = "blank" }
    return lines, meta
  end

  local width = side_width()
  local pending_del = {}

  local function push_row(left, right)
    local left_no = left and tostring(left.file_line) or ""
    local right_no = right and tostring(right.file_line) or ""
    local left_text = left and ((left.kind == "del" and "- " or "  ") .. left.text) or ""
    local right_text = right and ((right.kind == "add" and "+ " or "  ") .. right.text) or ""
    local left_cell = truncated(left_text, width)
    local right_cell = truncated(right_text, width)
    local line = string.format("%6s | %s | %6s | %s", left_no, left_cell, right_no, right_cell)
    local left_start = 9
    local right_start = 9 + width + 12

    lines[#lines + 1] = line
    meta[#meta + 1] = {
      kind = "side",
      left = left,
      right = right,
      left_start = left_start,
      left_end = left_start + width,
      right_start = right_start,
      right_end = right_start + width,
    }
    State.side_split_col = right_start
  end

  local function flush_deletions()
    while #pending_del > 0 do
      push_row(table.remove(pending_del, 1), nil)
    end
  end

  local old_ln, new_ln = 0, 0
  for _, raw in ipairs(unified) do
    local first = raw:sub(1, 1)
    if raw == "" then
      -- trailing empty from split; skip
    elseif first == "@" then
      flush_deletions()
      local o, n = parse_header(raw)
      old_ln = o or old_ln
      new_ln = n or new_ln
      lines[#lines + 1] = raw
      meta[#meta + 1] = { kind = "header" }
    elseif first == "-" then
      pending_del[#pending_del + 1] = {
        kind = "del",
        side = "deletions",
        file_line = old_ln,
        text = raw:sub(2),
      }
      old_ln = old_ln + 1
    elseif first == "+" then
      local right = {
        kind = "add",
        side = "additions",
        file_line = new_ln,
        text = raw:sub(2),
      }
      push_row(table.remove(pending_del, 1), right)
      new_ln = new_ln + 1
    else
      flush_deletions()
      if first == "\\" then
        lines[#lines + 1] = raw
        meta[#meta + 1] = { kind = "note" }
      else
        local text = raw:sub(2)
        push_row({ kind = "context", side = "deletions", file_line = old_ln, text = text }, {
          kind = "context",
          side = "additions",
          file_line = new_ln,
          text = text,
        })
        old_ln = old_ln + 1
        new_ln = new_ln + 1
      end
    end
  end
  flush_deletions()

  return lines, meta
end

-- Returns lines (array of strings) and meta (parallel array, 1-based).
function M.build(file)
  State.side_split_col = nil
  if State.view_mode == "side_by_side" then
    return build_side_by_side(file)
  end
  return build_unified(file)
end

-- Render the file at State.current into the diff buffer.
function M.render()
  local file = State:current_file()
  if not file then
    return
  end

  local lines, meta = M.build(file)

  State.meta = meta
  State.anchor_to_line = {}
  for i, m in ipairs(meta) do
    if m.file_line then
      State.anchor_to_line[m.side .. ":" .. m.file_line] = i
    end
    if m.left and m.left.file_line then
      State.anchor_to_line[m.left.side .. ":" .. m.left.file_line] = i
    end
    if m.right and m.right.file_line then
      State.anchor_to_line[m.right.side .. ":" .. m.right.file_line] = i
    end
  end

  local buf = State.diff_buf
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- line highlights
  vim.api.nvim_buf_clear_namespace(buf, State.ns_diff, 0, -1)
  for i, m in ipairs(meta) do
    local hl
    if m.kind == "add" then
      hl = "DiffVimAdd"
    elseif m.kind == "del" then
      hl = "DiffVimDel"
    elseif m.kind == "header" then
      hl = "DiffVimHeader"
    elseif m.kind == "title" then
      hl = "DiffVimTitle"
    elseif m.kind == "subtitle" then
      hl = "DiffVimSubtitle"
    end
    if hl then
      vim.api.nvim_buf_set_extmark(buf, State.ns_diff, i - 1, 0, {
        line_hl_group = hl,
      })
    end
    if m.kind == "side" then
      if m.left and m.left.kind == "del" then
        vim.api.nvim_buf_set_extmark(buf, State.ns_diff, i - 1, m.left_start, {
          end_col = m.left_end,
          hl_group = "DiffVimDel",
        })
      end
      if m.right and m.right.kind == "add" then
        vim.api.nvim_buf_set_extmark(buf, State.ns_diff, i - 1, m.right_start, {
          end_col = m.right_end,
          hl_group = "DiffVimAdd",
        })
      end
    end
  end

  -- winbar / title
  if State.diff_win and vim.api.nvim_win_is_valid(State.diff_win) then
    vim.wo[State.diff_win].winbar =
      "%#DiffVimWinbar# a:comment  v+a:range  ^h/^l:panes  <leader>ss:" .. (State.view_mode == "side_by_side" and "unified" or "side") .. "  <leader>s:note  <leader>y:submit "
  end

  -- overlay comments for this file
  require("diffvim.comments").render()

  -- park the cursor on the first real diff line
  if State.diff_win and vim.api.nvim_win_is_valid(State.diff_win) then
    for i, m in ipairs(meta) do
      if m.kind == "add" or m.kind == "del" or m.kind == "context" or m.kind == "side" then
        pcall(vim.api.nvim_win_set_cursor, State.diff_win, { i, 0 })
        break
      end
    end
  end
end

-- Resolve the comment anchor (side, file_line) for a given buffer line.
function M.anchor_at(bufline, col)
  local m = State.meta[bufline]
  if not m or not m.file_line then
    if not m or m.kind ~= "side" then
      return nil
    end
    local prefer_right = col == nil or col >= (m.right_start or State.side_split_col or 0)
    local anchor = prefer_right and m.right or m.left
    anchor = anchor or m.right or m.left
    if not anchor or not anchor.file_line then
      return nil
    end
    return { side = anchor.side, file_line = anchor.file_line }
  end
  return { side = m.side, file_line = m.file_line }
end

function M.anchors_at(bufline)
  local m = State.meta[bufline]
  if not m then
    return {}
  end
  if m.file_line then
    return { { side = m.side, file_line = m.file_line } }
  end
  if m.kind ~= "side" then
    return {}
  end
  local anchors = {}
  if m.right and m.right.file_line then
    anchors[#anchors + 1] = { side = m.right.side, file_line = m.right.file_line }
  end
  if m.left and m.left.file_line then
    anchors[#anchors + 1] = { side = m.left.side, file_line = m.left.file_line }
  end
  return anchors
end

function M.toggle_view()
  if State.view_mode == "side_by_side" then
    State.view_mode = "unified"
  else
    State.view_mode = "side_by_side"
  end
  M.render()
  vim.notify("diff-vim: " .. (State.view_mode == "side_by_side" and "side-by-side" or "unified") .. " view", vim.log.levels.INFO)
end

return M
