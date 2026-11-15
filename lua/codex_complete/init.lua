local M = {}

local activity = require("codex_complete.activity")
local brief = require("codex_complete.brief")
local context = require("codex_complete.context")
local prompt = require("codex_complete.prompt")
local related = require("codex_complete.related")
local config_module = require("codex_complete.config")
local Engine = require("codex_complete.engine")
local ui = require("codex_complete.ui")

local state = {
  configured = false,
  enabled = false,
  config = nil,
  engine = nil,
  timer = nil,
  schedule_generation = 0,
  mappings = {},
  cache = {},
  accepted_changedtick = {},
  waiter = nil,
  intent = nil,
  intent_error = nil,
  intent_revision = 0,
  intent_timer = nil,
}

local function notify(message, level)
  if state.config and state.config.notify then
    vim.notify(message, level or vim.log.levels.INFO, { title = "codex-complete.nvim" })
  end
end

local function redraw_statusline()
  vim.cmd.redrawstatus()
end

local function stop_timer()
  state.schedule_generation = state.schedule_generation + 1
  if state.timer then
    state.timer:stop()
  end
end

--- Answers the pending null-ls completion request, if any.
---
---@param captured table|nil Context of the visible suggestion.
---@param completion string|nil Suggestion text.
---@param replace_length integer|nil Bytes after the cursor the suggestion replaces.
---
local function resolve_waiter(captured, completion, replace_length)
  local waiter = state.waiter
  state.waiter = nil
  if waiter then
    waiter(captured, completion, replace_length)
  end
end

--- Records the suggestion, optionally as ghost text, and hands it to a waiting null-ls request.
local function show(captured, completion, paired_delimiter)
  ui.show(captured, completion, {
    paired_delimiter = paired_delimiter,
    highlights = state.config.highlights,
    render = state.config.ghost_text,
  })
  resolve_waiter(captured, completion, paired_delimiter and paired_delimiter.replace_length or 0)
  if state.config.open_menu then
    require("codex_complete.null_ls").ensure_menu(captured)
  end
end

local function cancel_work()
  stop_timer()
  if state.engine then
    state.engine:cancel()
  end
end

--- Attaches the rolling activity window and intent summary to a request.
---
---@param captured table
---@return table captured
---
local function with_activity(captured)
  local options = state.config.context.activity
  if options.enabled then
    captured.recent_edits, captured.recent_files = activity.snapshot(options)
  end
  if state.config.intent.enabled then
    captured.intent = state.intent
  end
  if state.config.project_brief.enabled then
    captured.project = brief.get(brief.root(captured.bufnr))
  end
  return captured
end

--- Asks Codex in the background what the recent edits are working towards.
---
local function summarize_intent()
  if not state.enabled or not state.config.intent.enabled then
    return
  end
  local revision = activity.revision()
  if revision - state.intent_revision < state.config.intent.min_edits then
    return
  end
  local edits, files = activity.snapshot(state.config.context.activity)
  if not edits then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local root = related.project({ bufnr = bufnr, filename = vim.api.nvim_buf_get_name(bufnr) })
  local engine = state.engine
  local payload = prompt.build_intent({ recent_edits = edits, recent_files = files, intent = state.intent })
  local started = engine:summarize(payload, root, function(err, intent)
    if state.engine ~= engine then
      return
    end
    state.intent_error = err
    if not err and intent ~= "" then
      state.intent = intent
    end
  end)
  if started then
    --- Failures also advance the revision so a broken login is not retried on every pause.
    state.intent_revision = revision
  end
end

--- Records the latest edit and schedules a summary once editing pauses.
---
---@param bufnr integer
---
local function record_activity(bufnr)
  local options = state.config.context.activity
  if not state.enabled or not options.enabled or not context.eligible(bufnr, state.config, true) then
    return
  end
  if activity.record(bufnr, options) and state.config.intent.enabled then
    state.intent_timer:stop()
    state.intent_timer:start(state.config.intent.idle_ms, 0, vim.schedule_wrap(summarize_intent))
  end
end

