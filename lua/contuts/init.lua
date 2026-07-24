local M = {}

local job_id = nil
local tcp_chan = nil
local request_queue = {}
local on_notification = nil
local last_build = nil
local last_evidence = nil

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
        if msg.type == 'build_status' and msg.content and msg.content:match('^Branch:') then
          vim.notify('contuts: ' .. msg.content, vim.log.levels.INFO)
        end
        if msg.type == 'evidence' then
          last_evidence = msg.items
          require('contuts.plan').set_ai_items(msg.items or {})
          vim.notify('contuts: ' .. #(msg.items or {}) .. ' claims/tasks received', vim.log.levels.INFO)
        end
        if msg.type == 'plan_proposal' then
          require('contuts.plan').set_proposal_state('proposed', { diff = msg.diff or '', files = msg.files or {}, diffStat = msg.diffStat or '', intention = msg.intention or '' })
        elseif msg.type == 'plan_accepted' then
          require('contuts.plan').set_proposal_state('accepted')
        elseif msg.type == 'plan_rejected' then
          require('contuts.plan').set_proposal_state('rejected')
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
        elseif msg.type == 'plan_proposal' or msg.type == 'plan_accepted' or msg.type == 'plan_rejected' then
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

function M.get_last_evidence()
  return last_evidence
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

vim.api.nvim_create_user_command('ContutsChat', function()
  require('contuts.chat').toggle()
end, { desc = 'Toggle the persistent chat window' })

local function add_item_from_selection(item_type, opts)
  local file = vim.fn.expand('%:.:')
  if file == '' then
    vim.notify('contuts: no file', vim.log.levels.ERROR)
    return
  end
  local start_line = opts.line1
  local end_line = opts.line2
  local code_block = nil
  if start_line and end_line then
    local lines = vim.fn.getline(start_line, end_line)
    code_block = table.concat(lines, '\n')
  end
  local desc = vim.fn.input(item_type == 'task' and 'Task: ' or 'Claim: ')
  if desc == '' then
    vim.notify('contuts: cancelled', vim.log.levels.INFO)
    return
  end
  require('contuts.plan').add_item({
    type = item_type,
    file = file,
    line = start_line or vim.fn.line('.'),
    endLine = end_line or vim.fn.line('.'),
    codeBlock = code_block,
    description = desc,
    detail = desc,
    chat = {},
  })
  vim.notify(string.format('contuts: %s added at %s:%d', item_type, file, start_line or vim.fn.line('.')), vim.log.levels.INFO)
end

vim.api.nvim_create_user_command('ContutsAddClaim', function(opts)
  add_item_from_selection('claim', opts)
end, { range = true, desc = 'Add a claim at current line or visual selection' })

vim.api.nvim_create_user_command('ContutsAddTask', function(opts)
  add_item_from_selection('task', opts)
end, { range = true, desc = 'Add a task at current line or visual selection' })

vim.api.nvim_create_user_command('ContutsBuild', function(opts)
  if not ensure_tcp() then return end
  local msg = opts.args or ''
  if msg == '' then
    msg = 'Please implement the changes we discussed'
  end
  local plan_text = require('contuts.plan').get_active_text()
  if plan_text and plan_text ~= '' then
    msg = msg .. '\n\n── Planning context ──\n' .. plan_text
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
  require('contuts.review').open(build)
end, { desc = 'Review the last build result side by side' })

vim.api.nvim_create_user_command('ContutsEvidence', function()
  require('contuts.plan').open()
end, { desc = 'View claims and tasks (plan view)' })

vim.api.nvim_create_user_command('ContutsPlan', function()
  if not ensure_tcp() then return end
  local plan = require('contuts.plan')
  plan.open({
    on_build = function(item, idx)
      local msg = string.format('Handle the issue at %s:%d:\n\n%s', item.file, item.line, item.description)
      local plan_text = plan.get_active_task_text()
      if plan_text and plan_text ~= '' then
        msg = msg .. '\n\n── Other active tasks ──\n' .. plan_text
      end
      if item.chat and #item.chat > 0 then
        msg = msg .. '\n\n── Task discussion ──\n'
        for _, m in ipairs(item.chat) do
          msg = msg .. m.role .. ': ' .. m.content .. '\n'
        end
      end
      vim.schedule(function()
        M.send({ type = 'plan_build', content = msg }, function(result)
          if result.type == 'error' then
            vim.notify('contuts plan build error: ' .. result.content, vim.log.levels.ERROR)
            plan.set_proposal_state('rejected')
          end
        end)
      end)
    end,
    on_build_all = function()
      local msg = 'Please implement the pending tasks'
      local plan_text = plan.get_active_task_text()
      if plan_text and plan_text ~= '' then
        msg = msg .. '\n\n── Tasks ──\n' .. plan_text
      end
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
    end,
    on_accept = function(idx)
      vim.schedule(function()
        M.send({ type = 'plan_accept' }, function(result)
          if result.type == 'error' then
            vim.notify('contuts accept error: ' .. result.content, vim.log.levels.ERROR)
          end
        end)
      end)
    end,
    on_reject = function(idx)
      vim.schedule(function()
        M.send({ type = 'plan_reject' }, function(result)
          if result.type == 'error' then
            vim.notify('contuts reject error: ' .. result.content, vim.log.levels.ERROR)
          end
        end)
      end)
    end,
  })
end, { desc = 'Interactive plan — claims and tasks, build tasks per-item (b) or all (B)' })

vim.api.nvim_create_user_command('ContutsPlanReview', function()
  require('contuts.planreview').open(last_build)
end, { desc = 'View evidence with annotations and build summary' })

vim.api.nvim_create_user_command('ContutsMerge', function()
  vim.notify('contuts: builds commit directly — no merge needed. Use :ContutsReview to see changes, or git log to review commits.', vim.log.levels.INFO)
end, { desc = 'Not needed — builds commit directly to your branch' })

vim.api.nvim_create_user_command('ContutsDiscard', function()
  vim.notify('contuts: builds commit directly — use git reset --soft HEAD~1 to undo the last build commit.', vim.log.levels.INFO)
end, { desc = 'Not needed — use git reset to undo commits' })

vim.api.nvim_create_user_command('ContutsRestart', function()
  M.stop()
  vim.wait(500, function() return false end, 50)
  M.start()
end, { desc = 'Restart the contuts server' })

vim.keymap.set('n', '<Leader>ce', function()
  local file = vim.fn.expand('%:.:')
  local line = vim.fn.line('.')
  local plan = require('contuts.plan')
  for _, item in ipairs(plan.get_items()) do
    if item.file == file and item.line == line then
      require('contuts.plan').view_item_detail(item)
      return
    end
  end
  vim.notify('contuts: no claim/task on this line', vim.log.levels.INFO)
end, { desc = 'Show contuts claim/task detail for the line under cursor' })

vim.api.nvim_create_autocmd('VimLeavePre', {
  callback = function()
    M.stop()
  end,
})

M.start()

return M
