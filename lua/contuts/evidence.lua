local M = {}

local ns = vim.api.nvim_create_namespace('contuts_evidence')
local items = {}
local annotations = {}
local dismissed = {}
local display_items = {}
local detail_win = nil
local file_win = nil
local list_win = nil
local list_buf = nil
local viewer_open = false
local proposal_states = {}
local proposal_data = {}
local pending_idx = nil

local severity = {
  error   = { sign = '⚑', hl_sign = 'DiagnosticSignError', hl_line = 'ContutsEvidenceErr' },
  warning = { sign = '⚐', hl_sign = 'DiagnosticSignWarn', hl_line = 'ContutsEvidenceWarn' },
  info    = { sign = '●', hl_sign = 'DiagnosticSignInfo', hl_line = 'ContutsEvidenceInfo' },
}

vim.api.nvim_set_hl(0, 'ContutsEvidenceErr', { bg = '#5c1a1a' })
vim.api.nvim_set_hl(0, 'ContutsEvidenceWarn', { bg = '#5c5a1a' })
vim.api.nvim_set_hl(0, 'ContutsEvidenceInfo', { bg = '#1a3c5c' })
vim.api.nvim_set_hl(0, 'ContutsEvidenceAnnotation', { bg = '#1a4a1a' })
vim.api.nvim_set_hl(0, 'ContutsEvidenceDim', { fg = '#555555' })

local function render_list()
  if not (list_buf and vim.api.nvim_buf_is_valid(list_buf)) then return end
  local lines = {}
  for _, di in ipairs(display_items) do
    local state = di.idx and proposal_states[di.idx]
    local state_prefix = state == 'building' and '[···] ' or state == 'proposed' and '[P] ' or state == 'accepted' and '[✓] ' or state == 'rejected' and '[✗] ' or ''
    if di.type == 'annotation' then
      table.insert(lines, string.format('📝  %s:%d  %s', di.data.file, di.data.line, di.data.claim))
    elseif di.type == 'ai' then
      local sig = (severity[di.data.severity] or severity.info).sign
      table.insert(lines, string.format('%s  %s  %s:%d  %s', state_prefix, sig, di.data.file, di.data.line, di.data.claim))
    elseif di.type == 'ai_dismissed' then
      local sig = (severity[di.data.severity] or severity.info).sign
      table.insert(lines, string.format('%s  %s  %s:%d  [dismissed] %s', state_prefix, sig, di.data.file, di.data.line, di.data.claim))
    end
  end
  vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, lines)
end

local function rebuild_display()
  display_items = {}
  for _, a in ipairs(annotations) do
    table.insert(display_items, { type = 'annotation', data = a })
  end
  for i, item in ipairs(items) do
    if dismissed[i] then
      table.insert(display_items, { type = 'ai_dismissed', data = item, idx = i })
    else
      table.insert(display_items, { type = 'ai', data = item, idx = i })
    end
  end
  render_list()
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
  for _, a in ipairs(annotations) do
    if a.file == file then
      local buf = vim.fn.bufnr(file, true)
      if buf and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_set_extmark(buf, ns, a.line - 1, 0, {
          sign_text = '📝',
          hl_group = 'ContutsEvidenceAnnotation',
          priority = 200,
        })
      end
    end
  end
end

local function show_float(text, title)
  if detail_win and vim.api.nvim_win_is_valid(detail_win) then
    vim.api.nvim_win_close(detail_win, true)
    detail_win = nil
  end
  local float_buf = vim.api.nvim_create_buf(false, true)
  local lines = vim.split(text, '\n', { plain = true })
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
    title = ' ' .. (title or '') .. ' ',
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

local function open_item_at(file, line)
  if not (file_win and vim.api.nvim_win_is_valid(file_win)) then return end
  vim.api.nvim_set_current_win(file_win)
  vim.cmd('e ' .. file)
  vim.api.nvim_win_set_cursor(file_win, { line, 0 })
  vim.cmd('normal! zz')
  M.clear_marks()
  place_marks_for(file)
end

function M.get_items()
  return items
end

function M.get_items_for_file(file)
  local result = {}
  for _, item in ipairs(items) do
    if item.file == file then
      table.insert(result, item)
    end
  end
  return #result > 0 and result or nil
end

function M.set_items(new_items)
  M.clear_marks()
  items = new_items or {}
  dismissed = {}
  proposal_states = {}
  proposal_data = {}
  pending_idx = nil
  rebuild_display()
end

function M.clear_marks()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
  end
end

function M.get_annotations()
  return annotations
end

function M.get_dismissed()
  return dismissed
end

function M.set_proposal_state(state, data)
  if not pending_idx then return end
  local idx = pending_idx
  if state == 'proposed' then
    proposal_states[idx] = 'proposed'
    proposal_data[idx] = data
  elseif state == 'accepted' then
    proposal_states[idx] = 'accepted'
    pending_idx = nil
  elseif state == 'rejected' then
    proposal_states[idx] = 'rejected'
    pending_idx = nil
  end
  render_list()
end

function M.get_proposal_data(idx)
  return proposal_data[idx]
end

