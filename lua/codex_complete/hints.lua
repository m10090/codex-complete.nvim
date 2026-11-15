--- Language-server facts gathered for the cursor before a request is sent.
---
--- Asking the servers up front keeps the model to a single round trip.

local M = {}

local new_api = vim.fn.has("nvim-0.11") == 1
local hover_limit = 600
local label_limit = 80
local message_limit = 300
local diagnostic_rows = 10
local max_diagnostics = 5

--- Calls a client method across the Neovim 0.10 and 0.11 calling conventions.
---
---@param client table
---@param method string
---@return any ...
---
local function call(client, method, ...)
  if new_api then
    return client[method](client, ...)
  end
  return client[method](...)
end

--- Truncates text to a byte limit without splitting a character.
---
---@param value string
---@param limit integer
---@return string clipped
---
local function clip(value, limit)
  if #value <= limit then
    return value
  end
  return (value:sub(1, limit):gsub("[\194-\244][\128-\191]*$", "")) .. "…"
end

--- Converts a byte column to a client's position encoding.
---
---@param client table
---@param line string
---@param byte_col integer
---@return integer character
---
local function character(client, line, byte_col)
  local encoding = client.offset_encoding or "utf-16"
  byte_col = math.min(byte_col, #line)
  if encoding == "utf-8" then
    return byte_col
  end
  if new_api then
    return vim.str_utfindex(line, encoding, byte_col, false)
  end
  local utf32, utf16 = vim.str_utfindex(line, byte_col)
  return encoding == "utf-32" and utf32 or utf16
end

--- Flattens hover contents of any protocol shape into plain text.
---
---@param contents any
---@return string text
---
local function hover_text(contents)
  local ok, lines = pcall(vim.lsp.util.convert_input_to_markdown_lines, contents)
  if not ok or type(lines) ~= "table" then
    return ""
  end
  return vim.trim(table.concat(lines, "\n"))
end

--- Collects diagnostics close to the cursor.
---
---@param bufnr integer
---@param row integer Zero-based cursor row.
---@return table[]|nil diagnostics
---
local function nearby_diagnostics(bufnr, row)
  local found = {}
  for _, diagnostic in ipairs(vim.diagnostic.get(bufnr)) do
    if #found >= max_diagnostics then
      break
    end
    if math.abs(diagnostic.lnum - row) <= diagnostic_rows then
      found[#found + 1] = {
        line = diagnostic.lnum + 1,
        severity = (vim.diagnostic.severity[diagnostic.severity] or "ERROR"):lower(),
        message = clip(diagnostic.message or "", message_limit),
      }
    end
  end
  return #found > 0 and found or nil
end

--- Lists identifiers before the cursor, nearest first, skipping the one being typed.
---
---@param line string
---@param col integer Cursor byte column.
---@param limit integer
---@return table[] symbols
---
local function symbols_before(line, col, limit)
  local all, offset = {}, 1
  while true do
    local start, finish, name = line:find("([%a_][%w_]*)", offset)
    if not start or start > col then
      break
    end
    if finish < col and #name > 2 then
      all[#all + 1] = { name = name, col = start - 1 }
    end
    offset = finish + 1
  end
  local nearest, seen = {}, {}
  for index = #all, 1, -1 do
    if #nearest >= limit then
      break
    end
    if not seen[all[index].name] then
      seen[all[index].name] = true
      nearest[#nearest + 1] = all[index]
    end
  end
  return nearest
end

--- Gathers signature help, completions, hover text, and diagnostics.
---
--- Sets `captured.lsp` when anything was found and always calls back once
--- unless cancelled.
---
---@param captured table
---@param config table
---@param callback fun()
---@return function cancel
---
function M.collect(captured, config, callback)
  local options = config.context.lsp
  captured.lsp = nil
  if not options.enabled or captured.kind == "comment" or not vim.api.nvim_buf_is_valid(captured.bufnr) then
    callback()
    return function() end
  end

  local bufnr = captured.bufnr
  local row = captured.row - 1
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local typed = line:sub(1, captured.col):match("[%w_]*$"):lower()
  local result = { diagnostics = nearby_diagnostics(bufnr, row) }
  local done, issuing, pending = false, true, 0
  local requests = {}
  local timer

  local function stop()
    done = true
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
    for _, request in ipairs(requests) do
      pcall(call, request.client, "cancel_request", request.id)
    end
    requests = {}
  end

  local function finish()
    if done then
      return
    end
    stop()
    if next(result) then
      captured.lsp = result
    end
    callback()
  end

  local function ask(client, method, params, handler)
    pending = pending + 1
    local ok, id = call(client, "request", method, params, function(err, response)
      pending = pending - 1
      if done then
        return
      end
      if not err and response then
        handler(response)
      end
      if pending == 0 and not issuing then
        finish()
      end
    end, bufnr)
    if ok then
      requests[#requests + 1] = { client = client, id = id }
    else
      pending = pending - 1
    end
  end

  local asked = {}
  local document = { uri = vim.uri_from_bufnr(bufnr) }
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    --- null-ls would route the completion request back to this plugin.
    if client.name ~= "null-ls" then
      local cursor = { line = row, character = character(client, line, captured.col) }
      if not asked.signature and call(client, "supports_method", "textDocument/signatureHelp") then
        asked.signature = true
        ask(client, "textDocument/signatureHelp", { textDocument = document, position = cursor }, function(response)
          local signature = (response.signatures or {})[(response.activeSignature or 0) + 1]
          if type(signature) == "table" and type(signature.label) == "string" then
            local active = signature.activeParameter or response.activeParameter
            local parameter = type(active) == "number" and (signature.parameters or {})[active + 1]
            result.signature = {
              label = clip(signature.label, hover_limit),
              active_parameter = parameter and type(parameter.label) == "string" and parameter.label or nil,
            }
          end
        end)
      end
      if not asked.completion and options.max_completions > 0 then
        if call(client, "supports_method", "textDocument/completion") then
          asked.completion = true
          ask(client, "textDocument/completion", { textDocument = document, position = cursor }, function(response)
            local labels = {}
            for _, item in ipairs(response.items or response) do
              if #labels >= options.max_completions then
                break
              end
              local label = type(item) == "table" and item.label
              if type(label) == "string" and label:lower():sub(1, #typed) == typed then
                labels[#labels + 1] = clip(label, label_limit)
              end
            end
            if #labels > 0 then
              result.completions = labels
            end
          end)
        end
      end
      if not asked.hover and options.max_hover > 0 and call(client, "supports_method", "textDocument/hover") then
        asked.hover = true
        for _, symbol in ipairs(symbols_before(line, captured.col, options.max_hover)) do
          local position = { line = row, character = character(client, line, symbol.col) }
          ask(client, "textDocument/hover", { textDocument = document, position = position }, function(response)
            local text = hover_text(response.contents)
            if text ~= "" then
              result.hover = result.hover or {}
              result.hover[#result.hover + 1] = { symbol = symbol.name, text = clip(text, hover_limit) }
            end
          end)
        end
      end
    end
  end
  issuing = false

  if pending == 0 then
    finish()
    return function() end
  end
  timer = vim.uv.new_timer()
  timer:start(options.timeout_ms, 0, vim.schedule_wrap(finish))
  return function()
    if not done then
      stop()
    end
  end
end

return M
