local MiniTest = require("mini.test")
local plugin = require("codex_complete")
local source = require("codex_complete.null_ls")
local ui = require("codex_complete.ui")

local function python_command(...)
  local python = vim.fn.exepath("python3")
  if python == "" then
    python = vim.fn.exepath("python")
  end
  local command = { python, vim.fn.getcwd() .. "/tests/fixtures/mock_codex.py" }
  vim.list_extend(command, { ... })
  return command
end

local function captured()
  local cursor = vim.api.nvim_win_get_cursor(0)
  return {
    kind = "completion",
    bufnr = vim.api.nvim_get_current_buf(),
    winid = vim.api.nvim_get_current_win(),
    row = cursor[1],
    col = cursor[2],
    changedtick = vim.api.nvim_buf_get_changedtick(0),
    filetype = "lua",
  }
end

local function extmark_count()
  return #vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace("codex_complete"), 0, -1, {})
end

local function wait_for(condition)
  MiniTest.expect.equality(vim.wait(5000, condition, 10), true)
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      vim.cmd("enew!")
      vim.wo.virtualedit = "onemore"
      vim.bo.filetype = "lua"
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local value = pri" })
      vim.api.nvim_win_set_cursor(0, { 1, 17 })
      plugin.setup({ auto_trigger = false })
    end,
    post_case = function()
      plugin.disable()
      ui.dismiss()
    end,
  },
})

T["builds an item that replaces the typed keyword"] = function()
  local item = source.item(captured(), "nt(value)", 0)
  MiniTest.expect.equality(item.label, "print(value)")
  MiniTest.expect.equality(item.filterText, "print(value)")
  MiniTest.expect.equality(item.textEdit.newText, "print(value)")
  MiniTest.expect.equality(item.textEdit.range, {
    start = { line = 0, character = 14 },
    ["end"] = { line = 0, character = 17 },
  })
  MiniTest.expect.equality(item.documentation.value, "```lua\nprint(value)\n```")
  MiniTest.expect.equality(item.kind, 23)
  MiniTest.expect.equality(item.labelDetails, { description = "Codex" })
  MiniTest.expect.equality(item.data, { codex_complete = true })
end

T["gives Codex entries their own kind in the nvim-cmp menu"] = function()
  local entry = { completion_item = source.item(captured(), "nt(value)", 0) }
  local formatted = source.cmp_format(entry, { abbr = "print(value)", kind = "Event", menu = "Codex" }, "* Codex")
  MiniTest.expect.equality(formatted, { abbr = "print(value)", kind = "* Codex", kind_hl_group = "CodexCompleteKind" })
  MiniTest.expect.equality(source.cmp_format(entry, { kind = "Event" }).kind, "Codex")

  local other = { completion_item = { label = "print", data = { id = 1 } } }
  MiniTest.expect.equality(source.cmp_format(other, { kind = "Function" }), { kind = "Function" })
  MiniTest.expect.equality(source.cmp_format({ completion_item = {} }, { kind = "Text" }), { kind = "Text" })
end

T["marks multiline suggestions and covers a paired delimiter"] = function()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "call()" })
  vim.api.nvim_win_set_cursor(0, { 1, 5 })
  local item = source.item(captured(), "\n  value\n)", 1)
  MiniTest.expect.equality(item.label, "value …")
  MiniTest.expect.equality(item.textEdit.newText, "\n  value\n)")
  MiniTest.expect.equality(item.textEdit.range, {
    start = { line = 0, character = 5 },
    ["end"] = { line = 0, character = 6 },
  })
end

T["converts byte columns to the client encoding"] = function()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local s = 'é' .. pri" })
  vim.api.nvim_win_set_cursor(0, { 1, 21 })
  local utf16 = source.item(captured(), "nt()", 0, "utf-16")
  MiniTest.expect.equality(utf16.textEdit.range.start.character, 17)
  MiniTest.expect.equality(utf16.textEdit.range["end"].character, 20)
  local utf8 = source.item(captured(), "nt()", 0, "utf-8")
  MiniTest.expect.equality(utf8.textEdit.range.start.character, 18)
  MiniTest.expect.equality(utf8.textEdit.range["end"].character, 21)
end

