import * as net from 'net'
import { spawn, execSync } from 'child_process'
import * as path from 'path'
interface Message {
  type: string
  content?: string
  repoPath?: string
}

interface ReadyMessage {
  ready: true
  port: number
}

interface BuildResult {
  type: 'build_result'
  taskId: string
  branch: string
  files: string[]
  insertions: number
  deletions: number
  log: string
  diffStat: string
}

console.log("hello world testing contuts chat")

const repoPath = process.cwd()
let buildTaskId: string | null = null
let buildWorktreePath: string | null = null
let buildBranch: string | null = null
let isBuilding = false
let chatSessionID: string | null = null

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

  sendMessage(socket, { type: 'build_status', content: `Creating worktree at ${buildWorktreePath}...` })

  try {
    execSync(`git worktree add -b ${buildBranch} ${buildWorktreePath} HEAD`, { cwd: cwd, stdio: 'pipe' })
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e)
    sendMessage(socket, { type: 'error', content: `Worktree creation failed: ${msg}` })
    isBuilding = false
    return
  }

  sendMessage(socket, { type: 'build_status', content: `Branch: ${buildBranch}` })
  sendMessage(socket, { type: 'build_status', content: 'Running opencode...' })

  const buildArgs = ['run', '--format', 'json', '--auto']
  if (chatSessionID) {
    buildArgs.push('--session', chatSessionID)
  }
  buildArgs.push(content)

  const proc = spawn('opencode', buildArgs, {
    cwd: buildWorktreePath,
    env: { ...process.env },
    stdio: ['ignore', 'pipe', 'pipe'],
  })

  const STALE_TIMEOUT = 5 * 60 * 1000
  const timer = setTimeout(() => {
    proc.kill('SIGTERM')
    sendMessage(socket, { type: 'error', content: 'Build timed out after 5 minutes' })
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
    collectBuildResult(socket, cwd)
  })

  proc.on('error', (err) => {
    clearTimeout(timer)
    sendMessage(socket, { type: 'error', content: `opencode failed: ${err.message}` })
    isBuilding = false
  })
}

function collectBuildResult(socket: net.Socket, cwd?: string): void {
  const repo = cwd || repoPath
  if (!buildBranch || !buildTaskId) {
    sendMessage(socket, { type: 'error', content: 'No build to collect results from' })
    isBuilding = false
    return
  }

  try {
    const branch = buildBranch

    const diffStat = execSync(`git diff main...${branch} --stat`, { cwd: repo, encoding: 'utf-8' }).trim()
    const numstat = execSync(`git diff main...${branch} --numstat`, { cwd: repo, encoding: 'utf-8' }).trim()
    const log = execSync(`git log main..${branch} --oneline`, { cwd: repo, encoding: 'utf-8' }).trim()

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
    execSync(`git branch -D ${branch}`, { cwd: repoPath, stdio: 'pipe' })

    sendMessage(socket, { type: 'build_status', content: `Merged ${branch} into main` })

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
  const proc = spawn('opencode', ['run', '--format', 'json', content], {
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
    sendMessage(socket, { type: 'response', content: responseText })
  })

  proc.on('error', () => {
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

  socket.on('close', () => {})
  socket.on('error', () => {})
})

server.listen(0, '127.0.0.1', () => {
  const addr = server.address()
  if (addr && typeof addr === 'object') {
    const msg: ReadyMessage = { ready: true, port: addr.port }
    process.stdout.write(JSON.stringify(msg) + '\n')
  }
})