local function current_mode_allows_manual()
  local mode = vim.api.nvim_get_mode().mode
  return mode:sub(1, 1) == "i" or mode:sub(1, 1) == "n"
end

function M.trigger(options)
  options = options or {}
  if not state.configured then
    notify("Call require('codex_complete').setup() before requesting completions", vim.log.levels.ERROR)
    return false
  end
  if not state.enabled then
    if options.silent ~= true then
      notify("Codex completions are disabled", vim.log.levels.WARN)
    end
    return false
  end
  local manual = options.manual ~= false
  if manual and not current_mode_allows_manual() then
    return false
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local eligible, reason = context.eligible(bufnr, state.config, manual)
  if not eligible then
    if manual and options.silent ~= true then
      notify("Completion unavailable: " .. reason, vim.log.levels.WARN)
    end
    return false
  end

  cancel_work()
  ui.dismiss()
  local captured = context.capture(bufnr, vim.api.nvim_get_current_win(), state.config)
  if state.config.loading_indicator then
    ui.show_loading(captured)
  end
  state.engine:request(with_activity(captured), manual)
  return true
end

function M.trigger_comment()
  if not state.configured then
    notify("Call require('codex_complete').setup() before requesting comment replacements", vim.log.levels.ERROR)
    return false
  end
  if not state.enabled then
    notify("Codex completions are disabled", vim.log.levels.WARN)
    return false
  end
  if vim.api.nvim_get_mode().mode:sub(1, 1) ~= "n" then
    notify("Comment replacements are only available in normal mode", vim.log.levels.WARN)
    return false
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local eligible, reason = context.eligible(bufnr, state.config, true)
  if not eligible then
    notify("Comment replacement unavailable: " .. reason, vim.log.levels.WARN)
    return false
  end
  local captured, capture_error = context.capture_comment(bufnr, vim.api.nvim_get_current_win(), state.config)
  if not captured then
    notify("Comment replacement unavailable: " .. capture_error, vim.log.levels.WARN)
    return false
  end

  cancel_work()
  ui.dismiss()
  if state.config.loading_indicator then
    ui.show_loading(captured)
  end
  state.engine:request(with_activity(captured), true)
  return true
end

function M.accept()
  local visible = ui.current()
  if visible and not related.valid(visible.context) then
    state.cache[visible.context.bufnr] = nil
    ui.dismiss()
    return false
  end
  local accepted = ui.accept()
  if accepted and visible then
    local bufnr = visible.context.bufnr
    state.cache[bufnr] = nil
    state.accepted_changedtick[bufnr] = vim.api.nvim_buf_get_changedtick(bufnr)
  end
  return accepted
end

--- Waits for the next inline suggestion on behalf of the null-ls source.
---
--- A newer call supersedes an older one, which is answered with no suggestion.
---
---@param callback fun(captured: table|nil, completion: string|nil, replace_length: integer|nil)
---
function M._await_suggestion(callback)
  resolve_waiter()
  if not state.configured or not state.enabled then
    callback()
    return
  end
  local visible = ui.current()
  if visible and visible.context.kind == "completion" and context.is_current(visible.context) then
    callback(visible.context, visible.completion, visible.replace_length)
    return
  end
  state.waiter = callback
end

--- Returns the brief of the current buffer's project, optionally rewriting it.
---
---@param refresh boolean|nil Ask Codex to write the brief again.
---@return string|nil brief
---
function M.project_brief(refresh)
  if not state.configured then
    return nil
  end
  local root = brief.root(vim.api.nvim_get_current_buf())
  if refresh and root and state.enabled then
    local started = brief.ensure(root, state.engine, state.config, true, function(err)
      notify(err and ("Project brief failed: " .. err) or "Project brief updated", err and vim.log.levels.ERROR or nil)
    end)
    if not started then
      notify("Codex is busy with another background summary; try again shortly", vim.log.levels.WARN)
    end
  end
  return brief.get(root)
end

--- Returns the latest background summary of what the developer is working on.
---
---@return string|nil intent
---
function M.intent()
  return state.intent
