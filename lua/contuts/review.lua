local M = {}

local ns = vim.api.nvim_create_namespace('contuts_review_evidence')

local state = {
  base = nil,
  branch = nil,
  files = {},
  current_file = nil,
  diff_left = nil,
  diff_right = nil,
  panel_win = nil,
  panel_buf = nil,
  panel_mode = 'files',
}

local severity = {
  error   = { sign = '⚑', hl_sign = 'DiagnosticSignError', hl_line = 'ContutsEvidenceErr' },
  warning = { sign = '⚐', hl_sign = 'DiagnosticSignWarn', hl_line = 'ContutsEvidenceWarn' },
  info    = { sign = '●', hl_sign = 'DiagnosticSignInfo', hl_line = 'ContutsEvidenceInfo' },
}

local function file_exists(ref, filename)
  vim.fn.system({ 'git', 'cat-file', '-e', ref .. ':' .. filename })
  return vim.v.shell_error == 0
end

local function load_file(win, ref, filename)
  vim.api.nvim_set_current_win(win)
  vim.cmd('enew!')
  if file_exists(ref, filename) then
    vim.cmd('Gedit ' .. ref .. ':' .. filename)
  else
    vim.api.nvim_buf_set_name(vim.api.nvim_get_current_buf(), 'missing-' .. ref:gsub('[^%w_-]', '_'))
    vim.api.nvim_buf_set_option(vim.api.nvim_get_current_buf(), 'bufhidden', 'wipe')
    vim.api.nvim_buf_set_lines(vim.api.nvim_get_current_buf(), 0, -1, false, {
      '', '  File does not exist in ' .. ref, '', '  ' .. filename, '',
    })
    vim.bo[vim.api.nvim_get_current_buf()].modified = false
  end
  vim.cmd('diffthis')
  vim.wo[win].scrollbind = true
  vim.api.nvim_buf_set_keymap(vim.api.nvim_get_current_buf(), 'n', 'r', '', {
    silent = true,
    callback = function() M.query_reference() end,
  })
end

local function place_evidence_marks()
  if not state.current_file then return end
  local items = require('contuts.evidence').get_items_for_file(state.current_file)
  if not items then return end
  for _, item in ipairs(items) do
    local cfg = severity[item.severity] or severity.info
    for _, win in ipairs({ state.diff_left, state.diff_right }) do
      if vim.api.nvim_win_is_valid(win) then
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.api.nvim_buf_is_valid(buf) then
          pcall(vim.api.nvim_buf_set_extmark, buf, ns, item.line - 1, 0, {
            sign_text = cfg.sign,
            sign_hl_group = cfg.hl_sign,
            hl_group = cfg.hl_line,
            priority = 200,
          })
        end
      end
    end
  end
end

local function load_diff(filename)
  if not vim.api.nvim_win_is_valid(state.diff_left) or not vim.api.nvim_win_is_valid(state.diff_right) then
    vim.notify('contuts review: diff windows closed', vim.log.levels.ERROR)
    return
  end
  state.current_file = filename
  load_file(state.diff_left, state.base, filename)
  load_file(state.diff_right, state.branch, filename)
  vim.cmd('diffupdate')
  vim.api.nvim_set_current_win(state.diff_left)
  place_evidence_marks()
  if state.panel_mode == 'evidence' then render_panel() end
  if state.panel_mode == 'changes' then M.parse_changes() end
end

local function render_panel()
  if not (state.panel_win and vim.api.nvim_win_is_valid(state.panel_win)) then return end
  if not (state.panel_buf and vim.api.nvim_buf_is_valid(state.panel_buf)) then return end

  local lines = {}
  if state.panel_mode == 'files' then
    for _, f in ipairs(state.files) do
      table.insert(lines, f)
    end
  elseif state.panel_mode == 'evidence' then
    local help = '  Press f=files e=evidence s=summary'
    table.insert(lines, help)
    table.insert(lines, '── Evidence ────────────────────────────────')
    local evidence = require('contuts.evidence')
    local items = evidence.get_items_for_file(state.current_file)
    if not items or #items == 0 then
      table.insert(lines, '  No claims for this file')
    else
      for _, item in ipairs(items) do
        local sig = (severity[item.severity] or severity.info).sign
        table.insert(lines, string.format('  %s  line %d  %s', sig, item.line, item.claim or ''))
      end
    end
  elseif state.panel_mode == 'changes' then
    return -- changes mode populates async, don't wipe it
  end

  vim.api.nvim_buf_set_lines(state.panel_buf, 0, -1, false, lines)
end

