local MiniTest = require("mini.test")
local config = require("codex_complete.config")
local hints = require("codex_complete.hints")

local client_id
local received

local function start_server(responses)
  received = {}
  client_id = vim.lsp.start({
    name = "hints-test",
    cmd = function()
      return {
        request = function(method, params, callback)
          if method == "initialize" then
            callback(nil, {
              capabilities = {
                hoverProvider = true,
                signatureHelpProvider = { triggerCharacters = { "(" } },
                completionProvider = {},
              },
            })
          elseif method == "shutdown" then
            callback(nil, nil)
          else
            received[#received + 1] = { method = method, params = params }
            local response = responses[method]
            if response ~= false then
              callback(nil, response)
            end
          end
          return true, #received + 1
        end,
        notify = function() end,
        is_closing = function()
          return false
        end,
        terminate = function() end,
      }
    end,
  })
  vim.wait(2000, function()
    local client = vim.lsp.get_client_by_id(client_id)
    return client ~= nil and client.initialized == true and #vim.lsp.get_clients({ bufnr = 0 }) > 0
  end, 10)
end

local function captured()
  local cursor = vim.api.nvim_win_get_cursor(0)
  return { kind = "completion", bufnr = vim.api.nvim_get_current_buf(), row = cursor[1], col = cursor[2] }
end

local function collect(value, target)
  local finished = false
  hints.collect(target, value, function()
    finished = true
  end)
  MiniTest.expect.equality(
    vim.wait(2000, function()
      return finished
    end, 10),
    true
  )
  return target.lsp
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      client_id = nil
      vim.cmd("enew!")
      vim.wo.virtualedit = "onemore"
      vim.bo.filetype = "lua"
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local total = math.max(count, pri" })
      vim.api.nvim_win_set_cursor(0, { 1, 33 })
    end,
    post_case = function()
      vim.diagnostic.reset()
      if client_id then
        vim.lsp.stop_client(client_id, true)
      end
    end,
  },
})

T["finishes immediately without language servers or diagnostics"] = function()
  MiniTest.expect.equality(collect(config.resolve(), captured()), nil)
end

T["skips comment requests and disabled collection"] = function()
  local comment = captured()
  comment.kind = "comment"
  MiniTest.expect.equality(collect(config.resolve(), comment), nil)
  MiniTest.expect.equality(collect(config.resolve({ context = { lsp = { enabled = false } } }), captured()), nil)
end

T["includes diagnostics near the cursor"] = function()
  local namespace = vim.api.nvim_create_namespace("codex_complete_hints_test")
  vim.diagnostic.set(namespace, 0, {
    { lnum = 0, col = 0, message = "undefined variable count", severity = vim.diagnostic.severity.WARN },
  })
  local lsp = collect(config.resolve(), captured())
  MiniTest.expect.equality(lsp.diagnostics, { { line = 1, severity = "warn", message = "undefined variable count" } })
end

T["gathers signature help, completions, and hover text"] = function()
  start_server({
    ["textDocument/signatureHelp"] = {
      activeSignature = 0,
      activeParameter = 1,
      signatures = {
        {
          label = "max(x: number, ...: number)",
          parameters = { { label = "x: number" }, { label = "...: number" } },
        },
      },
    },
    ["textDocument/completion"] = {
      items = { { label = "print" }, { label = "pairs" }, { label = "private_value" }, { label = "PRInt" } },
    },
    ["textDocument/hover"] = { contents = { kind = "markdown", value = "```lua\nlocal count: integer\n```" } },
  })
  local lsp = collect(config.resolve({ context = { lsp = { max_hover = 1 } } }), captured())
  MiniTest.expect.equality(lsp.signature, { label = "max(x: number, ...: number)", active_parameter = "...: number" })
  MiniTest.expect.equality(lsp.completions, { "print", "private_value", "PRInt" })
  MiniTest.expect.equality(#lsp.hover, 1)
  MiniTest.expect.equality(lsp.hover[1].symbol, "count")
  MiniTest.expect.equality(lsp.hover[1].text:find("local count: integer", 1, true) ~= nil, true)

  local hover_request
  for _, request in ipairs(received) do
    if request.method == "textDocument/hover" then
      hover_request = request
    end
  end
  MiniTest.expect.equality(hover_request.params.position, { line = 0, character = 23 })
end

T["stops waiting at the deadline and keeps what arrived"] = function()
  start_server({
    ["textDocument/signatureHelp"] = false,
    ["textDocument/hover"] = false,
    ["textDocument/completion"] = { { label = "print" } },
  })
  local value = config.resolve({ context = { lsp = { timeout_ms = 30 } } })
  local started = vim.uv.hrtime()
  local lsp = collect(value, captured())
  MiniTest.expect.equality((vim.uv.hrtime() - started) / 1e6 < 1500, true)
  MiniTest.expect.equality(lsp, { completions = { "print" } })
end

T["cancelling suppresses the callback"] = function()
  start_server({
    ["textDocument/signatureHelp"] = false,
    ["textDocument/hover"] = false,
    ["textDocument/completion"] = false,
  })
  local finished = false
  local cancel = hints.collect(captured(), config.resolve({ context = { lsp = { timeout_ms = 30 } } }), function()
    finished = true
  end)
  cancel()
  vim.wait(120, function()
    return finished
  end, 10)
  MiniTest.expect.equality(finished, false)
end

return T
