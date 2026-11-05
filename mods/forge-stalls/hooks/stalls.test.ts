import { describe, expect, test } from 'claude-code/testing'

import { isForgeSession, step } from './stalls'

const session = (sessionId: string, state: string, idleMinutes = 0) => ({
  id: sessionId.slice(0, 4),
  sessionId,
  name: `ACME P${sessionId} a/b`,
  state,
  idleMinutes,
})

describe('isForgeSession', () => {
  test('takes the forge session forms', async () => {
    expect(isForgeSession('ACME P191 hardening/perf-pass', '/x')).toBe(true)
    expect(isForgeSession('browser P179R3 new-machine/restore-gates', '/x')).toBe(true)
    expect(isForgeSession('nova verify v1/food', '/x')).toBe(true)
    expect(isForgeSession('ACME discuss inv-release/release-flow', '/x')).toBe(true)
    expect(isForgeSession('ACME debug on the hub consignments', '/x')).toBe(true)
    expect(isForgeSession('forge quick tidy help', '/x')).toBe(true)
    expect(isForgeSession('example-app forge watchdog: slot cleared; continue', '/p/worktrees/clouds-66')).toBe(true)
  })

  test('leaves other sessions out', async () => {
    expect(isForgeSession('op i head there was a new claude code mods', '/home/op')).toBe(false)
    expect(isForgeSession('ACME 9057 ready', '/x')).toBe(false)
    expect(isForgeSession('example-app forge watchdog: slot cleared; continue', '/p/worktrees/backlog')).toBe(false)
    expect(isForgeSession('', '/x')).toBe(false)
  })
})

describe('step', () => {
  test('alerts a session first seen blocked', async () => {
    const { current, fresh } = step([], [session('1', 'blocked')], 20)
    expect(fresh.map(a => [a.sessionId, a.kind])).toEqual([['1', 'blocked']])
    expect(current).toEqual(fresh)
  })

  test('does not alert a session again while it stays blocked', async () => {
    const first = step([], [session('1', 'blocked')], 20)
    const second = step(first.current, [session('1', 'blocked')], 20)
    expect(second.fresh).toEqual([])
    expect(second.current.map(a => a.sessionId)).toEqual(['1'])
  })

  test('alerts again once a session leaves blocked and comes back', async () => {
    const first = step([], [session('1', 'blocked')], 20)
    const working = step(first.current, [session('1', 'working')], 20)
    expect(working.current).toEqual([])
    const again = step(working.current, [session('1', 'blocked')], 20)
    expect(again.fresh.map(a => a.sessionId)).toEqual(['1'])
  })

  test('alerts a working session idle past the limit once', async () => {
    const quiet = step([], [session('1', 'working', 19)], 20)
    expect(quiet.fresh).toEqual([])
    const stalled = step(quiet.current, [session('1', 'working', 20)], 20)
    expect(stalled.fresh.map(a => [a.sessionId, a.kind, a.idleMinutes])).toEqual([['1', 'stalled', 20]])
    const still = step(stalled.current, [session('1', 'working', 45)], 20)
    expect(still.fresh).toEqual([])
    expect(still.current.map(a => a.idleMinutes)).toEqual([45])
  })

  test('clears a stall once the session writes again', async () => {
    const stalled = step([], [session('1', 'working', 30)], 20)
    const active = step(stalled.current, [session('1', 'working', 0)], 20)
    expect(active.current).toEqual([])
  })

  test('ignores sessions in other states', async () => {
    expect(step([], [session('1', 'done', 90), session('2', 'idle', 90)], 20).current).toEqual([])
  })
})
