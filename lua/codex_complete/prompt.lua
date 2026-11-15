local M = {}

M.developer_instructions = table.concat({
  "You are an inline code completion and comment-to-code engine.",
  "Use the supplied code context first; inspect relevant files when necessary.",
  "Discover and apply applicable project instructions and skills normally, including implicit skill triggers.",
  "Read selected skills and their relevant references, including documentation conventions when completing doc comments.",
  "Completing a doc comment or docstring is a documentation task: apply matching documentation skills and read their language-specific references before composing the insertion.",
  "Your task is only the requested insertion or comment replacement, not a repository-wide skill workflow.",
  "Never modify files, access the network, run skill scripts, or ask questions.",
  "Return a JSON object with one field named completion.",
  "For kind completion, the completion must contain only the exact text to insert at the cursor.",
  "For kind comment, treat instruction as a request and return only the exact code that replaces that comment.",
  "Never include comment delimiters from the instruction in a comment replacement.",
  "Do not repeat the prefix or suffix, and do not use Markdown fences.",
  "The cursor sits between line_before_cursor and line_after_cursor on the cursor line.",
  "Never repeat line_before_cursor or earlier lines: start with the very next character to insert.",
  "The project field summarises the repository; follow its structure, APIs, and conventions.",
  "The lsp field holds language-server facts for the cursor; prefer its completions and signature over guesses.",
  "The recent_edits and intent fields describe what the developer is doing; continue that work.",
  "Prefer a concise, idiomatic continuation. Return an empty string when no useful completion is clear.",
}, " ")

--- Single-response instructions for inline completions: no tool round trips.
M.fast_instructions = table.concat({
  "You are an inline code completion engine.",
  "Answer in a single response from the supplied context only.",
  "Never read files, run commands, use tools or skills, access the network, modify files, or ask questions.",
  "Return a JSON object with one field named completion.",
  "The completion must contain only the exact text to insert at the cursor.",
  "Do not repeat the prefix or suffix, and do not use Markdown fences.",
  "The cursor sits between line_before_cursor and line_after_cursor on the cursor line.",
  "Never repeat line_before_cursor or earlier lines: start with the very next character to insert.",
  "The project field summarises the repository; follow its structure, APIs, and conventions.",
  "The lsp field holds language-server facts for the cursor; prefer its completions and signature over guesses.",
  "The recent_edits and intent fields describe what the developer is doing; continue that work.",
  "Prefer a concise, idiomatic continuation. Return an empty string when no useful completion is clear.",
}, " ")

M.brief_instructions = table.concat({
  "You write a short brief of a code repository for an inline code completion engine.",
  "You must inspect the repository in the working directory before answering: list its files,",
  "then read the README, the manifest files, and the main source modules. Do not answer from the request alone.",
  "Never modify files, access the network, run skill scripts, or ask questions.",
  "Return a JSON object with one field named brief, at most 1800 characters of plain text covering:",
  "what the project does, its languages and frameworks, the directory layout, the main modules with",
  "their key functions and types, and naming, error-handling, and testing conventions.",
  "Be specific and dense; name real files and symbols you read.",
}, " ")

M.brief_schema = {
  type = "object",
  properties = {
    brief = { type = "string" },
  },
  required = { "brief" },
  additionalProperties = false,
}

M.intent_instructions = table.concat({
  "You observe a developer's recent edits and describe what they are working on.",
  "The user message is JSON with recent_edits as unified diffs, oldest first, recent_files, and the previous intent.",
  "You may read the listed project files when the diffs alone are unclear.",
  "Never modify files, access the network, run skill scripts, or ask questions.",
  "Return a JSON object with one field named intent: at most three plain sentences naming the goal,",
  "the symbols and files involved, and the likely next step. Return an empty string when the goal is unclear.",
}, " ")

M.intent_schema = {
  type = "object",
  properties = {
    intent = { type = "string" },
  },
  required = { "intent" },
  additionalProperties = false,
}

local intent_limit = 1024
local brief_limit = 2048

