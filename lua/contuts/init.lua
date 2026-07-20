local M = {}

local job_id = nil
local tcp_chan = nil
local request_queue = {}
local on_notification = nil
local last_build = nil

local function get_root()
  local src = debug.getinfo(1).source:match('@(.+)')
  return vim.fn.fnamemodify(src, ':h:h:h')
end

local function get_server_path()
  return get_root() .. '/server/index.ts'
end

local function get_tsx_path()
  return get_root() .. '/node_modules/.bin/tsx'
end

local function on_data(_, data, event)
  if event == 'eof' then return end
  for _, line in ipairs(type(data) == 'table' and data or { data }) do
    local trimmed = vim.trim(line)
    if trimmed ~= '' then
      local ok, msg = pcall(vim.json.decode, trimmed)
      if ok then
        if on_notification and (msg.type == 'build_status' or msg.type == 'error' or msg.type == 'mode_change') then
          on_notification(msg)
        end
        if msg.type == 'build_result' then
          last_build = msg
          local item = table.remove(request_queue, 1)
          if item then item(msg) end
        elseif msg.type == 'response' then
          local item = table.remove(request_queue, 1)
          if item then item(msg) end
        elseif msg.type == 'error' then
          local item = table.remove(request_queue, 1)
          if item then item(msg) end
        end
      end
    end
  end
end

function M.start()
  local path = get_server_path()
  local tsx = get_tsx_path()
  if vim.fn.executable(tsx) ~= 1 then
    vim.notify('contuts: tsx not found, run npm install', vim.log.levels.ERROR)
    return
  end
  job_id = vim.fn.jobstart({ tsx, path }, {
    on_stdout = function(_, data)
      for _, line in ipairs(data) do
        local trimmed = vim.trim(line)
        if trimmed ~= '' then
          local ok, msg = pcall(vim.json.decode, trimmed)
          if ok and msg.ready then
            tcp_chan = vim.fn.sockconnect('tcp', '127.0.0.1:' .. msg.port, {
              on_data = on_data,
            })
            if tcp_chan > 0 then
              vim.notify('contuts: connected to server', vim.log.levels.INFO)
            end
          end
        end
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if line ~= '' then
          vim.notify('contuts server: ' .. line, vim.log.levels.WARN)
        end
      end
    end,
    on_exit = function()
      job_id = nil
      tcp_chan = nil
    end,
  })
end

function M.stop()
  if tcp_chan then
    vim.api.nvim_chan_send(tcp_chan, vim.json.encode({ type = 'shutdown' }) .. '\n')
    vim.fn.chanclose(tcp_chan)
    tcp_chan = nil
  end
  if job_id then
    vim.fn.jobstop(job_id)
    job_id = nil
  end
end

