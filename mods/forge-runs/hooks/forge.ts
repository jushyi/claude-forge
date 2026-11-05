export type Run = {
  project: string
  kind: 'phase' | 'verify' | 'ship' | 'discuss' | 'quick' | 'debug'
  phase?: number
  retry?: number
  feature?: string
  text?: string
}

export type PhaseFiles = {
  files: readonly string[]
  tasksDone: number
  tasksTotal: number
  isDone: boolean
}

export function parseRun(name: string, cwd: string): Run | undefined {
  const head = /^(\S+) (.+)$/.exec(name)
  if (!head) return undefined
  const project = head[1]!
  const form = head[2]!

  const phase = /^P(\d+)(?:R(\d+))? (\S+\/\S+)$/.exec(form)
  if (phase) {
    const run: Run = { project, kind: 'phase', phase: Number(phase[1]), feature: phase[3]! }
    if (phase[2]) run.retry = Number(phase[2])
    return run
  }

  const feature = /^(verify|ship|discuss) (\S+\/\S+)$/.exec(form)
  if (feature) return { project, kind: feature[1] as Run['kind'], feature: feature[2]! }

  const task = /^(quick|debug) (.+)$/.exec(form)
  if (task) return { project, kind: task[1] as Run['kind'], text: task[2]! }

  if (form.startsWith('forge watchdog:')) {
    const tail = /-(\d+)$/.exec(cwd)
    if (tail) return { project, kind: 'phase', phase: Number(tail[1]) }
  }

  return undefined
}

export function phaseStage({ files, tasksDone, tasksTotal, isDone }: PhaseFiles): string {
  if (isDone) return 'done'
  if (!files.includes('plan.json')) return 'plan'
  if (tasksDone < tasksTotal) return `tasks ${tasksDone}/${tasksTotal}`
  return 'sync'
}
