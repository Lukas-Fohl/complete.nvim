local M = {}

-- One JSONL connection. All callbacks run on Neovim's main loop.
function M.new(command)
  local self = { next_id = 0, requests = {}, listeners = {}, ready = false }
  local job, partial = nil, ''

  function self.subscribe(callback)
    self.listeners[callback] = true
    return function() self.listeners[callback] = nil end
  end

  local function emit(method, params)
    for callback in pairs(self.listeners) do callback(method, params) end
  end

  function self.stop(reason)
    self.ready = false
    local old = job
    job = nil
    if old then pcall(vim.fn.jobstop, old) end
    local requests = self.requests
    self.requests = {}
    for _, callback in pairs(requests) do callback(reason or 'Codex server stopped') end
    emit('transport/closed', { message = reason or 'Codex server stopped' })
  end

  local function send(message)
    if not job then return false end
    local ok = pcall(vim.fn.chansend, job, vim.json.encode(message) .. '\n')
    if not ok then self.stop('Cannot write to Codex App Server') end
    return ok
  end

  function self.request(method, params, callback)
    callback = callback or function() end
    if not job then callback('Codex server is not running'); return end
    self.next_id = self.next_id + 1
    local id = self.next_id
    self.requests[id] = callback
    send({ id = id, method = method, params = params or vim.empty_dict() })
  end

  local function receive(line)
    local ok, message = pcall(vim.json.decode, line)
    if not ok or type(message) ~= 'table' then
      self.stop('Invalid JSON from Codex App Server')
      return
    end
    if message.method and message.id then
      -- This client never approves changes or interactive tool requests.
      local result
      if message.method == 'item/commandExecution/requestApproval'
        or message.method == 'item/fileChange/requestApproval' then
        result = { decision = 'decline' }
      elseif message.method == 'item/permissions/requestApproval' then
        result = { permissions = vim.empty_dict(), scope = 'turn' }
      end
      if result then
        send({ id = message.id, result = result })
      else
        send({ id = message.id, error = { code = -32601, message = 'Interactive tools are not supported by compl.nvim' } })
      end
      emit('transport/unsupportedRequest', message.params or {})
    elseif message.id then
      local callback = self.requests[message.id]
      self.requests[message.id] = nil
      if callback then
        local err = message.error
        callback(err and (type(err) == 'table' and err.message or tostring(err)) or nil, message.result)
      end
    elseif message.method then
      emit(message.method, message.params or {})
    end
  end

  function self.start(callback)
    if self.ready then callback(); return end
    if job then
      local unsubscribe
      unsubscribe = self.subscribe(function(method, params)
        if method == 'transport/ready' or method == 'transport/closed' then
          unsubscribe()
          callback(method == 'transport/closed' and params.message or nil)
        end
      end)
      return
    end
    partial = ''
    local argv = type(command) == 'table' and vim.deepcopy(command) or { command or 'codex' }
    vim.list_extend(argv, { 'app-server', '--listen', 'stdio://' })
    local ok, id = pcall(vim.fn.jobstart, argv, {
      on_stdout = function(source, data)
        if source ~= job then return end
        local chunk = partial .. table.concat(data, '\n')
        partial = ''
        local start = 1
        while true do
          local ending = chunk:find('\n', start, true)
          if not ending then partial = chunk:sub(start); break end
          local line = chunk:sub(start, ending - 1)
          if line ~= '' then
            local handled = pcall(receive, line)
            if not handled then self.stop('Unexpected response from Codex App Server') end
          end
          if source ~= job then return end
          start = ending + 1
        end
      end,
      on_stderr = function() end, -- Never echo credentials or file contents from process logs.
      on_exit = function(source, code)
        if source == job then self.stop('Codex App Server exited (code ' .. code .. ')') end
      end,
    })
    if not ok or id <= 0 then callback('Cannot start Codex; install it or configure codex.command'); return end
    job = id
    self.request('initialize', { clientInfo = { name = 'compl_nvim', version = '0.1.0' } }, function(err)
      if err then callback(err); self.stop(err); return end
      send({ method = 'initialized' })
      self.ready = true
      callback()
      emit('transport/ready', {})
    end)
  end

  return self
end

return M
