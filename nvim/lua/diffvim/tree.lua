-- The left-hand changed-files tree.
local State = require("diffvim.state")

local M = {}

local STATUS_ICON = {
  added = "",
  deleted = "",
  modified = "",
}

local function line_for(file)
  local icon = STATUS_ICON[file.status] or ""
  local n = State:count_for(file.path)
  local badge = n > 0 and string.format("  ●%d", n) or ""
  return string.format(" %s %s   +%d -%d%s", icon, file.path, file.additions or 0, file.deletions or 0, badge)
end

function M.render()
  local buf = State.tree_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local lines = {}
  for _, file in ipairs(State.files) do
    lines[#lines + 1] = line_for(file)
  end
  if #lines == 0 then
    lines = { " (no changed files)" }
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  M.highlight()
end

function M.highlight()
  local buf = State.tree_buf
  vim.api.nvim_buf_clear_namespace(buf, State.ns_tree, 0, -1)
  for i, file in ipairs(State.files) do
    local hl
    if file.status == "added" then
      hl = "DiffVimTreeAdd"
    elseif file.status == "deleted" then
      hl = "DiffVimTreeDel"
    end
    if hl then
      vim.api.nvim_buf_set_extmark(buf, State.ns_tree, i - 1, 1, {
        end_col = 3,
        hl_group = hl,
      })
    end
  end
  -- selected row
  if State.files[State.current] then
    vim.api.nvim_buf_set_extmark(buf, State.ns_tree, State.current - 1, 0, {
      line_hl_group = "DiffVimTreeSel",
    })
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
    pcall(vim.api.nvim_win_set_cursor, State.tree_win, cur)
  end
end

-- Open the file under the tree cursor in the diff pane.
function M.open_under_cursor()
  if not (State.tree_win and vim.api.nvim_win_is_valid(State.tree_win)) then
    return
  end
  local row = vim.api.nvim_win_get_cursor(State.tree_win)[1]
  if not State.files[row] then
    return
  end
  if row == State.current then
    return
  end
  State.current = row
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
  if State.tree_win and vim.api.nvim_win_is_valid(State.tree_win) then
    pcall(vim.api.nvim_win_set_cursor, State.tree_win, { State.current, 0 })
  end
  M.highlight()
  require("diffvim.diff").render()
end

return M
