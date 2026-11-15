--- null-ls (none-ls) completion source offering the current Codex suggestion.
---
--- The source never starts requests itself. It waits for the suggestion the
--- plugin produces through its usual automatic or manual triggers, so the
--- entry reaches any LSP completion client, including nvim-cmp.

local M = {}

--- LSP has no custom kinds; Event is rarely used by language servers.
local event_kind = 23
local marker = "Codex"
--- Long enough for nvim-cmp to list an answer it accepted.
local menu_delay_ms = 150
local plain_text_format = 1
local label_limit = 60
local registered = false

--- Converts a byte column to the client's position encoding.
---
---@param line string
---@param byte_col integer
---@param encoding string
---@return integer character
---
local function character(line, byte_col, encoding)
  byte_col = math.min(byte_col, #line)
  if encoding == "utf-8" then
    return byte_col
  end
  local utf32, utf16 = vim.str_utfindex(line, byte_col)
  return encoding == "utf-32" and utf32 or utf16
end

--- Builds a completion item replacing the typed keyword with the suggestion.
---
---@param captured table Context the suggestion was generated for.
---@param completion string Text to insert at the captured cursor.
---@param replace_length integer|nil Bytes after the cursor the suggestion replaces.
---@param encoding string|nil Position encoding; UTF-16 by default.
---@return table|nil item
---
function M.item(captured, completion, replace_length, encoding)
  encoding = encoding or "utf-16"
  local line = vim.api.nvim_buf_get_lines(captured.bufnr, captured.row - 1, captured.row, false)[1] or ""
  local start_col = line:sub(1, captured.col):find("[%w_]*$") - 1
  local text = line:sub(start_col + 1, captured.col) .. completion
  local label = vim.trim(text:match("[^\n]*%S[^\n]*") or "")
  if label == "" then
    return nil
  end
  if #label > label_limit then
    label = vim.fn.strcharpart(label, 0, label_limit) .. "…"
  elseif text:find("\n", 1, true) then
    label = label .. " …"
  end
  return {
    label = label,
    kind = event_kind,
    detail = marker .. " suggestion",
    labelDetails = { description = marker },
    data = { codex_complete = true },
    filterText = text,
    insertTextFormat = plain_text_format,
    textEdit = {
      newText = text,
      range = {
        start = { line = captured.row - 1, character = character(line, start_col, encoding) },
        ["end"] = {
          line = captured.row - 1,
          character = character(line, captured.col + (replace_length or 0), encoding),
        },
      },
    },
    documentation = {
      kind = "markdown",
      value = ("```%s\n%s\n```"):format(captured.filetype or "", text),
    },
  }
end

--- Tells whether a completion item came from this plugin.
---
---@param entry table nvim-cmp entry.
---@return boolean codex
---
local function is_codex(entry)
  local data = entry and entry.completion_item and entry.completion_item.data
  return type(data) == "table" and data.codex_complete == true
end

--- Marks Codex entries in an nvim-cmp menu with their own kind.
---
--- Call it from `formatting.format` after any existing formatter.
---
---@param entry table nvim-cmp entry.
---@param item table Menu item being formatted.
---@param label string|nil Kind text, such as an icon followed by a name.
---@return table item
---
function M.cmp_format(entry, item, label)
  if is_codex(entry) then
    item.kind = label or marker
    item.kind_hl_group = "CodexCompleteKind"
    item.menu = nil
  end
  return item
end

--- Opens the nvim-cmp menu showing only the Codex suggestion.
---
---@return boolean opened
---
function M.open_menu()
  local cmp = package.loaded["cmp"]
  if not cmp or vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i" then
    return false
  end
  cmp.complete({ config = { sources = { { name = "nvim_lsp", entry_filter = is_codex } } } })
  return true
end

--- Opens the menu shortly after a suggestion arrives unless nvim-cmp already lists it.
---
--- nvim-cmp only asks for completions while a word or trigger character is
--- typed, and drops answers to requests made before the latest keystroke.
---
---@param captured table Context of the suggestion.
---
function M.ensure_menu(captured)
  if not package.loaded["cmp"] then
    return
  end
  vim.defer_fn(function()
    local cmp = package.loaded["cmp"]
    local visible = require("codex_complete.ui").current()
    if not cmp or not visible or visible.context ~= captured then
      return
    end
    if not require("codex_complete.context").is_current(captured) then
      return
    end
    for _, entry in ipairs(cmp.get_entries()) do
      if is_codex(entry) then
        return
      end
    end
    M.open_menu()
  end, menu_delay_ms)
end

--- Answers a null-ls completion request once a suggestion is available.
---
---@param params table null-ls generator parameters.
---@param done fun(results: table[])
---@param encoding string|nil Position encoding of the null-ls client.
---
function M.complete(params, done, encoding)
  require("codex_complete")._await_suggestion(function(captured, completion, replace_length)
    local item = captured and captured.bufnr == params.bufnr and M.item(captured, completion, replace_length, encoding)
    done({ { items = item and { item } or {}, isIncomplete = true } })
  end)
end

--- Registers the completion source when null-ls is installed.
---
---@return boolean registered
---
function M.register()
  if registered then
    return true
  end
  local ok, null_ls = pcall(require, "null-ls")
  if not ok then
    return false
  end
  null_ls.register({
    name = "codex_complete",
    method = null_ls.methods.COMPLETION,
    filetypes = {},
    generator = {
      async = true,
      fn = function(params, done)
        M.complete(params, done, require("null-ls.client").get_offset_encoding())
      end,
    },
  })
  registered = true
  return true
end

return M