function M.query_reference()
  if not state.current_file then return end
  local buf = vim.api.nvim_get_current_buf()
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end

  local pos = vim.fn.getcurpos()
  local line = pos[2]

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local function_name = nil
  for i = math.min(line, #lines), 1, -1 do
    local l = lines[i]
    local name = l:match('function%s+([%w_%.]+)')
      or l:match('def%s+([%w_%.]+)')
      or l:match('(%w+)%s*[:=]%s*function')
      or l:match('(%w+)%s*%(')
    if name and not l:match('end') and not l:match('^%s*$') then
      function_name = name
      break
    end
  end

  if not function_name then
    vim.notify('contuts: could not find enclosing function', vim.log.levels.WARN)
    return
  end

  if vim.fn.exists('*vim.lsp.buf_request') == 0 then
    vim.notify('contuts: LSP not available', vim.log.levels.WARN)
    return
  end

  local params = vim.lsp.util.make_position_params(vim.api.nvim_get_current_win(), nil)
  if not params then
    vim.notify('contuts: LSP not active on this buffer', vim.log.levels.WARN)
    return
  end

  vim.notify('contuts: querying LSP for ' .. function_name .. '...', vim.log.levels.INFO)

  vim.lsp.buf_request(0, 'textDocument/references', {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = params.position,
    context = { includeDeclaration = true },
  }, function(err, result)
    if err or not result then
      vim.notify('contuts: LSP request failed', vim.log.levels.WARN)
      return
    end

    local same_file = {}
    local other_files = {}
    local cross_files = {}

    for _, loc in ipairs(result) do
      local loc_file = vim.uri_to_fname(loc.uri)
      local rel = vim.fn.fnamemodify(loc_file, ':.')
      if rel == state.current_file then
        table.insert(same_file, loc)
      else
        table.insert(other_files, loc)
        for _, f in ipairs(state.files) do
          if f == rel then
            table.insert(cross_files, loc)
            break
          end
        end
      end
    end

    local lines = {}
    local help = '  Press f=files e=evidence s=summary r=re-query'
    table.insert(lines, help)
    table.insert(lines, '── Change Summary ─────────────────────────')
    table.insert(lines, '')
    table.insert(lines, '  ' .. function_name)
    table.insert(lines, string.format('    same file: %d references', #same_file))
    table.insert(lines, string.format('    other files: %d references', #other_files))
    if #cross_files > 0 then
      table.insert(lines, '')
      table.insert(lines, '    ⚡ cross-file connections:')
      for _, loc in ipairs(cross_files) do
        local rel = vim.fn.fnamemodify(vim.uri_to_fname(loc.uri), ':.')
        table.insert(lines, string.format('       %s :%d', rel, loc.range.start.line + 1))
      end
    end

    vim.api.nvim_buf_set_lines(state.panel_buf, 0, -1, false, lines)
  end)
end

function M.parse_changes()
  if not state.current_file then return end
  local diff_output = vim.fn.system({
    'git', 'diff', state.base .. '...' .. state.branch, '--',
    '-U0', state.current_file
  })

  local functions = {}
  for line in diff_output:gmatch('[^\n]+') do
    local func = line:match('@@ .* @@%s*(.*)')
    if func then
      local name = func:match('function%s+([%w_%.]+)')
        or func:match('def%s+([%w_%.]+)')
        or func:match('(%w+)%s*[:=]%s*function')
        or func:match('(%w+)%s*%(')
      if name then
        functions[name] = true
      end
    end
  end

  local unique = {}
  for name, _ in pairs(functions) do
    table.insert(unique, name)
  end

  local lines = {}
  local help = '  Press f=files e=evidence s=summary r=re-query'
  table.insert(lines, help)
  table.insert(lines, '── Change Summary ─────────────────────────')
  if #unique == 0 then
    table.insert(lines, '')
    table.insert(lines, '  (no function names found in diff)')
    table.insert(lines, '  press r on any line to query LSP')
  else
    for _, name in ipairs(unique) do
      table.insert(lines, '')
      table.insert(lines, '  ' .. name)
      table.insert(lines, '    press r to query LSP references')
    end
  end

  vim.api.nvim_buf_set_lines(state.panel_buf, 0, -1, false, lines)
end

function M.open(build)
  local base = build.baseBranch or 'main'
  local repo = vim.fn.getcwd()
  local files = vim.fn.systemlist('git -C ' .. vim.fn.shellescape(repo)
    .. ' diff --name-only ' .. base .. '...' .. build.branch)

  if #files == 0 then
    vim.notify('contuts: no changed files to review', vim.log.levels.WARN)
    return
  end

  state.base = base
  state.branch = build.branch
  state.files = files
  state.current_file = nil
  state.panel_mode = 'files'

  vim.cmd('tabedit')

  vim.cmd('rightbelow new')
  state.panel_win = vim.api.nvim_get_current_win()
  state.panel_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(state.panel_win, state.panel_buf)
  vim.bo[state.panel_buf].buflisted = false
  vim.bo[state.panel_buf].modified = false
  vim.wo[state.panel_win].cursorline = true
  vim.wo[state.panel_win].number = true

  vim.cmd('wincmd k')
  state.diff_left = vim.api.nvim_get_current_win()
  vim.cmd('vertical rightbelow new')
  state.diff_right = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(state.diff_left)

  local function switch_mode(mode)
    state.panel_mode = mode
    if mode == 'files' or mode == 'evidence' then
      render_panel()
    elseif mode == 'changes' then
      M.parse_changes()
    end
  end

  vim.api.nvim_buf_set_keymap(state.panel_buf, 'n', '<CR>', '', {
    silent = true,
    callback = function()
      if state.panel_mode == 'files' then
        local line = vim.fn.getline('.')
        if line and line ~= '' then load_diff(line) end
      end
    end,
  })

  vim.api.nvim_buf_set_keymap(state.panel_buf, 'n', 'f', '', {
    silent = true, callback = function() switch_mode('files') end,
  })
  vim.api.nvim_buf_set_keymap(state.panel_buf, 'n', 'e', '', {
    silent = true, callback = function() switch_mode('evidence') end,
  })
  vim.api.nvim_buf_set_keymap(state.panel_buf, 'n', 's', '', {
    silent = true, callback = function() switch_mode('changes') end,
  })
  vim.api.nvim_buf_set_keymap(state.panel_buf, 'n', 'r', '', {
    silent = true, callback = M.query_reference,
  })
  vim.api.nvim_buf_set_keymap(state.panel_buf, 'n', 'q', '', {
    silent = true,
    callback = function()
      if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
        vim.api.nvim_win_close(state.panel_win, true)
      end
    end,
  })

  load_diff(files[1])
  vim.api.nvim_set_current_win(state.diff_left)
  vim.cmd('wincmd =')
  render_panel()
end

return M
