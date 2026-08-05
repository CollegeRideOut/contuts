local M = {}

local session = nil
local SESSION_ROOT = '/tmp/contuts'

local function trim(s)
  return (s or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function git(root, args, input)
  local cmd = { 'git', '-C', root, '-c', 'core.quotepath=false' }
  vim.list_extend(cmd, args)
  local opts = {}
  if input then opts.stdin = input end
  local res = vim.system(cmd, opts):wait()
  return { code = res.code, out = res.stdout or '', err = trim(res.stderr) }
end

local function split_args(s)
  local out = {}
  for a in (s or ''):gmatch('%S+') do out[#out + 1] = a end
  return out
end

local function unquote_path(s)
  if s:sub(1, 1) ~= '"' then return s end
  s = s:sub(2, -2)
  s = s:gsub('\\%d%d%d', function(oct)
    return string.char(tonumber(oct:sub(2), 8) or 63)
  end)
  return s:gsub('\\(.)', function(c)
    if c == 't' then return '\t'
    elseif c == 'n' then return '\n'
    elseif c == '\\' then return '\\'
    elseif c == '"' then return '"'
    end
    return c
  end)
end

local DIFF_FLAGS = { '--no-color', '--no-ext-diff', '--no-renames', '--binary' }

local function capture_diff(root, pre, args)
  local cmd = {}
  if pre and pre[1] == 'stash' then
    vim.list_extend(cmd, pre)
    vim.list_extend(cmd, DIFF_FLAGS)
  else
    table.insert(cmd, 'diff')
    vim.list_extend(cmd, DIFF_FLAGS)
    vim.list_extend(cmd, pre or {})
  end
  vim.list_extend(cmd, args or {})
  local res = git(root, cmd)
  if res.code ~= 0 then return nil, trim(res.err) or trim(res.out) end
  return res.out
end

local function parse_patch(text, patch)
  local files = {}
  local cur = nil
  local hunk = nil
  local in_hunk = false
  local ol, nl = 0, 0
  for line in (text .. '\n'):gmatch('(.-)\n') do
    if line == '' and not in_hunk then break end
    if line == '' and in_hunk then
      hunk.raw[#hunk.raw + 1] = line
    elseif line:sub(1, 10) == 'diff --git' then
      cur = {
        name = nil,
        hdr = { line },
        hunks = {},
        binary = nil,
        is_new = false,
        mode_change = false,
        patch = patch,
      }
      table.insert(files, cur)
      local dg = line:match('^diff %-%-git %S+ (%S+)$')
      if dg then
        local stripped = dg:gsub('^[abciw]/', '', 1)
        if stripped ~= '/dev/null' then
          cur.name = unquote_path(stripped)
        end
      end
      hunk = nil
      in_hunk = false
    elseif cur then
      if line:sub(1, 2) == '@@' then
        hunk = { raw = { line }, steps = {}, binary = false }
        table.insert(cur.hunks, hunk)
        in_hunk = true
        ol = tonumber(line:match('^@@%s*%-(%d+)')) or 0
        nl = tonumber(line:match('%s%+(%d+)')) or 0
        hunk.ol, hunk.nl = ol, nl
        hunk.ocnt = tonumber(line:match('^@@%s*%-%d+,(%d+)')) or 1
        hunk.ncnt = tonumber(line:match('%s%+%d+,(%d+)')) or 1
      elseif line:sub(1, 16) == 'GIT binary patch' then
        hunk = { raw = { line }, steps = {}, binary = true }
        table.insert(cur.hunks, hunk)
        cur.binary = 'patch'
        in_hunk = true
      elseif in_hunk and hunk then
        local rpos = #hunk.raw + 1
        hunk.raw[rpos] = line
        local kind = line:sub(1, 1)
        if kind == '+' then
          table.insert(hunk.steps, { kind = 'add', old_ln = ol, new_ln = nl, text = line:sub(2), rpos = rpos })
          nl = nl + 1
        elseif kind == '-' then
          table.insert(hunk.steps, { kind = 'del', old_ln = ol, new_ln = nl, text = line:sub(2), rpos = rpos })
          ol = ol + 1
        elseif kind == ' ' then
          ol = ol + 1
          nl = nl + 1
        end
      else
        table.insert(cur.hdr, line)
        if line:sub(1, 14) == 'Binary files ' then
          cur.binary = 'note'
        end
        if line:match('^old mode') or line:match('^new mode') then
          cur.mode_change = true
        end
        local name = line:match('^[+-][+-][+-] (.+)$')
        if name then
          local stripped = name:gsub('^[abciw]/', '', 1)
          if stripped == '/dev/null' then
            if line:sub(1, 3) == '---' then
              cur.is_new = true
            else
              cur.is_del = true
            end
          else
            cur.name = unquote_path(stripped)
          end
        end
      end
    end
  end
  return files
end

local function patch_text(files)
  local parts = {}
  for _, f in ipairs(files) do
    if f.binary ~= 'note' then
      local lines = {}
      vim.list_extend(lines, f.hdr)
      for _, h in ipairs(f.hunks) do
        vim.list_extend(lines, h.raw)
      end
      table.insert(parts, table.concat(lines, '\n'))
    end
  end
  return table.concat(parts, '\n')
end

local function build_steps(files, granularity)
  local steps = {}
  local add, del = 0, 0
  for _, f in ipairs(files) do
    for _, h in ipairs(f.hunks) do
      for _, st in ipairs(h.steps) do
        if st.kind == 'add' then
          add = add + 1
        elseif st.kind == 'del' then
          del = del + 1
        end
      end
    end
    if #f.hunks == 0 then
      if f.mode_change then
        table.insert(steps, { kind = 'mode', file = f, hunk = nil, text = 'mode change' })
      elseif f.binary == 'note' then
        table.insert(steps, { kind = 'note', file = f, hunk = nil, text = 'binary change — not walkable' })
      end
    end
    for _, h in ipairs(f.hunks) do
      if h.binary then
        table.insert(steps, { kind = 'bin', file = f, hunk = h, text = 'binary' })
      elseif granularity == 'line' and not f.is_new and not f.is_del then
        for _, ls in ipairs(h.steps) do
          table.insert(steps, {
            kind = ls.kind,
            file = f,
            hunk = h,
            old_ln = ls.old_ln,
            new_ln = ls.new_ln,
            rpos = ls.rpos,
            text = ls.text,
          })
        end
      else
        local first = h.steps[1]
        local ln = h.ol
        if first then
          ln = first.kind == 'del' and first.old_ln or first.new_ln
        end
        table.insert(steps, {
          kind = 'hunk',
          file = f,
          hunk = h,
          old_ln = ln,
          new_ln = ln,
          text = first and first.text or 'hunk',
        })
      end
    end
  end
  return steps, add, del
end

local function to_ab_header(line)
  if line:sub(1, 4) == '--- ' or line:sub(1, 4) == '+++ ' then
    local out = line:gsub('^([+-]+ )(%a)/', function(prefix, letter)
      local map = { a = 'a', b = 'b', c = 'a', i = 'a', w = 'b' }
      return prefix .. map[letter] .. '/'
    end)
    return out
  end
  return line
end

local function hunk_slice(f, h)
  if not h.slice then
    local lines = {}
    for _, ln in ipairs(f.hdr) do
      table.insert(lines, to_ab_header(ln))
    end
    vim.list_extend(lines, h.raw)
    h.slice = table.concat(lines, '\n') .. '\n'
  end
  return h.slice
end

local function write_file(path, text)
  if text == '' then
    vim.fn.writefile({}, path)
    return
  end
  vim.fn.writefile(vim.split(text, '\n', { plain = true }), path)
end

local function save_session()
  local s = session
  if not s then return end
  local meta = {
    kind = s.kind,
    root = s.root,
    args = s.args,
    granularity = s.granularity,
    ts = s.ts,
    idx = s.idx,
    total = #s.steps,
    patches = s.patch_files,
    snapshot = s.snapshot_files,
  }
  write_file(s.dir .. '/meta.json', vim.json.encode(meta))
end

local function cleanup_old()
  local dirs = vim.fn.glob(SESSION_ROOT .. '/*', false, true)
  for _, d in ipairs(dirs) do
    local ts = tonumber(d:match('(%d+)%-'))
    if ts and os.time() - ts > 86400 then
      vim.fn.delete(d, 'rf')
    end
  end
end

local function apply_file_args(p, reverse, check)
  local args = { 'apply' }
  if p.index then table.insert(args, '--index') end
  if check then table.insert(args, '--check') end
  if reverse then table.insert(args, '-R') end
  table.insert(args, p.file)
  return args
end

local function file_delta(s, name, upto)
  local limit = upto or s.idx
  local delta = 0
  for i = 1, limit do
    local st = s.steps[i]
    if st.file.name == name then
      if st.kind == 'hunk' then
        delta = delta + (st.hunk.ncnt - st.hunk.ocnt)
      elseif st.kind == 'add' then
        delta = delta + 1
      elseif st.kind == 'del' then
        delta = delta - 1
      end
    end
  end
  return delta
end

local function join_path(root, name)
  if root == '/' then return '/' .. name end
  return root .. '/' .. name
end

local function read_lines_raw(path)
  local res = vim.system({ 'cat', path }, { text = false }):wait()
  if res.code ~= 0 then return nil end
  local lines = vim.split(res.stdout, '\n', { plain = true })
  if #lines > 0 and lines[#lines] == '' then lines[#lines] = nil end
  return lines
end

local CTX = 1

local function line_slice(f, st, reverse)
  local lines = read_lines_raw(join_path(session.root, f.name))
  if not lines then return nil end
  local k = nil
  for i = 1, #session.steps do
    if session.steps[i] == st then
      k = i
      break
    end
  end
  if not k then return nil end
  local delta = file_delta(session, f.name, k - 1)
  local is_del = (st.kind == 'del') ~= reverse
  local p = st.old_ln + delta
  if is_del and not lines[p] then return nil end
  local above, below = {}, {}
  for i = math.max(p - CTX, 1), p - 1 do above[#above + 1] = lines[i] end
  if is_del then
    for i = p + 1, math.min(p + CTX, #lines) do below[#below + 1] = lines[i] end
  else
    for i = p, math.min(p + CTX - 1, #lines) do below[#below + 1] = lines[i] end
  end
  local kept = {}
  for _, l in ipairs(above) do kept[#kept + 1] = ' ' .. l end
  if is_del then
    kept[#kept + 1] = '-' .. lines[p]
  else
    kept[#kept + 1] = '+' .. st.text
  end
  for _, l in ipairs(below) do kept[#kept + 1] = ' ' .. l end
  local ocnt, ncnt
  if is_del then
    ocnt = #above + 1 + #below
    ncnt = #above + #below
  else
    ocnt = #above + #below
    ncnt = #above + 1 + #below
  end
  local ostart = p - #above
  local nstart = ostart
  if ocnt == 0 and #above == 0 then ostart = 0 end
  if ncnt == 0 and #above == 0 then nstart = 0 end
  local out = {}
  for _, l in ipairs(f.hdr) do out[#out + 1] = to_ab_header(l) end
  out[#out + 1] = string.format('@@ -%d,%d +%d,%d @@', ostart, ocnt, nstart, ncnt)
  for _, l in ipairs(kept) do out[#out + 1] = l end
  return table.concat(out, '\n') .. '\n'
end

local function apply_step(step, reverse)
  if step.kind == 'note' then return true end
  local args = { 'apply' }
  if step.file.patch.index then
    git(session.root, { 'update-index', '--refresh', '-q' })
    table.insert(args, '--index')
  end
  if reverse then table.insert(args, '-R') end
  table.insert(args, '-')
  local slice
  if step.kind == 'del' or step.kind == 'add' then
    if step._slice then
      slice = step._slice
    else
      slice = line_slice(step.file, step, reverse)
      if not slice then return false, 'line context mismatch — file edited externally?' end
      step._slice = slice
    end
  elseif step.hunk then
    slice = hunk_slice(step.file, step.hunk)
  else
    local lines = {}
    for _, ln in ipairs(step.file.hdr) do
      table.insert(lines, to_ab_header(ln))
    end
    slice = table.concat(lines, '\n') .. '\n'
  end
  local res = git(session.root, args, slice)
  if res.code ~= 0 then return false, trim(res.err) end
  return true
end

function M.capture(args_str, opts)
  opts = opts or {}
  if session then
    return { ok = false, err = 'a diff walk is already active — quit it (q) first' }
  end
  local root_res = vim.system({ 'git', 'rev-parse', '--show-toplevel' }, { text = true }):wait()
  if root_res.code ~= 0 then
    return { ok = false, err = 'not inside a git work tree' }
  end
  local root = trim(root_res.stdout)
  if root == '' then
    return { ok = false, err = 'not inside a git work tree' }
  end

  local args_list = split_args(args_str)
  local first = args_list[1]
  local has_cached = args_str:match('%-%-cached') ~= nil
  local kind
  if has_cached then
    kind = 'cached'
  elseif first and first:sub(1, 5) == 'stash' then
    kind = 'stash'
  elseif first and first:sub(1, 1) ~= '-' then
    local r = git(root, { 'rev-parse', '--verify', '--quiet', first .. '^{commit}' })
    if r.code == 0 then
      kind = 'rev'
    else
      kind = 'worktree'
    end
  else
    kind = 'worktree'
  end

  local dir = SESSION_ROOT .. '/' .. tostring(os.time()) .. '-' .. tostring(vim.fn.getpid())
  vim.fn.mkdir(dir, 'p')

  local s = {
    kind = kind,
    root = root,
    args = args_str,
    granularity = opts.lines and 'line' or 'hunk',
    ts = os.time(),
    dir = dir,
    idx = 0,
    patch_files = {},
    snapshot_files = {},
  }
  session = s

  local files = {}
  local steps = {}
  local add, del = 0, 0
  local patch_recs = {}

  local function append_patch(key, index_flag, pre, args)
    local text, err = capture_diff(root, pre, args)
    if err then
      session = nil
      vim.fn.delete(dir, 'rf')
      error('capture failed: ' .. err)
    end
    local pf = parse_patch(text, { key = key, index = index_flag })
    local ptext = patch_text(pf)
    s.patch_files[key] = dir .. '/' .. key .. '.patch'
    write_file(s.patch_files[key], ptext)
    local st, a, d = build_steps(pf, s.granularity)
    vim.list_extend(files, pf)
    vim.list_extend(steps, st)
    add = add + a
    del = del + d
    local rec = { key = key, index = index_flag, file = s.patch_files[key] }
    patch_recs[key] = rec
    return rec
  end

  local okc, cap_err = pcall(function()
    if kind == 'stash' then
      append_patch('snapshot_worktree', false, nil, {})
      append_patch('snapshot_cached', true, { '--cached' }, {})
      local res = git(root, vim.list_extend({ 'stash', 'apply' }, args_list))
      if res.code ~= 0 then
        for _, p in ipairs({ patch_recs.snapshot_worktree, patch_recs.snapshot_cached }) do
          git(root, apply_file_args(p, false, false))
        end
        error('stash apply failed: ' .. (trim(res.err) or '') .. ' — original state restored')
      end
      append_patch('stash', false, { 'stash', 'show', '-p' }, args_list)
    elseif kind == 'rev' then
      local rest = {}
      for i = 2, #args_list do rest[#rest + 1] = args_list[i] end
      append_patch('cached', true, { '--cached' }, args_list)
      append_patch('worktree', false, nil, rest)
    elseif kind == 'cached' then
      append_patch('cached', true, { '--cached' }, args_list)
    else
      append_patch('worktree', false, nil, args_list)
    end
  end)

  if not okc then
    session = nil
    vim.fn.delete(dir, 'rf')
    return { ok = false, err = cap_err and 'capture failed: ' .. cap_err or 'capture failed' }
  end

  if #steps == 0 then
    session = nil
    vim.fn.delete(dir, 'rf')
    return { ok = false, err = 'no changes', code = 'no_changes' }
  end

  if kind == 'stash' then
    s.patches = { patch_recs.stash }
    s.snapshot = { patch_recs.snapshot_worktree, patch_recs.snapshot_cached }
  elseif kind == 'rev' then
    s.patches = { patch_recs.worktree, patch_recs.cached }
  elseif kind == 'cached' then
    s.patches = { patch_recs.cached }
  else
    s.patches = { patch_recs.worktree }
  end

  s.files = files
  s.steps = steps
  s.add = add
  s.del = del
  local seen = {}
  for _, st in ipairs(steps) do seen[st.file.name] = true end
  s.fcount = 0
  for _ in pairs(seen) do s.fcount = s.fcount + 1 end
  save_session()
  return { ok = true }
end

function M.rewind()
  local s = session
  if not s then return { ok = false, err = 'no active walk' } end
  for _, p in ipairs(s.patches) do
    if p.index then
      git(s.root, { 'update-index', '--refresh', '-q' })
    end
    local res = git(s.root, apply_file_args(p, true, true))
    if res.code ~= 0 then
      return { ok = false, err = 'tree does not match the captured diff (was it edited in another process?) [' .. p.key .. ']: ' .. (res.err or '') }
    end
    res = git(s.root, apply_file_args(p, true, false))
    if res.code ~= 0 then
      return { ok = false, err = 'rewind failed: ' .. (res.err or '') }
    end
  end
  s.idx = 0
  save_session()
  return { ok = true }
end

function M.step(dir)
  local s = session
  if not s then return { ok = false, err = 'no active walk' } end
  local t = s.idx + dir
  if t < 0 or t > #s.steps then return { ok = false, err = 'boundary' } end
  local st = s.steps[dir > 0 and t or s.idx]
  local ok, err = apply_step(st, dir < 0)
  if not ok then
    local res = { ok = false, err = 'apply failed: ' .. (err or '') }
    if st.hunk and st.hunk.slice then res.slice = st.hunk.slice end
    return res
  end
  s.idx = t
  save_session()
  local cur = s.steps[s.idx]
  return {
    ok = true,
    dir = dir,
    step = cur,
    file = cur and cur.file.name or nil,
  }
end

local function trunc_txt(s, n)
  if #s > n then return s:sub(1, n - 1) .. '…' end
  return s
end

function M.preview()
  local s = session
  if not s then return nil end
  if s.idx >= #s.steps then return { done = true } end
  local st = s.steps[s.idx + 1]
  local delta = file_delta(s, st.file.name)
  local ln = 1
  if st.kind == 'del' then
    ln = st.old_ln + delta
  elseif st.kind == 'add' then
    ln = st.old_ln + delta - 1
  elseif st.kind == 'hunk' then
    local first = st.hunk.steps[1]
    if first and first.kind == 'del' then
      ln = first.old_ln + delta
    else
      ln = st.hunk.ol + (first and (first.new_ln - st.hunk.nl) or 0) - 1 + delta
    end
  end
  ln = math.max(ln, 1)
  return { file = st.file.name, ln = ln, step = st, absent = st.file.is_new or false }
end

function M.preview_text()
  local s = session
  if not s or s.idx >= #s.steps then return '' end
  local st = s.steps[s.idx + 1]
  if st.kind == 'bin' then return 'binary change' end
  if st.kind == 'mode' then return 'mode change' end
  if st.kind == 'note' then return 'binary change — not walkable' end
  if st.kind == 'del' then return 'delete ' .. trunc_txt(st.text, 40) end
  if st.kind == 'add' then return 'add ' .. trunc_txt(st.text, 40) end
  if st.file.is_new then return 'creates ' .. st.file.name end
  local del_txt, add_txt
  for _, p in ipairs(st.hunk.steps) do
    if p.kind == 'del' and not del_txt then del_txt = p.text end
    if p.kind == 'add' and not add_txt then add_txt = p.text end
  end
  if del_txt and add_txt then
    return 'replace ' .. trunc_txt(del_txt, 20) .. ' → ' .. trunc_txt(add_txt, 20)
  elseif del_txt then
    return 'delete ' .. trunc_txt(del_txt, 40)
  elseif add_txt then
    return 'add ' .. trunc_txt(add_txt, 40)
  end
  return 'hunk'
end

function M.restore()
  local s = session
  if not s then return { ok = false, err = 'no active walk' } end
  if s.kind == 'stash' then
    for i = s.idx, 1, -1 do
      local ok, err = apply_step(s.steps[i], true)
      if not ok then return { ok = false, err = 'restore failed: ' .. (err or '') } end
    end
    for _, p in ipairs(s.snapshot) do
      if vim.fn.getfsize(p.file) > 0 then
        local res = git(s.root, apply_file_args(p, false, false))
        if res.code ~= 0 then
          return { ok = false, err = 'restore failed: ' .. (res.err or '') }
        end
      end
    end
    s.idx = 0
  else
    for i = s.idx + 1, #s.steps do
      local ok, err = apply_step(s.steps[i], false)
      if not ok then return { ok = false, err = 'restore failed: ' .. (err or '') } end
    end
    s.idx = #s.steps
  end
  save_session()
  return { ok = true }
end

function M.close()
  if session then
    vim.fn.delete(session.dir, 'rf')
    session = nil
  end
end

function M.state()
  return session
end

local INDEX_KEYS = { cached = true, snapshot_cached = true }

function M.restore_from_disk()
  if session then return { ok = false, err = 'a diff walk is active' } end
  local dirs = vim.fn.glob(SESSION_ROOT .. '/*', false, true)
  table.sort(dirs, function(a, b) return a > b end)
  local dir = nil
  for _, d in ipairs(dirs) do
    if vim.fn.filereadable(d .. '/meta.json') == 1 then
      dir = d
      break
    end
  end
  if not dir then return { ok = false, err = 'no saved diff walk session found' } end

  local ok, meta = pcall(vim.json.decode, table.concat(vim.fn.readfile(dir .. '/meta.json'), '\n'))
  if not (ok and meta and meta.root and meta.patches) then
    return { ok = false, err = 'session meta unreadable: ' .. dir }
  end

  local s = {
    kind = meta.kind,
    root = meta.root,
    args = meta.args,
    granularity = meta.granularity or 'hunk',
    ts = meta.ts,
    dir = dir,
    idx = meta.idx or 0,
    patch_files = meta.patches,
    snapshot_files = meta.snapshot or {},
  }
  local files = {}
  local steps = {}
  local add, del = 0, 0
  local patch_recs = {}
  for key, path in pairs(meta.patches) do
    if vim.fn.filereadable(path) ~= 1 then
      path = dir .. '/' .. key .. '.patch'
    end
    if vim.fn.filereadable(path) ~= 1 then
      return { ok = false, err = 'session patch missing: ' .. path }
    end
    local text = table.concat(vim.fn.readfile(path), '\n')
    local pf = parse_patch(text, { key = key, index = INDEX_KEYS[key] or false })
    local st, a, d = build_steps(pf, s.granularity)
    vim.list_extend(files, pf)
    vim.list_extend(steps, st)
    add = add + a
    del = del + d
    patch_recs[key] = { key = key, index = INDEX_KEYS[key] or false, file = path }
  end
  if #steps == 0 then
    return { ok = false, err = 'session has no steps: ' .. dir }
  end
  s.files = files
  s.steps = steps
  s.add = add
  s.del = del
  local seen = {}
  for _, st in ipairs(steps) do seen[st.file.name] = true end
  s.fcount = 0
  for _ in pairs(seen) do s.fcount = s.fcount + 1 end
  if meta.kind == 'stash' then
    s.patches = { patch_recs.stash }
    s.snapshot = { patch_recs.snapshot_worktree, patch_recs.snapshot_cached }
  elseif meta.kind == 'rev' then
    s.patches = { patch_recs.worktree, patch_recs.cached }
  elseif meta.kind == 'cached' then
    s.patches = { patch_recs.cached }
  else
    s.patches = { patch_recs.worktree }
  end
  session = s
  local res = M.restore()
  if not res.ok then
    session = nil
    return { ok = false, err = res.err }
  end
  local names = {}
  for _, st in ipairs(steps) do names[st.file.name] = true end
  local out_names = {}
  for n in pairs(names) do out_names[#out_names + 1] = n end
  vim.fn.delete(dir, 'rf')
  session = nil
  return { ok = true, root = meta.root, files = out_names, dir = dir }
end

cleanup_old()

return M
