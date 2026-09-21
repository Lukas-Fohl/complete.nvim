local M = {}

local context = require('compl.context')
local processor = require('compl.processor')
local ghost = require('compl.ghost')
local mappings = {}
local process = processor.process
local generate = function()
  return { text = 'example suggestion' }
end
local provider
local active
local controls
local suggestion_keys = { accept = { '<Tab>', '<CR>' }, dismiss = { '<Esc>' } }

local function key_list(value, defaults, name)
  if value == nil then return vim.deepcopy(defaults) end
  if value == false then return {} end
  if type(value) == 'string' then value = { value } end
  assert(type(value) == 'table', 'compl: ' .. name .. ' must be a key, a list of keys, or false')
  local keys = {}
  for _, lhs in ipairs(value) do
    assert(type(lhs) == 'string' and lhs ~= '', 'compl: ' .. name .. ' contains an invalid key')
    keys[#keys + 1] = lhs
  end
  return keys
end

local function clear_controls()
  if not controls then return end
  local current = controls
  controls = nil
  for _, lhs in ipairs(current.keys) do
    local previous = current.previous[lhs]
    pcall(vim.keymap.del, 'n', lhs, { buffer = current.buf })
    if previous then
      vim.keymap.set('n', lhs, previous.callback or previous.rhs, {
        buffer = current.buf,
        desc = previous.desc,
        expr = previous.expr == 1,
        nowait = previous.nowait == 1,
        remap = previous.noremap ~= 1,
        script = previous.script == 1,
        silent = previous.silent == 1,
      })
    end
  end
end

local function set_controls(buf)
  clear_controls()
  local previous = {}
  local keys, seen = {}, {}
  for _, action in ipairs({ 'accept', 'dismiss' }) do
    for _, lhs in ipairs(suggestion_keys[action]) do
      assert(not seen[lhs], 'compl: a suggestion key cannot accept and dismiss')
      seen[lhs] = true
      keys[#keys + 1] = lhs
    end
  end
  for _, lhs in ipairs(keys) do
    local mapping = vim.fn.maparg(lhs, 'n', false, true)
    if mapping and (mapping.buffer == 1 or mapping.buffer == true) then previous[lhs] = mapping end
  end
  controls = { buf = buf, keys = keys, previous = previous }
  for _, lhs in ipairs(suggestion_keys.accept) do
    vim.keymap.set('n', lhs, M.accept, { buffer = buf, desc = 'compl: accept suggestion', silent = true })
  end
  for _, lhs in ipairs(suggestion_keys.dismiss) do
    vim.keymap.set('n', lhs, M.dismiss, { buffer = buf, desc = 'compl: dismiss suggestion', silent = true })
  end
end

function M.dismiss()
  local previous = active
  active = nil
  if previous and previous.cancel then previous.cancel() end
  clear_controls()
  ghost.dismiss()
end

function M.trigger()
  M.dismiss()
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].buftype ~= '' or not vim.bo[buf].modifiable then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local snapshot = context.capture(buf)
  local processed = process(vim.deepcopy(snapshot))
  if not provider then
    local result = generate(processed)
    if result ~= nil then
      if ghost.show(buf, snapshot, tick, cursor, result) then set_controls(buf) end
    end
    return
  end
  local request = { buf = buf }
  active = request
  local current_provider = provider
  local function render(result, partial)
    local ok, displayed = pcall(ghost.show, buf, snapshot, tick, cursor, result, partial)
    if not ok then
      M.dismiss()
      vim.notify('compl: invalid suggestion: ' .. tostring(displayed), vim.log.levels.ERROR)
      return false
    end
    if not displayed then M.dismiss() end
    return displayed
  end
  ghost.thinking(buf, snapshot, tick, cursor)
  set_controls(buf)
  vim.notify('compl: generating suggestion…', vim.log.levels.INFO)
  request.cancel = current_provider.generate(processed, function(err, result)
    if active ~= request then return end
    active = nil
    if err then
      M.dismiss()
      vim.notify('compl: ' .. err, vim.log.levels.ERROR)
      return
    end
    if result then
      if result.text == '' then
        M.dismiss()
        vim.notify('compl: no suggestion', vim.log.levels.INFO)
      else
        render(result, false)
      end
    else
      M.dismiss()
    end
  end, {
    position = { row = cursor[1] - 1, col = math.min(cursor[2], #snapshot.file.lines[cursor[1]]) },
    on_partial = function(result)
      if active == request then render(result, true) end
    end,
  })
end

function M.accept()
  if active then
    vim.notify('compl: suggestion is still generating', vim.log.levels.INFO)
    return
  end
  clear_controls()
  ghost.accept()
end

function M.stats()
  return provider and provider.stats() or {}
end

function M.setup(opts)
  if vim.fn.has('nvim-0.10') == 0 then
    error('compl.nvim requires Neovim 0.10 or newer')
  end
  opts = opts or {}
  M.dismiss()
  local previous_provider = provider
  provider = nil
  if previous_provider then previous_provider.stop() end
  assert(opts.provider == nil or opts.provider == 'stub' or opts.provider == 'codex', 'compl: unknown provider')
  assert(not (opts.provider == 'codex' and opts.generate), 'compl: choose codex provider or custom generate')
  if opts.provider == 'codex' then provider = require('compl.providers.codex').new(opts.codex) end
  process = opts.process or processor.process
  generate = opts.generate or function()
    return { text = 'example suggestion' }
  end
  assert(type(process) == 'function', 'compl: process must be a function')
  assert(type(generate) == 'function', 'compl: generate must be a function')
  for _, lhs in ipairs(mappings) do
    pcall(vim.keymap.del, 'n', lhs)
  end
  mappings = {}
  local keys = vim.tbl_extend('force', {
    trigger = '<leader>cg', accept = '<leader>ca', dismiss = '<leader>cd',
  }, opts.keys or {})
  local pending_keys = (opts.keys or {}).suggestion or {}
  suggestion_keys = {
    accept = key_list(pending_keys.accept, { '<Tab>', '<CR>' }, 'keys.suggestion.accept'),
    dismiss = key_list(pending_keys.dismiss, { '<Esc>' }, 'keys.suggestion.dismiss'),
  }
  local pending_seen = {}
  for _, action in ipairs({ 'accept', 'dismiss' }) do
    for _, lhs in ipairs(suggestion_keys[action]) do
      assert(not pending_seen[lhs], 'compl: a suggestion key cannot accept and dismiss')
      pending_seen[lhs] = true
    end
  end
  for _, action in ipairs({ 'trigger', 'accept', 'dismiss' }) do
    local lhs = keys[action]
    if lhs and lhs ~= '' then
      vim.keymap.set('n', lhs, M[action], { desc = 'compl: ' .. action })
      table.insert(mappings, lhs)
    end
  end
  vim.api.nvim_create_user_command('ComplStats', function()
    vim.notify(vim.inspect(M.stats()), vim.log.levels.INFO, { title = 'compl timings (milliseconds)' })
  end, { desc = 'Show the latest suggestion latency measurements', force = true })
  if provider and provider.auto_start then
    local starting = provider
    vim.schedule(function()
      if provider ~= starting then return end
      starting.warmup(function(err)
        if err and provider == starting then
          vim.notify('compl: ' .. err, vim.log.levels.WARN)
        end
      end)
    end)
  end
  local group = vim.api.nvim_create_augroup('Compl', { clear = true })
  local function highlight()
    vim.api.nvim_set_hl(0, 'ComplGhostText', { default = true, link = 'Comment' })
    vim.api.nvim_set_hl(0, 'ComplThinking', { default = true, link = 'DiagnosticHint' })
  end
  highlight()
  vim.api.nvim_create_autocmd('VimLeavePre', { group = group, callback = function()
    M.dismiss()
    if provider then provider.stop() end
  end })
  vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = highlight })
  vim.api.nvim_create_autocmd({
    'TextChanged', 'TextChangedI', 'TextChangedP', 'CursorMoved', 'CursorMovedI',
    'BufLeave', 'BufWipeout', 'InsertEnter',
  }, {
    group = group,
    callback = function(event)
      if ghost.buffer() == event.buf or (active and active.buf == event.buf) then
        M.dismiss()
      end
    end,
  })
end

return M
