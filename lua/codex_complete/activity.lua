--- Rolling window of the developer's recent edits and visited files.
---
--- Edits are stored as small unified diffs so requests can show what the
--- developer has been doing without resending whole files.

local M = {}

local snapshots = {}
local edits = {}
local files = {}
local revision = 0
local max_lines = 10000
local max_diff_bytes = 1200
local max_files = 6
local diff = (vim.text and vim.text.diff) or vim.diff

--- Keeps whole lines of a diff up to a byte limit.
---
---@param value string
---@param limit integer
---@return string clipped
---
local function clip(value, limit)
  if #value <= limit then
    return value
  end
  local kept, size = {}, 0
  for line in value:gmatch("[^\n]*\n?") do
    if line == "" or size + #line > limit then
      break
    end
    kept[#kept + 1] = line
    size = size + #line
  end
  return table.concat(kept) .. "...\n"
end

--- Remembers the buffer's text as the baseline for the next recorded edit.
---
---@param bufnr integer
---
function M.track(bufnr)
  if snapshots[bufnr] or not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  if vim.api.nvim_buf_line_count(bufnr) <= max_lines then
    snapshots[bufnr] = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end
end

--- Notes a visited file, most recent last.
---
---@param bufnr integer
---
function M.visit(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return
  end
  for index, existing in ipairs(files) do
    if existing == name then
      table.remove(files, index)
      break
    end
  end
  files[#files + 1] = name
  if #files > max_files then
    table.remove(files, 1)
  end
end

--- Records the change since the last baseline as one edit.
---
---@param bufnr integer
---@param options table Activity limits from the configuration.
---@return boolean recorded
---
function M.record(bufnr, options)
  local before = snapshots[bufnr]
  if not before then
    M.track(bufnr)
    return false
  end
  if not vim.api.nvim_buf_is_loaded(bufnr) or vim.api.nvim_buf_line_count(bufnr) > max_lines then
    snapshots[bufnr] = nil
    return false
  end
  local after = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local patch = diff(table.concat(before, "\n") .. "\n", table.concat(after, "\n") .. "\n", {
    result_type = "unified",
    ctxlen = 1,
  })
  snapshots[bufnr] = after
  if type(patch) ~= "string" or patch == "" or patch:find("%z") then
    return false
  end
  edits[#edits + 1] = { filename = vim.api.nvim_buf_get_name(bufnr), diff = clip(patch, max_diff_bytes) }
  while #edits > options.max_edits do
    table.remove(edits, 1)
  end
  revision = revision + 1
  return true
end

--- Returns the newest edits that fit the byte budget, oldest first.
---
---@param options table Activity limits from the configuration.
---@return table[]|nil recent_edits
---@return string[]|nil recent_files
---
function M.snapshot(options)
  local selected, size = {}, 0
  for index = #edits, 1, -1 do
    local edit = edits[index]
    if size + #edit.diff > options.max_bytes then
      break
    end
    table.insert(selected, 1, { filename = edit.filename, diff = edit.diff })
    size = size + #edit.diff
  end
  return #selected > 0 and selected or nil, #files > 0 and vim.deepcopy(files) or nil
end

--- Counts every edit recorded since startup.
---
---@return integer revision
---
function M.revision()
  return revision
end

--- Drops a buffer's baseline.
---
---@param bufnr integer
---
function M.forget(bufnr)
  snapshots[bufnr] = nil
end

--- Clears all recorded activity.
---
function M.reset()
  snapshots, edits, files = {}, {}, {}
end

return M
