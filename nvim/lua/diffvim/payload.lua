-- Loading the review payload and shipping the result back out.
local State = require("diffvim.state")

local M = {}

local function read_file(path)
  local fd = io.open(path, "r")
  if not fd then
    return nil, "cannot open " .. path
  end
  local data = fd:read("*a")
  fd:close()
  return data
end

-- Populate State.cfg from the environment the plugin set on the kitty tab.
function M.load_cfg()
  State.cfg.payload_file = vim.env.DIFF_VIM_PAYLOAD
  State.cfg.submit_url = vim.env.DIFF_VIM_SUBMIT_URL
  State.cfg.result_file = vim.env.DIFF_VIM_RESULT
end

-- Read + decode the payload file written by the plugin.
function M.load()
  if not State.cfg.payload_file or State.cfg.payload_file == "" then
    error("DIFF_VIM_PAYLOAD is not set")
  end
  local raw, err = read_file(State.cfg.payload_file)
  if not raw then
    error(err)
  end
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok then
    error("failed to parse payload json: " .. tostring(decoded))
  end
  State.payload = decoded
  State.files = decoded.files or {}

  -- Seed any pre-existing open findings from prior rounds so they stay visible.
  for _, f in ipairs(decoded.existing_findings or {}) do
    State.findings[#State.findings + 1] = {
      id = f.id,
      file = f.file,
      side = f.side or "additions",
      start_line = f.start_line,
      end_line = f.end_line,
      comment = f.comment or "",
      existing = true,
    }
  end
  State.notes = (decoded.draft and decoded.draft.notes) or ""
  return decoded
end

-- Serialize the review and send it back to the waiting opencode tool.
-- Returns ok, message.
function M.submit()
  local body = vim.json.encode({
    notes = State.notes or "",
    new_findings = vim.tbl_map(function(f)
      return {
        file = f.file,
        side = f.side,
        start_line = f.start_line,
        end_line = f.end_line,
        comment = f.comment,
      }
    end, vim.tbl_filter(function(f)
      return not f.existing
    end, State.findings)),
  })

  -- Mock mode: no server, just drop a result file (or no-op) so the UX is testable.
  if not State.cfg.submit_url or State.cfg.submit_url == "" then
    if State.cfg.result_file and State.cfg.result_file ~= "" then
      local fd = io.open(State.cfg.result_file, "w")
      if fd then
        fd:write(body)
        fd:close()
      end
    end
    return true, "mock: review written"
  end

  local tmp = vim.fn.tempname()
  local fd = io.open(tmp, "w")
  if not fd then
    return false, "could not write temp body"
  end
  fd:write(body)
  fd:close()

  local result = vim.system({
    "curl",
    "-s",
    "-S",
    "-o",
    "/dev/null",
    "-w",
    "%{http_code}",
    "-X",
    "POST",
    State.cfg.submit_url,
    "-H",
    "content-type: application/json",
    "--data-binary",
    "@" .. tmp,
  }, { text = true }):wait()

  os.remove(tmp)

  if result.code ~= 0 then
    return false, "curl failed: " .. (result.stderr or "")
  end
  local code = tonumber((result.stdout or ""):match("%d+"))
  if code ~= 200 then
    return false, "server returned HTTP " .. tostring(code)
  end
  return true, "submitted"
end

-- Best-effort signal that the user closed the review without submitting,
-- so the plugin's await can resolve as a cancel instead of hanging.
function M.cancel()
  if State.submitted then
    return
  end
  if not State.cfg.submit_url or State.cfg.submit_url == "" then
    return
  end
  local url = State.cfg.submit_url:gsub("/submit", "/cancel")
  pcall(function()
    vim.system({
      "curl",
      "-s",
      "-o",
      "/dev/null",
      "-X",
      "POST",
      url,
      "-H",
      "content-type: application/json",
      "--data-binary",
      "{}",
    }):wait(2000)
  end)
end

return M
