import { describe, expect, test } from 'claude-code/testing'

import { parseRun, phaseStage } from './forge'

describe('parseRun', () => {
  test('reads a phase session', async () => {
    expect(parseRun('ACME P191 hardening/perf-pass', '/x')).toEqual({
      project: 'ACME',
      kind: 'phase',
      phase: 191,
      feature: 'hardening/perf-pass',
    })
  })

  test('reads a phase retry', async () => {
    expect(parseRun('browser P179R3 new-machine/restore-gates', '/x')).toEqual({
      project: 'browser',
      kind: 'phase',
      phase: 179,
      retry: 3,
      feature: 'new-machine/restore-gates',
    })
  })

  test('reads verify, ship and discuss sessions', async () => {
    expect(parseRun('nova verify v1/food', '/x')).toEqual({ project: 'nova', kind: 'verify', feature: 'v1/food' })
    expect(parseRun('ACME ship a/b', '/x')).toEqual({ project: 'ACME', kind: 'ship', feature: 'a/b' })
    expect(parseRun('ACME discuss inv-release/release-flow', '/x')).toEqual({
      project: 'ACME',
      kind: 'discuss',
      feature: 'inv-release/release-flow',
    })
  })

  test('reads quick and debug sessions', async () => {
    expect(parseRun('ACME debug on the hub consignments', '/x')).toEqual({
      project: 'ACME',
      kind: 'debug',
      text: 'on the hub consignments',
    })
    expect(parseRun('forge quick tidy help', '/x')).toEqual({ project: 'forge', kind: 'quick', text: 'tidy help' })
  })

  test('reads a watchdog continuation by its worktree phase number', async () => {
    expect(
      parseRun('example-app forge watchdog: slot cleared; continue', '/p/.claude/worktrees/clouds-volumetric-clouds-66'),
    ).toEqual({ project: 'example-app', kind: 'phase', phase: 66 })
  })

  test('leaves other sessions out', async () => {
    expect(parseRun('op i head there was a new claude code mods', '/home/op')).toBeUndefined()
    expect(parseRun('ACME 9057 ready', '/x')).toBeUndefined()
    expect(parseRun('example-app forge watchdog: slot cleared; continue', '/p/worktrees/flight-planning-backlog')).toBeUndefined()
  })
})

describe('phaseStage', () => {
  const none = { files: [], tasksDone: 0, tasksTotal: 0, isDone: false }

  test('is done once the phase is done', async () => {
    expect(phaseStage({ ...none, files: ['plan.json'], tasksDone: 3, tasksTotal: 3, isDone: true })).toBe('done')
    expect(phaseStage({ ...none, files: ['plan.json', 'review.json'], isDone: true })).toBe('done')
    expect(phaseStage({ ...none, isDone: true })).toBe('done')
  })

  test('is plan with no plan.json, also beside a legacy research.json', async () => {
    expect(phaseStage(none)).toBe('plan')
    expect(phaseStage({ ...none, files: ['spec.json'] })).toBe('plan')
    expect(phaseStage({ ...none, files: ['scout.json', 'research.json'] })).toBe('plan')
  })

  test('counts tasks n/m while tasks remain', async () => {
    expect(phaseStage({ ...none, files: ['plan.json'], tasksDone: 0, tasksTotal: 3 })).toBe('tasks 0/3')
    expect(phaseStage({ ...none, files: ['research.json', 'plan.json'], tasksDone: 1, tasksTotal: 3 })).toBe('tasks 1/3')
    expect(phaseStage({ ...none, files: ['plan.json', 'verify.json'], tasksDone: 2, tasksTotal: 3 })).toBe('tasks 2/3')
  })

  test('is sync once every task is done, also beside a legacy verify.json or review.json', async () => {
    expect(phaseStage({ ...none, files: ['plan.json'], tasksDone: 3, tasksTotal: 3 })).toBe('sync')
    expect(phaseStage({ ...none, files: ['plan.json', 'verify.json'], tasksDone: 3, tasksTotal: 3 })).toBe('sync')
    expect(phaseStage({ ...none, files: ['plan.json', 'review.json'], tasksDone: 3, tasksTotal: 3 })).toBe('sync')
    expect(phaseStage({ ...none, files: ['plan.json', 'verify.json', 'review.json'], tasksDone: 3, tasksTotal: 3 })).toBe('sync')
  })
})
