local M = {}

-- Context contains only file information; editor lifecycle stays in the controller.
function M.capture(buf)
  return {
    file = {
      path = vim.api.nvim_buf_get_name(buf),
      filetype = vim.bo[buf].filetype,
      lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
    },
  }
end

return M
