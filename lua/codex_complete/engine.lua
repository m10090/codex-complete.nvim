local context = require("codex_complete.context")
local Client = require("codex_complete.client")
local prompt = require("codex_complete.prompt")
local related = require("codex_complete.related")
local hints = require("codex_complete.hints")

local Engine = {}
Engine.__index = Engine

function Engine.new(config, callbacks)
  local self = setmetatable({
    config = config,
    callbacks = callbacks,
    generation = 0,
    active = nil,
    last_error = nil,
    model = config.codex.model,
    effort = config.codex.effort,
  }, Engine)
  self.client = Client.new({
    command = config.codex.command,
    on_notification = function(method, params)
      self:_on_notification(method, params)
    end,
    on_exit = function(message)
      self.warm = nil
      self.warming = false
      self:_end_background(self.background, message)
      self:_fail_active(message)
    end,
  })
  return self
end

function Engine:_is_active(request)
  return self.active == request and not request.cancelled and request.generation == self.generation
end

function Engine:_finish(request, completion)
  if not self:_is_active(request) then
    return
  end
  self.active = nil
  self.last_retrieval = request.context.retrieval
  self.last_duration_ms = (vim.uv.hrtime() - request.started) / 1e6
  if request.timeout then
    request.timeout:stop()
    request.timeout:close()
  end
  if self.callbacks.on_finished then
    self.callbacks.on_finished(request.context)
  end
  if completion and context.is_current(request.context) and related.valid(request.context) then
    self.last_error = nil
    self.callbacks.on_completion(request.context, completion)
  end
end

function Engine:_fail(request, message)
  if not self:_is_active(request) then
    return
  end
  self.active = nil
  if request.cancel_context then
    request.cancel_context()
  end
  self.last_retrieval = request.context.retrieval
  self.last_duration_ms = (vim.uv.hrtime() - request.started) / 1e6
  self.last_error = message
  if request.timeout then
    request.timeout:stop()
    request.timeout:close()
  end
  if self.callbacks.on_finished then
    self.callbacks.on_finished(request.context)
  end
  if request.manual then
    self.callbacks.on_error(message)
  end
end

function Engine:_fail_active(message)
  if self.active then
    self:_fail(self.active, message)
  else
    self.last_error = message
  end
end

--- Builds the parameters for a new ephemeral, read-only thread.
---
---@param instructions string Developer instructions for the thread.
---@param cwd string Working directory of the thread.
---@return table params
---
function Engine:_thread_params(instructions, cwd)
  local params = {
    cwd = cwd,
    ephemeral = true,
    approvalPolicy = "never",
    sandbox = "read-only",
    developerInstructions = instructions,
    serviceName = "codex-complete.nvim",
  }
  if self.model then
    params.model = self.model
  end
  return params
end

--- Builds the parameters for a read-only turn with structured output.
---
---@param thread_id string
---@param text string User message.
---@param schema table Output schema.
---@param effort string|nil Reasoning effort; the engine's by default.
---@return table params
---
function Engine:_turn_params(thread_id, text, schema, effort)
  local params = {
    threadId = thread_id,
    input = { { type = "text", text = text } },
    approvalPolicy = "never",
    effort = effort or self.effort,
    outputSchema = schema,
    sandboxPolicy = { type = "readOnly", networkAccess = false },
  }
  if self.model then
    params.model = self.model
  end
  return params
end

--- Starts a completion thread ahead of time so the next request skips that round trip.
---
---@param cwd string Working directory the next request is expected to use.
---
function Engine:prewarm(cwd)
  local warm = self.warm
  if self.warming or (warm and warm.cwd == cwd and warm.model == self.model) then
    return
  end
  self.warming = true
  local model = self.model
  local client = self.client
  client:start(function(err)
    if err or self.client ~= client then
      self.warming = false
      return
    end
    local params = self:_thread_params(prompt.instructions("completion", self.config), cwd)
    client:request("thread/start", params, function(thread_err, result)
      self.warming = false
      local thread_id = not thread_err and result and result.thread and result.thread.id
      if thread_id and model == self.model then
        self.warm = { thread_id = thread_id, cwd = cwd, model = model }
      end
    end)
  end)
