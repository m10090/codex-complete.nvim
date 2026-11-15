local MiniTest = require("mini.test")
local config = require("codex_complete.config")
local prompt = require("codex_complete.prompt")

local T = MiniTest.new_set()

T["builds a JSON-only context payload"] = function()
  local encoded = prompt.build({
    filename = "example.lua",
    filetype = "lua",
    row = 2,
    col = 4,
    prefix = "local foo",
    suffix = "bar",
  })
  local decoded = vim.json.decode(encoded)
  MiniTest.expect.equality(decoded.kind, "completion")
  MiniTest.expect.equality(decoded.prefix, "local foo")
  MiniTest.expect.equality(decoded.cursor, { line = 2, byte_column = 4 })
end

T["builds comment replacement payloads"] = function()
  local encoded = prompt.build({
    kind = "comment",
    filename = "example.lua",
    filetype = "lua",
    row = 2,
    col = 5,
    prefix = "local foo =\n  ",
    suffix = "\nreturn foo",
    instruction = "-- initialize foo",
    edit = { start_row = 1, start_col = 2, end_row = 1, end_col = 19 },
  })
  local decoded = vim.json.decode(encoded)
  MiniTest.expect.equality(decoded.kind, "comment")
  MiniTest.expect.equality(decoded.instruction, "-- initialize foo")
  MiniTest.expect.equality(decoded.replacement, {
    start = { line = 2, byte_column = 2 },
    finish = { line = 2, byte_column = 19 },
  })
end

T["parses single and multiline structured output"] = function()
  local value = prompt.parse('{"completion":"bar\\nbaz"}', config.resolve())
  MiniTest.expect.equality(value, "bar\nbaz")
end

T["rejects malformed and oversized output"] = function()
  local _, malformed = prompt.parse("bar", config.resolve())
  MiniTest.expect.equality(type(malformed), "string")
  local _, oversized = prompt.parse('{"completion":"abcdef"}', config.resolve({ suggestion = { max_bytes = 3 } }))
  MiniTest.expect.equality(type(oversized), "string")
end

T["uses tool-free instructions for inline completions only"] = function()
  local value = config.resolve()
  MiniTest.expect.equality(prompt.instructions("completion", value), prompt.fast_instructions)
  MiniTest.expect.equality(prompt.instructions(nil, value), prompt.fast_instructions)
  MiniTest.expect.equality(prompt.instructions("comment", value), prompt.developer_instructions)
  local with_tools = config.resolve({ codex = { completion_tools = true } })
  MiniTest.expect.equality(prompt.instructions("completion", with_tools), prompt.developer_instructions)
  MiniTest.expect.equality(prompt.fast_instructions:find("Never read files", 1, true) ~= nil, true)
end

T["includes language-server facts, recent edits, and intent in the payload"] = function()
  local decoded = vim.json.decode(prompt.build({
    filename = "example.lua",
    filetype = "lua",
    row = 1,
    col = 0,
    prefix = "",
    suffix = "",
    lsp = { completions = { "print" } },
    recent_edits = { { filename = "example.lua", diff = "+local a = 1\n" } },
    recent_files = { "example.lua" },
    intent = "Adding a counter.",
  }))
  MiniTest.expect.equality(decoded.lsp, { completions = { "print" } })
  MiniTest.expect.equality(decoded.recent_edits[1].diff, "+local a = 1\n")
  MiniTest.expect.equality(decoded.recent_files, { "example.lua" })
  MiniTest.expect.equality(decoded.intent, "Adding a counter.")
end

T["builds and parses intent summaries"] = function()
  local payload = vim.json.decode(prompt.build_intent({
    recent_edits = { { filename = "a.lua", diff = "+x\n" } },
    recent_files = { "a.lua" },
    intent = "Earlier goal.",
  }))
  MiniTest.expect.equality(payload.previous_intent, "Earlier goal.")
  MiniTest.expect.equality(payload.recent_edits[1].filename, "a.lua")
  MiniTest.expect.equality(prompt.parse_intent('{"intent":"  Adding\\n a counter. "}'), "Adding a counter.")
  local _, malformed = prompt.parse_intent("not json")
  MiniTest.expect.equality(type(malformed), "string")
  MiniTest.expect.equality(#prompt.parse_intent(vim.json.encode({ intent = string.rep("é", 2000) })) <= 1024, true)
end

return T
