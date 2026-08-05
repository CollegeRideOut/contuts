local M = {}

local walker = require('contuts.patch_walker')

local ns = vim.api.nvim_create_namespace('contuts_diff')
local state = { win = nil, prev_stl = nil, flash_id = nil }

vim.api.nvim_set_hl(0, 'ContutsDiffAdd', { bg = '#1d4a2d' })
vim.api.nvim_set_hl(0, 'ContutsDiffDel', { bg = '#4a1d1d' })
vim.api.nvim_set_hl(0, 'ContutsDiffCur', { bg = '#2a4a7a', bold = true })
vim.api.nvim_set_hl(0, 'ContutsDiffTitle', { fg = '#c0c0c0', bold = true })
vim.api.nvim_set_hl(0, 'ContutsDiffHelp', { fg = '#5f6b7a' })

local function full_path(root, name)
  if root == '/' then return '/' .. name end
  return root .. '/' .. name
end

local function set_keymaps(buf)
  local k = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set('n', ']', function() M.step(1) end, k)
  vim.keymap.set('n', '<CR>', function() M.step(1) end, k)
  vim.keymap.set('n', 'n', function() M.step(1) end, k)
  vim.keymap.set('n', '[', function() M.step(-1) end, k)
  vim.keymap.set('n', 'p', function() M.step(-1) end, k)
  vim.keymap.set('n', 'J', function() M.jump_file(1) end, k)
  vim.keymap.set('n', 'K', function() M.jump_file(-1) end, k)
  vim.keymap.set('n', 'g', function() M.goto(0) end, k)
  vim.keymap.set('n', 'G', function() M.goto(math.huge) end, k)
  vim.keymap.set('n', 'o', function() M.open_file() end, k)
  vim.keymap.set('n', 'q', function() M.quit() end, k)
end

local function open_buf(win, path)
  vim.api.nvim_set_current_win(win)
  if vim.fn.filereadable(path) == 1 then
    vim.cmd('keepalt edit! ' .. vim.fn.fnameescape(path))
  else
    vim.cmd('enew')
    vim.api.nvim_buf_set_name(0, path)
  end
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buflisted = false
  set_keymaps(buf)
end

local function reload_path(path)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_get_name(buf) == path then
      if vim.bo[buf].modified then
        vim.notify('contuts diff: skipping reload of modified buffer ' .. path, vim.log.levels.WARN)
      else
        vim.api.nvim_buf_call(buf, function() vim.cmd('edit!') end)
      end
    end
  end
end

