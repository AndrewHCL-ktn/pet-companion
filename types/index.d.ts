export type MoodKind =
  | 'idle'
  | 'thinking'
  | 'working'
  | 'waiting'
  | 'done'
  | 'error'
  | 'sleep'

export type Mood = { kind: MoodKind; detail: string; at: number }

export type TaskStatus = 'pending' | 'in_progress' | 'completed'
export type PetTask = { id: string; text: string; status: TaskStatus }

export type Stats = { turns: number; tools: number; lastTurnMs: number }

export type Limit = { kind: string; percent: number; resetsAt?: string }
export type Usage = {
  contextPercent?: number
  contextTokens?: number
  window: number
  limits: Limit[]
  usd?: number
  startedAt: number
}

declare module 'claude-code' {
  interface PluginState {
    'pet-companion': {
      mood: Shaped<Mood>
      tasks: Shaped<PetTask[]>
      stats: Shaped<Stats>
      usage: Shaped<Usage>
    }
  }
}
