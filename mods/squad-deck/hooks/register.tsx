// squad deck: a live, observe-only dashboard of squad workers. It reads status
// files and the tail of worker logs on this machine, watches this session's own
// permission checks and Bash calls, and draws them in a pane, a band and the
// status line. Every hook passes its event on unchanged; nothing leaves the
// machine and nothing in the session changes.
import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

import type { Layout } from '../types'
import {
  MAX_RUNS,
  TAIL_BYTES,
  activity,
  addVerdict,
  clean,
  emptyPerms,
  parseStatus,
  pickRuns,
  pickShape,
  statusText,
} from './deck'
import type { Run } from './deck'
import { Band, Deck } from './view'

const PANE = 'squad-deck'
const EVERY_MS = 2000
const LINGER_MS = 60_000 // the pane and the band stay this long after the last worker stops
const IDLE_EVERY = 5 // while nothing is open and no worker is known: every 10 s
const MAX_TAILS = 8
const LAYOUTS = ['auto', 'compact', 'wide', 'mini']

// Change a tag when the shape of a value changes: an older one reads as the initial.
const runs = atom({ plugin: 'squad-deck', key: 'runs' } as const, [], { shape: 'runs-2' })
const now = atom({ plugin: 'squad-deck', key: 'now' } as const, 0)
const since = atom({ plugin: 'squad-deck', key: 'since' } as const, 0)
const isDocked = atom({ plugin: 'squad-deck', key: 'isDocked' } as const, false)
const isActive = atom({ plugin: 'squad-deck', key: 'isActive' } as const, false)
const perms = atom({ plugin: 'squad-deck', key: 'perms' } as const, emptyPerms(), {
  shape: 'perms-1',
})
const commands = atom({ plugin: 'squad-deck', key: 'commands' } as const, [], {
  shape: 'commands-1',
})
const layout = atom({ plugin: 'squad-deck', key: 'layout' } as const, 'auto', {
  shape: 'layout-1',
})

// Caches and the timer belong to this load of the module; a reload starts them over.
let timer: { cancel: () => void } | undefined
let tick = 0
let isBusy = false
// null until the first refresh: a load starts with no status line shown, and the first
// refresh must still call ui.status, so a line left by the previous load gets cleared.
let shownStatus: string | undefined | null = null
// Pane manners: /deck open pins it, a close by the person or /deck close holds it shut
// until a run not seen before turns up, and it closes LINGER_MS after the last run stops.
let isPinned = false
let isDismissed = false
let hasRun = false
let wasOpen = false
let stoppedAt: number | undefined
const seen = new Set<string>()
const statuses = new Map<string, { mtimeMs: number; run: Run | null }>()
// Whether this session is a squad session; decided once, on first need.
let squadSession: Promise<boolean> | undefined

// A squad session has a squad environment variable or a .squad/workers folder in its directory.
// The plugin may be installed for every session, so the others get /deck and nothing else.
function isSquadSession($: any): Promise<boolean> {
  squadSession ??= (async () => {
    const manager = await $.env.get('SQUAD_MANAGER_ID').catch(() => undefined)
    if (typeof manager === 'string' && manager !== '') return true
    const workspace = await $.env.get('SQUAD_DEVKIT_WORKSPACE').catch(() => undefined)
    if (typeof workspace === 'string' && workspace !== '') return true
    const cwd = await $.session.cwd().catch(() => undefined)
    if (typeof cwd !== 'string' || cwd === '') return false
    const stat = await $.fs.stat(`${cwd.replace(/\/+$/, '')}/.squad/workers`).catch(() => undefined)

    return stat?.kind === 'dir'
  })()

  return squadSession
}

async function startedAt($: any): Promise<number> {
  const fromEnv = Number(await $.env.get('SQUAD_DEVKIT_SESSION_START'))
  if (Number.isFinite(fromEnv) && fromEnv > 0) return Math.floor(fromEnv)
  const stored = await read($, since)
  if (stored > 0) return stored
  const seconds = Math.floor((await $.clock.now()) / 1000)
  await update($, since, () => seconds)

  return seconds
}

async function workersDir($: any): Promise<string> {
  const workspace = await $.env.get('SQUAD_DEVKIT_WORKSPACE')
  const base = workspace !== undefined && workspace !== '' ? workspace : await $.session.cwd()

  return `${base.replace(/\/+$/, '')}/.squad/workers`
}

