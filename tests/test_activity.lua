local MiniTest = require("mini.test")
local activity = require("codex_complete.activity")

local options = { max_edits = 3, max_bytes = 4096 }

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      activity.reset()
      vim.cmd("enew!")
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local a = 1", "local b = 2" })
    end,
  },
})

T["records an edit as a unified diff against the tracked baseline"] = function()
  local revision = activity.revision()
  activity.track(0)
  MiniTest.expect.equality(activity.record(0, options), false)
  vim.api.nvim_buf_set_lines(0, 1, 2, false, { "local b = 3" })
  MiniTest.expect.equality(activity.record(0, options), true)
  MiniTest.expect.equality(activity.revision(), revision + 1)

  local edits = activity.snapshot(options)
  MiniTest.expect.equality(#edits, 1)
  MiniTest.expect.equality(edits[1].diff:find("-local b = 2", 1, true) ~= nil, true)
  MiniTest.expect.equality(edits[1].diff:find("+local b = 3", 1, true) ~= nil, true)
  MiniTest.expect.equality(activity.record(0, options), false)
end

T["keeps a rolling window of the newest edits"] = function()
  activity.track(0)
  for index = 1, 5 do
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "local a = " .. index * 10 })
    activity.record(0, options)
  end
  local edits = activity.snapshot(options)
  MiniTest.expect.equality(#edits, 3)
  MiniTest.expect.equality(edits[1].diff:find("+local a = 30", 1, true) ~= nil, true)
  MiniTest.expect.equality(edits[3].diff:find("+local a = 50", 1, true) ~= nil, true)
end

T["drops the oldest edits that exceed the byte budget"] = function()
  activity.track(0)
  for index = 2, 4 do
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "local a = " .. index })
    activity.record(0, options)
  end
  local all = activity.snapshot(options)
  local newest = all[#all].diff
  local edits = activity.snapshot({ max_edits = 3, max_bytes = #newest })
  MiniTest.expect.equality(#edits, 1)
  MiniTest.expect.equality(edits[1].diff, newest)
  MiniTest.expect.equality(activity.snapshot({ max_edits = 3, max_bytes = 1 }), nil)
end

T["clips oversized diffs on line boundaries"] = function()
  activity.track(0)
  local lines = {}
  for index = 1, 200 do
    lines[index] = "value_" .. index .. " = " .. string.rep("x", 40)
  end
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  activity.record(0, options)
  local diff = activity.snapshot(options)[1].diff
  MiniTest.expect.equality(#diff <= 1204, true)
  MiniTest.expect.equality(diff:sub(-4), "...\n")
end

T["lists visited files with the most recent last"] = function()
  local directory = vim.fn.tempname()
  vim.api.nvim_buf_set_name(0, directory .. "/one.lua")
  activity.visit(0)
  vim.cmd("enew!")
  vim.api.nvim_buf_set_name(0, directory .. "/two.lua")
  activity.visit(0)
  local _, files = activity.snapshot(options)
  MiniTest.expect.equality(#files, 2)
  MiniTest.expect.equality(vim.fs.basename(files[2]), "two.lua")
end

return T