end

function M.dismiss()
  state.cache[vim.api.nvim_get_current_buf()] = nil
  ui.dismiss()
  return true
end

function M.enable()
  if not state.configured then
    return false
  end
  state.enabled = true
  redraw_statusline()
  return true
end

function M.disable()
  if not state.configured then
    return false
  end
  state.enabled = false
  if state.intent_timer then
    state.intent_timer:stop()
  end
  resolve_waiter()
  cancel_work()
  ui.dismiss()
  redraw_statusline()
  return true
end

function M.toggle()
  if state.enabled then
    M.disable()
  else
    M.enable()
  end
  return state.enabled
end

local function model_label(model)
  return model or "Codex default"
end

local function apply_runtime(model, effort)
  if not state.configured then
    return false
  end
  if state.engine.model ~= model or state.engine.effort ~= effort then
    cancel_work()
    ui.dismiss()
    state.cache = {}
    state.engine:set_model(model)
    state.engine:set_effort(effort)
    redraw_statusline()
  end
  return true
end

local function supports_effort(model, effort)
  for _, option in ipairs(model.supportedReasoningEfforts) do
    if option.reasoningEffort == effort then
      return true
    end
  end
  return false
end

local function apply_model(model, available)
  local effort = state.engine.effort
  local adjusted = not supports_effort(available, effort)
  if adjusted then
    effort = available.defaultReasoningEffort
  end
  apply_runtime(model, effort)
  notify("Codex completion model: " .. model_label(model))
  if adjusted then
    notify("Reasoning effort adjusted to " .. effort .. " for " .. available.displayName)
  end
  return true
end

local function list_model_catalog(include_hidden, callback)
  if not state.configured then
    callback("Call require('codex_complete').setup() before listing models")
    return false
  end

  local engine = state.engine
  engine:list_models({ include_hidden = include_hidden }, function(err, models)
    if state.engine ~= engine then
      callback("Codex model request was superseded by setup")
      return
    end
    callback(err, models)
  end)
  return true
end

local function find_model(models, model)
  for _, available in ipairs(models) do
    if (model == nil and available.isDefault) or available.id == model or available.model == model then
      return available
    end
  end
end

function M.list_models(callback)
  if type(callback) ~= "function" then
    error("codex-complete: list_models callback must be a function")
  end
  return list_model_catalog(false, callback)
end

function M.list_efforts(callback)
  if type(callback) ~= "function" then
    error("codex-complete: list_efforts callback must be a function")
  end
  local model = state.engine and state.engine.model
  return list_model_catalog(true, function(err, models)
    if err then
      callback(err)
      return
    end
    local available = find_model(models, model)
    if not available then
      callback("Could not find the active Codex model in the model catalog")
      return
    end
    callback(nil, available.supportedReasoningEfforts)
  end)
end

function M.set_model(model)
  if type(model) ~= "string" or model == "" then
    notify("Model must be a non-empty string", vim.log.levels.ERROR)
    return false
  end

  return M.list_models(function(err, models)
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end
    for _, available in ipairs(models) do
      if available.id == model or available.model == model then
        apply_model(available.model, available)
        return
      end
    end
    notify("Codex model is not available: " .. model, vim.log.levels.ERROR)
  end)
end

function M.reset_model()
  if not state.configured then
    return false
  end
  local model = state.config.codex.model
  return list_model_catalog(true, function(err, models)
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end
    local available = find_model(models, model)
    if not available then
      notify("Configured Codex model is not available: " .. model_label(model), vim.log.levels.ERROR)
      return
    end
    apply_model(model, available)
  end)
end

function M.select_model()
  local engine = state.engine
  return M.list_models(function(err, models)
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end

    local reset = {
      reset = true,
      model = state.config.codex.model,
    }
    local choices = { reset }
    vim.list_extend(choices, models)
    vim.ui.select(choices, {
      prompt = "Codex completion model",
      format_item = function(item)
        local current = state.engine and state.engine.model
        if item.reset then
          local label = "Configured default (" .. model_label(item.model) .. ")"
          return item.model == current and label .. " [current]" or label
        end
        local label = item.displayName .. " (" .. item.model .. ")"
        return item.model == current and label .. " [current]" or label
      end,
    }, function(choice)
      if not choice or state.engine ~= engine then
        return
      end
      if choice.reset then
        M.reset_model()
      else
        apply_model(choice.model, choice)
      end
    end)
  end)
