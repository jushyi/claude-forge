import { expect, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const NOW = 1_800_000_000_000
const ROOT = '/p/ACME'
const PHASE = '/s/state/forge/ACME/phases/191-auth-round-trips'

const agents = [
  {
    name: 'ACME P191 hardening/perf-pass',
    cwd: '/p/ACME/acme-hub/.claude/worktrees/hardening-perf-pass-191',
    state: 'working',
    startedAt: NOW - 75 * 60_000,
  },
  { name: 'ACME discuss inv-release/release-flow', cwd: '/p/ACME', state: 'blocked', startedAt: NOW - 4 * 60_000 },
  { name: 'ACME P190 hardening/perf-pass', cwd: '/p/ACME', state: 'done', startedAt: NOW },
  { name: 'op some chat', cwd: '/Users/op', state: 'working', startedAt: NOW },
]

const status = {
  tracks: [
    { track: 'hardening', features: [{ feature: 'perf-pass', status: 'discussed', phases: { done: 5, total: 9 } }] },
    { track: 'inv-release', features: [{ feature: 'release-flow', status: 'discussing', phases: null }] },
  ],
}

const entry = (name: string, kind: 'file' | 'dir') => ({ name, kind, size: 0, mtimeMs: 0, isLink: false })

const listings: Record<string, ReturnType<typeof entry>[]> = {
  [PHASE]: [entry('spec.json', 'file'), entry('research.json', 'file'), entry('plan.json', 'file'), entry('tasks', 'dir')],
  [`${PHASE}/tasks`]: [entry('T1.json', 'file'), entry('T2.json', 'file')],
}

const files: Record<string, unknown> = {
  [`${PHASE}/spec.json`]: { track: 'hardening', feature: 'perf-pass' },
  [`${PHASE}/plan.json`]: { tasks: [{ id: 'T1' }, { id: 'T2' }, { id: 'T3' }] },
  [`${PHASE}/tasks/T1.json`]: { status: 'done' },
  [`${PHASE}/tasks/T2.json`]: { status: 'done' },
}

const exited = (exitCode: number, stdout: string, stderr = '') => ({
  value: { exitCode, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false },
})

const pathsOut = [`R=${ROOT}`, `W=${ROOT}/acme-hub/.claude/worktrees/hardening-perf-pass-191`, `P=${PHASE}`, ''].join('\n')

type Call = { argv: readonly string[]; cwd: string | undefined }

function forge(
  on: On,
  sessions: typeof agents,
  paths: (argv: readonly string[], cwd: string | undefined) => ReturnType<typeof exited>,
  calls: Call[] = [],
) {
  on('clock.now', () => ({ value: NOW }))
  on('clock.every', () => ({ value: undefined }))
  on('ui.open', () => ({ value: { isPlaced: true as const } }))
  on('session.surfaces', () => ({ value: ['terminal' as const] }))
  on('process.run', (_$, e) => {
    calls.push({ argv: e.argv, cwd: e.init?.cwd })
    if (e.argv[0] === 'claude') return exited(0, JSON.stringify(sessions))
    if (e.argv[0] === 'forge' && e.argv[1] === 'paths') return paths(e.argv, e.init?.cwd)
    return exited(0, JSON.stringify(status))
  })
  on('fs.exists', (_$, e) => ({ value: e.path === `${ROOT}/.forge/tracks` }))
  on('fs.list', (_$, e) => ({ value: listings[e.path] ?? [] }))
  on('fs.read', (_$, e) => ({ value: JSON.stringify(files[e.path]) }))
}

const open = {
  command: 'forge-runs',
  args: '',
  origin: { kind: 'composer' as const },
  presentation: { isFullscreen: true, columns: 200 },
}

const pane = (surface: 'terminal' | 'desktop') => ({
  plugin: 'forge-runs',
  surface,
  component: 'Pane' as const,
  requestId: 'forge-runs',
  props: {
    title: 'Forge',
    isFocused: false,
    bodyColumns: 40,
    placement: 'dock' as const,
    scroll: { offset: 0, bodyRows: 30 },
    view: {},
  },
})

test('the pane shows each live forge session with its feature progress and phase stage', async ($, on) => {
  forge(on, agents, (argv, cwd) =>
    argv.join(' ') === 'forge paths 191' && cwd === ROOT ? exited(0, pathsOut) : exited(2, '', `unexpected ${argv.join(' ')} in ${cwd}`),
  )

  await $.command.run(open)

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount(pane(surface))
    expect(await ui.find({ type: 'Text', text: /^ACME$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /hardening\/perf-pass 5\/9 phases/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /P191 tasks 2\/3 1h15m/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /discuss · needs you 4m/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /P190|op/ })).toBeUndefined()
    await ui.unmount()
  }
})

test('a phase forge paths does not know yet shows starting', async ($, on) => {
  forge(on, agents, () => exited(1, '', 'forge: no phase 191'))

  await $.command.run(open)

  const ui = await $.ui.mount(pane('terminal'))
  expect(await ui.find({ type: 'Text', text: /P191 starting 1h15m/ })).toBeDefined()
  await ui.unmount()
})

test('any other forge paths failure shows the phase unreadable', async ($, on) => {
  forge(on, agents, () => exited(2, '', 'forge: paths broke'))

  await $.command.run(open)

  const ui = await $.ui.mount(pane('terminal'))
  expect(await ui.find({ type: 'Text', text: /P191 unreadable: .*paths broke/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /P191 starting/ })).toBeUndefined()
  await ui.unmount()
})

test('a P05 session asks forge paths for phase 05 from the repo root', async ($, on) => {
  const calls: Call[] = []
  const p05 = [{ ...agents[0]!, name: 'ACME P05 hardening/perf-pass', cwd: '/p/ACME/acme-hub/.claude/worktrees/hardening-perf-pass-05' }]
  forge(on, p05, () => exited(0, pathsOut), calls)

  await $.command.run(open)

  const paths = calls.filter(c => c.argv[0] === 'forge' && c.argv[1] === 'paths')
  expect(paths).toEqual([{ argv: ['forge', 'paths', '05'], cwd: ROOT }])
})

test('a session with no surface attached polls nothing', async ($, on) => {
  let runs = 0
  on('ui.open', () => ({ value: { isPlaced: true as const } }))
  on('session.surfaces', () => ({ value: [] }))
  on('process.run', () => {
    runs++
    return { deny: 'no process in this test' }
  })

  await $.command.run(open)

  expect(runs).toBe(0)
})
