---@module "peek"
local api = vim.api
local lsp = vim.lsp
local util = vim.lsp.util
local M = {}

---@class PeekConfig
---@field width integer?   Lebar preview
---@field height integer?  Tinggi preview
---@field border string?   Style border: "rounded", "single", dsb.
---@field list_height integer? Tinggi list untuk multiple definitions
---@field show_line_preview boolean? Show line preview in list
---@type PeekConfig
M.config = {
  width = 80,
  height = 20,
  border = "rounded",
  list_height = 20,
  show_line_preview = true,
}

-- state
local float_win
local list_win

local function close()
  if float_win and api.nvim_win_is_valid(float_win) then
    api.nvim_win_close(float_win, true)
  end
  if list_win and api.nvim_win_is_valid(list_win) then
    api.nvim_win_close(list_win, true)
  end
  float_win = nil
  list_win = nil
end

local function close_list_only()
  if list_win and api.nvim_win_is_valid(list_win) then
    api.nvim_win_close(list_win, true)
  end
  list_win = nil
end

local function open_preview_from_loc(loc)
  M.last_location = loc
  local uri = loc.uri or loc.targetUri
  local range = loc.range or loc.targetSelectionRange
  local path = vim.uri_to_fname(uri)

  -- Check if file exists and is readable
  if vim.fn.filereadable(path) == 0 then
    vim.notify("File not readable: " .. path, vim.log.levels.WARN)
    return
  end

  local all = vim.fn.readfile(path)
  local s = math.max(1, range.start.line - 5)
  local e = math.min(#all, range["end"].line + 6)
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

  -- Highlight the target line
  local target_line = range.start.line - s + 1
  if target_line > 0 and target_line <= #lines then
    api.nvim_buf_add_highlight(buf, -1, "CursorLine", target_line - 1, 0, -1)
  end

  -- Set up keymaps
  local opts = { nowait = true, noremap = true, silent = true, buffer = buf }
  vim.keymap.set("n", "q", close, opts)
  vim.keymap.set("n", "<Esc>", close, opts)
  vim.keymap.set("n", "<CR>", function()
    close()
    if M.last_location then
      local uri = M.last_location.uri or M.last_location.targetUri
      local range = M.last_location.range or M.last_location.targetSelectionRange
      local bufnr = vim.uri_to_bufnr(uri)
      vim.fn.bufload(bufnr)
      api.nvim_set_current_buf(bufnr)
      api.nvim_win_set_cursor(0, { range.start.line + 1, range.start.character })
    end
  end, opts)

  -- Auto-close on cursor move
  api.nvim_create_autocmd("CursorMoved", {
    callback = function()
      local cur = api.nvim_get_current_win()
      if float_win and api.nvim_win_is_valid(float_win) and cur ~= float_win and
          (not list_win or cur ~= list_win) then
        close()
      end
    end,
  })
end

local function get_line_content(uri, line_num)
  local path = vim.uri_to_fname(uri)
  if vim.fn.filereadable(path) == 0 then
    return ""
  end

  local lines = vim.fn.readfile(path, "", line_num + 1)
  if #lines > line_num then
    return vim.trim(lines[line_num + 1])
  end
  return ""
end

local function create_definition_list(locs)
  local items = {}
  local max_filename_len = 0

  -- Prepare items with additional info
  for i, loc in ipairs(locs) do
    local uri = loc.uri or loc.targetUri
    local range = loc.range or loc.targetSelectionRange
    local path = vim.uri_to_fname(uri)
    local fname = vim.fn.fnamemodify(path, ":t")
    local dirname = vim.fn.fnamemodify(path, ":h:t")
    local line = range.start.line + 1
    local col = range.start.character + 1

    local line_content = ""
    if M.config.show_line_preview then
      line_content = get_line_content(uri, range.start.line)
      -- Truncate if too long
      if #line_content > 60 then
        line_content = line_content:sub(1, 57) .. "..."
      end
    end

    local item = {
      index = i,
      filename = fname,
      dirname = dirname,
      line = line,
      col = col,
      line_content = line_content,
      loc = loc,
      full_path = path,
    }

    max_filename_len = math.max(max_filename_len, #fname)
    table.insert(items, item)
  end

  -- Format display lines
  local display_lines = {}
  for _, item in ipairs(items) do
    local filename_padded = item.filename .. string.rep(" ", max_filename_len - #item.filename)
    local location_info = string.format("%s:%d:%d", filename_padded, item.line, item.col)

    local line_str = ""
    if M.config.show_line_preview and item.line_content ~= "" then
      line_str = string.format(" │ %s", item.line_content)
    end

    local dirname_info = ""
    if item.dirname ~= "." and item.dirname ~= "" then
      dirname_info = string.format(" (%s)", item.dirname)
    end

    local display = string.format("%d. %s%s%s", item.index, location_info, dirname_info, line_str)
    table.insert(display_lines, display)
  end

  return items, display_lines
end

local function open_definition_list(locs)
  local items, display_lines = create_definition_list(locs)

  -- Create buffer for the list
  local buf = api.nvim_create_buf(false, true)

  -- Set buffer options
  api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  api.nvim_buf_set_option(buf, "filetype", "peek-definitions")

  -- Set the content
  api.nvim_buf_set_lines(buf, 0, -1, false, display_lines)
  api.nvim_buf_set_option(buf, "modifiable", false)

  -- Calculate window size and position
  local width = math.min(50, vim.o.columns - 4)
  local height = math.min(M.config.list_height, #display_lines + 2)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  -- Create floating window
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    border = M.config.border,
    title = string.format(" Definitions (%d) ", #locs),
    title_pos = "center",
    style = "minimal",
  })

  list_win = win

  -- Set window options
  api.nvim_win_set_option(win, "cursorline", true)
  api.nvim_win_set_option(win, "wrap", false)

  -- Set up syntax highlighting
  vim.cmd([[
    syntax match PeekDefinitionIndex "^\d\+\." nextgroup=PeekDefinitionFile
    syntax match PeekDefinitionFile " \S\+:\d\+:\d\+" contained nextgroup=PeekDefinitionDir
    syntax match PeekDefinitionDir " ([^)]\+)" contained nextgroup=PeekDefinitionSeparator
    syntax match PeekDefinitionSeparator " │ " contained nextgroup=PeekDefinitionPreview
    syntax match PeekDefinitionPreview ".*$" contained

    highlight link PeekDefinitionIndex Number
    highlight link PeekDefinitionFile Identifier
    highlight link PeekDefinitionDir Comment
    highlight link PeekDefinitionSeparator Delimiter
    highlight link PeekDefinitionPreview String
  ]])

  -- Set up keymaps
  local function select_current()
    local line_num = api.nvim_win_get_cursor(win)[1]
    if line_num >= 1 and line_num <= #items then
      close_list_only()
      open_preview_from_loc(items[line_num].loc)
    end
  end

  local function goto_current()
    local line_num = api.nvim_win_get_cursor(win)[1]
    if line_num >= 1 and line_num <= #items then
      local item = items[line_num]
      close()
      local bufnr = vim.uri_to_bufnr(item.loc.uri or item.loc.targetUri)
      local range = item.loc.range or item.loc.targetSelectionRange
      vim.fn.bufload(bufnr)
      api.nvim_set_current_buf(bufnr)
      api.nvim_win_set_cursor(0, { range.start.line + 1, range.start.character })
    end
  end

  local opts = { nowait = true, noremap = true, silent = true, buffer = buf }
  vim.keymap.set("n", "<CR>", select_current, opts)
  vim.keymap.set("n", "<Space>", select_current, opts)
  vim.keymap.set("n", "o", goto_current, opts)
  vim.keymap.set("n", "q", close, opts)
  vim.keymap.set("n", "<Esc>", close, opts)

  -- Number keys for quick selection
  for i = 1, math.min(9, #items) do
    vim.keymap.set("n", tostring(i), function()
      if i <= #items then
        close_list_only()
        open_preview_from_loc(items[i].loc)
      end
    end, opts)
  end

  -- Auto-close on focus loss
  api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
    buffer = buf,
    once = true,
    callback = function()
      vim.defer_fn(function()
        if list_win and api.nvim_win_is_valid(list_win) and
            api.nvim_get_current_win() ~= list_win then
          close()
        end
      end, 50)
    end,
  })
end

local function pick_and_preview(locs)
  if #locs == 1 then
    return open_preview_from_loc(locs[1])
  end

  -- Use enhanced list UI for multiple definitions
  open_definition_list(locs)
end

function M.peek()
  local bufnr = api.nvim_get_current_buf()
  local clients = lsp.get_clients { bufnr = bufnr }
  if #clients == 0 then
    vim.notify("No LSP clients attached", vim.log.levels.WARN)
    return
  end

  local params = util.make_position_params(nil, clients[1].offset_encoding or "utf-16")
  lsp.buf_request(bufnr, "textDocument/definition", params, function(_, result)
    if not result or vim.tbl_isempty(result) then
      vim.notify("No definitions found", vim.log.levels.INFO)
      return
    end

    local locs = vim.islist(result) and result or { result }
    pick_and_preview(locs)
  end)
end

---@param opts PeekConfig?
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  -- Create user commands
  vim.api.nvim_create_user_command("PeekOpen", M.peek, { desc = "Open Peek Preview" })
  vim.api.nvim_create_user_command("PeekClose", close, { desc = "Close Peek Window" })

  -- Set up highlight groups if not exists
  vim.api.nvim_create_autocmd("ColorScheme", {
    pattern = "*",
    callback = function()
      vim.api.nvim_set_hl(0, "PeekDefinitionIndex", { link = "Number", default = true })
      vim.api.nvim_set_hl(0, "PeekDefinitionFile", { link = "Identifier", default = true })
      vim.api.nvim_set_hl(0, "PeekDefinitionDir", { link = "Comment", default = true })
      vim.api.nvim_set_hl(0, "PeekDefinitionSeparator", { link = "Delimiter", default = true })
      vim.api.nvim_set_hl(0, "PeekDefinitionPreview", { link = "String", default = true })
    end,
  })

  -- Initialize highlight groups
  vim.api.nvim_set_hl(0, "PeekDefinitionIndex", { link = "Number", default = true })
  vim.api.nvim_set_hl(0, "PeekDefinitionFile", { link = "Identifier", default = true })
  vim.api.nvim_set_hl(0, "PeekDefinitionDir", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "PeekDefinitionSeparator", { link = "Delimiter", default = true })
  vim.api.nvim_set_hl(0, "PeekDefinitionPreview", { link = "String", default = true })
end

return M
