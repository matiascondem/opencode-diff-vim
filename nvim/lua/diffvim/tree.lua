-- The left-hand changed-files tree.
local State = require("diffvim.state")

local M = {}

local STATUS_ICON = {
  added = "+",
  deleted = "-",
  modified = "~",
}

local function split_path(path)
  local parts = {}
  for part in path:gmatch("[^/]+") do
    parts[#parts + 1] = part
  end
  return parts
end

local function node_path(parent, name)
  if parent == "" then
    return name
  end
  return parent .. "/" .. name
end

local function build_tree()
  local root = { type = "dir", name = "", path = "", children = {} }

  for file_index, file in ipairs(State.files) do
    local cursor = root
    local parts = split_path(file.path)
    for i, part in ipairs(parts) do
      local is_file = i == #parts
      local path = node_path(cursor.path, part)
      cursor.children[part] = cursor.children[part] or {
        type = is_file and "file" or "dir",
        name = part,
        path = path,
        children = {},
      }
      cursor = cursor.children[part]
      if is_file then
        cursor.type = "file"
        cursor.file = file
        cursor.file_index = file_index
      end
    end
  end

  return root
end

local function sorted_children(node)
  local children = {}
  for _, child in pairs(node.children or {}) do
    children[#children + 1] = child
  end
  table.sort(children, function(a, b)
    if a.type ~= b.type then
      return a.type == "dir"
    end
    return a.name < b.name
  end)
  return children
end

local function repo_name()
  local root = State.payload and State.payload.repo_root
  if not root or root == "" then
    return "changes"
  end
  return vim.fn.fnamemodify(root, ":t")
end

local function file_line(node, depth)
  local file = node.file
  local icon = STATUS_ICON[file.status] or "~"
  local n = State:count_for(file.path)
  local badge = n > 0 and string.format("  ●%d", n) or ""
  return string.format("%s  %s %s  +%d -%d%s", string.rep("  ", depth), icon, node.name, file.additions or 0, file.deletions or 0, badge)
end

local function push_rows(lines, node, depth)
  for _, child in ipairs(sorted_children(node)) do
    if child.type == "dir" then
      State.tree_rows[#State.tree_rows + 1] = { type = "dir", path = child.path }
      lines[#lines + 1] = string.format("%s▾ %s", string.rep("  ", depth), child.name)
      push_rows(lines, child, depth + 1)
    else
      State.tree_rows[#State.tree_rows + 1] = { type = "file", file_index = child.file_index, path = child.path }
      lines[#lines + 1] = file_line(child, depth)
    end
  end
end

local function visible_row_for_file(file_index)
  for row, item in ipairs(State.tree_rows) do
    if item.type == "file" and item.file_index == file_index then
      return row
    end
  end
  return nil
end

function M.render()
  local buf = State.tree_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local lines = {}
  State.tree_rows = {}

  if #State.files == 0 then
    State.tree_rows[#State.tree_rows + 1] = { type = "empty" }
    lines = { " (no changed files)" }
  else
    State.tree_rows[#State.tree_rows + 1] = { type = "header" }
    lines[#lines + 1] = "▾ " .. repo_name()
    push_rows(lines, build_tree(), 1)
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  M.highlight()
end

function M.highlight()
  local buf = State.tree_buf
  vim.api.nvim_buf_clear_namespace(buf, State.ns_tree, 0, -1)

  for i, row in ipairs(State.tree_rows) do
    local line = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
    if row.type == "file" then
      local file = State.files[row.file_index]
      local hl
      if file.status == "added" then
        hl = "DiffVimTreeAdd"
      elseif file.status == "deleted" then
        hl = "DiffVimTreeDel"
      end
      if hl then
        vim.api.nvim_buf_set_extmark(buf, State.ns_tree, i - 1, 0, {
          end_col = #line,
          hl_group = hl,
        })
      end
      if row.file_index == State.current then
        vim.api.nvim_buf_set_extmark(buf, State.ns_tree, i - 1, 0, {
          line_hl_group = "DiffVimTreeSel",
        })
      end
    elseif row.type == "dir" or row.type == "header" then
      vim.api.nvim_buf_set_extmark(buf, State.ns_tree, i - 1, 0, {
        end_col = #line,
        hl_group = "DiffVimTreeDir",
      })
    end
  end
end

-- Re-render keeping the cursor where it is (used after comment count changes).
function M.refresh()
  local buf = State.tree_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local cur
  if State.tree_win and vim.api.nvim_win_is_valid(State.tree_win) then
    cur = vim.api.nvim_win_get_cursor(State.tree_win)
  end
  M.render()
  if cur then
    local row = math.min(cur[1], #State.tree_rows)
    pcall(vim.api.nvim_win_set_cursor, State.tree_win, { row, cur[2] })
  end
end

-- Open the file under the tree cursor in the diff pane.
function M.open_under_cursor()
  if not (State.tree_win and vim.api.nvim_win_is_valid(State.tree_win)) then
    return
  end
  local row_num = vim.api.nvim_win_get_cursor(State.tree_win)[1]
  local row = State.tree_rows[row_num]
  if not row then
    return
  end
  if row.type ~= "file" then
    return
  end
  if row.file_index == State.current then
    return
  end
  State.current = row.file_index
  M.highlight()
  require("diffvim.diff").render()
end

function M.focus()
  if State.tree_win and vim.api.nvim_win_is_valid(State.tree_win) then
    vim.api.nvim_set_current_win(State.tree_win)
  end
end

-- Jump to next/prev file from anywhere.
function M.cycle(delta)
  local n = #State.files
  if n == 0 then
    return
  end
  State.current = ((State.current - 1 + delta) % n) + 1
  M.render()
  if State.tree_win and vim.api.nvim_win_is_valid(State.tree_win) then
    local row = visible_row_for_file(State.current)
    if row then
      pcall(vim.api.nvim_win_set_cursor, State.tree_win, { row, 0 })
    end
  end
  require("diffvim.diff").render()
end

return M