end

--- Claims the pre-started thread when it matches the request.
---
---@param request table
---@return string|nil thread_id
---
function Engine:_take_warm(request)
  local warm = self.warm
  if not warm or request.context.kind == "comment" then
    return nil
  end
  self.warm = nil
  if warm.cwd == request.context.cwd and warm.model == self.model and self.client.state == "ready" then
    return warm.thread_id
  end
  return nil
end

function Engine:_start_turn(request)
  local start_thread

  local function start_on(thread_id, warm)
    request.thread_id = thread_id
    local turn_params = self:_turn_params(thread_id, prompt.build(request.context), prompt.output_schema)
    self.client:request("turn/start", turn_params, function(turn_err, turn_result)
      if not self:_is_active(request) then
        return
      end
      if turn_err and warm then
        --- A pre-started thread may have expired; retry once on a fresh one.
        request.thread_id = nil
        start_thread()
        return
      end
      if turn_err then
        self:_fail(request, "Could not start Codex completion: " .. turn_err)
        return
      end
      request.turn_id = turn_result and turn_result.turn and turn_result.turn.id
      if not request.turn_id then
        self:_fail(request, "Codex app-server returned no turn id")
      end
    end)
    if self.config.codex.prewarm and request.context.kind ~= "comment" and self:_is_active(request) then
      self:prewarm(request.context.cwd)
    end
  end

  start_thread = function()
    local instructions = prompt.instructions(request.context.kind, self.config)
    local thread_params = self:_thread_params(instructions, request.context.cwd)
    self.client:request("thread/start", thread_params, function(err, result)
      if not self:_is_active(request) then
        return
      end
      if err then
        self:_fail(request, "Could not start Codex completion thread: " .. err)
        return
      end
      local thread_id = result and result.thread and result.thread.id
      if not thread_id then
        self:_fail(request, "Codex app-server returned no thread id")
        return
      end
      start_on(thread_id, false)
    end)
  end

  local warm_thread = self:_take_warm(request)
  if warm_thread then
    start_on(warm_thread, true)
  else
    start_thread()
  end
end

--- Finishes the background summary exactly once.
---
---@param job table|nil
---@param err string|nil
---@param intent string|nil
---
function Engine:_end_background(job, err, intent)
  if not job or self.background ~= job then
    return
  end
  self.background = nil
  if job.timeout then
    job.timeout:stop()
    job.timeout:close()
  end
  job.callback(err, intent)
end

--- Summarises recent activity on a separate thread without blocking completions.
---
---@param payload string JSON description of recent edits.
---@param cwd string Working directory for the thread.
---@param callback fun(err: string|nil, intent: string|nil)
---@param options table|nil Instructions, schema, parser, and timeout; an intent summary by default.
---@return boolean started
---
function Engine:summarize(payload, cwd, callback, options)
  if self.background then
    return false
  end
  options = options or {}
  local job = {
    callback = callback,
    instructions = options.instructions or prompt.intent_instructions,
    schema = options.schema or prompt.intent_schema,
    parse = options.parse or prompt.parse_intent,
    effort = options.effort,
  }
  self.background = job
  job.timeout = vim.uv.new_timer()
  job.timeout:start(
    options.timeout_ms or self.config.codex.timeout_ms,
    0,
    vim.schedule_wrap(function()
      if self.background == job and job.thread_id and job.turn_id then
        self.client:request("turn/interrupt", { threadId = job.thread_id, turnId = job.turn_id }, function() end)
      end
      self:_end_background(job, "Codex background summary timed out")
    end)
  )

  self.client:start(function(err)
    if self.background ~= job then
      return
    end
    if err then
      self:_end_background(job, err)
      return
    end
    local thread_params = self:_thread_params(job.instructions, cwd)
    self.client:request("thread/start", thread_params, function(thread_err, result)
      if self.background ~= job then
        return
      end
      job.thread_id = not thread_err and result and result.thread and result.thread.id
      if not job.thread_id then
        self:_end_background(job, thread_err or "Codex app-server returned no thread id")
        return
      end
      local turn_params = self:_turn_params(job.thread_id, payload, job.schema, job.effort)
      self.client:request("turn/start", turn_params, function(turn_err, turn_result)
        if self.background ~= job then
          return
        end
        job.turn_id = not turn_err and turn_result and turn_result.turn and turn_result.turn.id
        if not job.turn_id then
          self:_end_background(job, turn_err or "Codex app-server returned no turn id")
        end
      end)
    end)
  end)
  return true
