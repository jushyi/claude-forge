import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { ItemView, ProjectView } from '../types'
import { parseRun, phaseStage } from './forge'
import type { Run } from './forge'

const PANE = 'forge-runs'
const COLUMNS = 38
const POLL_MS = 10_000
const snapshot = atom({ plugin: 'forge-runs', key: 'snapshot' } as const, {
  projects: [],
  error: '',
  isLoaded: false,
})

type Agent = { name?: string; cwd: string; state: string; startedAt: number }
type Feature = { feature: string; status: string; phases: { done: number; total: number } | null }
type Status = { tracks: { track: string; features: Feature[] }[] }

async function readJson<T>($: EngineInterface, path: string): Promise<T> {
  return JSON.parse((await $.fs.read(path)) as string) as T
}

async function run($: EngineInterface, argv: string[], cwd?: string): Promise<string> {
  const result = await $.process.run(argv, { cwd, timeoutMs: 20_000 })
  if (result.exitCode !== 0) {
    throw new Error(`${argv.join(' ')} exited ${result.exitCode}: ${result.stderr.trim()}`)
  }
  return result.stdout
}

async function findRoot($: EngineInterface, cwd: string): Promise<string | undefined> {
  let root: string | undefined
  for (let dir = cwd; dir.length > 1; dir = dir.slice(0, dir.lastIndexOf('/')) || '/') {
    if (await $.fs.exists(`${dir}/.forge/tracks`)) root = dir
  }
  return root
}

async function phaseInfo($: EngineInterface, root: string, n: number) {
  const argv = ['forge', 'paths', String(n).padStart(2, '0')]
  const result = await $.process.run(argv, { cwd: root, timeoutMs: 20_000 })
  if (result.exitCode === 1) return { stage: 'starting', feature: undefined }
  if (result.exitCode !== 0) {
    throw new Error(`${argv.join(' ')} exited ${result.exitCode}: ${result.stderr.trim()}`)
  }
  const path = result.stdout
    .split('\n')
    .find(line => line.startsWith('P='))
    ?.slice(2)
  if (!path) throw new Error(`${argv.join(' ')} printed no P= line`)
  const files = (await $.fs.list(path)).map(f => f.name)
  const spec = await readJson<{ track: string; feature: string }>($, `${path}/spec.json`)

  let tasksTotal = 0
  let tasksDone = 0
  if (files.includes('plan.json')) {
    tasksTotal = ((await readJson<{ tasks?: unknown[] }>($, `${path}/plan.json`)).tasks ?? []).length
    if (files.includes('tasks')) {
      for (const task of await $.fs.list(`${path}/tasks`)) {
        const { status } = await readJson<{ status?: string }>($, `${path}/tasks/${task.name}`)
        if (status === 'done') tasksDone++
      }
    }
  }
  const isDone =
    files.includes('result.json') &&
    (await readJson<{ status?: string }>($, `${path}/result.json`)).status === 'done'

  return {
    stage: phaseStage({ files, tasksDone, tasksTotal, isDone }),
    feature: `${spec.track}/${spec.feature}`,
  }
}

function progressOf(feature: Feature | undefined): string {
  if (!feature) return ''
  return feature.phases ? `${feature.phases.done}/${feature.phases.total} phases` : feature.status
}

async function collect($: EngineInterface): Promise<ProjectView[]> {
  const agents = JSON.parse(await run($, ['claude', 'agents', '--json', '--all'])) as Agent[]
  const now = await $.clock.now()
  const statuses = new Map<string, Promise<Map<string, Feature>>>()
  const projects = new Map<string, Map<string, ItemView>>()

  const featuresOf = (root: string) => {
    if (!statuses.has(root)) {
      statuses.set(
        root,
        run($, ['forge', 'status', '--json'], root).then(out => {
          const map = new Map<string, Feature>()
          for (const track of (JSON.parse(out) as Status).tracks) {
            for (const feature of track.features) map.set(`${track.track}/${feature.feature}`, feature)
          }
          return map
        }),
      )
    }
    return statuses.get(root)!
  }

  for (const agent of agents) {
    if (agent.state !== 'working' && agent.state !== 'blocked') continue
    const found: Run | undefined = parseRun(agent.name ?? '', agent.cwd)
    if (!found) continue

    let feature = found.feature
    let stage = ''
    const root = await findRoot($, agent.cwd)
    if (found.kind === 'phase' && found.phase !== undefined && root) {
      try {
        const info = await phaseInfo($, root, found.phase)
        stage = info.stage
        feature ??= info.feature
      } catch (error) {
        stage = `unreadable: ${(error as Error).message}`
      }
    }

    const label = feature ?? `${found.kind}: ${found.text ?? ''}`
    const items = projects.get(found.project) ?? new Map<string, ItemView>()
    projects.set(found.project, items)
    let item = items.get(label)
    if (!item) {
      const progress = feature && root ? progressOf((await featuresOf(root)).get(feature)) : ''
      item = { label, progress, runs: [] }
      items.set(label, item)
    }
    item.runs.push({
      label: found.kind === 'phase' ? `P${found.phase}${found.retry ? `R${found.retry}` : ''}` : found.kind,
      stage,
      isBlocked: agent.state === 'blocked',
      minutes: Math.max(0, Math.floor((now - agent.startedAt) / 60_000)),
    })
  }

  return [...projects]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([name, items]) => ({ name, items: [...items.values()] }))
}

function age(minutes: number): string {
  return minutes < 60 ? `${minutes}m` : `${Math.floor(minutes / 60)}h${String(minutes % 60).padStart(2, '0')}m`
}

let isPolling = false

async function poll($: EngineInterface) {
  if (isPolling || (await $.session.surfaces()).length === 0) return
  isPolling = true
  try {
    const projects = await collect($)
    await update($, snapshot, () => ({ projects, error: '', isLoaded: true }))
  } catch (error) {
    await update($, snapshot, previous => ({ ...previous, error: (error as Error).message, isLoaded: true }))
  } finally {
    isPolling = false
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({ name: 'forge-runs', description: 'Show the forge runs pane' })
    void $.ui.open({ id: PANE, title: 'Forge', columns: COLUMNS })
    void poll($)
    $.clock.every(POLL_MS, () => void poll($))
    return next(e)
  })

  on('command.run', { command: 'forge-runs' }, async $ => {
    await $.ui.open({ id: PANE, title: 'Forge', columns: COLUMNS })
    await poll($)
    return { text: 'Forge runs pane opened.' }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    const { projects, error, isLoaded } = await read($, snapshot)

    return (
      <Box flexDirection="column">
        {error !== '' && <Text color="error">{error}</Text>}
        {!isLoaded && <Text dimColor>Reading forge sessions…</Text>}
        {isLoaded && projects.length === 0 && <Text dimColor>No forge runs active.</Text>}
        {projects.map(project => (
          <Box flexDirection="column" marginBottom={1}>
            <Text bold>{project.name}</Text>
            {project.items.map(item => (
              <Box flexDirection="column" paddingLeft={1}>
                <Text wrap="truncate-end">
                  {item.label} <Text dimColor>{item.progress}</Text>
                </Text>
                {item.runs.map(one => (
                  <Box paddingLeft={2}>
                    <Text wrap="truncate-end" color={one.isBlocked ? 'warning' : 'text'}>
                      {[one.label, one.stage, one.isBlocked ? '· needs you' : ''].filter(Boolean).join(' ')}{' '}
                      <Text dimColor>{age(one.minutes)}</Text>
                    </Text>
                  </Box>
                ))}
              </Box>
            ))}
          </Box>
        ))}
      </Box>
    )
  })
}
