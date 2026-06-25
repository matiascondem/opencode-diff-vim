-- opencode-diff-vim :: Neovim review app entrypoint.
-- Launched by the opencode plugin via:
--   nvim --env NVIM_APPNAME=diff-vim -u <repo>/nvim/init.lua
-- This file is intentionally self-contained: no external plugins, no user config.

-- Match the author's muscle memory.
vim.g.mapleader = " "
vim.g.maplocalleader = " "

-- Make the repo's lua/ importable regardless of cwd.
local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":h") -- <repo>/nvim
vim.opt.runtimepath:prepend(root)

-- Sensible, quiet defaults for a read-only review surface.
vim.opt.termguicolors = true
vim.opt.number = false
vim.opt.relativenumber = false
vim.opt.signcolumn = "yes:1"
vim.opt.wrap = false
vim.opt.swapfile = false
vim.opt.laststatus = 3
vim.opt.cmdheight = 1
vim.opt.fillchars:append({ eob = " " })
vim.opt.scrolloff = 6
vim.opt.mouse = ""

local ok, err = pcall(function()
  require("diffvim").start()
end)

if not ok then
  vim.schedule(function()
    vim.api.nvim_echo({ { "diff-vim failed to start: " .. tostring(err), "ErrorMsg" } }, true, {})
  end)
end
