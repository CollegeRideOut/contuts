import * as net from 'net'
import { spawn, execSync, spawnSync } from 'child_process'
import * as path from 'path'

interface Message {
  type: string
  content?: string
  repoPath?: string
  mode?: string
  diff?: string
  diffStat?: string
  files?: string[]
  proposalId?: string
}

interface ReadyMessage {
  ready: true
  port: number
}

interface BuildResult {
  type: 'build_result'
  taskId: string
  branch: string
  baseBranch: string
  files: string[]
  insertions: number
  deletions: number
  log: string
  diffStat: string
}
console.log("test numero 4 of contuts")
console.log("klk test numero 5 of contuts")

const repoPath = process.cwd()
let worktreePath: string | null = null
let worktreeBranch: string | null = null
let worktreeBaseRef: string | null = null
let isBuilding = false
let chatSessionID: string | null = null
let buildTaskId: string | null = null
let defaultBranch: string | null = null
let pendingProposal: { stashed: boolean } | null = null

function detectDefaultBranch(cwd: string): string {
  if (defaultBranch) return defaultBranch
  try {
    defaultBranch = execSync(
      `git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || git rev-parse --abbrev-ref HEAD`,
      { cwd, encoding: 'utf-8' }
    ).trim().replace('refs/remotes/origin/', '')
  } catch {
    defaultBranch = 'main'
  }
  return defaultBranch
}

function ensureWorktree(cwd: string): void {
  if (worktreePath) return
  const id = Date.now().toString(36) + Math.random().toString(36).slice(2, 6)
  worktreeBranch = `agent/contuts-${id}`
  worktreePath = path.join(path.dirname(cwd), `contuts-${id}`)

  try {
    execSync('git rev-parse HEAD', { cwd, stdio: 'pipe' })
  } catch {
    execSync('git commit --allow-empty -m "contuts: root"', { cwd, stdio: 'pipe' })
  }

  worktreeBaseRef = execSync('git rev-parse HEAD', { cwd, encoding: 'utf-8' }).trim()
  execSync(`git worktree add -b ${worktreeBranch} ${worktreePath} HEAD`, { cwd, stdio: 'pipe' })
}

function cleanupWorktree(): void {
  if (!worktreePath || !worktreeBranch) return
  try {
    execSync(`git worktree remove ${worktreePath}`, { cwd: repoPath, stdio: 'pipe' })
  } catch { }
  try {
    execSync(`git branch -D ${worktreeBranch}`, { cwd: repoPath, stdio: 'pipe' })
  } catch { }
  worktreePath = null
  worktreeBranch = null
}

function chmodRepo(cwd: string, readonly: boolean): void {
  const mode = readonly ? 'a-w' : 'u+w'
  execSync(
    `find ${cwd} -path '${cwd}/.git' -prune -o -type f -exec chmod ${mode} {} +`,
    { stdio: 'pipe' }
  )
}

function sendMessage(socket: net.Socket, msg: Message): void {
  socket.write(JSON.stringify(msg) + '\n')
}

function generateTaskId(): string {
  return Date.now().toString(36) + Math.random().toString(36).slice(2, 6)
}

function collectBuildResult(socket: net.Socket, cwd?: string): void {
  const repo = cwd || repoPath
  const base = worktreeBaseRef || detectDefaultBranch(repo)
  if (!worktreeBranch || !buildTaskId) {
    sendMessage(socket, { type: 'error', content: 'No build to collect results from' })
    isBuilding = false
    return
  }

  try {
    const branch = worktreeBranch

    const diffStat = execSync(`git diff ${base}...${branch} --stat`, { cwd: repo, encoding: 'utf-8' }).trim()
    const numstat = execSync(`git diff ${base}...${branch} --numstat`, { cwd: repo, encoding: 'utf-8' }).trim()
    const log = execSync(`git log ${base}..${branch} --oneline`, { cwd: repo, encoding: 'utf-8' }).trim()

    const files: string[] = []
    let insertions = 0
    let deletions = 0

    for (const line of numstat.split('\n')) {
      if (!line.trim()) continue
      const parts = line.split('\t')
      if (parts.length === 3) {
        insertions += parseInt(parts[0]) || 0
        deletions += parseInt(parts[1]) || 0
        files.push(parts[2])
      }
    }

    const result: BuildResult = {
      type: 'build_result',
      taskId: buildTaskId,
      branch,
      baseBranch: base,
      files,
      insertions,
      deletions,
      log,
      diffStat,
    }

    sendMessage(socket, result)
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e)
    sendMessage(socket, { type: 'error', content: `Failed to collect results: ${msg}` })
  }

  sendMessage(socket, { type: 'mode_change', mode: 'plan' })
  isBuilding = false
}