// This tab's manager id; empty outside a squad-devkit tab, which then sees every run.
async function managerId($: any): Promise<string> {
  const id = await $.env.get('SQUAD_MANAGER_ID').catch(() => undefined)

  return typeof id === 'string' ? id.trim() : ''
}

// The newest status per worker; of this tab's runs, the newest MAX_RUNS files only.
async function readRuns($: any, dir: string, session: number, manager: string): Promise<Run[]> {
  const entries = await $.fs.list(dir).catch(() => [])
  const files = entries
    .filter((entry: any) => entry.kind === 'file' && entry.name.endsWith('.status'))
    .sort((a: any, b: any) => b.mtimeMs - a.mtimeMs)
  const present = new Set<string>()
  const parsed = await Promise.all(
    files.map(async (file: any): Promise<Run | null> => {
      const path = `${dir}/${file.name}`
      present.add(path)
      const hit = statuses.get(path)
      if (hit !== undefined && hit.mtimeMs === file.mtimeMs) return hit.run
      const text = await $.fs.read(path).catch(() => undefined)
      const fallback = file.name.replace(/-\d{8}-\d{6}\.status$/, '')
      const run = typeof text === 'string' ? parseStatus(text, fallback) : null
      statuses.set(path, { mtimeMs: file.mtimeMs, run })

      return run
    }),
  )
  for (const path of [...statuses.keys()]) if (!present.has(path)) statuses.delete(path)

  // The tab's filter comes before the cap, so the cap counts this tab's runs.
  const mine = parsed
    .filter((run): run is Run => run !== null && (manager === '' || run.manager === manager))
    .slice(0, MAX_RUNS)

  return pickRuns(mine, session)
}

// Only the last 16 KB of a log is read, and only from the workers directory.
async function addActivity($: any, dir: string, list: Run[]): Promise<void> {
  const isOurs = (run: Run) => run.log.startsWith(`${dir}/`) && !run.log.includes('..')
  const live = list.filter(run => run.state === 'running' && isOurs(run))
  await Promise.all(
    live.slice(0, MAX_TAILS).map(async run => {
      const out = await $.process
        .run(['tail', '-c', String(TAIL_BYTES), run.log], { timeoutMs: 3000 })
        .catch(() => undefined)
      if (out !== undefined && out.exitCode === 0) run.activity = activity(out.stdout)
    }),
  )
}

const PANE_ARGS = { id: PANE, title: 'squad', backgroundColor: 'transparent' } as const

async function refresh($: any, isForced = false): Promise<void> {
  if (isBusy) return
  isBusy = true
  try {
    const panes = await $.ui.panes().catch(() => [])
    const isOpen = panes.some((pane: any) => pane.id === PANE)
    const isUp = panes.some((pane: any) => pane.id === PANE && pane.isPlaced)
    // A pane that was open and is gone without this module closing it was the person's doing
    // (the ui.close hook sees the same, a tick sooner): unpin it, and wait for a new run.
    if (wasOpen && !isOpen) {
      isPinned = false
      isDismissed = true
    }
    wasOpen = isOpen
    if ((await read($, isDocked)) !== isUp) await update($, isDocked, () => isUp)
    const before = await read($, runs)
    // Calm when idle: no pane and no recent worker, look every 10 s only.
    tick += 1
    if (!isForced && !isOpen && !(await read($, isActive)) && tick % IDLE_EVERY !== 1) return

    const clock: number = await $.clock.now()
    const dir = await workersDir($)
    const list = await readRuns($, dir, await startedAt($), await managerId($))
    await addActivity($, dir, list)
    const running = list.filter(run => run.state === 'running')
    const keys = running.map(run => `${run.id}@${run.started}`)
    const hasFresh = keys.some(key => !seen.has(key))
    for (const key of keys) seen.add(key)
    if (hasFresh) isDismissed = false
    if (running.length > 0) {
      hasRun = true
      stoppedAt = undefined
    } else {
      stoppedAt ??= clock
    }
    const isLingering = hasRun && stoppedAt !== undefined && clock - stoppedAt < LINGER_MS
    const active = running.length > 0 || isLingering

    if (running.length > 0 && !isOpen && !isDismissed) {
      // Unasked, the engine seats it from 144 columns and otherwise leaves it waiting.
      const opened = await $.ui.open(PANE_ARGS).catch(() => undefined)
      wasOpen = opened !== undefined
      if (opened?.isPlaced === true) await update($, isDocked, () => true)
    } else if (running.length === 0 && isOpen && !isPinned && stoppedAt !== undefined && clock - stoppedAt >= LINGER_MS) {
      wasOpen = false
      await $.ui.close({ id: PANE }).catch(() => undefined)
      await update($, isDocked, () => false)
    }

    if (running.length > 0 || JSON.stringify(list) !== JSON.stringify(before)) {
      await update($, runs, () => list)
      await update($, now, () => Math.floor(clock / 1000))
    }
    if ((await read($, isActive)) !== active) await update($, isActive, () => active)
    const text = active ? statusText(list) : undefined
    if (text !== shownStatus) {
      shownStatus = text
      $.ui.status(text)
    }
  } catch (error) {
    // A missing directory, a log being written: try again next tick.
    $.ui.log(`squad-deck: refresh failed: ${String(error).slice(0, 200)}`, { to: 'debug' })
  } finally {
    isBusy = false
  }
}

