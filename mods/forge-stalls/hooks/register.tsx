import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Alert } from '../types'
import { isForgeSession, step } from './stalls'
import type { Session } from './stalls'

const POLL_MS = 30_000
const alerts = atom({ plugin: 'forge-stalls', key: 'alerts' } as const, [])

type Agent = { id?: string; sessionId?: string; name?: string; cwd: string; state: string }

async function lastWrite($: EngineInterface, home: string, agent: Agent): Promise<number | undefined> {
  const dir = `${home}/.claude/projects/${agent.cwd.replace(/[^a-zA-Z0-9]/g, '-')}`
  const main = `${dir}/${agent.sessionId}.jsonl`
  if (!(await $.fs.exists(main))) return undefined
  let last = (await $.fs.stat(main)).mtimeMs
  const subagents = `${dir}/${agent.sessionId}/subagents`
  if (await $.fs.exists(subagents)) {
    for (const entry of await $.fs.list(subagents)) last = Math.max(last, entry.mtimeMs)
  }
  return last
}

async function sessions($: EngineInterface): Promise<Session[]> {
  const listed = await $.process.run(['claude', 'agents', '--json'], { timeoutMs: 20_000 })
  if (listed.exitCode !== 0) throw new Error(`claude agents exited ${listed.exitCode}: ${listed.stderr.trim()}`)
  const home = await $.env.get('HOME')
  if (!home) throw new Error('HOME is not set')
  const now = await $.clock.now()
  const found: Session[] = []
  for (const agent of JSON.parse(listed.stdout) as Agent[]) {
    if (!agent.sessionId || !isForgeSession(agent.name ?? '', agent.cwd)) continue
    const last = agent.state === 'working' ? await lastWrite($, home, agent) : undefined
    found.push({
      id: agent.id ?? agent.sessionId,
      sessionId: agent.sessionId,
      name: agent.name ?? '',
      state: agent.state,
      idleMinutes: last === undefined ? 0 : Math.floor((now - last) / 60_000),
    })
  }
  return found
}

function describe(alert: Alert): string {
  return alert.kind === 'blocked'
    ? `${alert.name} needs you`
    : `${alert.name} has written nothing for ${alert.idleMinutes} min`
}

const NOTIFIED_NAME = /^\S+ (discuss|quick|debug) /

function claimKey(alert: Alert): string {
  return `${alert.id}:${alert.kind}`
}

const CLAIM_SETTLE_MS = 2_000

async function claimAndNotify($: EngineInterface, alert: Alert) {
  const key = claimKey(alert)
  if ((await $.store.get(key)) !== undefined) return
  const token = Math.random().toString(36).slice(2)
  await $.store.set(key, token)
  await $.clock.sleep(CLAIM_SETTLE_MS)
  if ((await $.store.get(key)) !== token) return
  let isSent = false
  try {
    isSent = (await $.ui.notify(`${describe(alert)} · claude attach ${alert.id}`, { title: 'forge' })).isSent
  } finally {
    if (!isSent) await $.store.delete(key)
  }
}

let isPolling = false

async function poll($: EngineInterface, stallMinutes: number) {
  if (isPolling || (await $.session.surfaces()).length === 0) return
  isPolling = true
  try {
    const found = await sessions($)
    const previous: Alert[] = await read($, alerts)
    const { current, fresh } = step(previous, found, stallMinutes)
    await update($, alerts, () => current)
    for (const alert of fresh) $.ui.toast(describe(alert), { timeoutMs: 15_000 })
    for (const alert of current) {
      if (NOTIFIED_NAME.test(alert.name)) await claimAndNotify($, alert)
    }
    const live = new Set(current.map(claimKey))
    for (const key of await $.store.keys()) {
      if (!live.has(key)) await $.store.delete(key)
    }
    $.ui.status(undefined)
  } catch (error) {
    $.ui.status(`forge-stalls: ${(error as Error).message}`)
  } finally {
    isPolling = false
  }
}

export const register: Register = (on, options) => {
  const stallMinutes = Number(options.stallMinutes ?? 20)

  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'forge-stalls',
      description: 'List the forge sessions that are blocked on you or stalled',
    })
    void poll($, stallMinutes)
    $.clock.every(POLL_MS, () => void poll($, stallMinutes))
    return next(e)
  })

  on('command.run', { command: 'forge-stalls' }, async $ => {
    await poll($, stallMinutes)
    const current: Alert[] = await read($, alerts)
    if (current.length === 0) return { text: 'No forge session is blocked or stalled.' }
    return {
      text: current.map(alert => `${describe(alert)} · claude attach ${alert.id}`).join('\n'),
    }
  })
}