function handlePrompt(socket: net.Socket, content: string): void {
  const cwd = repoPath
  ensureWorktree(cwd)
  sendMessage(socket, { type: 'build_status', content: `Branch: ${worktreeBranch}` })

  execSync('git checkout -f HEAD', { cwd: worktreePath!, stdio: 'pipe' })
  chmodRepo(worktreePath!, true)

  const evidenceInstruction = `
[SYSTEM: EVIDENCE] At the end of your response, if you reference specific code locations, include an <evidence> tag with a JSON array of claims. Each claim must have: file (relative path), line (1-based number), claim (short phrase), detail (full explanation sentence), severity (one of: error, warning, info). Example: <evidence>[{"file":"src/main.ts","line":42,"claim":"Unhandled promise rejection","detail":"The async function lacks a .catch() handler.","severity":"error"}]</evidence> If you don't reference any code, output <evidence></evidence>.`

  const prompt = `[SYSTEM: PLAN MODE] You are in plan mode. You may read files for context, but you MUST NOT create, edit, or delete any files. Only discuss and analyze.\n\n${content}${evidenceInstruction}`

  const proc = spawn('opencode', ['run', '--format', 'json', prompt], {
    cwd: worktreePath!,
    env: { ...process.env },
    stdio: ['ignore', 'pipe', 'pipe'],
  })

  let responseText = ''
  let stdoutBuf = ''

  const heartbeat = setInterval(() => {
    sendMessage(socket, { type: 'build_status', content: '  ● working...' })
  }, 5000)

  proc.stdout.on('data', (chunk: Buffer) => {
    stdoutBuf += chunk.toString()
    const lines = stdoutBuf.split('\n')
    stdoutBuf = lines.pop() ?? ''
    for (const line of lines) {
      const trimmed = line.trim()
      if (!trimmed) continue
      try {
        const event = JSON.parse(trimmed)
        if (event.sessionID && !chatSessionID) {
          chatSessionID = event.sessionID
        }
        if (event.type === 'text' && event.part?.text) {
          responseText += event.part.text
        }
      } catch { }
    }
  })

  proc.on('close', () => {
    clearInterval(heartbeat)
    chmodRepo(worktreePath!, false)

    const evidenceMatch = responseText.match(/<evidence>([\s\S]*?)<\/evidence>/)
    if (evidenceMatch) {
      try {
        const items = JSON.parse(evidenceMatch[1].trim())
        if (Array.isArray(items) && items.length > 0) {
          sendMessage(socket, { type: 'evidence', items })
        }
      } catch { }
      responseText = responseText.replace(/<evidence>[\s\S]*?<\/evidence>/, '').trim()
    }

    sendMessage(socket, { type: 'response', content: responseText })
  })

  proc.on('error', () => {
    clearInterval(heartbeat)
    chmodRepo(worktreePath!, false)
    sendMessage(socket, { type: 'error', content: 'Failed to run opencode' })
  })
}