end

local function apply_effort(effort)
  apply_runtime(state.engine.model, effort)
  notify("Codex reasoning effort: " .. effort)
  return true
end

function M.set_effort(effort)
  if type(effort) ~= "string" or effort == "" then
    notify("Reasoning effort must be a non-empty string", vim.log.levels.ERROR)
    return false
  end

  return M.list_efforts(function(err, efforts)
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end
    for _, available in ipairs(efforts) do
      if available.reasoningEffort == effort then
        apply_effort(available.reasoningEffort)
        return
      end
    end
    notify("Reasoning effort is not available for the active model: " .. effort, vim.log.levels.ERROR)
  end)
end

function M.reset_effort()
  if not state.configured then
    return false
  end
  local effort = state.config.codex.effort
  return M.list_efforts(function(err, efforts)
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end
    for _, available in ipairs(efforts) do
      if available.reasoningEffort == effort then
        apply_effort(effort)
        return
      end
    end
    notify("Configured reasoning effort is not supported by the active model: " .. effort, vim.log.levels.ERROR)
  end)
end

function M.select_effort()
  local engine = state.engine
  return M.list_efforts(function(err, efforts)
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end

    local reset = {
      reset = true,
      reasoningEffort = state.config.codex.effort,
    }
    local choices = { reset }
    vim.list_extend(choices, efforts)
    vim.ui.select(choices, {
      prompt = "Codex reasoning effort",
      format_item = function(item)
        local current = state.engine and state.engine.effort
        if item.reset then
          local label = "Configured default (" .. item.reasoningEffort .. ")"
          return item.reasoningEffort == current and label .. " [current]" or label
        end
        local label = item.reasoningEffort
        if item.description ~= "" then
          label = label .. " - " .. item.description
        end
        return item.reasoningEffort == current and label .. " [current]" or label
      end,
    }, function(choice)
      if not choice or state.engine ~= engine then
        return
      end
      if choice.reset then
        M.reset_effort()
      else
        apply_effort(choice.reasoningEffort)
      end
    end)
  end)
end

function M.status()
  return {
    configured = state.configured,
    enabled = state.enabled,
    auto_trigger = state.config and state.config.auto_trigger or false,
    loading = ui.loading() ~= nil,
    suggestion_visible = ui.current() ~= nil,
    model = {
      current = state.engine and state.engine.model or nil,
      default = state.config and state.config.codex.model or nil,
    },
    effort = {
      current = state.engine and state.engine.effort or nil,
      default = state.config and state.config.codex.effort or nil,
    },
    intent = {
      text = state.intent,
      error = state.intent_error,
      pending = state.engine ~= nil and state.engine.background ~= nil,
    },
    engine = state.engine and state.engine:status() or nil,
  }
end

local function schedule_auto(args)
  local bufnr = args and args.buf or vim.api.nvim_get_current_buf()
  local accepted_changedtick = state.accepted_changedtick[bufnr]
  if accepted_changedtick then
    local event = args and args.event
    if event == "CursorMovedI" or vim.api.nvim_buf_get_changedtick(bufnr) == accepted_changedtick then
      return
    end
    state.accepted_changedtick[bufnr] = nil
  end
  ui.dismiss()
  cancel_work()
  if not state.enabled or not state.config.auto_trigger then
    return
  end
  if not context.eligible(bufnr, state.config, false) then
    return
  end
  local captured = context.capture(bufnr, vim.api.nvim_get_current_win(), state.config)
  local cached = state.cache[bufnr]
  if cached and related.valid(cached.context) then
    local remainder, paired_delimiter = context.cached_remainder(cached.context, captured, cached.completion)
    if remainder == "" then
      return
    elseif remainder then
      show(captured, remainder, paired_delimiter)
      return
    end
  end

  state.schedule_generation = state.schedule_generation + 1
  local generation = state.schedule_generation
  state.timer:start(
    state.config.debounce_ms,
    0,
    vim.schedule_wrap(function()
      if generation ~= state.schedule_generation then
        return
      end
      if vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i" then
        return
      end
      M.trigger({ manual = false, silent = true })
    end)
  )
