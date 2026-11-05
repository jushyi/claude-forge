export type Alert = {
  id: string
  sessionId: string
  name: string
  kind: 'blocked' | 'stalled'
  idleMinutes: number
}

declare module 'claude-code' {
  interface PluginState {
    'forge-stalls': { alerts: Alert[] }
  }
}