function M.get_active_text()
  local parts = {}
  local has_content = false
  if #annotations > 0 then
    table.insert(parts, 'Human annotations:')
    has_content = true
    for _, a in ipairs(annotations) do
      table.insert(parts, string.format('  %s:%d — %s', a.file, a.line, a.claim))
    end
  end
  local active_ai = {}
  for i, item in ipairs(items) do
    if not dismissed[i] then
      table.insert(active_ai, item)
    end
  end
  if #active_ai > 0 then
    if has_content then table.insert(parts, '') end
    table.insert(parts, 'AI evidence:')
    has_content = true
    for _, item in ipairs(active_ai) do
      table.insert(parts, string.format('  %s:%d [%s] — %s', item.file, item.line, item.severity, item.claim))
    end
  end
  return has_content and table.concat(parts, '\n') or ''
end

function M.open(opts)
  opts = opts or {}
  if #items == 0 and #annotations == 0 then
    vim.notify('contuts: no evidence or annotations', vim.log.levels.WARN)
    return
  end
  viewer_open = true
  vim.cmd('tabedit')
  file_win = vim.api.nvim_get_current_win()
  vim.cmd('rightbelow new')
  list_win = vim.api.nvim_get_current_win()
  list_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(list_win, list_buf)
  vim.bo[list_buf].buflisted = false
  vim.bo[list_buf].modified = false
  vim.wo[list_win].cursorline = true
  rebuild_display()

  vim.api.nvim_buf_set_keymap(list_buf, 'n', '<CR>', '', {
    silent = true, callback = function()
      local di = display_items[vim.fn.line('.')]
      if di then open_item_at(di.data.file, di.data.line) end
    end,
  })

  vim.api.nvim_buf_set_keymap(list_buf, 'n', 'v', '', {
    silent = true, callback = function()
      local di = display_items[vim.fn.line('.')]
      if not di then return end
      if di.idx and proposal_data[di.idx] then
        show_float(proposal_data[di.idx].diff or '(empty diff)', 'Proposed diff')
      elseif di.data.detail then
        show_float(di.data.detail, di.data.claim)
      end
    end,
  })

  vim.api.nvim_buf_set_keymap(list_buf, 'n', 'a', '', {
    silent = true, callback = function()
      local di = display_items[vim.fn.line('.')]
      if not di then return end
      local text = vim.fn.input('Annotation: ')
      if text and text ~= '' then
        table.insert(annotations, { file = di.data.file, line = di.data.line, claim = text, detail = text })
        rebuild_display()
        if file_win and vim.api.nvim_win_is_valid(file_win) then
          M.clear_marks()
          place_marks_for(di.data.file)
        end
      end
    end,
  })

  vim.api.nvim_buf_set_keymap(list_buf, 'n', 'd', '', {
    silent = true, callback = function()
      local di = display_items[vim.fn.line('.')]
      if di and di.type ~= 'annotation' and di.idx then
        dismissed[di.idx] = not dismissed[di.idx]
        rebuild_display()
      end
    end,
  })

  if opts.on_build then
    vim.api.nvim_buf_set_keymap(list_buf, 'n', 'b', '', {
      silent = true, callback = function()
        if pending_idx then
          vim.notify('contuts: a proposal is already in progress', vim.log.levels.WARN)
          return
        end
        local di = display_items[vim.fn.line('.')]
        if not di or di.type == 'annotation' or not di.idx then return end
        pending_idx = di.idx
        proposal_states[di.idx] = 'building'
        render_list()
        opts.on_build(di)
      end,
    })
    vim.api.nvim_buf_set_keymap(list_buf, 'n', 'B', '', {
      silent = true, callback = function() opts.on_build_all() end,
    })
    vim.api.nvim_buf_set_keymap(list_buf, 'n', 'y', '', {
      silent = true, callback = function()
        local di = display_items[vim.fn.line('.')]
        if di and di.idx and proposal_states[di.idx] == 'proposed' then opts.on_accept(di) end
      end,
    })
    vim.api.nvim_buf_set_keymap(list_buf, 'n', 'n', '', {
      silent = true, callback = function()
        local di = display_items[vim.fn.line('.')]
        if di and di.idx and proposal_states[di.idx] == 'proposed' then opts.on_reject(di) end
      end,
    })
  end

  vim.api.nvim_buf_set_keymap(list_buf, 'n', 'q', '', {
    silent = true, callback = function()
      viewer_open = false
      if list_win and vim.api.nvim_win_is_valid(list_win) then vim.api.nvim_win_close(list_win, true) end
    end,
  })

  if #display_items > 0 then
    open_item_at(display_items[1].data.file, display_items[1].data.line)
  end
  vim.api.nvim_set_current_win(file_win)
  vim.cmd('wincmd =')
end

function M.show_detail()
  local buf = vim.api.nvim_get_current_buf()
  local line = vim.fn.line('.')
  local file = vim.fn.expand('%:.:')
  for _, item in ipairs(items) do
    if item.file == file and item.line == line then
      show_float(item.detail or item.claim, item.claim)
      return
    end
  end
  for _, a in ipairs(annotations) do
    if a.file == file and a.line == line then
      show_float(a.detail or a.claim, a.claim)
      return
    end
  end
  vim.notify('contuts: no claim on this line', vim.log.levels.INFO)
end

return M