--- Selects the developer instructions for a request.
---
---@param kind string|nil Request kind: completion or comment.
---@param config table Resolved plugin configuration.
---@return string instructions
---
function M.instructions(kind, config)
  if kind ~= "comment" and not config.codex.completion_tools then
    return M.fast_instructions
  end
  return M.developer_instructions
end

M.output_schema = {
  type = "object",
  properties = {
    completion = { type = "string" },
  },
  required = { "completion" },
  additionalProperties = false,
}

function M.build(context)
  local payload = {
    kind = context.kind or "completion",
    filename = context.filename,
    filetype = context.filetype,
    cursor = { line = context.row, byte_column = context.col },
    prefix = context.prefix,
    suffix = context.suffix,
    line_before_cursor = context.kind ~= "comment" and context.prefix:match("[^\n]*$") or nil,
    line_after_cursor = context.kind ~= "comment" and context.suffix:match("^[^\n]*") or nil,
    project = context.project,
    related = context.related,
    lsp = context.lsp,
    recent_edits = context.recent_edits,
    recent_files = context.recent_files,
    intent = context.intent,
  }
  if context.kind == "comment" then
    payload.instruction = context.instruction
    payload.replacement = {
      start = { line = context.edit.start_row + 1, byte_column = context.edit.start_col },
      finish = { line = context.edit.end_row + 1, byte_column = context.edit.end_col },
    }
  end
  return vim.json.encode(payload)
end

--- Builds the payload for a background intent summary.
---
---@param activity table Recent edits, recent files, and the previous intent.
---@return string payload
---
function M.build_intent(activity)
  return vim.json.encode({
    recent_edits = activity.recent_edits,
    recent_files = activity.recent_files,
    previous_intent = activity.intent,
  })
end

--- Extracts one bounded text field from a structured background reply.
---
---@param message string|nil
---@param field string
---@param limit integer
---@return string|nil text
---@return string|nil error
---
local function parse_summary(message, field, limit)
  local ok, decoded = pcall(vim.json.decode, message or "")
  if not ok or type(decoded) ~= "table" or type(decoded[field]) ~= "string" then
    return nil, ("Codex returned a malformed %s summary"):format(field)
  end
  local text = vim.trim((decoded[field]:gsub("%z", ""):gsub("%s+", " ")))
  if #text > limit then
    text = text:sub(1, limit):gsub("[\194-\244][\128-\191]*$", "")
  end
  return text
end

--- Extracts the intent summary from a structured reply.
---
---@param message string|nil
---@return string|nil intent
---@return string|nil error
---
function M.parse_intent(message)
  return parse_summary(message, "intent", intent_limit)
end

--- Extracts the project brief from a structured reply.
---
---@param message string|nil
---@return string|nil brief
---@return string|nil error
---
function M.parse_brief(message)
  return parse_summary(message, "brief", brief_limit)
end

--- Builds the request for a project brief.
---
---@param root string Repository root.
---@return string payload
---
function M.build_brief(root)
  return ("Read the repository at %s and write its brief. Start by listing the files."):format(root)
end

local function remove_fence(value)
  local language, body = value:match("^```([^\n]*)\n(.*)\n```%s*$")
  if language ~= nil then
    return body
  end
  return value
end

function M.parse(message, config)
  if type(message) ~= "string" or message == "" then
    return nil, "Codex returned no completion"
  end

  local ok, decoded = pcall(vim.json.decode, message)
  if not ok or type(decoded) ~= "table" or type(decoded.completion) ~= "string" then
    return nil, "Codex returned malformed structured output"
  end

  local completion = remove_fence(decoded.completion:gsub("\r\n", "\n"):gsub("\r", "\n"))
  if completion:find("%z") then
    return nil, "Codex returned an invalid NUL byte"
  end
  if completion == "" then
    return nil, "Codex did not suggest a completion"
  end
  if #completion > config.suggestion.max_bytes then
    return nil, "Codex completion exceeded the configured byte limit"
  end
  local lines = vim.split(completion, "\n", { plain = true })
  if #lines > config.suggestion.max_lines then
    return nil, "Codex completion exceeded the configured line limit"
  end
  return completion
end

return M
