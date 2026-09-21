vim.opt.runtimepath:append(vim.fn.getcwd())
vim.g.mapleader = ' '
local compl = require('compl')
compl.setup()
local ns = vim.api.nvim_get_namespaces().compl
local function eq(actual, expected)
  assert(vim.deep_equal(actual, expected), vim.inspect(actual) .. ' ~= ' .. vim.inspect(expected))
end
local function marks()
  return vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })
end
local function content()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end
local function keys(value)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(value, true, false, true), 'xt', false)
end
local function fresh(lines, col)
  compl.dismiss()
  vim.cmd('enew!')
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(0, { 1, col or 0 })
end

fresh({ 'hello', 'unsaved second line' })
local before = content()
local tick = vim.api.nvim_buf_get_changedtick(0)
keys(' cg')
eq(#marks(), 1)
eq(marks()[1][4].virt_text[1][1], 'example suggestion')
eq(content(), before)
eq(vim.api.nvim_buf_get_changedtick(0), tick)

local ghost = require('compl.ghost')
ghost.thinking(vim.api.nvim_get_current_buf(), { file = { lines = content() } }, tick, vim.api.nvim_win_get_cursor(0))
eq(marks()[1][4].virt_text[1], { ' … thinking', 'ComplThinking' })
ghost.accept()
eq(content(), before)
ghost.dismiss()
eq(#marks(), 0)

keys(' cg')
keys(' ca')
eq(content(), { 'example suggestionhello', 'unsaved second line' })
eq(#marks(), 0)
keys('u')
eq(content(), before)
compl.accept()
compl.dismiss()
eq(content(), before)

keys(' cg')
keys(' cd')
eq(#marks(), 0)
eq(content(), before)
compl.trigger()
compl.trigger()
eq(#marks(), 1)
keys('l')
-- Headless feedkeys does not run the interactive idle event loop.
vim.api.nvim_exec_autocmds('CursorMoved', { buffer = 0 })
eq(#marks(), 0)

for _, event in ipairs({ 'TextChanged', 'TextChangedI', 'TextChangedP',
  'CursorMoved', 'CursorMovedI', 'InsertEnter', 'BufLeave', 'BufWipeout' }) do
  compl.trigger()
  vim.api.nvim_exec_autocmds(event, { buffer = 0 })
  eq(#marks(), 0)
end

fresh({ 'original' })
compl.trigger()
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'edited' })
compl.accept() -- Reject stale contents even before TextChanged runs.
eq(content(), { 'edited' })
eq(#marks(), 0)

fresh({ '' })
compl.trigger()
compl.accept()
eq(content(), { 'example suggestion' })

vim.o.virtualedit = 'onemore'
fresh({ 'abc' }, 3)
compl.trigger()
compl.accept()
eq(content(), { 'abcexample suggestion' })
vim.o.virtualedit = ''

fresh({ 'éabc' }, 2)
compl.trigger()
compl.accept()
eq(content(), { 'éexample suggestionabc' })

fresh({ 'first' })
local old = vim.api.nvim_get_current_buf()
compl.trigger()
vim.cmd('enew!')
eq(vim.api.nvim_buf_get_extmarks(old, ns, 0, -1, {}), {})
compl.accept()
eq(content(), { '' })

vim.bo.modifiable = false
compl.trigger()
eq(#marks(), 0)
vim.bo.modifiable = true
vim.bo.buftype = 'nofile'
compl.trigger()
eq(#marks(), 0)
vim.bo.buftype = ''

compl.setup({ keys = { trigger = 'gS', accept = false, dismiss = false } })
eq(vim.fn.maparg(' cg', 'n'), '')
eq(vim.fn.maparg(' ca', 'n'), '')
keys('gS')
eq(#marks(), 1)
compl.setup()
eq(#marks(), 0)
eq(vim.fn.maparg('gS', 'n'), '')
-- The processor receives only file context; its output feeds the generator.
fresh({ 'first', 'second' })
local captured
compl.setup({
  process = function(context)
    eq(vim.tbl_keys(context), { 'file' })
    eq(context.file.lines, { 'first', 'second' })
    eq(context.file.path, '')
    eq(context.file.filetype, '')
    captured = context
    context.processed = true
    return context
  end,
  generate = function(context)
    eq(context, captured)
    eq(context.processed, true)
    return { text = '!', position = { row = 1, col = 3 } }
  end,
})
keys(' cg')
eq(marks()[1][2], 1)
eq(marks()[1][3], 3)
eq(content(), { 'first', 'second' })
keys(' ca')
eq(content(), { 'first', 'sec!ond' })
keys('u')
eq(content(), { 'first', 'second' })

for _, result in ipairs({
  { text = '!', position = { row = 2, col = 0 } },
  { text = '!', position = { row = 0, col = 99 } },
  { text = '!', position = { row = -1, col = 0 } },
  { text = '!', position = { row = 0, col = 0.5 } },
  { text = 'bad\rnewline' },
}) do
  compl.setup({ generate = function() return result end })
  eq(pcall(compl.trigger), false)
  eq(#marks(), 0)
end
fresh({ 'éabc' })
compl.setup({ generate = function()
  return { text = '!', position = { row = 0, col = 1 } }
end })
eq(pcall(compl.trigger), false)
eq(#marks(), 0)
for _, generate in ipairs({ function() return nil end, function() return { text = '' } end }) do
  compl.setup({ generate = generate })
  compl.trigger()
  eq(#marks(), 0)
end
compl.setup()
compl.trigger()
eq(#marks(), 1)
compl.dismiss()
for _, case in ipairs({
  { 'abc', 0, 'x\ny', { 'x', 'yabc' } },
  { 'abc', 1, 'x\ny', { 'ax', 'ybc' } },
  { 'abc', 3, 'x\n', { 'abcx', '' } },
  { '', 0, '\nx\n', { '', 'x', '' } },
  { 'éabc', 2, 'x\ny', { 'éx', 'yabc' } },
}) do
  fresh({ case[1] })
  compl.setup({ generate = function()
    return { text = case[3], position = { row = 0, col = case[2] } }
  end })
  keys(' cg')
  eq(#marks()[1][4].virt_lines, #case[4] - 1)
  keys(' ca')
  eq(content(), case[4])
  keys('u')
  eq(content(), { case[1] })
end
print('compl.nvim: all checks passed')
vim.cmd('qa!')
