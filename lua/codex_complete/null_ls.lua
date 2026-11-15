--- null-ls (none-ls) completion source offering the current Codex suggestion.
---
--- The source never starts requests itself. It waits for the suggestion the
--- plugin produces through its usual automatic or manual triggers, so the
--- entry reaches any LSP completion client, including nvim-cmp.

local M = {}

local text_kind = 1
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
    kind = text_kind,
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
