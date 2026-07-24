local M = {}

local ns = vim.api.nvim_create_namespace('contuts_plan')

local items = {}
local dismissed = {}
local proposal_states = {}
local proposal_data = {}
local pending_idx = nil

local file_win = nil
local list_win = nil
local list_buf = nil
local viewer_open = false

local detail_win = nil
local chat_win = nil
local chat_buf = nil
local chat_item_idx = nil

local severity = {
  error   = { sign = '⚑', hl_sign = 'DiagnosticSignError', hl_line = 'ContutsPlanErr' },
  warning = { sign = '⚐', hl_sign = 'DiagnosticSignWarn', hl_line = 'ContutsPlanWarn' },
  info    = { sign = '●', hl_sign = 'DiagnosticSignInfo', hl_line = 'ContutsPlanInfo' },
  task    = { sign = '▶', hl_sign = 'DiagnosticSignHint', hl_line = 'ContutsPlanTask' },
}

vim.api.nvim_set_hl(0, 'ContutsPlanErr', { bg = '#5c1a1a' })
vim.api.nvim_set_hl(0, 'ContutsPlanWarn', { bg = '#5c5a1a' })
vim.api.nvim_set_hl(0, 'ContutsPlanInfo', { bg = '#1a3c5c' })
vim.api.nvim_set_hl(0, 'ContutsPlanTask', { bg = '#1a4a4a' })
vim.api.nvim_set_hl(0, 'ContutsPlanDim', { fg = '#555555' })
vim.api.nvim_set_hl(0, 'ContutsPlanAnnotation', { bg = '#2a2a1a' })

-- helpers

local function item_id()
  return os.time() .. tostring(#items + 1)
end

local function render_list()
  if not (list_buf and vim.api.nvim_buf_is_valid(list_buf)) then return end
  local lines = {}
  for i, item in ipairs(items) do
    if dismissed[i] then
      local sig = (severity[item.severity] or severity.info).sign
      table.insert(lines, string.format('  %s  %s:%d  [dismissed] %s', sig, item.file, item.line, item.description))
    else
      local state = proposal_states[i]
      local state_prefix = state == 'building' and '[···] ' or state == 'proposed' and '[P] ' or state == 'accepted' and '[✓] ' or state == 'rejected' and '[✗] ' or ''
      local type_label = item.type == 'task' and 'task' or 'claim'
      local sig = (severity[item.severity] or severity.info).sign
      table.insert(lines, string.format('%s%s [%s] %s:%d  %s', state_prefix, sig, type_label, item.file, item.line, item.description))
    end
  end
  if #lines == 0 then
    lines = { '  (no claims or tasks — use :ContutsChat to talk to AI, or :ContutsAddClaim/:ContutsAddTask)' }
  end
  vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, lines)
end

local function rebuild_display()
  render_list()
end

local function place_marks_for(file)
  for i, item in ipairs(items) do
    if item.file == file and not dismissed[i] then
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

function M.clear_marks()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
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

-- per-task mini-chat