end

local function clear_runtime()
  pcall(vim.api.nvim_del_augroup_by_name, "CodexComplete")
  for _, mapping in ipairs(state.mappings) do
    pcall(vim.keymap.del, mapping.mode, mapping.lhs)
  end
  state.mappings = {}
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
  if state.intent_timer then
    state.intent_timer:stop()
    state.intent_timer:close()
    state.intent_timer = nil
  end
  if state.engine then
    local engine = state.engine
    state.engine = nil
    engine:stop()
  end
  activity.reset()
  brief.reset()
  state.intent = nil
  state.intent_error = nil
  state.cache = {}
  state.accepted_changedtick = {}
  resolve_waiter()
  ui.dismiss()
end

local function set_mapping(mode, lhs, callback, description)
  if lhs == false then
    return
  end
  vim.keymap.set(mode, lhs, callback, { silent = true, desc = description })
  state.mappings[#state.mappings + 1] = { mode = mode, lhs = lhs }
end

local function create_commands()
  local commands = {
    CodexComplete = function()
      M.trigger({ manual = true })
    end,
    CodexCompleteComment = M.trigger_comment,
    CodexCompleteEnable = M.enable,
    CodexCompleteDisable = M.disable,
    CodexCompleteToggle = M.toggle,
    CodexCompleteDismiss = M.dismiss,
    CodexCompleteIntent = function()
      vim.notify(state.intent or "Codex has not summarised your recent edits yet", vim.log.levels.INFO, {
        title = "codex-complete.nvim",
      })
    end,
  }
  for name, callback in pairs(commands) do
    pcall(vim.api.nvim_del_user_command, name)
    vim.api.nvim_create_user_command(name, callback, {})
  end
  pcall(vim.api.nvim_del_user_command, "CodexCompleteProject")
  vim.api.nvim_create_user_command("CodexCompleteProject", function(args)
    local text = M.project_brief(args.bang)
    if not args.bang then
      vim.notify(text or "Codex has not written a brief for this project yet", vim.log.levels.INFO, {
        title = "codex-complete.nvim",
      })
    end
  end, {
    bang = true,
    desc = "Show or rewrite the Codex project brief",
  })
  pcall(vim.api.nvim_del_user_command, "CodexCompleteModel")
  vim.api.nvim_create_user_command("CodexCompleteModel", function(args)
    if args.bang then
      if args.args ~= "" then
        notify("CodexCompleteModel! does not accept a model argument", vim.log.levels.ERROR)
        return
      end
      M.reset_model()
    elseif args.args == "" then
      M.select_model()
    else
      M.set_model(args.args)
    end
  end, {
    bang = true,
    nargs = "?",
    desc = "Select the Codex completion model",
  })
  pcall(vim.api.nvim_del_user_command, "CodexCompleteEffort")
  vim.api.nvim_create_user_command("CodexCompleteEffort", function(args)
    if args.bang then
      if args.args ~= "" then
        notify("CodexCompleteEffort! does not accept an effort argument", vim.log.levels.ERROR)
        return
      end
      M.reset_effort()
    elseif args.args == "" then
      M.select_effort()
    else
      M.set_effort(args.args)
    end
  end, {
    bang = true,
    nargs = "?",
    desc = "Select the Codex reasoning effort",
  })
end

function M.setup(options)
  if state.configured then
    clear_runtime()
  end
  state.config = config_module.resolve(options)
  state.enabled = state.config.enabled
  state.timer = vim.uv.new_timer()
  state.intent_timer = vim.uv.new_timer()
  state.intent_revision = activity.revision()
  state.engine = Engine.new(state.config, {
    on_finished = function(captured)
      ui.dismiss(captured.bufnr)
    end,
    on_completion = function(captured, completion)
      if captured.kind == "comment" then
        ui.show_replacement(captured, completion, {
          highlights = state.config.highlights,
        })
        return
      end
      local reconciled, paired_delimiter = context.reconcile_completion(captured, completion)
      if reconciled == "" then
        return
      end
      state.cache[captured.bufnr] = { context = captured, completion = reconciled }
      show(captured, reconciled, paired_delimiter)
    end,
    on_error = function(message)
      notify(message, vim.log.levels.ERROR)
    end,
  })
  state.configured = true

  create_commands()
  local group = vim.api.nvim_create_augroup("CodexComplete", { clear = true })
  ui.setup_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = ui.setup_highlights,
  })
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChangedP", "CursorMovedI" }, {
    group = group,
    callback = schedule_auto,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    callback = function()
      local active = state.engine and state.engine.active
      local current = ui.current() or ui.loading() or active
      if current and current.context.kind == "comment" and not context.is_current(current.context) then
        cancel_work()
        ui.dismiss()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave", "BufDelete", "TextChanged" }, {
    group = group,
    callback = function(args)
      resolve_waiter()
      cancel_work()
      ui.dismiss()
      if args.event == "BufDelete" then
        state.cache[args.buf] = nil
        state.accepted_changedtick[args.buf] = nil
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufEnter", "InsertEnter" }, {
    group = group,
    callback = function(args)
      if not state.enabled then
        return
      end
      if state.config.context.activity.enabled and context.eligible(args.buf, state.config, true) then
        activity.track(args.buf)
        if args.event == "BufEnter" then
          activity.visit(args.buf)
        end
      end
      if state.config.project_brief.enabled and context.eligible(args.buf, state.config, true) then
        local root = brief.root(args.buf)
        if root then
          brief.ensure(root, state.engine, state.config)
        end
      end
      if
        args.event == "InsertEnter"
        and state.config.auto_trigger
        and state.config.codex.prewarm
        and context.eligible(args.buf, state.config, false)
      then
        local _, cwd = related.project({ bufnr = args.buf, filename = vim.api.nvim_buf_get_name(args.buf) })
        state.engine:prewarm(cwd)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "InsertLeave", "TextChanged", "BufWritePost" }, {
    group = group,
    callback = function(args)
      record_activity(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    callback = function(args)
      activity.forget(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      if state.engine then
        state.engine:stop()
      end
    end,
  })

  set_mapping("i", state.config.keymaps.accept, function()
    if not M.accept() then
      local keys = vim.api.nvim_replace_termcodes(state.config.keymaps.accept, true, false, true)
      vim.api.nvim_feedkeys(keys, "n", false)
    end
  end, "Accept Codex completion")
  set_mapping("i", state.config.keymaps.trigger, function()
    M.trigger({ manual = true })
  end, "Request Codex completion")
  set_mapping("i", state.config.keymaps.dismiss, M.dismiss, "Dismiss Codex completion")
  set_mapping("n", state.config.keymaps.comment_trigger, function()
    M.trigger_comment()
  end, "Generate code from comment")
  set_mapping("n", state.config.keymaps.comment_accept, function()
    if not M.accept() then
      local keys = vim.api.nvim_replace_termcodes(state.config.keymaps.comment_accept, true, false, true)
      vim.api.nvim_feedkeys(keys, "n", false)
    end
  end, "Accept Codex comment replacement")
  set_mapping("n", state.config.keymaps.toggle, function()
    M.toggle()
  end, "Toggle Codex suggestions")
  set_mapping("n", state.config.keymaps.select_model, function()
    M.select_model()
  end, "Select Codex completion model")
  set_mapping("n", state.config.keymaps.select_effort, function()
    M.select_effort()
  end, "Select Codex reasoning effort")
  require("codex_complete.null_ls").register()
  redraw_statusline()
  return M
end

M._state = state

return M