T["completes with the suggestion once it arrives, without ghost text"] = function()
  plugin.setup({ auto_trigger = false, codex = { command = python_command(), timeout_ms = 5000 } })
  local params = { bufnr = vim.api.nvim_get_current_buf() }
  local response
  source.complete(params, function(result)
    response = result
  end)
  MiniTest.expect.equality(response, nil)
  MiniTest.expect.equality(plugin.trigger({ manual = true }), true)
  wait_for(function()
    return response ~= nil
  end)
  MiniTest.expect.equality(#response, 1)
  MiniTest.expect.equality(response[1].isIncomplete, true)
  MiniTest.expect.equality(#response[1].items, 1)
  MiniTest.expect.equality(response[1].items[1].textEdit.newText, "pri" .. ui.current().completion)
  MiniTest.expect.equality(extmark_count(), 0)

  local immediate
  source.complete(params, function(result)
    immediate = result
  end)
  MiniTest.expect.equality(immediate[1].items[1].textEdit.newText, response[1].items[1].textEdit.newText)
  MiniTest.expect.equality(plugin.accept(), true)
  MiniTest.expect.equality(
    table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"),
    "local value = " .. response[1].items[1].textEdit.newText
  )
end

T["draws ghost text only when enabled"] = function()
  plugin.setup({
    auto_trigger = false,
    ghost_text = true,
    loading_indicator = false,
    codex = { command = python_command(), timeout_ms = 5000 },
  })
  MiniTest.expect.equality(plugin.trigger({ manual = true }), true)
  wait_for(function()
    return plugin.status().suggestion_visible
  end)
  MiniTest.expect.equality(extmark_count() > 0, true)
end

T["ignores suggestions for another buffer"] = function()
  plugin.setup({ auto_trigger = false, codex = { command = python_command(), timeout_ms = 5000 } })
  local response
  source.complete({ bufnr = -1 }, function(result)
    response = result
  end)
  MiniTest.expect.equality(plugin.trigger({ manual = true }), true)
  wait_for(function()
    return response ~= nil
  end)
  MiniTest.expect.equality(response[1].items, {})
end

T["answers a superseded or abandoned request with no items"] = function()
  local params = { bufnr = vim.api.nvim_get_current_buf() }
  local first, second
  source.complete(params, function(result)
    first = result
  end)
  source.complete(params, function(result)
    second = result
  end)
  MiniTest.expect.equality(first[1].items, {})
  MiniTest.expect.equality(second, nil)
  plugin.disable()
  MiniTest.expect.equality(second[1].items, {})
end

T["opens an nvim-cmp menu limited to Codex entries unless one is listed"] = function()
  local calls = {}
  local entries = {}
  package.loaded["cmp"] = {
    complete = function(options)
      calls[#calls + 1] = options
    end,
    get_entries = function()
      return entries
    end,
  }
  local get_mode = vim.api.nvim_get_mode
  vim.api.nvim_get_mode = function()
    return { mode = "i", blocking = false }
  end
  local function suggest(options)
    plugin.setup(vim.tbl_extend("force", {
      auto_trigger = false,
      codex = { command = python_command(), timeout_ms = 5000 },
    }, options or {}))
    MiniTest.expect.equality(plugin.trigger({ manual = true }), true)
    wait_for(function()
      return plugin.status().suggestion_visible
    end)
    vim.wait(300, function()
      return false
    end, 10)
  end

  suggest()
  MiniTest.expect.equality(#calls, 1)
  local configured = calls[1].config.sources[1]
  MiniTest.expect.equality(configured.name, "nvim_lsp")
  MiniTest.expect.equality(configured.entry_filter({ completion_item = { data = { codex_complete = true } } }), true)
  MiniTest.expect.equality(configured.entry_filter({ completion_item = { label = "print" } }), false)

  --- A menu already listing the Codex entry is left alone.
  entries = { { completion_item = { label = "print" } }, { completion_item = { data = { codex_complete = true } } } }
  suggest()
  MiniTest.expect.equality(#calls, 1)

  entries = {}
  suggest({ open_menu = false })
  MiniTest.expect.equality(#calls, 1)
  package.loaded["cmp"] = nil
  vim.api.nvim_get_mode = get_mode
end

T["does not register without null-ls installed"] = function()
  MiniTest.expect.equality(source.register(), false)
end

return T