local function open_chat(idx)
  local item = items[idx]
  if not item or item.type ~= 'task' then return end

  chat_item_idx = idx

  if chat_buf and vim.api.nvim_buf_is_valid(chat_buf) then
    local ui = vim.api.nvim_list_uis()[1]
    local width = math.min(72, math.floor(ui.width * 0.6))
    local height = math.min(20, math.floor(ui.height * 0.5))
    chat_win = vim.api.nvim_open_win(chat_buf, true, {
      relative = 'editor',
      width = width,
      height = height,
      row = math.floor((ui.height - height) / 2),
      col = math.floor((ui.width - width) / 2),
      style = 'minimal',
      border = 'rounded',
      title = ' Task: ' .. item.description .. ' ',
    })
    vim.wo[chat_win].wrap = true
    vim.api.nvim_win_set_cursor(chat_win, { vim.api.nvim_buf_line_count(chat_buf), 2 })
    vim.cmd('startinsert!')
    return
  end

  chat_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(chat_buf, 'buftype', 'acwrite')

  local ui = vim.api.nvim_list_uis()[1]
  local width = math.min(72, math.floor(ui.width * 0.6))
  local height = math.min(20, math.floor(ui.height * 0.5))

  chat_win = vim.api.nvim_open_win(chat_buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((ui.height - height) / 2),
    col = math.floor((ui.width - width) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' Task: ' .. item.description .. ' ',
  })
  vim.wo[chat_win].wrap = true

  -- render existing chat history
  local lines = {}
  table.insert(lines, string.rep('─', width - 2))
  table.insert(lines, 'Task: ' .. item.description)
  if item.codeBlock then
    table.insert(lines, 'Code:')
    for _, cl in ipairs(vim.split(item.codeBlock, '\n', { plain = true })) do
      table.insert(lines, '  ' .. cl)
    end
  end
  table.insert(lines, string.rep('─', width - 2))
  table.insert(lines, '')
  for _, m in ipairs(item.chat or {}) do
    table.insert(lines, m.role .. ': ' .. m.content)
    table.insert(lines, '')
  end
  table.insert(lines, '> ')
  vim.api.nvim_buf_set_lines(chat_buf, 0, -1, false, lines)

  local function send_chat_input()
    local clines = vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false)
    local input = clines[#clines]:match('^> (.*)$')
    if not input or input:match('^%s*$') then return end

    local n = #clines
    vim.api.nvim_buf_set_lines(chat_buf, n - 1, n, false, {
      'You: ' .. input,
      string.rep('─', width - 2),
      '',
      '> ',
    })
    if chat_win and vim.api.nvim_win_is_valid(chat_win) then
      vim.api.nvim_win_set_cursor(chat_win, { vim.api.nvim_buf_line_count(chat_buf), 2 })
    end

    if not item.chat then item.chat = {} end
    table.insert(item.chat, { role = 'You', content = input })

    local taskContext = string.format('Task context — file: %s:%d', item.file, item.line)
    if item.codeBlock then
      taskContext = taskContext .. '\nCode:\n' .. item.codeBlock
    end
    taskContext = taskContext .. '\n\nChat history:\n'
    for _, m in ipairs(item.chat) do
      taskContext = taskContext .. m.role .. ': ' .. m.content .. '\n'
    end

    require('contuts').send({ type = 'prompt', content = input, taskContext = taskContext }, function(response)
      if not (chat_buf and vim.api.nvim_buf_is_valid(chat_buf)) then return end
      vim.schedule(function()
        pcall(function()
          if response.type == 'response' then
            table.insert(item.chat, { role = 'AI', content = response.content })
            local resp_lines = vim.split(response.content, '\n', { plain = true })
            local insert = {}
            for _, l in ipairs(resp_lines) do
              table.insert(insert, l)
            end
            table.insert(insert, '')
            table.insert(insert, '> ')
            local lc = vim.api.nvim_buf_line_count(chat_buf)
            vim.api.nvim_buf_set_lines(chat_buf, lc - 1, lc, false, insert)
            if chat_win and vim.api.nvim_win_is_valid(chat_win) then
              vim.api.nvim_win_set_cursor(chat_win, { vim.api.nvim_buf_line_count(chat_buf), 2 })
            end
            vim.cmd('startinsert!')
          end
        end)
      end)
    end)
  end

  local opts = { noremap = true, silent = true }
  vim.api.nvim_buf_set_keymap(chat_buf, 'n', '<CR>', '', vim.tbl_extend('force', opts, { callback = send_chat_input }))
  vim.api.nvim_buf_set_keymap(chat_buf, 'i', '<CR>', '', vim.tbl_extend('force', opts, { callback = send_chat_input }))
  vim.api.nvim_buf_set_keymap(chat_buf, 'n', 'q', '', vim.tbl_extend('force', opts, {
    callback = function()
      if chat_win and vim.api.nvim_win_is_valid(chat_win) then
        vim.api.nvim_win_close(chat_win, true)
      end
      chat_win = nil
      chat_item_idx = nil
    end,
  }))
  vim.api.nvim_buf_set_keymap(chat_buf, 'n', '<Esc>', '', vim.tbl_extend('force', opts, {
    callback = function()
      if chat_win and vim.api.nvim_win_is_valid(chat_win) then
        vim.api.nvim_win_close(chat_win, true)
      end
      chat_win = nil
      chat_item_idx = nil
    end,
  }))

  vim.api.nvim_win_set_cursor(chat_win, { vim.api.nvim_buf_line_count(chat_buf), 2 })
  vim.cmd('startinsert!')
end

-- public API

function M.get_items()
  return items
end

function M.add_items(new_items)
  for _, item in ipairs(new_items) do
    item.id = item_id()
    if not item.source then item.source = 'ai' end
    table.insert(items, item)
  end
  rebuild_display()
  if viewer_open then
    local fc = items[1]
    if fc then open_item_at(fc.file, fc.line) end
  end
end

function M.add_item(item)
  item.id = item_id()
  item.source = 'user'
  if not item.severity then
    item.severity = item.type == 'task' and 'task' or 'info'
  end
  table.insert(items, item)
  rebuild_display()
end

function M.set_ai_items(new_items)
  local user_items = {}
  for _, item in ipairs(items) do
    if item.source == 'user' then
      table.insert(user_items, item)
    end
  end
  items = user_items
  for _, raw in ipairs(new_items) do
    local item = {
      id = item_id(),
      type = raw.severity == 'task' and 'task' or 'claim',
      source = 'ai',
      file = raw.file,
      line = raw.line,
      endLine = nil,
      codeBlock = nil,
      description = raw.claim or '',
      detail = raw.detail or raw.claim or '',
      severity = raw.severity or 'info',
      chat = {},
    }
    table.insert(items, item)
  end
  dismissed = {}
  rebuild_display()
end

function M.get_active_text()
  local parts = {}
  local has_content = false
  for i, item in ipairs(items) do
    if not dismissed[i] then
      if not has_content then
        table.insert(parts, 'Planning context:')
        has_content = true
      end
      local type_label = item.type == 'task' and 'Task' or 'Claim'
      table.insert(parts, string.format('  %s: %s:%d [%s] — %s', type_label, item.file, item.line, item.severity, item.description))
    end
  end
  return has_content and table.concat(parts, '\n') or ''
end

function M.get_active_task_text()
  local parts = {}
  local has_content = false
  for i, item in ipairs(items) do
    if not dismissed[i] and item.type == 'task' then
      if not has_content then
        table.insert(parts, 'Active tasks:')
        has_content = true
      end
      table.insert(parts, string.format('  %s:%d — %s', item.file, item.line, item.description))
    end
  end
  return has_content and table.concat(parts, '\n') or ''
end

function M.set_proposal_state(state, data)
  if not pending_idx then return end
  local idx = pending_idx
  if state == 'proposed' then
    proposal_states[idx] = 'proposed'
    proposal_data[idx] = data or {}
    if data.intention then
      proposal_data[idx].intention = data.intention
    end
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

function M.promote_to_task(idx)
  if items[idx] and items[idx].type == 'claim' then
    items[idx].type = 'task'
    items[idx].severity = 'task'
    rebuild_display()
    vim.notify('contuts: claim promoted to task', vim.log.levels.INFO)
  end
end

function M.open(opts)
  opts = opts or {}
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
      local idx = vim.fn.line('.')
      local item = items[idx]
      if item then open_item_at(item.file, item.line) end
    end,
  })

  vim.api.nvim_buf_set_keymap(list_buf, 'n', 'v', '', {
    silent = true, callback = function()
      local idx = vim.fn.line('.')
      local item = items[idx]
      if not item then return end
      if proposal_data[idx] then
        local proposal = proposal_data[idx]
        local display = ''
        if proposal.intention and proposal.intention ~= '' then
          display = 'Intention:\n' .. proposal.intention .. '\n\n'
        end
        display = display .. 'Diff:\n' .. (proposal.diff or '(empty diff)')
        show_float(display, 'Proposed: ' .. item.description)
      elseif item.detail then
        show_float(item.detail, item.description)
      end
    end,
  })

  vim.api.nvim_buf_set_keymap(list_buf, 'n', 'd', '', {
    silent = true, callback = function()
      local idx = vim.fn.line('.')
      if idx and idx <= #items then
        dismissed[idx] = not dismissed[idx]
        rebuild_display()
      end
    end,
  })

  vim.api.nvim_buf_set_keymap(list_buf, 'n', 't', '', {
    silent = true, callback = function()
      local idx = vim.fn.line('.')
      if idx then M.promote_to_task(idx) end
    end,
  })

  vim.api.nvim_buf_set_keymap(list_buf, 'n', 'c', '', {
    silent = true, callback = function()
      local idx = vim.fn.line('.')
      local item = items[idx]
      if item and item.type == 'task' then
        open_chat(idx)
      else
        vim.notify('contuts: only tasks have a chat', vim.log.levels.INFO)
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
        local idx = vim.fn.line('.')
        local item = items[idx]
        if not item or item.type ~= 'task' then
          vim.notify('contuts: only tasks can be built', vim.log.levels.INFO)
          return
        end
        if dismissed[idx] then
          vim.notify('contuts: dismissed item, undismiss with d first', vim.log.levels.WARN)
          return
        end
        pending_idx = idx
        proposal_states[idx] = 'building'
        render_list()
        opts.on_build(item, idx)
      end,
    })

    vim.api.nvim_buf_set_keymap(list_buf, 'n', 'B', '', {
      silent = true, callback = function() opts.on_build_all() end,
    })

    vim.api.nvim_buf_set_keymap(list_buf, 'n', 'y', '', {
      silent = true, callback = function()
        local idx = vim.fn.line('.')
        if idx and proposal_states[idx] == 'proposed' then opts.on_accept(idx) end
      end,
    })

    vim.api.nvim_buf_set_keymap(list_buf, 'n', 'n', '', {
      silent = true, callback = function()
        local idx = vim.fn.line('.')
        if idx and proposal_states[idx] == 'proposed' then opts.on_reject(idx) end
      end,
    })
  end

  vim.api.nvim_buf_set_keymap(list_buf, 'n', 'q', '', {
    silent = true, callback = function()
      viewer_open = false
      if list_win and vim.api.nvim_win_is_valid(list_win) then vim.api.nvim_win_close(list_win, true) end
    end,
  })

  if #items > 0 then
    open_item_at(items[1].file, items[1].line)
  end
  vim.api.nvim_set_current_win(file_win)
  vim.cmd('wincmd =')
end

function M.close()
  viewer_open = false
end

function M.view_item_detail(item)
  show_float(item.detail or item.description, item.description)
end

return M
