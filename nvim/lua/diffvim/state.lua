-- Shared application state. A single table passed around the modules.
local State = {
  cfg = {
    payload_file = nil, -- path to payload json (written by the plugin)
    submit_url = nil, -- full POST url incl ?token=... ; nil => mock mode
    result_file = nil, -- mock mode: where to write the result json
  },

  payload = nil, -- decoded payload table
  files = {}, -- payload.files : { {path,status,additions,deletions,before,after}, ... }
  tree_rows = {}, -- visible rows in the changed-files tree

  -- Findings the user creates this session: { {file, side, start_line, end_line, comment}, ... }
  findings = {},
  notes = "", -- the <leader>s overall review comment

  current = 1, -- index into files of the file shown in the diff pane
  view_mode = "unified", -- "unified" or "side_by_side"
  submitted = false,

  -- windows / buffers
  tree_win = nil,
  tree_buf = nil,
  diff_win = nil,
  diff_buf = nil,

  -- namespaces
  ns_diff = nil, -- diff line highlights
  ns_comment = nil, -- inline comment extmarks
  ns_tree = nil, -- changed-files tree highlights

  -- per-render bookkeeping for the file currently in the diff pane
  meta = {}, -- meta[bufline] = { kind = "add"|"del"|"context"|"header"|"title", side, file_line }
  anchor_to_line = {}, -- ["<side>:<file_line>"] = bufline (last occurrence)
  side_split_col = nil, -- 0-based column where the right side starts in side-by-side mode
}

function State.current_file(self)
  return self.files[self.current]
end

-- Count findings for a given file path.
function State.count_for(self, path)
  local n = 0
  for _, f in ipairs(self.findings) do
    if f.file == path then
      n = n + 1
    end
  end
  return n
end

-- Findings belonging to a file path.
function State.findings_for(self, path)
  local out = {}
  for _, f in ipairs(self.findings) do
    if f.file == path then
      out[#out + 1] = f
    end
  end
  return out
end

return State
