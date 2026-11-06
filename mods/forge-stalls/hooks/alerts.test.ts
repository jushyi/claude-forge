import { expect, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const NOW = 1_800_000_000_000
const DIR = '/Users/op/.claude/projects/-p-ACME-acme-hub--claude-worktrees-perf-191'

type Agent = { id: string; sessionId: string; name: string; cwd: string; state: string }

const DISCUSS: Agent = {
  id: 'aaaa1111',
  sessionId: 's-blocked',
  name: 'ACME discuss inv-release/release-flow',
  cwd: '/p/ACME',
  state: 'blocked',
}
const PHASE: Agent = {
  id: 'bbbb2222',
  sessionId: 's-stalled',
  name: 'ACME P191 hardening/perf-pass',
  cwd: '/p/ACME/acme-hub/.claude/worktrees/perf-191',
  state: 'working',
}
const CHAT: Agent = { id: 'cccc3333', sessionId: 's-chat', name: 'op some chat', cwd: '/Users/op', state: 'blocked' }

const DISCUSS_NOTE = 'ACME discuss inv-release/release-flow needs you · claude attach aaaa1111'

const RUN = {
  command: 'forge-stalls',
  args: '',
  origin: { kind: 'composer' as const },
  presentation: { isFullscreen: true, columns: 200 },
}

type Host = {
  agents: Agent[]
  toasts: string[]
  notes: string[]
  store: Map<string, unknown>
  failKeys: boolean
  isNotifySent: boolean
  onSleep: () => void
}

function mockHost(on: On, subagentMtime: number, agents: Agent[], store = new Map<string, unknown>()): Host {
  const host: Host = { agents, toasts: [], notes: [], store, failKeys: false, isNotifySent: true, onSleep: () => {} }
  on('session.surfaces', () => ({ value: ['terminal' as const] }))
  on('clock.now', () => ({ value: NOW }))
  on('clock.every', () => ({ value: undefined }))
  on('clock.sleep', () => {
    host.onSleep()
    return { value: undefined }
  })
  on('env.get', () => ({ value: '/Users/op' }))
  on('process.run', () => ({
    value: {
      exitCode: 0,
      stdout: JSON.stringify(host.agents),
      stderr: '',
      isStdoutTruncated: false,
      isStderrTruncated: false,
    },
  }))
  on('fs.exists', (_$, e) => ({ value: e.path === `${DIR}/s-stalled.jsonl` || e.path === `${DIR}/s-stalled/subagents` }))
  on('fs.stat', () => ({ value: { kind: 'file' as const, size: 1, mtimeMs: NOW - 60 * 60_000, isLink: false } }))
  on('fs.list', () => ({
    value: [{ name: 'agent-1.jsonl', kind: 'file' as const, size: 1, mtimeMs: subagentMtime, isLink: false }],
  }))
  on('store.get', (_$, e) => ({ value: host.store.get(e.key) }))
  on('store.set', (_$, e) => {
    host.store.set(e.key, e.value)
    return { value: undefined }
  })
  on('store.delete', (_$, e) => {
    host.store.delete(e.key)
    return { value: undefined }
  })
  on('store.keys', () => {
    if (host.failKeys) throw new Error('store unavailable')
    return { value: [...host.store.keys()] }
  })
  on('ui.toast', (_$, e) => {
    host.toasts.push(e.text)
    return { value: undefined }
  })
  on('ui.notify', (_$, e) => {
    host.notes.push(e.text)
    return {
      value: host.isNotifySent
        ? { isSent: true as const, channel: 'terminal_bell' as const }
        : { isSent: false as const, reason: 'no-channel' as const },
    }
  })
  on('ui.status', () => ({ value: undefined }))
  return host
}

test('alerts blocked and stalled forge sessions once and lists them', async ($, on) => {
  const host = mockHost(on, NOW - 25 * 60_000, [DISCUSS, PHASE, CHAT])

  const first = await $.command.run(RUN)
  expect(host.toasts).toEqual([
    'ACME discuss inv-release/release-flow needs you',
    'ACME P191 hardening/perf-pass has written nothing for 25 min',
  ])
  expect(host.notes).toEqual([DISCUSS_NOTE])
  expect(first.text).toBe(
    [DISCUSS_NOTE, 'ACME P191 hardening/perf-pass has written nothing for 25 min · claude attach bbbb2222'].join('\n'),
  )

  await $.command.run(RUN)
  expect(host.toasts.length).toBe(2)
  expect(host.notes.length).toBe(1)
})

test('a phase session alert toasts and sends no desktop note', async ($, on) => {
  const host = mockHost(on, NOW - 25 * 60_000, [PHASE])

  const result = await $.command.run(RUN)
  expect(host.toasts).toEqual(['ACME P191 hardening/perf-pass has written nothing for 25 min'])
  expect(host.notes).toEqual([])
  expect(result.text).toBe('ACME P191 hardening/perf-pass has written nothing for 25 min · claude attach bbbb2222')
})

test('a discuss alert another session already claimed in the store toasts and sends no note', async ($, on) => {
  const host = mockHost(on, NOW - 2 * 60_000, [DISCUSS], new Map<string, unknown>([['aaaa1111:blocked', true]]))

  await $.command.run(RUN)
  expect(host.toasts).toEqual(['ACME discuss inv-release/release-flow needs you'])
  expect(host.notes).toEqual([])
  expect(host.store.has('aaaa1111:blocked')).toBe(true)
})

test('a discuss alert claims its store key and notifies once', async ($, on) => {
  const host = mockHost(on, NOW - 2 * 60_000, [DISCUSS])

  await $.command.run(RUN)
  expect(host.notes).toEqual([DISCUSS_NOTE])
  expect(host.store.has('aaaa1111:blocked')).toBe(true)
})

test('a discuss alert another session claims during the settle wait sends no note', async ($, on) => {
  const host = mockHost(on, NOW - 2 * 60_000, [DISCUSS])
  host.onSleep = () => host.store.set('aaaa1111:blocked', 'other-session')

  await $.command.run(RUN)
  expect(host.toasts).toEqual(['ACME discuss inv-release/release-flow needs you'])
  expect(host.notes).toEqual([])
  expect(host.store.get('aaaa1111:blocked')).toBe('other-session')
})

test('a discuss note that is not sent releases its claim and is retried on the next poll', async ($, on) => {
  const host = mockHost(on, NOW - 2 * 60_000, [DISCUSS])
  host.isNotifySent = false

  await $.command.run(RUN)
  expect(host.notes).toEqual([DISCUSS_NOTE])
  expect(host.store.has('aaaa1111:blocked')).toBe(false)

  host.isNotifySent = true
  await $.command.run(RUN)
  expect(host.notes).toEqual([DISCUSS_NOTE, DISCUSS_NOTE])
  expect(host.store.has('aaaa1111:blocked')).toBe(true)

  await $.command.run(RUN)
  expect(host.notes).toEqual([DISCUSS_NOTE, DISCUSS_NOTE])
  expect(host.toasts).toEqual(['ACME discuss inv-release/release-flow needs you'])
})

test('a failing store cleanup still delivers the fresh alert', async ($, on) => {
  const host = mockHost(on, NOW - 2 * 60_000, [DISCUSS])
  host.failKeys = true

  await $.command.run(RUN)
  expect(host.toasts).toEqual(['ACME discuss inv-release/release-flow needs you'])
  expect(host.notes).toEqual([DISCUSS_NOTE])
})

test('a cleared then re-blocked discuss session notifies again', async ($, on) => {
  const host = mockHost(on, NOW - 2 * 60_000, [DISCUSS])

  await $.command.run(RUN)
  expect(host.notes).toEqual([DISCUSS_NOTE])

  host.agents = [{ ...DISCUSS, state: 'idle' }]
  await $.command.run(RUN)
  expect(host.store.has('aaaa1111:blocked')).toBe(false)
  expect(host.notes).toEqual([DISCUSS_NOTE])

  host.agents = [DISCUSS]
  await $.command.run(RUN)
  expect(host.toasts).toEqual([
    'ACME discuss inv-release/release-flow needs you',
    'ACME discuss inv-release/release-flow needs you',
  ])
  expect(host.notes).toEqual([DISCUSS_NOTE, DISCUSS_NOTE])
})

test('a working session whose subagent wrote recently is not stalled', async ($, on) => {
  const host = mockHost(on, NOW - 2 * 60_000, [DISCUSS, PHASE, CHAT])

  const result = await $.command.run(RUN)
  expect(host.toasts).toEqual(['ACME discuss inv-release/release-flow needs you'])
  expect(result.text).toBe(DISCUSS_NOTE)
})
