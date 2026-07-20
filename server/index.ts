import * as net from 'net'
import { spawn, execSync, spawnSync } from 'child_process'
import * as path from 'path'
interface Message {
  type: string
  content?: string
  repoPath?: string
  mode?: string
}

interface ReadyMessage {
  ready: true
  port: number
}

console.log("hello world")

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

const repoPath = process.cwd()
let buildTaskId: string | null = null
let buildWorktreePath: string | null = null
let buildBranch: string | null = null
let isBuilding = false
let chatSessionID: string | null = null
let defaultBranch: string | null = null

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

let chmodNeedsRestore = false

function chmodRepo(cwd: string, readonly: boolean): void {
  const mode = readonly ? 'a-w' : 'u+w'
  execSync(
    `find ${cwd} -path '${cwd}/.git' -prune -o -type f -exec chmod ${mode} {} +`,
    { stdio: 'pipe' }
  )
  chmodNeedsRestore = readonly
}

function cleanupPerms(): void {
  if (chmodNeedsRestore) {
    spawnSync('find', [repoPath, '-path', `${repoPath}/.git`, '-prune', '-o', '-type', 'f', '-exec', 'chmod', 'u+w', '{}', '+'])
    chmodNeedsRestore = false
  }
}

process.on('exit', cleanupPerms)
process.on('SIGINT', () => { cleanupPerms(); process.exit(2) })
process.on('SIGTERM', () => { cleanupPerms(); process.exit(15) })
process.on('uncaughtException', () => { cleanupPerms(); process.exit(1) })

function sendMessage(socket: net.Socket, msg: Message): void {
  socket.write(JSON.stringify(msg) + '\n')
}

function generateTaskId(): string {
  return Date.now().toString(36) + Math.random().toString(36).slice(2, 6)
}

