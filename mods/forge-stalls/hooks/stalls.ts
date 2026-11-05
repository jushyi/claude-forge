import type { Alert } from '../types'

export type Session = {
  id: string
  sessionId: string
  name: string
  state: string
  idleMinutes: number
}

export function isForgeSession(name: string, cwd: string): boolean {
  const head = /^(\S+) (.+)$/.exec(name)
  if (!head) return false
  const form = head[2]!
  if (/^P(\d+)(?:R(\d+))? (\S+\/\S+)$/.test(form)) return true
  if (/^(verify|ship|discuss) (\S+\/\S+)$/.test(form)) return true
  if (/^(quick|debug) (.+)$/.test(form)) return true
  return form.startsWith('forge watchdog:') && /-(\d+)$/.test(cwd)
}

export function step(
  previous: readonly Alert[],
  sessions: readonly Session[],
  stallMinutes: number,
): { current: Alert[]; fresh: Alert[] } {
  const key = (a: Pick<Alert, 'kind' | 'sessionId'>) => `${a.kind}:${a.sessionId}`
  const known = new Set(previous.map(key))
  const current: Alert[] = []
  for (const s of sessions) {
    const kind =
      s.state === 'blocked' ? 'blocked' : s.state === 'working' && s.idleMinutes >= stallMinutes ? 'stalled' : undefined
    if (kind) current.push({ id: s.id, sessionId: s.sessionId, name: s.name, kind, idleMinutes: s.idleMinutes })
  }
  return { current, fresh: current.filter(a => !known.has(key(a))) }
}
