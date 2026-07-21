local M = {}

local ns = vim.api.nvim_create_namespace('contuts_evidence')
local items = {}
local detail_win = nil
local file_win = nil

local severity = {
  error   = { sign = '⚑', hl_sign = 'DiagnosticSignError', hl_line = 'ContutsEvidenceErr' },
  warning = { sign = '⚐', hl_sign = 'DiagnosticSignWarn', hl_line = 'ContutsEvidenceWarn' },
  info    = { sign = '●', hl_sign = 'DiagnosticSignInfo', hl_line = 'ContutsEvidenceInfo' },
}

vim.api.nvim_set_hl(0, 'ContutsEvidenceErr', { bg = '#5c1a1a' })
vim.api.nvim_set_hl(0, 'ContutsEvidenceWarn', { bg = '#5c5a1a' })
vim.api.nvim_set_hl(0, 'ContutsEvidenceInfo', { bg = '#1a3c5c' })

function M.set_items(new_items)
  M.clear_marks()
  items = new_items or {}
end

function M.clear_marks()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
  end
end

local function place_marks_for(file)
  for _, item in ipairs(items) do
    if item.file == file then
      local cfg = severity[item.severity] or severity.info
      local buf = vim.fn.bufnr(file, true)
      if buf and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_set_extmark(buf, ns, item.line - 1, 0, {
          sign_text = cfg.sign,
          sign_hl_group = cfg.hl_sign,
          hl_group = cfg.hl_line,
          priority = 200,
        })
      end
    end
  end
end

local function show_float(item)
  if detail_win and vim.api.nvim_win_is_valid(detail_win) then
    vim.api.nvim_win_close(detail_win, true)
    detail_win = nil
  end

  local float_buf = vim.api.nvim_create_buf(false, true)
  local lines = vim.split(item.detail or item.claim, '\n', { plain = true })
  vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)
  vim.bo[float_buf].modifiable = false

  local ui = vim.api.nvim_list_uis()[1]
  local width = math.min(80, ui.width - 4)
  local height = math.min(#lines + 2, 14)
  detail_win = vim.api.nvim_open_win(float_buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((ui.height - height) / 2),
    col = math.floor((ui.width - width) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' ' .. item.claim .. ' ',
  })

  local function close_detail()
    if detail_win and vim.api.nvim_win_is_valid(detail_win) then
      vim.api.nvim_win_close(detail_win, true)
      detail_win = nil
    end
  end

  vim.api.nvim_buf_set_keymap(float_buf, 'n', 'q', '', { silent = true, callback = close_detail })
  vim.api.nvim_buf_set_keymap(float_buf, 'n', '<Esc>', '', { silent = true, callback = close_detail })
end

local function open_item(item)
  if not item then return end
  if not (file_win and vim.api.nvim_win_is_valid(file_win)) then return end

  vim.api.nvim_set_current_win(file_win)
  vim.cmd('e ' .. item.file)
  vim.api.nvim_win_set_cursor(file_win, { item.line, 0 })
  vim.cmd('normal! zz')

  M.clear_marks()
  place_marks_for(item.file)
end

function M.open()
  if #items == 0 then
    vim.notify('contuts: no evidence to show', vim.log.levels.WARN)
    return
  end

  vim.cmd('tabedit')

  file_win = vim.api.nvim_get_current_win()

  vim.cmd('rightbelow new')
  local list_win = vim.api.nvim_get_current_win()
  local list_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(list_win, list_buf)
  vim.bo[list_buf].buflisted = false
  vim.bo[list_buf].modified = false
  vim.wo[list_win].cursorline = true

  local lines = {}
  for _, item in ipairs(items) do
    local sig = (severity[item.severity] or severity.info).sign
    table.insert(lines, string.format('%s  %s:%d  %s', sig, item.file, item.line, item.claim or ''))
  end
  vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, lines)

  vim.api.nvim_buf_set_keymap(list_buf, 'n', '<CR>', '', {
    silent = true,
    callback = function()
      local idx = vim.fn.line('.')
      if idx < 1 or idx > #items then return end
      open_item(items[idx])
    end,
  })

  vim.api.nvim_buf_set_keymap(list_buf, 'n', 'd', '', {
    silent = true,
    callback = function()
      local idx = vim.fn.line('.')
      if idx < 1 or idx > #items then return end
      show_float(items[idx])
    end,
  })

  vim.api.nvim_buf_set_keymap(list_buf, 'n', 'q', '', {
    silent = true,
    callback = function()
      if list_win and vim.api.nvim_win_is_valid(list_win) then
        vim.api.nvim_win_close(list_win, true)
      end
    end,
  })

  vim.api.nvim_set_current_win(file_win)
  open_item(items[1])
  vim.cmd('wincmd =')
end

function M.show_detail()
  local buf = vim.api.nvim_get_current_buf()
  local line = vim.fn.line('.')
  local file = vim.fn.expand('%:.:')

  for _, item in ipairs(items) do
    if item.file == file and item.line == line then
      show_float(item)
      return
    end
  end
  vim.notify('contuts: no claim on this line', vim.log.levels.INFO)
end

return M
