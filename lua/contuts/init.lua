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
          require('contuts.evidence').set_items(msg.items)
          vim.notify('contuts: ' .. #(msg.items or {}) .. ' evidence claims received', vim.log.levels.INFO)
        end
        if msg.type == 'plan_proposal' then
          require('contuts.evidence').set_proposal_state('proposed', { diff = msg.diff or '', files = msg.files or {}, diffStat = msg.diffStat or '' })
        elseif msg.type == 'plan_accepted' then
          require('contuts.evidence').set_proposal_state('accepted')
        elseif msg.type == 'plan_rejected' then
          require('contuts.evidence').set_proposal_state('rejected')
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

vim.api.nvim_create_user_command('ContutsBuild', function(opts)
  if not ensure_tcp() then return end
  local msg = opts.args or ''
  if msg == '' then
    msg = 'Please implement the changes we discussed'
  end
  local evidence_text = require('contuts.evidence').get_active_text()
  if evidence_text and evidence_text ~= '' then
    msg = msg .. '\n\n── Planning context (evidence and annotations) ──\n' .. evidence_text
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
  require('contuts.evidence').open()
end, { desc = 'View evidence claims from the last AI response' })

vim.api.nvim_create_user_command('ContutsPlan', function()
  if not ensure_tcp() then return end
  local evidence = require('contuts.evidence')
  evidence.open({
    on_build = function(item)
      local instruction = item.data.claim
      local msg = string.format('Handle the issue at %s:%d [%s]:\n\n%s', item.data.file, item.data.line, item.data.severity or '', instruction)
      local evidence_text = evidence.get_active_text()
      if evidence_text and evidence_text ~= '' then
        msg = msg .. '\n\n── Planning context (evidence and annotations) ──\n' .. evidence_text
      end
      vim.schedule(function()
        M.send({ type = 'plan_build', content = msg }, function(result)
          if result.type == 'error' then
            vim.notify('contuts plan build error: ' .. result.content, vim.log.levels.ERROR)
            evidence.set_proposal_state('rejected')
          end
        end)
      end)
    end,
    on_build_all = function()
      local msg = 'Please implement the changes we discussed'
      local evidence_text = evidence.get_active_text()
      if evidence_text and evidence_text ~= '' then
        msg = msg .. '\n\n── Planning context (evidence and annotations) ──\n' .. evidence_text
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
    on_accept = function(item)
      vim.schedule(function()
        M.send({ type = 'plan_accept' }, function(result)
          if result.type == 'error' then
            vim.notify('contuts accept error: ' .. result.content, vim.log.levels.ERROR)
          end
        end)
      end)
    end,
    on_reject = function(item)
      vim.schedule(function()
        M.send({ type = 'plan_reject' }, function(result)
          if result.type == 'error' then
            vim.notify('contuts reject error: ' .. result.content, vim.log.levels.ERROR)
          end
        end)
      end)
    end,
  })
end, { desc = 'Interactive plan — browse evidence, annotate, build by item (b) or all (B)' })

vim.api.nvim_create_user_command('ContutsPlanReview', function()
  require('contuts.planreview').open(last_build)
end, { desc = 'View evidence with annotations and build summary' })

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

vim.keymap.set('n', '<Leader>ce', function()
  require('contuts.evidence').show_detail()
end, { desc = 'Show contuts evidence claim detail for the line under cursor' })

vim.api.nvim_create_autocmd('VimLeavePre', {
  callback = function()
    M.stop()
  end,
})

M.start()

return M
