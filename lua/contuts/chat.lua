local M = {}

local buf = nil
local win = nil
local pending = false
local width = 0
local current_mode = 'plan'

local function set_title(mode)
  current_mode = mode
  if win and vim.api.nvim_win_is_valid(win) then
    local label = mode == 'build' and 'BUILD MODE' or 'PLAN MODE'
    vim.api.nvim_win_set_config(win, { title = ' Contuts Chat [' .. label .. '] ' })
  end
end

function M.open()
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_set_current_win(win)
    return
  end

  buf = vim.api.nvim_create_buf(false, true)

  local ui = vim.api.nvim_list_uis()[1]
  width = math.min(88, math.floor(ui.width * 0.8))
  local height = math.min(30, math.floor(ui.height * 0.7))
  local row = math.floor((ui.height - height) / 2)
  local col = math.floor((ui.width - width) / 2)

  win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = row,
    col = col,
    style = 'minimal',
    border = 'rounded',
    title = ' Contuts Chat [PLAN MODE] ',
  })

  vim.wo[win].wrap = true

  vim.api.nvim_buf_set_option(buf, 'buftype', 'acwrite')
  vim.api.nvim_buf_set_option(buf, 'filetype', 'contuts-chat')

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    string.rep('─', width - 2),
    '',
    '> ',
  })

  require('contuts').set_notification_handler(function(msg)
    if msg.type == 'mode_change' then
      vim.schedule(function()
        pcall(function()
          set_title(msg.mode)
        end)
      end)
      return
    end
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.schedule(function()
        pcall(function()
          local prefix = msg.type == 'error' and '  ⚠ ' or '  '
          local lines = vim.split(msg.content, '\n', { plain = true })
          local insert = {}
          for _, l in ipairs(lines) do
            insert[#insert + 1] = prefix .. l
          end
          insert[#insert + 1] = ''
          insert[#insert + 1] = '> '
          local lc = vim.api.nvim_buf_line_count(buf)
          vim.api.nvim_buf_set_lines(buf, lc - 1, lc, false, insert)
          vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 2 })
        end)
      end)
    end
  end)

  local function send_input()
    if pending then
      vim.notify('contuts: waiting for response', vim.log.levels.WARN)
      return
    end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local input = lines[#lines]:match('^> (.*)$')
    if not input or input:match('^%s*$') then
      return
    end

    pending = true
    local n = #lines
    vim.api.nvim_buf_set_lines(buf, n - 1, n, false, {
      'You: ' .. input,
      string.rep('─', width - 2),
      '',
      '> ',
    })
    vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 2 })

    require('contuts').send({ type = 'prompt', content = input }, function(response)
      pending = false
      if response.type == 'response' then
        vim.schedule(function()
          pcall(function()
            local lc = vim.api.nvim_buf_line_count(buf)
            local resp_lines = vim.split(response.content, '\n', { plain = true })
            local insert = {}
            for _, l in ipairs(resp_lines) do
              insert[#insert + 1] = l
            end
            insert[#insert + 1] = ''
            insert[#insert + 1] = '> '
            vim.api.nvim_buf_set_lines(buf, lc - 1, lc, false, insert)
            vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 2 })
            vim.cmd('startinsert!')
          end)
        end)
      elseif response.type == 'error' then
        vim.schedule(function()
          vim.notify('contuts error: ' .. response.content, vim.log.levels.ERROR)
          pending = false
        end)
      end
    end)
  end

  local opts = { noremap = true, silent = true }
  vim.api.nvim_buf_set_keymap(buf, 'n', '<CR>', '', vim.tbl_extend('force', opts, { callback = send_input }))
  vim.api.nvim_buf_set_keymap(buf, 'i', '<CR>', '', vim.tbl_extend('force', opts, { callback = send_input }))
  vim.api.nvim_buf_set_keymap(buf, 'n', 'q', '', vim.tbl_extend('force', opts, { callback = M.close }))
  vim.api.nvim_buf_set_keymap(buf, 'n', '<Esc>', '', vim.tbl_extend('force', opts, { callback = M.close }))

  vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 2 })
  vim.cmd('startinsert!')
end

function M.close()
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  win = nil
  buf = nil
end

function M.toggle()
  if win and vim.api.nvim_win_is_valid(win) then
    M.close()
  else
    M.open()
  end
end

return M
