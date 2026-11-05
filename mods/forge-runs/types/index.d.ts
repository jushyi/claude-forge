export type RunView = { label: string; stage: string; isBlocked: boolean; minutes: number }

export type ItemView = { label: string; progress: string; runs: RunView[] }

export type ProjectView = { name: string; items: ItemView[] }

export type Snapshot = { projects: ProjectView[]; error: string; isLoaded: boolean }

declare module 'claude-code' {
  interface PluginState {
    'forge-runs': { snapshot: Snapshot }
  }
}
