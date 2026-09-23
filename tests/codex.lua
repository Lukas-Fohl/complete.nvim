vim.opt.runtimepath:append(vim.fn.getcwd())
local Provider = require('compl.providers.codex')
local log = vim.fn.tempname()
vim.env.COMPL_FAKE_LOG = log
local command = { 'python3', vim.fn.getcwd() .. '/tests/fake_server.py' }
local context = { file = { path = '', filetype = 'lua', lines = { 'abc' } } }
local function eq(a, b) assert(vim.deep_equal(a, b), vim.inspect(a) .. ' ~= ' .. vim.inspect(b)) end
local function wait(check) assert(vim.wait(3000, check, 5), 'timed out waiting for fake server') end
local function requests()
  local items = {}
  for _, line in ipairs(vim.fn.readfile(log)) do items[#items + 1] = vim.json.decode(line) end
  return items
end
local function count(method)
  local total = 0
  if vim.fn.filereadable(log) == 0 then return 0 end
  for _, item in ipairs(requests()) do if item.method == method then total = total + 1 end end
  return total
end
local function create(mode, timeout)
  vim.fn.writefile({}, log)
  vim.env.COMPL_FAKE_MODE = mode
  return Provider.new({ command = command, timeout_ms = timeout or 2000, position = 'model' })
end
local p = create('success')
for _ = 1, 2 do
  local completed = false
  p.generate(context, function(err, result)
    eq(err, nil)
    eq(result, { text = 'one\ntwo', position = { row = 0, col = 1 } })
    completed = true
  end)
  wait(function() return completed end)
end
eq(count('initialize'), 1)
eq(count('account/read'), 1)
eq(count('thread/start'), 1)
p.stop()

-- The larger limit and autonomy prompt are configurable per provider.
vim.fn.writefile({}, log)
p = Provider.new({ command = command, timeout_ms = 2000, position = 'model', max_suggestion_lines = 40, autonomous = true, fast = true })
local completed = false
p.generate(context, function(err) eq(err, nil); completed = true end)
wait(function() return completed end)
for _, item in ipairs(requests()) do
  if item.method == 'thread/start' then
    assert(item.params.developerInstructions:find('Work proactively', 1, true))
    assert(item.params.developerInstructions:find('at most 40 lines', 1, true))
  elseif item.method == 'turn/start' then
    eq(item.params.serviceTierForTurn, 'fast')
  end
end
p.stop()

-- Nearby and full-file context are explicit configuration choices.
local selection_context = { file = { path = '', filetype = 'lua', lines = { 'one', 'two', 'three' } } }
for _, choice in ipairs({
  { context = 'nearby', context_lines = 0, expected = { 'two' } },
  { context = 'file', context_lines = 0, expected = { 'one', 'two', 'three' } },
}) do
  vim.fn.writefile({}, log)
  p = Provider.new({ command = command, timeout_ms = 2000, position = 'model', context = choice.context, context_lines = choice.context_lines })
  local completed = false
  p.generate(selection_context, function(err) eq(err, nil); completed = true end, { position = { row = 1, col = 0 } })
  wait(function() return completed end)
  for _, item in ipairs(requests()) do
    if item.method == 'turn/start' then
      local payload = vim.json.decode(item.params.input[1].text:match('\n(.*)'))
      eq(payload.file.lines, choice.expected)
    end
  end
  p.stop()
end

for mode, expected in pairs({
  signed_out = 'codex login', rpc_error = 'Usage limit', bad_output = 'invalid suggestion',
  bad_wire = 'Invalid JSON', exit = 'exited', hang = 'timed out', hang_init = 'timed out',
  approval = 'interactive tool',
}) do
  p = create(mode, (mode == 'hang' or mode == 'hang_init') and 150 or 2000)
  local error
  p.generate(context, function(err) error = err end)
  wait(function() return error ~= nil end)
  assert(error:find(expected, 1, true), error)
  if mode == 'approval' then
    wait(function()
      for _, item in ipairs(requests()) do
        if item.id == 'approval-1' then return item.result.decision == 'decline' end
      end
      return false
    end)
  end
  p.stop()
end

-- Cancellation before thread/turn IDs arrive still interrupts the request.
for _, mode in ipairs({ 'slow_thread', 'slow_turn', 'hang' }) do
  p = create(mode)
  local called = false
  local cancel = p.generate(context, function() called = true end)
  wait(function() return count(mode == 'slow_thread' and 'thread/start' or 'turn/start') == 1 end)
  cancel()
  if mode ~= 'slow_thread' then wait(function() return count('turn/interrupt') >= 1 end) end
  eq(called, false)
  p.stop()
end

-- The same provider can start a fresh process after a crash.
p = create('exit')
local failed = false
p.generate(context, function(err) failed = err ~= nil end)
wait(function() return failed end)
vim.env.COMPL_FAKE_MODE = 'success'
local recovered = false
p.generate(context, function(err) eq(err, nil); recovered = true end)
wait(function() return recovered end)
p.stop()

-- End-to-end controller: async render, cancellation, and acceptance.
vim.env.COMPL_FAKE_MODE = 'success'
vim.g.mapleader = ' '
local compl = require('compl')
local notifications = {}
vim.notify = function(message) notifications[#notifications + 1] = message end
compl.setup({ provider = 'codex', codex = { command = command, timeout_ms = 2000 } })
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'abc' })
local ns = vim.api.nvim_get_namespaces().compl
local function marks() return vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {}) end
compl.trigger()
wait(function() return compl.stats().request.status == 'completed' and #marks() == 1 end)
compl.accept()
eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'one', 'twoabc' })
compl.trigger()
compl.dismiss()
vim.wait(200, function() return false end, 10)
eq(#marks(), 0)
compl.trigger()
vim.api.nvim_exec_autocmds('CursorMoved', { buffer = 0 })
vim.wait(200, function() return false end, 10)
eq(#marks(), 0)
-- Replacement requests and buffer events must never resurrect old previews.
compl.trigger()
compl.trigger()
wait(function() return #marks() == 1 end)
compl.dismiss()
for _, event in ipairs({ 'TextChanged', 'InsertEnter', 'BufLeave', 'BufWipeout' }) do
  compl.trigger()
  vim.api.nvim_exec_autocmds(event, { buffer = 0 })
  vim.wait(100, function() return false end, 10)
  eq(#marks(), 0)
end
-- Even without a delivered edit event, the changed tick rejects stale output.
compl.trigger()
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'changed during generation' })
vim.wait(200, function() return false end, 10)
eq(#marks(), 0)

-- Suggestion controls are temporary and preserve a user's buffer-local mapping.
compl.dismiss()
vim.keymap.set('n', '<Tab>', 'l', { buffer = 0 })
vim.env.COMPL_FAKE_MODE = 'hang'
compl.setup({
  provider = 'codex',
  codex = { command = command, timeout_ms = 2000, auto_start = false },
  keys = { suggestion = { accept = '<C-y>', dismiss = '<C-e>' } },
})
compl.trigger()
wait(function()
  return vim.fn.maparg('<C-y>', 'n', false, true).desc == 'compl: accept suggestion'
end)
eq(vim.fn.maparg('<C-e>', 'n', false, true).desc, 'compl: dismiss suggestion')
eq(vim.fn.maparg('<Tab>', 'n', false, true).rhs, 'l')
compl.dismiss()
eq(vim.fn.maparg('<Tab>', 'n', false, true).rhs, 'l')
pcall(vim.keymap.del, 'n', '<Tab>', { buffer = 0 })
compl.setup()
vim.fn.delete(log)
print('compl.nvim: App Server checks passed')
vim.cmd('qa!')
