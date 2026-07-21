local evidence = require('contuts.evidence')

local severity = {
  error   = { sign = '⚑' },
  warning = { sign = '⚐' },
  info    = { sign = '●' },
}

local state = {
  build = nil,
  detail_win = nil,
  file_win = nil,
  list_win = nil,
  list_buf = nil,
  summary_win = nil,
  summary_buf = nil,
  show_summary = false,
}

local function close_detail()
  if state.detail_win and vim.api.nvim_win_is_valid(state.detail_win) then
    vim.api.nvim_win_close(state.detail_win, true)
    state.detail_win = nil
  end
end

local function show_float(text, title)
  close_detail()
  local float_buf = vim.api.nvim_create_buf(false, true)
  local lines = vim.split(text, '\n', { plain = true })
  vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)
  vim.bo[float_buf].modifiable = false
  local ui = vim.api.nvim_list_uis()[1]
  local width = math.min(80, ui.width - 4)
  local height = math.min(#lines + 2, 14)
  state.detail_win = vim.api.nvim_open_win(float_buf, true, {
    relative = 'editor', width = width, height = height,
    row = math.floor((ui.height - height) / 2),
    col = math.floor((ui.width - width) / 2),
    style = 'minimal', border = 'rounded',
    title = ' ' .. (title or '') .. ' ',
  })
  vim.api.nvim_buf_set_keymap(float_buf, 'n', 'q', '', { silent = true, callback = close_detail })
  vim.api.nvim_buf_set_keymap(float_buf, 'n', '<Esc>', '', { silent = true, callback = close_detail })
end

local function place_marks_for(file)
  evidence.clear_marks()
  for _, item in ipairs(evidence.get_items()) do
    if item.file == file then
      local buf = vim.fn.bufnr(file, true)
      if buf and vim.api.nvim_buf_is_valid(buf) then
        local cfg = severity[item.severity] or severity.info
        vim.api.nvim_buf_set_extmark(buf, 0, item.line - 1, 0, {
          sign_text = cfg.sign, sign_hl_group = 'DiagnosticSignInfo',
          hl_group = 'ContutsEvidenceInfo', priority = 200,
        })
      end
    end
  end
  for _, a in ipairs(evidence.get_annotations()) do
    if a.file == file then
      local buf = vim.fn.bufnr(file, true)
      if buf and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_set_extmark(buf, 0, a.line - 1, 0, {
          sign_text = '📝', hl_group = 'ContutsEvidenceAnnotation', priority = 200,
        })
      end
    end
  end
end

local function open_item(file, line)
  if not (state.file_win and vim.api.nvim_win_is_valid(state.file_win)) then return end
  vim.api.nvim_set_current_win(state.file_win)
  vim.cmd('e ' .. file)
  vim.api.nvim_win_set_cursor(state.file_win, { line, 0 })
  vim.cmd('normal! zz')
  place_marks_for(file)
end

local function display_items()
  local result = {}
  for _, a in ipairs(evidence.get_annotations()) do
    table.insert(result, { type = 'annotation', data = a })
  end
  local dismissed = evidence.get_dismissed()
  for i, item in ipairs(evidence.get_items()) do
    table.insert(result, { type = dismissed[i] and 'ai_dismissed' or 'ai', data = item, idx = i })
  end
  return result
end

local function render_list()
  if not (state.list_buf and vim.api.nvim_buf_is_valid(state.list_buf)) then return end
  local lines = {}
  for _, di in ipairs(display_items()) do
    if di.type == 'annotation' then
      table.insert(lines, string.format('📝  %s:%d  %s', di.data.file, di.data.line, di.data.claim))
    elseif di.type == 'ai_dismissed' then
      local sig = (severity[di.data.severity] or severity.info).sign
      table.insert(lines, string.format('%s  %s:%d  [dismissed] %s', sig, di.data.file, di.data.line, di.data.claim))
    else
      local sig = (severity[di.data.severity] or severity.info).sign
      table.insert(lines, string.format('%s  %s:%d  %s', sig, di.data.file, di.data.line, di.data.claim))
    end
  end
  vim.api.nvim_buf_set_lines(state.list_buf, 0, -1, false, lines)
end

local function render_summary()
  if not (state.summary_buf and vim.api.nvim_buf_is_valid(state.summary_buf)) then return end
  local text
  if state.build and state.build.files then
    text = string.format('%d files changed, +%d/-%d', #state.build.files, state.build.insertions or 0, state.build.deletions or 0)
  else
    text = 'No build results loaded'
  end
  vim.api.nvim_buf_set_lines(state.summary_buf, 0, -1, false, { text })
end

local function open_summary_panel(list_win)
  vim.api.nvim_set_current_win(list_win)
  vim.cmd('rightbelow new')
  state.summary_win = vim.api.nvim_get_current_win()
  state.summary_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(state.summary_win, state.summary_buf)
  vim.bo[state.summary_buf].buflisted = false
  vim.wo[state.summary_win].winfixheight = true
  vim.api.nvim_win_set_height(state.summary_win, 1)
  render_summary()
end

function M.open(build)
  if #evidence.get_items() == 0 and #evidence.get_annotations() == 0 then
    vim.notify('contuts: no evidence or annotations', vim.log.levels.WARN)
    return
  end

  state.build = build
  state.show_summary = build ~= nil

  vim.cmd('tabedit')
  state.file_win = vim.api.nvim_get_current_win()

  vim.cmd('rightbelow new')
  state.list_win = vim.api.nvim_get_current_win()
  state.list_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(state.list_win, state.list_buf)
  vim.bo[state.list_buf].buflisted = false
  vim.wo[state.list_win].cursorline = true

  if state.show_summary then
    open_summary_panel(state.list_win)
    vim.api.nvim_set_current_win(state.list_win)
  end

  render_list()

  vim.api.nvim_buf_set_keymap(state.list_buf, 'n', '<CR>', '', {
    silent = true,
    callback = function()
      local di = display_items()[vim.fn.line('.')]
      if di then open_item(di.data.file, di.data.line) end
    end,
  })

  vim.api.nvim_buf_set_keymap(state.list_buf, 'n', 'v', '', {
    silent = true,
    callback = function()
      local di = display_items()[vim.fn.line('.')]
      if di and di.data.detail then show_float(di.data.detail, di.data.claim) end
    end,
  })

  vim.api.nvim_buf_set_keymap(state.list_buf, 'n', 'a', '', {
    silent = true,
    callback = function()
      local di = display_items()[vim.fn.line('.')]
      if not di or di.type == 'annotation' then return end
      local text = vim.fn.input('Annotation: ')
      if text and text ~= '' then
        local ann = evidence.get_annotations()
        table.insert(ann, { file = di.data.file, line = di.data.line, claim = text, detail = text })
        render_list()
        place_marks_for(di.data.file)
      end
    end,
  })

  vim.api.nvim_buf_set_keymap(state.list_buf, 'n', 'd', '', {
    silent = true,
    callback = function()
      local di = display_items()[vim.fn.line('.')]
      if not di or di.type == 'annotation' or not di.idx then return end
      local dismissed = evidence.get_dismissed()
      dismissed[di.idx] = not dismissed[di.idx]
      render_list()
    end,
  })

  vim.api.nvim_buf_set_keymap(state.list_buf, 'n', 's', '', {
    silent = true,
    callback = function()
      state.show_summary = not state.show_summary
      if state.show_summary and not (state.summary_win and vim.api.nvim_win_is_valid(state.summary_win)) then
        open_summary_panel(state.list_win)
        vim.api.nvim_set_current_win(state.list_win)
      elseif not state.show_summary then
        if state.summary_win and vim.api.nvim_win_is_valid(state.summary_win) then
          vim.api.nvim_win_close(state.summary_win, true)
        end
      end
    end,
  })

  vim.api.nvim_buf_set_keymap(state.list_buf, 'n', 'q', '', {
    silent = true,
    callback = function()
      close_detail()
      if state.summary_win and vim.api.nvim_win_is_valid(state.summary_win) then
        vim.api.nvim_win_close(state.summary_win, true)
      end
      if state.list_win and vim.api.nvim_win_is_valid(state.list_win) then
        vim.api.nvim_win_close(state.list_win, true)
      end
    end,
  })

  vim.api.nvim_set_current_win(state.file_win)
  vim.cmd('wincmd =')
end

return M