local function set_statusline(win)
  local s = walker.state()
  if not s or not vim.api.nvim_win_is_valid(win) then return end
  local pv = walker.preview()
  local fname = ''
  if pv and pv.file then
    fname = pv.file
  elseif s.steps[1] then
    fname = s.steps[1].file.name
  end
  local cur_step = math.min(s.idx + 1, #s.steps)
  local tag = pv and pv.done and '[done]' or '[preview]'
  local file_num = 0
  for i = 1, #s.files do
    if s.files[i].name == fname then
      file_num = i
      break
    end
  end
  local sl = string.format('%%#ContutsDiffTitle#ContutsDiff%%* step %d/%d %s  file %d/%d  %s  +%d/-%d',
    cur_step, #s.steps, tag, file_num, s.fcount, fname, s.add, s.del)
  if not (pv and pv.done) then
    local txt = walker.preview_text()
    if txt ~= '' then sl = sl .. '  |  → ' .. txt end
  end
  vim.wo[win].statusline = sl
end

local function show_preview()
  local s = walker.state()
  if not s or not (state.win and vim.api.nvim_win_is_valid(state.win)) then return end
  local win = state.win
  local buf = vim.api.nvim_win_get_buf(win)
  if state.flash_id then
    pcall(vim.api.nvim_buf_del_extmark, buf, ns, state.flash_id)
    state.flash_id = nil
  end
  local pv = walker.preview()
  if not pv or pv.done then
    set_statusline(win)
    return
  end
  if pv.file then
    local path = full_path(s.root, pv.file)
    local cur_path = vim.api.nvim_buf_get_name(buf)
    if cur_path ~= path then
      open_buf(win, path)
      buf = vim.api.nvim_win_get_buf(win)
    end
  end
  local lc = vim.api.nvim_buf_line_count(buf)
  local ln = math.min(math.max(pv.ln, 1), math.max(lc, 1))
  vim.api.nvim_win_set_cursor(win, { ln, 0 })
  vim.cmd('normal! zz')
  local txt = walker.preview_text()
  if txt ~= '' then
    state.flash_id = vim.api.nvim_buf_set_extmark(buf, ns, ln - 1, 0, {
      virt_text = { { '→ ' .. txt, 'ContutsDiffCur' } },
      virt_text_pos = 'eol',
    })
  end
  set_statusline(win)
end

local function after_step(step_result)
  local s = walker.state()
  if not s then return end
  if step_result.file then
    reload_path(full_path(s.root, step_result.file))
  end
  show_preview()
end

function M.step(dir)
  local s = walker.state()
  if not s then return end
  local res = walker.step(dir)
  if not res.ok then
    if res.err == 'boundary' then
      vim.notify(dir > 0 and 'contuts diff: at last step' or 'contuts diff: at first step', vim.log.levels.INFO)
    else
      vim.notify('contuts diff: ' .. res.err, vim.log.levels.ERROR)
    end
    return
  end
  after_step(res)
end

function M.goto(target)
  local s = walker.state()
  if not s then return end
  target = math.max(0, math.min(target, #s.steps))
  local guard = #s.steps + 2
  while s.idx < target and guard > 0 do
    M.step(1)
    guard = guard - 1
  end
  guard = #s.steps + 2
  while s.idx > target and guard > 0 do
    M.step(-1)
    guard = guard - 1
  end
end

function M.jump_file(dir)
  local s = walker.state()
  if not s then return end
  local cur = s.steps[s.idx]
  local cur_file = cur and cur.file.name
  if dir > 0 then
    for i = s.idx + 1, #s.steps do
      if not cur_file or s.steps[i].file.name ~= cur_file then
        return M.goto(i)
      end
    end
    vim.notify('contuts diff: at last file', vim.log.levels.INFO)
  else
    for i = s.idx - 1, 0, -1 do
      local nm = i > 0 and s.steps[i].file.name or nil
      if nm and nm ~= cur_file then
        return M.goto(i)
      end
    end
    vim.notify('contuts diff: at first file', vim.log.levels.INFO)
  end
end

function M.open_file()
  local s = walker.state()
  if not s then return end
  local pv = walker.preview()
  local st = pv and pv.step or s.steps[#s.steps]
  if not st then
    vim.notify('contuts diff: no step selected', vim.log.levels.INFO)
    return
  end
  local path = full_path(s.root, st.file.name)
  if vim.fn.filereadable(path) ~= 1 then
    vim.notify('contuts diff: ' .. st.file.name .. ' not present in the tree', vim.log.levels.WARN)
    return
  end
  vim.cmd('tabedit ' .. vim.fn.fnameescape(path))
  local ln = pv and pv.ln or 1
  local lc = vim.api.nvim_buf_line_count(0)
  vim.api.nvim_win_set_cursor(0, { math.min(math.max(ln, 1), math.max(lc, 1)), 0 })
end

function M.quit()
  local s = walker.state()
  if not s then return end
  local res = walker.restore()
  if not res.ok then
    vim.notify('contuts diff: restore failed — ' .. res.err .. ' (run :ContutsDiffRestore to retry)', vim.log.levels.ERROR)
    return
  end
  local root = s.root
  local names = {}
  for _, f in ipairs(s.files) do names[full_path(root, f.name)] = true end
  for _, st in ipairs(s.steps) do names[full_path(root, st.file.name)] = true end
  local win = state.win
  local prev = state.prev_stl
  walker.close()
  state.flash_id = nil
  for p in pairs(names) do reload_path(p) end
  if vim.api.nvim_win_is_valid(win) then
    if prev then
      vim.wo[win].statusline = prev
    else
      vim.wo[win].statusline = nil
    end
    pcall(vim.cmd, 'close')
  end
  state.win = nil
  vim.notify('contuts diff: original state restored', vim.log.levels.INFO)
end

function M.restore_command()
  if walker.state() then
    local res = walker.restore()
    if not res.ok then
      vim.notify('contuts diff: ' .. res.err, vim.log.levels.ERROR)
      return
    end
    M.quit()
    return
  end
  local res = walker.restore_from_disk()
  if not res.ok then
    vim.notify('contuts diff: ' .. res.err, vim.log.levels.ERROR)
    return
  end
  for _, name in ipairs(res.files) do reload_path(full_path(res.root, name)) end
  vim.notify('contuts diff: restored saved session ' .. res.dir, vim.log.levels.INFO)
end

function M.win()
  return state.win
end

function M.open(args, opts)
  opts = opts or {}
  local res = walker.capture(args, opts)
  if not res.ok then
    vim.notify('contuts diff: ' .. res.err, vim.log.levels.INFO)
    return
  end
  local s = walker.state()
  res = walker.rewind()
  if not res.ok then
    walker.close()
    vim.notify('contuts diff: ' .. res.err, vim.log.levels.ERROR)
    return
  end
  vim.cmd('tabnew')
  state.win = vim.api.nvim_get_current_win()
  state.prev_stl = vim.wo[state.win].statusline
  local root = s.root
  local names = {}
  for _, f in ipairs(s.files) do names[full_path(root, f.name)] = true end
  for p in pairs(names) do reload_path(p) end
  open_buf(state.win, full_path(root, s.steps[1].file.name))
  vim.api.nvim_set_current_win(state.win)
  show_preview()
  local mode = s.granularity == 'line' and ' (line-by-line)' or ''
  vim.notify(string.format(
    'contuts diff: %d steps%s across %d files (+%d/-%d) — tree rewound to base; ] applies each change after you see it; original restored on q.  ]/[ step  J/K file  g/G first/last  o open  q quit',
    #s.steps, mode, s.fcount, s.add, s.del), vim.log.levels.INFO)
end

vim.api.nvim_create_autocmd('VimLeavePre', {
  callback = function()
    if walker.state() then
      walker.restore()
    end
  end,
})

vim.api.nvim_create_autocmd('WinClosed', {
  callback = function()
    if state.win and walker.state() and not vim.api.nvim_win_is_valid(state.win) then
      local res = walker.restore()
      if res.ok then
        walker.close()
      else
        vim.notify('contuts diff: walk window closed — ' .. res.err .. ' (run :ContutsDiffRestore)', vim.log.levels.ERROR)
      end
      state.win = nil
      state.flash_id = nil
    end
  end,
})

return M
