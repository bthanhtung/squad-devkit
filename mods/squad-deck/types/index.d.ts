// The contract is self-contained: the shapes the deck keeps live here, and the
// hooks import them from '../types'.

export type Run = {
  id: string
  // The manager tab that started the run; empty when the file names none.
  manager: string
  engine: string
  model: string
  role: string
  state: string
  started: number
  finished: number | null
  verify: string
  verdict: string
  tokensIn: number | null
  tokensOut: number | null
  // The run's time limit and token budget; null when the status file has none.
  timeoutSeconds: number | null
  budgetTokens: number | null
  // The plan file the run belongs to (absolute path); empty or `none` without one.
  plan: string
  title: string
  isScopeViolation: boolean
  log: string
  activity: string
}

// Progress of one active plan: tasks done out of tasks.
export type PlanProgress = { name: string; done: number; total: number }

export type Kind = 'file' | 'shell' | 'other'
export type Verdict = 'allow' | 'ask' | 'deny'
export type Perms = Record<Kind, Record<Verdict, number>>
export type Layout = 'auto' | 'compact' | 'wide' | 'mini'

declare module 'claude-code' {
  interface PluginState {
    'squad-deck': {
      // Workers of this session, newest per id, with the clock (seconds) of the
      // refresh that read them: a new `now` redraws the live elapsed times.
      runs: Shaped<Run[]>
      now: number
      // When this session began (epoch seconds); older runs are not shown.
      since: number
      // True while the pane is drawn, so the band above the prompt stays quiet.
      isDocked: boolean
      // True while a run of this tab runs, or within a minute after the last one ended.
      isActive: boolean
      perms: Shaped<Perms>
      commands: Shaped<string[]>
      layout: Shaped<Layout>
      // Progress of this tab's active plans, newest first, at most two.
      plans: Shaped<PlanProgress[]>
    }
  }
}
