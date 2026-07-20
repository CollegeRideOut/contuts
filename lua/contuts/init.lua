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
        if on_notification and (msg.type == 'build_status' or msg.type == 'error') then
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
  vim.cmd('tab Git log --oneline main..' .. build.branch)
  vim.cmd('tab Git diff main...' .. build.branch)
end, { desc = 'Review the last build result (log + diff)' })

vim.api.nvim_create_user_command('ContutsMerge', function()
  if not ensure_tcp() then return end
  M.send({ type = 'build_merge' }, function(msg)
    if msg.type == 'build_status' then
      vim.notify('contuts: ' .. msg.content, vim.log.levels.INFO)
    elseif msg.type == 'error' then
      vim.notify('contuts error: ' .. msg.content, vim.log.levels.ERROR)
    end
  end)
end, { desc = 'Merge the last worktree branch into main' })

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
