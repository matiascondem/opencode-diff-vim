-- diff-vim Neovim review app — orchestration entrypoint.
local M = {}

function M.start()
  local payload = require("diffvim.payload")
  payload.load_cfg()
  payload.load()
  require("diffvim.ui").build()
end

return M