function handleBuild(socket: net.Socket, content: string, buildRepoPath?: string): void {
  const cwd = buildRepoPath || repoPath
  if (isBuilding) {
    sendMessage(socket, { type: 'error', content: 'Build already in progress' })
    return
  }

  isBuilding = true
  buildTaskId = generateTaskId()
  ensureWorktree(cwd)

  sendMessage(socket, { type: 'mode_change', mode: 'build' })
  sendMessage(socket, { type: 'build_status', content: `Branch: ${worktreeBranch}` })
  sendMessage(socket, { type: 'build_status', content: 'Running opencode...' })

  chmodRepo(worktreePath!, false)

  const buildPrompt = `[SYSTEM: BUILD MODE] You are in build mode. You have full write permissions in the worktree.\n\n${content}`
  const buildArgs = ['run', '--format', 'json', '--auto']
  if (chatSessionID) {
    buildArgs.push('--session', chatSessionID)
  }
  buildArgs.push(buildPrompt)

  const proc = spawn('opencode', buildArgs, {
    cwd: worktreePath!,
    env: { ...process.env },
    stdio: ['ignore', 'pipe', 'pipe'],
  })

  const STALE_TIMEOUT = 5 * 60 * 1000
  const timer = setTimeout(() => {
    proc.kill('SIGTERM')
    sendMessage(socket, { type: 'error', content: 'Build timed out after 5 minutes' })
    sendMessage(socket, { type: 'mode_change', mode: 'plan' })
    isBuilding = false
  }, STALE_TIMEOUT)

  let stderrBuf = ''
  let stdoutBuf = ''
  let lastActivity = Date.now()

  const heartbeat = setInterval(() => {
    if (Date.now() - lastActivity > 4000) {
      sendMessage(socket, { type: 'build_status', content: '  ● working...' })
    }
  }, 5000)

  proc.stdout.on('data', (chunk: Buffer) => {
    lastActivity = Date.now()
    stdoutBuf += chunk.toString()
    const lines = stdoutBuf.split('\n')
    stdoutBuf = lines.pop() ?? ''
    for (const line of lines) {
      const trimmed = line.trim()
      if (!trimmed) continue
      try {
        const event = JSON.parse(trimmed)
        if (event.type === 'text' && event.part?.text) {
          sendMessage(socket, { type: 'build_status', content: event.part.text })
        }
        if (event.type === 'tool_use' && event.part?.tool) {
          const tool = event.part
          const title = tool.title ? ` ${tool.title}` : ''
          const status = tool.state?.status === 'completed' ? '✓' : '⋯'
          sendMessage(socket, { type: 'build_status', content: `  ${status} [${tool.tool}]${title}` })
        }
      } catch { }
    }
  })

  proc.stderr.on('data', (chunk: Buffer) => {
    stderrBuf += chunk.toString()
  })

  proc.on('close', () => {
    clearTimeout(timer)
    clearInterval(heartbeat)
    if (stderrBuf.trim()) {
      sendMessage(socket, { type: 'build_status', content: `stderr: ${stderrBuf.trim()}` })
    }
    sendMessage(socket, { type: 'build_status', content: 'Committing changes...' })
    try {
      execSync('git add -A', { cwd: worktreePath!, stdio: 'pipe' })
      execSync('git commit -m "contuts: build task"', { cwd: worktreePath!, stdio: 'pipe' })
      sendMessage(socket, { type: 'build_status', content: 'Changes committed.' })
    } catch {
      sendMessage(socket, { type: 'build_status', content: 'Nothing to commit (no changes made).' })
    }
    collectBuildResult(socket, cwd)
  })

  proc.on('error', (err) => {
    clearTimeout(timer)
    clearInterval(heartbeat)
    sendMessage(socket, { type: 'error', content: `opencode failed: ${err.message}` })
    sendMessage(socket, { type: 'mode_change', mode: 'plan' })
    isBuilding = false
  })
}

function handleMerge(socket: net.Socket): void {
  if (!worktreeBranch || !worktreePath) {
    sendMessage(socket, { type: 'error', content: 'No build to merge' })
    return
  }

  try {
    const branch = worktreeBranch

    let stashed = false
    try {
      execSync('git stash', { cwd: repoPath, stdio: 'pipe' })
      stashed = true
    } catch { }

    try {
      execSync(`git merge --squash ${branch}`, { cwd: repoPath, stdio: 'pipe' })
      execSync(`git commit -m "contuts: merge ${branch}"`, { cwd: repoPath, stdio: 'pipe' })
    } finally {
      if (stashed) {
        execSync('git stash pop', { cwd: repoPath, stdio: 'pipe' })
      }
    }

    cleanupWorktree()
    const base = detectDefaultBranch(repoPath)
    sendMessage(socket, { type: 'build_status', content: `Merged ${branch} into ${base}` })
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e)
    sendMessage(socket, { type: 'error', content: `Merge failed: ${msg}` })
  }
}