function handleBuild(socket: net.Socket, content: string, buildRepoPath?: string): void {
  const cwd = buildRepoPath || repoPath
  if (isBuilding) {
    sendMessage(socket, { type: 'error', content: 'Build already in progress' })
    return
  }

  isBuilding = true
  const id = generateTaskId()
  buildTaskId = id
  buildBranch = `agent/contuts-${id}`
  buildWorktreePath = path.join(path.dirname(cwd), `contuts-wt-${id}`)
  sendMessage(socket, { type: 'mode_change', mode: 'build' })

  const baseBranch = detectDefaultBranch(cwd)

  try {
    execSync('git rev-parse HEAD', { cwd, stdio: 'pipe' })
  } catch {
    sendMessage(socket, { type: 'build_status', content: 'No commits yet, creating initial commit...' })
    execSync('git commit --allow-empty -m "contuts: root"', { cwd, stdio: 'pipe' })
  }

  sendMessage(socket, { type: 'build_status', content: `Creating worktree at ${buildWorktreePath}...` })

  try {
    execSync(`git worktree add -b ${buildBranch} ${buildWorktreePath} HEAD`, { cwd: cwd, stdio: 'pipe' })
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e)
    sendMessage(socket, { type: 'error', content: `Worktree creation failed: ${msg}` })
    sendMessage(socket, { type: 'mode_change', mode: 'plan' })
    isBuilding = false
    return
  }

  sendMessage(socket, { type: 'build_status', content: `Branch: ${buildBranch}` })
  sendMessage(socket, { type: 'build_status', content: 'Running opencode...' })

  const buildPrompt = `[SYSTEM: BUILD MODE] You are in build mode. You have full write permissions in the worktree.\n\n${content}`
  const buildArgs = ['run', '--format', 'json', '--auto']
  if (chatSessionID) {
    buildArgs.push('--session', chatSessionID)
  }
  buildArgs.push(buildPrompt)

  const proc = spawn('opencode', buildArgs, {
    cwd: buildWorktreePath,
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

  proc.stdout.on('data', (chunk: Buffer) => {
    const output = chunk.toString()
    for (const line of output.split('\n').filter(l => l.trim())) {
      try {
        const event = JSON.parse(line)
        if (event.type === 'text' && event.part?.text) {
          sendMessage(socket, { type: 'build_status', content: event.part.text })
        }
        if (event.type === 'tool_use' && event.part?.tool) {
          const tool = event.part
          const title = tool.title ? ` ${tool.title}` : ''
          const status = tool.state?.status === 'completed' ? '✓' : '⋯'
          sendMessage(socket, { type: 'build_status', content: `  ${status} [${tool.tool}]${title}` })
        }
      } catch {
        // skip non-JSON lines
      }
    }
  })

  proc.stderr.on('data', (chunk: Buffer) => {
    stderrBuf += chunk.toString()
  })

  proc.on('close', () => {
    clearTimeout(timer)
    if (stderrBuf.trim()) {
      sendMessage(socket, { type: 'build_status', content: `stderr: ${stderrBuf.trim()}` })
    }
    sendMessage(socket, { type: 'build_status', content: 'Committing changes...' })
    try {
      execSync('git add -A', { cwd: buildWorktreePath!, stdio: 'pipe' })
      execSync('git commit -m "contuts: build task"', { cwd: buildWorktreePath!, stdio: 'pipe' })
      sendMessage(socket, { type: 'build_status', content: 'Changes committed.' })
    } catch {
      sendMessage(socket, { type: 'build_status', content: 'Nothing to commit (no changes made).' })
    }
    collectBuildResult(socket, cwd, baseBranch)
  })

  proc.on('error', (err) => {
    clearTimeout(timer)
    sendMessage(socket, { type: 'error', content: `opencode failed: ${err.message}` })
    sendMessage(socket, { type: 'mode_change', mode: 'plan' })
    isBuilding = false
  })
}

function collectBuildResult(socket: net.Socket, cwd?: string, baseBranch?: string): void {
  const repo = cwd || repoPath
  const base = baseBranch || detectDefaultBranch(repo)
  if (!buildBranch || !buildTaskId) {
    sendMessage(socket, { type: 'error', content: 'No build to collect results from' })
    isBuilding = false
    return
  }

  try {
    const branch = buildBranch

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

function handleMerge(socket: net.Socket): void {
  if (!buildBranch || !buildWorktreePath) {
    sendMessage(socket, { type: 'error', content: 'No build to merge' })
    return
  }

  try {
    const branch = buildBranch
    const wtPath = buildWorktreePath

    execSync(`git merge --squash ${branch}`, { cwd: repoPath, stdio: 'pipe' })
    execSync(`git commit -m "contuts: merge ${branch}"`, { cwd: repoPath, stdio: 'pipe' })

    // Clean up
    execSync(`git worktree remove ${wtPath}`, { cwd: repoPath, stdio: 'pipe' })
    const base = detectDefaultBranch(repoPath)
    execSync(`git branch -D ${branch}`, { cwd: repoPath, stdio: 'pipe' })

    sendMessage(socket, { type: 'build_status', content: `Merged ${branch} into ${base}` })

    buildBranch = null
    buildWorktreePath = null
    buildTaskId = null
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e)
    sendMessage(socket, { type: 'error', content: `Merge failed: ${msg}` })
  }
}

function handleDiscard(socket: net.Socket): void {
  if (!buildBranch || !buildWorktreePath) {
    sendMessage(socket, { type: 'error', content: 'No build to discard' })
    return
  }

  try {
    const branch = buildBranch
    const wtPath = buildWorktreePath

    execSync(`git worktree remove ${wtPath}`, { cwd: repoPath, stdio: 'pipe' })
    execSync(`git branch -D ${branch}`, { cwd: repoPath, stdio: 'pipe' })

    sendMessage(socket, { type: 'build_status', content: `Discarded ${branch} and cleaned up worktree` })

    buildBranch = null
    buildWorktreePath = null
    buildTaskId = null
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e)
    sendMessage(socket, { type: 'error', content: `Discard failed: ${msg}` })
  }
}

function handlePrompt(socket: net.Socket, content: string): void {
  const cwd = repoPath
  chmodRepo(cwd, true)

  const prompt = `[SYSTEM: PLAN MODE] You are in plan mode. You may read files for context, but you MUST NOT create, edit, or delete any files. Only discuss and analyze.\n\n${content}`

  const proc = spawn('opencode', ['run', '--format', 'json', prompt], {
    cwd,
    env: { ...process.env },
    stdio: ['ignore', 'pipe', 'pipe'],
  })

  let responseText = ''

  proc.stdout.on('data', (chunk: Buffer) => {
    const output = chunk.toString()
    for (const line of output.split('\n').filter(l => l.trim())) {
      try {
        const event = JSON.parse(line)
        if (event.sessionID && !chatSessionID) {
          chatSessionID = event.sessionID
        }
        if (event.type === 'text' && event.part?.text) {
          responseText += event.part.text
        }
      } catch {
        // skip
      }
    }
  })

  proc.on('close', () => {
    chmodRepo(cwd, false)
    sendMessage(socket, { type: 'response', content: responseText })
  })

  proc.on('error', () => {
    chmodRepo(cwd, false)
    sendMessage(socket, { type: 'error', content: 'Failed to run opencode' })
  })
}

function handleMessage(socket: net.Socket, msg: Message): void {
  switch (msg.type) {
    case 'prompt':
      handlePrompt(socket, msg.content ?? '')
      break
    case 'build':
      handleBuild(socket, msg.content ?? '', msg.repoPath)
      break
    case 'build_merge':
      handleMerge(socket)
      break
    case 'build_discard':
      handleDiscard(socket)
      break
    case 'shutdown':
      socket.end()
      break
    default:
      sendMessage(socket, { type: 'error', content: `Unknown type: ${msg.type}` })
  }
}

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