function M.send(msg, cb)
  if not tcp_chan then
    vim.notify('contuts: server not connected', vim.log.levels.ERROR)
    return
  end
  request_queue[#request_queue + 1] = cb
  vim.api.nvim_chan_send(tcp_chan, vim.json.encode(msg) .. '\n')
end

function M.set_notification_handler(handler)
  on_notification = handler
end

function M.get_last_build()
  return last_build
end

local function ensure_tcp()
  if not tcp_chan then
    vim.notify('contuts: server not connected', vim.log.levels.ERROR)
    return false
  end
  return true
end

vim.api.nvim_create_user_command('ContutsPrompt', function()
  require('contuts.chat').toggle()
end, { desc = 'Open or close the contuts chat window' })

vim.api.nvim_create_user_command('ContutsBuild', function(opts)
  if not ensure_tcp() then return end
  local msg = opts.args or ''
  if msg == '' then
    msg = 'Please implement the changes we discussed'
  end
  require('contuts.chat').open()
  vim.schedule(function()
    M.send({ type = 'build', content = msg, repoPath = vim.fn.getcwd() }, function(result)
      if result.type == 'build_result' then
        vim.notify(string.format('contuts: build complete — %d files, +%d/-%d lines',
          #result.files, result.insertions, result.deletions), vim.log.levels.INFO)
      elseif result.type == 'error' then
        vim.notify('contuts build error: ' .. result.content, vim.log.levels.ERROR)
      end
    end)
  end)
end, { nargs = '?', desc = 'Run a build task via opencode in a worktree' })

vim.api.nvim_create_user_command('ContutsReview', function()
  local build = last_build
  if not build then
    vim.notify('contuts: no build to review', vim.log.levels.ERROR)
    return
  end
  local base = build.baseBranch or 'main'
  local repo = vim.fn.getcwd()
  local files = vim.fn.systemlist('git -C ' .. vim.fn.shellescape(repo)
    .. ' diff --name-only ' .. base .. '...' .. build.branch)

  if #files == 0 then
    vim.notify('contuts: no changed files to review', vim.log.levels.WARN)
    return
  end

  vim.cmd('tabedit')
  local diff_left = vim.api.nvim_get_current_win()
  vim.cmd('Gedit ' .. base .. ':' .. files[1])
  vim.cmd('diffthis')
  vim.cmd('vertical rightbelow new')
  local diff_right = vim.api.nvim_get_current_win()
  vim.cmd('Gedit ' .. build.branch .. ':' .. files[1])
  vim.cmd('diffthis')
  vim.wo[diff_left].scrollbind = true
  vim.wo[diff_right].scrollbind = true
  vim.api.nvim_set_current_win(diff_left)

  local items = {}
  for _, f in ipairs(files) do
    items[#items + 1] = { filename = vim.fn.fnamemodify(f, ':.'), text = f }
  end
  vim.fn.setqflist({}, 'r', {
    title = 'Contuts Review: ' .. build.branch,
    items = items,
  })

  vim.cmd('copen')
  vim.cmd('wincmd L')

  vim.api.nvim_buf_set_keymap(vim.fn.bufnr('%'), 'n', '<CR>', '', {
    noremap = true, silent = true,
    callback = function()
      local qf = vim.fn.getqflist({ items = 1, idx = 1 })
      local entry = qf.items and qf.items[qf.idx]
      if not entry or not entry.filename then return end

      if vim.api.nvim_win_is_valid(diff_left) and vim.api.nvim_win_is_valid(diff_right) then
        vim.api.nvim_set_current_win(diff_left)
        vim.cmd('Gedit ' .. base .. ':' .. entry.filename)
        vim.cmd('diffthis')
        vim.api.nvim_set_current_win(diff_right)
        vim.cmd('Gedit ' .. build.branch .. ':' .. entry.filename)
        vim.cmd('diffthis')
        vim.cmd('diffupdate')
        vim.api.nvim_set_current_win(diff_left)
      end
    end,
  })

  vim.cmd('wincmd =')
end, { desc = 'Review the last build result side by side' })

vim.api.nvim_create_user_command('ContutsMerge', function()
  if not ensure_tcp() then return end
  M.send({ type = 'build_merge' }, function(msg)
    if msg.type == 'build_status' then
      vim.notify('contuts: ' .. msg.content, vim.log.levels.INFO)
    elseif msg.type == 'error' then
      vim.notify('contuts error: ' .. msg.content, vim.log.levels.ERROR)
    end
  end)
end, { desc = 'Merge the last worktree branch into the base branch' })

vim.api.nvim_create_user_command('ContutsDiscard', function()
  if not ensure_tcp() then return end
  M.send({ type = 'build_discard' }, function(msg)
    if msg.type == 'build_status' then
      vim.notify('contuts: ' .. msg.content, vim.log.levels.INFO)
    elseif msg.type == 'error' then
      vim.notify('contuts error: ' .. msg.content, vim.log.levels.ERROR)
    end
  end)
end, { desc = 'Discard the last worktree and clean up' })

vim.api.nvim_create_user_command('ContutsRestart', function()
  M.stop()
  vim.wait(500, function() return false end, 50)
  M.start()
end, { desc = 'Restart the contuts server' })

vim.api.nvim_create_autocmd('VimLeavePre', {
  callback = function()
    M.stop()
  end,
})

M.start()

return M
