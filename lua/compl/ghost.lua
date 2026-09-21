local M = {}
local namespace = vim.api.nvim_create_namespace('compl')
local pending

function M.buffer()
  return pending and pending.buf
end

function M.dismiss()
  if pending and vim.api.nvim_buf_is_valid(pending.buf) then
    vim.api.nvim_buf_clear_namespace(pending.buf, namespace, 0, -1)
  end
  pending = nil
end

function M.show(buf, snapshot, tick, cursor, result, partial)
  M.dismiss()
  assert(type(result) == 'table' and type(result.text) == 'string',
    'compl: generate must return nil or { text = string, position = { row, col } }')
  assert(not result.text:find('\r'), 'compl: use LF newlines in suggestions')
  if result.text == '' then
    return false
  end
  local position = result.position or {
    row = cursor[1] - 1,
    col = math.min(cursor[2], #snapshot.file.lines[cursor[1]]),
  }
  assert(type(position) == 'table', 'compl: position must be a table')
  local row, col = position.row, position.col
  local function integer(value)
    return type(value) == 'number' and value >= 0 and value < math.huge and value == math.floor(value)
  end
  assert(integer(row) and row < #snapshot.file.lines, 'compl: row is outside the file')
  local line = snapshot.file.lines[row + 1]
  assert(integer(col) and col <= #line, 'compl: column is outside the line')
  local byte = line:byte(col + 1)
  assert(not byte or byte < 128 or byte >= 192, 'compl: column must be a UTF-8 character boundary')
  if not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_get_current_buf() ~= buf
    or vim.api.nvim_buf_get_changedtick(buf) ~= tick
    or not vim.deep_equal(vim.api.nvim_win_get_cursor(0), cursor) then
    return false
  end
  local lines = vim.split(result.text, '\n', { plain = true, trimempty = false })
  local virtual_lines = {}
  for i = 2, #lines do virtual_lines[#virtual_lines + 1] = { { lines[i], 'ComplGhostText' } } end
  vim.api.nvim_buf_set_extmark(buf, namespace, row, col, {
    virt_lines = virtual_lines,
    virt_text = { { lines[1], result.highlight or 'ComplGhostText' } },
    virt_text_pos = 'inline',
  })
  pending = {
    buf = buf, snapshot = snapshot, tick = tick, cursor = cursor,
    row = row, col = col, lines = lines, partial = partial,
  }
  return true
end

function M.thinking(buf, snapshot, tick, cursor)
  M.show(buf, snapshot, tick, cursor, {
    text = ' … thinking',
    highlight = 'ComplThinking',
  }, true)
end

function M.accept()
  local item = pending
  if not item or item.partial then
    return
  end
  local valid = vim.api.nvim_get_current_buf() == item.buf
    and vim.api.nvim_buf_is_valid(item.buf)
    and vim.bo[item.buf].modifiable
    and vim.api.nvim_buf_get_changedtick(item.buf) == item.tick
    and vim.deep_equal(vim.api.nvim_win_get_cursor(0), item.cursor)
  M.dismiss()
  if valid then
    vim.api.nvim_buf_set_text(item.buf, item.row, item.col, item.row, item.col, item.lines)
  end
end

return M
