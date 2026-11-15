--- Cached per-project briefs that tell completions what the repository is.
---
--- A brief is written once in the background, where Codex may read the
--- repository, and is then reused from disk until it expires.

local M = {}

local briefs = {}
local attempted = {}

--- Overrides the directory holding stored briefs.
M.directory = nil

--- Resolves the cache file for a project root.
---
---@param root string
---@return string path
---
local function cache_path(root)
  local directory = M.directory or vim.fs.joinpath(vim.fn.stdpath("cache"), "codex-complete", "briefs")
  return vim.fs.joinpath(directory, vim.fn.sha256(root) .. ".json")
end

--- Finds the Git root that owns a buffer's file.
---
---@param bufnr integer
---@return string|nil root
---
function M.root(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" or vim.bo[bufnr].buftype ~= "" then
    return nil
  end
  local git = vim.fs.find(".git", { path = vim.fs.dirname(name), upward = true })[1]
  return git and vim.fs.normalize(vim.fs.dirname(git)) or nil
end

--- Returns the brief known for a project root.
---
---@param root string|nil
---@return string|nil brief
---
function M.get(root)
  return root and briefs[root] or nil
end

--- Loads a stored brief that has not expired.
---
---@param root string
---@param max_age_days integer
---@return string|nil brief
---
local function load(root, max_age_days)
  local ok, lines = pcall(vim.fn.readfile, cache_path(root))
  if not ok then
    return nil
  end
  local decoded, stored = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decoded or type(stored) ~= "table" or stored.root ~= root or type(stored.brief) ~= "string" then
    return nil
  end
  if type(stored.time) ~= "number" or os.time() - stored.time > max_age_days * 86400 then
    return nil
  end
  return stored.brief
end

--- Stores a brief in memory and on disk.
---
---@param root string
---@param brief string
---
local function store(root, brief)
  briefs[root] = brief
  local path = cache_path(root)
  pcall(vim.fn.mkdir, vim.fs.dirname(path), "p")
  pcall(vim.fn.writefile, { vim.json.encode({ root = root, brief = brief, time = os.time() }) }, path)
end

--- Makes sure a project has a brief, asking Codex for one when needed.
---
---@param root string
---@param engine table
---@param config table
---@param force boolean|nil Rewrite the brief even when one is cached.
---@param callback fun(err: string|nil, brief: string|nil)|nil
---@return boolean requested Whether a background request was started.
---
function M.ensure(root, engine, config, force, callback)
  callback = callback or function() end
  if not force then
    if briefs[root] or attempted[root] then
      return false
    end
    local stored = load(root, config.project_brief.max_age_days)
    if stored then
      briefs[root] = stored
      return false
    end
  end
  local prompt = require("codex_complete.prompt")
  local started = engine:summarize(prompt.build_brief(root), root, function(err, brief)
    if not err and brief ~= "" then
      store(root, brief)
    end
    callback(err, brief)
  end, {
    instructions = prompt.brief_instructions,
    schema = prompt.brief_schema,
    parse = prompt.parse_brief,
    timeout_ms = config.project_brief.timeout_ms,
    effort = config.project_brief.effort,
  })
  --- A failed attempt is not repeated until the next session or a forced refresh.
  attempted[root] = started or attempted[root]
  return started
end

--- Forgets in-memory briefs and attempts; stored files are kept.
---
function M.reset()
  briefs, attempted = {}, {}
end

return M