function handleDiscard(socket: net.Socket): void {
  if (!worktreeBranch || !worktreePath) {
    sendMessage(socket, { type: 'error', content: 'No build to discard' })
    return
  }

  try {
    const branch = worktreeBranch
    sendMessage(socket, { type: 'build_status', content: `Discarded ${branch} and cleaned up worktree` })
    cleanupWorktree()
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e)
    sendMessage(socket, { type: 'error', content: `Discard failed: ${msg}` })
  }
}

function handlePlanBuild(socket: net.Socket, content: string): void {
  const cwd = repoPath
  if (isBuilding || pendingProposal) {
    sendMessage(socket, { type: 'error', content: 'A build or proposal is already in progress' })
    return
  }

  ensureWorktree(cwd)
  sendMessage(socket, { type: 'build_status', content: `Branch: ${worktreeBranch}` })
  chmodRepo(worktreePath!, false)

  let stashed = false
  try {
    execSync('git stash push -m "contuts: pre-proposal"', { cwd: worktreePath!, stdio: 'pipe' })
    stashed = true
  } catch { }

  const buildPrompt = `[SYSTEM: BUILD MODE] You have full write permissions in the worktree. Make the following targeted change. Do NOT write any commentary — just implement the change and stop.\n\n${content}`
  const buildArgs = ['run', '--format', 'json', '--auto']
  if (chatSessionID) buildArgs.push('--session', chatSessionID)
  buildArgs.push(buildPrompt)

  const proc = spawn('opencode', buildArgs, {
    cwd: worktreePath!,
    env: { ...process.env },
    stdio: ['ignore', 'pipe', 'pipe'],
  })

  const STALE_TIMEOUT = 3 * 60 * 1000
  const timer = setTimeout(() => {
    proc.kill('SIGTERM')
    if (stashed) {
      try { execSync('git stash pop', { cwd: worktreePath!, stdio: 'pipe' }) } catch { }
    }
    pendingProposal = null
    sendMessage(socket, { type: 'error', content: 'Plan build timed out after 3 minutes' })
  }, STALE_TIMEOUT)

  let stderrBuf = ''
  let stdoutBuf = ''
  let errored = false

  proc.stdout.on('data', (chunk: Buffer) => {
    stdoutBuf += chunk.toString()
    const lines = stdoutBuf.split('\n')
    stdoutBuf = lines.pop() ?? ''
    for (const line of lines) {
      const trimmed = line.trim()
      if (!trimmed) continue
      try {
        const event = JSON.parse(trimmed)
        if (event.type === 'text' && event.part?.text) {
          sendMessage(socket, { type: 'build_status', content: event.part.text })
        }
      } catch { }
    }
  })

  proc.stderr.on('data', (chunk: Buffer) => {
    stderrBuf += chunk.toString()
  })

  proc.on('close', () => {
    clearTimeout(timer)
    if (errored) return
    if (stderrBuf.trim()) {
      sendMessage(socket, { type: 'build_status', content: `stderr: ${stderrBuf.trim()}` })
    }

    try {
      const diffOutput = execSync('git diff HEAD', { cwd: worktreePath!, encoding: 'utf-8' }).trim()
      if (!diffOutput) {
        if (stashed) {
          try { execSync('git stash pop', { cwd: worktreePath!, stdio: 'pipe' }); stashed = false } catch { }
        }
        pendingProposal = null
        sendMessage(socket, { type: 'plan_proposal', diff: '', files: [] })
        return
      }

      const diffStat = execSync('git diff HEAD --stat', { cwd: worktreePath!, encoding: 'utf-8' }).trim()
      const numstat = execSync('git diff HEAD --numstat', { cwd: worktreePath!, encoding: 'utf-8' }).trim()
      const files: string[] = []
      for (const line of numstat.split('\n')) {
        if (!line.trim()) continue
        const parts = line.split('\t')
        if (parts.length === 3) files.push(parts[2])
      }

      pendingProposal = { stashed }
      sendMessage(socket, {
        type: 'plan_proposal',
        diff: diffOutput,
        diffStat,
        files,
      })
    } catch (e: unknown) {
      if (stashed) {
        try { execSync('git stash pop', { cwd: worktreePath!, stdio: 'pipe' }); stashed = false } catch { }
      }
      pendingProposal = null
      const msg = e instanceof Error ? e.message : String(e)
      sendMessage(socket, { type: 'error', content: `Proposal failed: ${msg}` })
    }
  })

  proc.on('error', (err) => {
    clearTimeout(timer)
    errored = true
    if (stashed) {
      try { execSync('git stash pop', { cwd: worktreePath!, stdio: 'pipe' }) } catch { }
    }
    pendingProposal = null
    sendMessage(socket, { type: 'error', content: `opencode failed: ${err.message}` })
  })
}

