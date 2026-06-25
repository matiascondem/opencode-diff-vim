-- The <leader>s final-comment step and the <leader>y submit-everything step.
local State = require("diffvim.state")
local payload = require("diffvim.payload")

local M = {}

function M.edit_notes()
  require("diffvim.comments").input(
    { title = "Final review comment", height = 6, width = 72 },
    State.notes,
    function(text)
      State.notes = text or ""
      if State.notes ~= "" then
        vim.notify("diff-vim: review note saved (press <leader>y to submit)", vim.log.levels.INFO)
      end
    end
  )
end

local function count_new()
  local n = 0
  for _, f in ipairs(State.findings) do
    if not f.existing then
      n = n + 1
    end
  end
  return n
end

function M.submit()
  local new = count_new()
  local has_notes = State.notes ~= nil and State.notes ~= ""
  if new == 0 and not has_notes then
    local choice = vim.fn.confirm("Submit an empty review (no comments, no note)?", "&Yes\n&No", 2)
    if choice ~= 1 then
      return
    end
  end

  local ok, msg = payload.submit()
  if not ok then
    vim.notify("diff-vim: submit failed — " .. tostring(msg), vim.log.levels.ERROR)
    return
  end
  State.submitted = true
  vim.notify("diff-vim: submitted (" .. new .. " comments)", vim.log.levels.INFO)
  vim.schedule(function()
    vim.cmd("qa!")
  end)
end

return M
