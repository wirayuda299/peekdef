-- lua/peek.lua
---@module "peek"

local api = vim.api
local lsp = vim.lsp
local util = vim.lsp.util

local M = {}

---@class PeekConfig
---@field width integer?   Lebar preview
---@field height integer?  Tinggi preview
---@field border string?   Style border: "rounded", "single", dsb.

---@type PeekConfig
M.config = {
  width = 80,
  height = 20,
  border = "rounded",
}

-- state
local float_win

local function close()
  if float_win and api.nvim_win_is_valid(float_win) then
    api.nvim_win_close(float_win, true)
  end
  float_win = nil
end

local function open_preview_from_loc(loc)
  M.last_location = loc
  local uri = loc.uri or loc.targetUri
  local range = loc.range or loc.targetSelectionRange
  local path = vim.uri_to_fname(uri)
  local all = vim.fn.readfile(path)

  local s = math.max(1, range.start.line - 5)
  local e = range["end"].line + 5
  local lines = vim.list_slice(all, s, e)
  local ft = vim.fn.fnamemodify(path, ":e")

  local buf, win = util.open_floating_preview(lines, ft, {
    border = M.config.border,
    max_width = M.config.width,
    max_height = M.config.height,
    wrap = true,
    cursorline = true,
  })
  float_win = win

  api.nvim_buf_set_keymap(buf, "n", "q", "", { nowait = true, noremap = true, silent = true, callback = close })
  api.nvim_buf_set_keymap(buf, "n", "<Esc>", "", { nowait = true, noremap = true, silent = true, callback = close })
  api.nvim_buf_set_keymap(buf, "n", "<CR>", "", {
    nowait = true,
    noremap = true,
    silent = true,
    callback = function()
      close()
      if M.last_location then
        local uri = M.last_location.uri or M.last_location.targetUri
        local range = M.last_location.range or M.last_location.targetSelectionRange
        local bufnr = vim.uri_to_bufnr(uri)
        vim.fn.bufload(bufnr)
        api.nvim_set_current_buf(bufnr)
        api.nvim_win_set_cursor(0, { range.start.line + 1, range.start.character })
      end
    end,
  })

  api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = close,
  })
  api.nvim_create_autocmd("CursorMoved", {
    callback = function()
      local cur = api.nvim_get_current_win()
      if float_win and api.nvim_win_is_valid(float_win) and cur ~= float_win then
        close()
      end
    end,
  })
end

local function pick_and_preview(locs)
  if #locs == 1 then
    return open_preview_from_loc(locs[1])
  end

  local items = vim.tbl_map(function(loc)
    local uri = loc.uri or loc.targetUri
    local range = loc.range or loc.targetSelectionRange
    local fname = vim.fn.fnamemodify(vim.uri_to_fname(uri), ":t")
    local line = range.start.line + 1
    return {
      display = string.format("%s:%d", fname, line),
      loc = loc,
    }
  end, locs)

  vim.ui.select(items, {
    prompt = "Pilih definition:",
    format_item = function(item)
      return item.display
    end,
  }, function(choice)
    if choice then
      open_preview_from_loc(choice.loc)
    end
  end)
end

function M.peek()
  local bufnr = api.nvim_get_current_buf()
  local clients = lsp.get_clients { bufnr = bufnr }
  if #clients == 0 then
    return
  end

  local params = util.make_position_params(nil, clients[1].offset_encoding or "utf-16")
  lsp.buf_request(bufnr, "textDocument/definition", params, function(_, result)
    if not result or vim.tbl_isempty(result) then
      return
    end
    local locs = vim.tbl_islist(result) and result or { result }
    pick_and_preview(locs)
  end)
end

---@param opts PeekConfig?
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  vim.api.nvim_create_user_command("PeekOpen", M.peek, { desc = "Open Peek Preview" })
  vim.api.nvim_create_user_command("PeekClose", close, { desc = "Close Peek Window" })
end

return M