function handlePlanAccept(socket: net.Socket): void {
  if (!pendingProposal) {
    sendMessage(socket, { type: 'error', content: 'No pending proposal to accept' })
    return
  }

  try {
    const stashed = pendingProposal.stashed
    execSync('git add -A', { cwd: worktreePath!, stdio: 'pipe' })
    execSync('git commit -m "contuts: plan proposal"', { cwd: worktreePath!, stdio: 'pipe' })
    if (stashed) {
      try { execSync('git stash pop', { cwd: worktreePath!, stdio: 'pipe' }) } catch { }
    }
    pendingProposal = null
    sendMessage(socket, { type: 'plan_accepted' })
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e)
    sendMessage(socket, { type: 'error', content: `Accept failed: ${msg}` })
  }
}

function handlePlanReject(socket: net.Socket): void {
  if (!pendingProposal) {
    sendMessage(socket, { type: 'error', content: 'No pending proposal to reject' })
    return
  }

  try {
    const stashed = pendingProposal.stashed
    execSync('git checkout HEAD -- .', { cwd: worktreePath!, stdio: 'pipe' })
    try { execSync('git clean -fd', { cwd: worktreePath!, stdio: 'pipe' }) } catch { }
    if (stashed) {
      try { execSync('git stash pop', { cwd: worktreePath!, stdio: 'pipe' }) } catch { }
    }
    pendingProposal = null
    sendMessage(socket, { type: 'plan_rejected' })
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e)
    sendMessage(socket, { type: 'error', content: `Reject failed: ${msg}` })
  }
}

function handleMessage(socket: net.Socket, msg: Message): void {
  switch (msg.type) {
    case 'prompt':
      handlePrompt(socket, msg.content ?? '')
      break
    case 'build':
      handleBuild(socket, msg.content ?? '', msg.repoPath)
      break
    case 'plan_build':
      handlePlanBuild(socket, msg.content ?? '')
      break
    case 'plan_accept':
      handlePlanAccept(socket)
      break
    case 'plan_reject':
      handlePlanReject(socket)
      break
    case 'build_merge':
      handleMerge(socket)
      break
    case 'build_discard':
      handleDiscard(socket)
      break
    case 'shutdown':
      cleanupWorktree()
      socket.end()
      break
    default:
      sendMessage(socket, { type: 'error', content: `Unknown type: ${msg.type}` })
  }
}

process.on('exit', () => {
  cleanupWorktree()
})
process.on('SIGINT', () => { cleanupWorktree(); process.exit(2) })
process.on('SIGTERM', () => { cleanupWorktree(); process.exit(15) })
process.on('uncaughtException', () => { cleanupWorktree(); process.exit(1) })

const server = net.createServer((socket: net.Socket) => {
  let buffer = ''

  socket.on('data', (chunk: Buffer) => {
    buffer += chunk.toString()
    const lines = buffer.split('\n')
    buffer = lines.pop() ?? ''

    for (const line of lines) {
      const trimmed = line.trim()
      if (!trimmed) continue
      try {
        handleMessage(socket, JSON.parse(trimmed) as Message)
      } catch {
        sendMessage(socket, { type: 'error', content: 'Invalid JSON' })
      }
    }
  })

  socket.on('close', () => { })
  socket.on('error', () => { })
})

server.listen(0, '127.0.0.1', () => {
  const addr = server.address()
  if (addr && typeof addr === 'object') {
    const msg: ReadyMessage = { ready: true, port: addr.port }
    process.stdout.write(JSON.stringify(msg) + '\n')
  }
})