end

--- Routes a notification belonging to the background summary.
---
---@param job table
---@param method string
---@param params table
---
function Engine:_on_background(job, method, params)
  if method == "item/completed" then
    local item = params.item or {}
    if item.type == "agentMessage" and item.text and item.phase ~= "commentary" then
      job.message = item.text
    end
  elseif method == "turn/completed" then
    local turn = params.turn or {}
    if turn.status and turn.status ~= "completed" then
      self:_end_background(job, "Codex background summary ended with status " .. tostring(turn.status))
      return
    end
    local intent, parse_error = job.parse(job.message)
    self:_end_background(job, parse_error, intent)
  elseif method == "error" then
    self:_end_background(job, params.message or "Codex app-server reported an error")
  end
end

function Engine:list_models(options, callback)
  if type(options) == "function" then
    callback = options
    options = {}
  end
  options = options or {}
  local models = {}
  local model_ids = {}
  local cursors = {}

  local function request_page(cursor)
    local params = { limit = 100, includeHidden = options.include_hidden == true }
    if cursor then
      params.cursor = cursor
    end
    self.client:request("model/list", params, function(err, result)
      if err then
        callback("Could not list Codex models: " .. err)
        return
      end
      if type(result) ~= "table" or type(result.data) ~= "table" then
        callback("Codex app-server returned an invalid model list")
        return
      end
      for _, model in ipairs(result.data) do
        if
          type(model) ~= "table"
          or type(model.id) ~= "string"
          or model.id == ""
          or type(model.model) ~= "string"
          or model.model == ""
          or type(model.displayName) ~= "string"
          or model.displayName == ""
          or type(model.hidden) ~= "boolean"
          or type(model.isDefault) ~= "boolean"
          or type(model.defaultReasoningEffort) ~= "string"
          or model.defaultReasoningEffort == ""
          or type(model.supportedReasoningEfforts) ~= "table"
        then
          callback("Codex app-server returned an invalid model entry")
          return
        end
        local supported = {}
        for _, effort in ipairs(model.supportedReasoningEfforts) do
          if
            type(effort) ~= "table"
            or type(effort.reasoningEffort) ~= "string"
            or effort.reasoningEffort == ""
            or type(effort.description) ~= "string"
          then
            callback("Codex app-server returned invalid reasoning-effort metadata")
            return
          end
          supported[effort.reasoningEffort] = true
        end
        if not supported[model.defaultReasoningEffort] then
          callback("Codex app-server returned an unsupported default reasoning effort")
          return
        end
        if (options.include_hidden or model.hidden ~= true) and not model_ids[model.model] then
          models[#models + 1] = model
          model_ids[model.model] = true
        end
      end

      local next_cursor = result.nextCursor
      if next_cursor == nil or next_cursor == vim.NIL then
        callback(nil, models)
        return
      end
      if type(next_cursor) ~= "string" or next_cursor == "" or cursors[next_cursor] then
        callback("Codex app-server returned an invalid model-list cursor")
        return
      end
      cursors[next_cursor] = true
      request_page(next_cursor)
    end)
  end

  self.client:start(function(err)
    if err then
      callback(err)
      return
    end
    request_page(nil)
  end)
end

function Engine:set_model(model)
  self.model = model
  self.warm = nil
end

function Engine:set_effort(effort)
  self.effort = effort
end

function Engine:request(captured_context, manual)
  self:cancel()
  self.generation = self.generation + 1
  local request = {
    generation = self.generation,
    context = captured_context,
    manual = manual,
    message = nil,
    cancelled = false,
    started = vim.uv.hrtime(),
  }
  self.active = request

  request.timeout = vim.uv.new_timer()
  request.timeout:start(
    self.config.codex.timeout_ms,
    0,
    vim.schedule_wrap(function()
      if self:_is_active(request) then
        if request.thread_id and request.turn_id then
          self.client:request("turn/interrupt", {
            threadId = request.thread_id,
            turnId = request.turn_id,
          }, function() end)
        end
        self:_fail(request, "Codex completion timed out")
      end
    end)
  )

  self.client:start(function(err)
    if not self:_is_active(request) then
      return
    end
    if err then
      self:_fail(request, err)
      return
    end
    --- Project snippets and language-server facts are gathered in parallel.
    local remaining = 2
    local function ready()
      remaining = remaining - 1
      if remaining > 0 then
        return
      end
      if self:_is_active(request) and context.is_current(captured_context) then
        self:_start_turn(request)
      elseif self:_is_active(request) then
        self:cancel()
      end
    end
    local cancel_related = related.collect(captured_context, self.config, ready)
    local cancel_hints = hints.collect(captured_context, self.config, ready)
    request.cancel_context = function()
      cancel_related()
      cancel_hints()
    end
  end)
end

function Engine:cancel()
  local request = self.active
  if not request then
    return
  end
  request.cancelled = true
  if request.cancel_context then
    request.cancel_context()
  end
  self.active = nil
  if request.timeout then
    request.timeout:stop()
    request.timeout:close()
  end
  if self.callbacks.on_finished then
    self.callbacks.on_finished(request.context)
  end
  if request.thread_id and request.turn_id and self.client.state == "ready" then
    self.client:request("turn/interrupt", {
      threadId = request.thread_id,
      turnId = request.turn_id,
    }, function() end)
  end
end

function Engine:_matches(params)
  if not self.active then
    return false
  end
  local thread_id = params.threadId or (params.turn and params.turn.threadId)
  return not thread_id or thread_id == self.active.thread_id
end

function Engine:_on_notification(method, params)
  local job = self.background
  local thread_id = params.threadId or (params.turn and params.turn.threadId)
  if job and thread_id and thread_id == job.thread_id then
    self:_on_background(job, method, params)
    return
  end
  local request = self.active
  if not request or not self:_matches(params) then
    return
  end

  if method == "item/completed" then
    local item = params.item or {}
    if item.type == "agentMessage" and item.text and item.phase ~= "commentary" then
      request.message = item.text
    end
    return
  end
  if method == "turn/completed" then
    local turn = params.turn or {}
    if turn.status and turn.status ~= "completed" then
      self:_fail(request, "Codex completion ended with status " .. tostring(turn.status))
      return
    end
    local completion, parse_error = prompt.parse(request.message, self.config)
    if completion and request.context.kind ~= "comment" then
      completion = context.strip_repeated_prefix(request.context.prefix, completion)
      if not completion:find("%S") then
        completion, parse_error = nil, "Codex did not suggest a completion"
      end
    end
    if not completion then
      self:_fail(request, parse_error)
      return
    end
    self:_finish(request, completion)
    return
  end
  if method == "error" then
    self:_fail(request, params.message or "Codex app-server reported an error")
  end
end

function Engine:stop()
  self:cancel()
  self.warm = nil
  self.warming = false
  self:_end_background(self.background, "Codex app-server stopped")
  self.client:stop()
end

function Engine:status()
  return {
    active = self.active ~= nil,
    generation = self.generation,
    last_error = self.last_error,
    model = self.model,
    effort = self.effort,
    client = self.client:status(),
    context = self.active and self.active.context.retrieval or self.last_retrieval,
    duration_ms = self.last_duration_ms,
    warm = self.warm ~= nil,
    summarizing = self.background ~= nil,
  }
end

return Engine