// Starts the 2 s refresh once per load of the module; true when it just started.
function ensureTimer($: any): boolean {
  if (timer !== undefined) return false
  try {
    timer = $.clock.every(EVERY_MS, () => void refresh($))
  } catch {
    return false // no clock: the next hook tries again
  }

  return true
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'deck',
      description: 'Dock the squad worker dashboard: /deck [open|close|layout auto|compact|wide|mini]',
      argumentHint: '[open|close|layout auto|compact|wide|mini]',
    })
    if (await isSquadSession($)) {
      await startedAt($)
      ensureTimer($)
      await refresh($, true)
    }

    return next(e)
  })

  on('command.run', { command: 'deck' }, async ($, e) => {
    const [first = '', arg = ''] = e.args.trim().split(/\s+/)
    const verb = first === '' ? 'open' : first
    if (verb === 'close') {
      isPinned = false
      isDismissed = true
      await $.ui.close({ id: PANE }).catch(() => undefined)

      return { text: 'Squad deck closed.' }
    }
    if (verb === 'layout' && LAYOUTS.includes(arg)) {
      await update($, layout, () => arg as Layout)

      return { text: `Squad deck layout: ${arg}.` }
    }
    if (verb === 'open') {
      isPinned = true
      isDismissed = false
      ensureTimer($)
      const opened = await $.ui.open(PANE_ARGS).catch(() => undefined)
      await refresh($, true)

      return { text: opened?.isPlaced === true ? 'Squad deck opened.' : 'Squad deck could not be placed here.' }
    }

    return { text: 'Usage: /deck [open|close|layout auto|compact|wide|mini]' }
  })

  // The person closed the pane (its mark or Esc): unpin it, and keep it shut until a new run starts.
  on('ui.close', async ($, e, next) => {
    if (e.id === PANE && e.origin.kind === 'person') {
      isPinned = false
      isDismissed = true
    }

    return next(e)
  })

  on('tool.check', async ($, e, next) => {
    if ((await isSquadSession($)) && ensureTimer($)) void refresh($, true)
    const verdict = await next(e)
    if (e.tool_use_id !== undefined) {
      await update($, perms, one => addVerdict(one, e.tool, verdict.decision)).catch(() => undefined)
    }

    return verdict
  }).catch(($, e, next) => next(e))

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    if ((await isSquadSession($)) && ensureTimer($)) void refresh($, true)
    const line = clean(String(e.command ?? ''), 100)
    if (line !== '') {
      await update($, commands, list => [...list, line].slice(-5)).catch(() => undefined)
    }

    return next(e)
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const ui = $.ui.resolve(e)
    const columns = e.props.bodyColumns
    const rows = e.props.scroll?.bodyRows ?? e.viewport?.rows ?? 24
    const list = await read($, runs)
    const choice = await read($, layout)

    return Deck(ui, {
      runs: list,
      now: await read($, now),
      perms: await read($, perms),
      commands: await read($, commands),
      shape: pickShape(choice, columns, rows, list.length),
    })
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const list = await read($, runs)
    if (e.props.hasSurvey || list.length === 0 || !(await read($, isActive)) || (await read($, isDocked))) {
      return next(e)
    }

    return Band($.ui.resolve(e), list)
  })
}
