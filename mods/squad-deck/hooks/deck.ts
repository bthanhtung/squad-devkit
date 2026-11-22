// Pure helpers of the squad deck: parsing, redaction, formatting. No `$` here,
// so every function is testable on its own.

import type { Kind, Perms, PlanProgress, Run, Verdict } from '../types'

export type { Kind, Perms, PlanProgress, Run, Verdict }

export const MAX_RUNS = 30
export const TAIL_BYTES = 16384

// --- Cleaning -------------------------------------------------------------

const ANSI_CSI = /\u001b\[[0-?]*[ -/]*[@-~]/g
const ANSI_OSC = /\u001b\][^\u0007\u001b]*(?:\u0007|\u001b\\)?/g
const CONTROLS = /[\u0000-\u001f\u007f-\u009f​-‏‪-‮⁦-⁩﻿]/g

/** Removes ANSI sequences, control and bidi characters; whitespace runs become one space. */
export function strip(text: string): string {
  return text
    .replace(ANSI_OSC, '')
    .replace(ANSI_CSI, '')
    .replace(/[\t\r\n]+/g, ' ')
    .replace(CONTROLS, '')
}

const REDACTIONS: [RegExp, string][] = [
  [/-----BEGIN [A-Z0-9 ]+-----[\s\S]*?(?:-----END [A-Z0-9 ]+-----|$)/g, '***'],
  [/(authorization\s*[:=]\s*)(?:(?:bearer|basic|token)\s+)?[^\s'"]+/gi, '$1***'],
  [/\b(bearer\s+)[A-Za-z0-9._~+/=-]{6,}/gi, '$1***'],
  [
    /\b((?:[A-Za-z0-9]+[_-])*(?:token|key|secret|password|passwd))(=|:\s)("[^"]*"|'[^']*'|[^\s'"]+)/gi,
    '$1$2***',
  ],
  [/\bgh[pousr]_[A-Za-z0-9]{20,}/g, '***'],
  [/\bgithub_pat_[A-Za-z0-9_]{20,}/g, '***'],
  [/\bsk-[A-Za-z0-9_-]{16,}/g, '***'],
  [/\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/g, '***'],
  [/\bxox[bpas]-[A-Za-z0-9-]{10,}/g, '***'],
  [/\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*/g, '***'],
  [/(?<!\d)\d{8,10}:[A-Za-z0-9_-]{30,}/g, '***'],
  [/(\/\/[^\s:@/]+:)[^\s@/]+@/g, '$1***@'],
]

/** Replaces credentials a command or a log line may carry with `***`. */
export function redact(text: string): string {
  let out = text
  for (const [pattern, to] of REDACTIONS) out = out.replace(pattern, to)
  return out
}

/** Redacts first (a PEM block spans lines), then strips and shortens. */
export function clean(text: string, max = 120): string {
  const out = strip(redact(text)).trim()
  return out.length > max ? `${out.slice(0, max - 1)}…` : out
}

// --- Status files ---------------------------------------------------------

function count(value: string | undefined): number | null {
  return value !== undefined && /^\d{1,15}$/.test(value) ? Number(value) : null
}

/** Reads `key=value` lines; a missing or partial file yields what it has. */
export function parseFields(text: string): Record<string, string> {
  const fields: Record<string, string> = {}
  for (const line of text.split('\n')) {
    const at = line.indexOf('=')
    if (at < 1) continue
    const key = line.slice(0, at)
    if (/^[a-z_]{1,40}$/.test(key)) fields[key] = line.slice(at + 1).trim()
  }
  return fields
}

/** One status file as a Run, or null when it names no worker. */
export function parseStatus(text: string, fallbackId = ''): Run | null {
  const f = parseFields(text)
  const id = clean(f.worker || fallbackId, 40)
  if (id === '') return null
  const actual = f.actual_model && f.actual_model !== 'unknown' ? f.actual_model : f.model
  const word = (value: string | undefined, max: number, other = ''): string =>
    value !== undefined && new RegExp(`^[a-z_-]{1,${max}}$`).test(value) ? value : other
  return {
    id,
    manager: clean(f.manager ?? '', 40),
    engine: clean(f.engine ?? '', 20),
    model: clean(actual ?? '', 40),
    role: clean(f.role ?? '', 24),
    state: word(f.state, 20, 'unknown'),
    started: count(f.started) ?? 0,
    finished: count(f.finished),
    verify: word(f.verify, 20),
    verdict: word(f.verdict, 24),
    tokensIn: count(f.tokens_in),
    tokensOut: count(f.tokens_out),
    timeoutSeconds: count(f.timeout_seconds),
    budgetTokens: count(f.budget_tokens),
    plan: (f.plan ?? '').slice(0, 400),
    title: clean(f.title ?? '', 80),
    isScopeViolation: (f.scope_violation ?? '') !== '',
    log: f.log ?? '',
    activity: '',
  }
}

/** Runs of this session, the newest per worker id, running first then newest. */
export function pickRuns(runs: Run[], since: number): Run[] {
  const newest = new Map<string, Run>()
  for (const run of runs) {
    if (run.started < since) continue
    const seen = newest.get(run.id)
    if (seen === undefined || run.started >= seen.started) newest.set(run.id, run)
  }
  const rank = (run: Run) => (run.state === 'running' ? 0 : 1)

  return [...newest.values()].sort(
    (a, b) => rank(a) - rank(b) || b.started - a.started || a.id.localeCompare(b.id),
  )
}

// --- Activity -------------------------------------------------------------

const KEYS = ['file_path', 'filePath', 'path', 'command', 'pattern', 'url', 'description']

function shortInput(input: unknown): string {
  if (typeof input !== 'object' || input === null) return ''
  const fields = input as Record<string, unknown>
  for (const key of KEYS) {
    const value = fields[key]
    if (typeof value === 'string' && value !== '') {
      return key === 'command' ? clean(value, 60) : clean(value, 80)
    }
  }
  return ''
}

function label(tool: string, input: unknown): string {
  const name = clean(tool, 24)
  const rest = shortInput(input)
  return rest === '' ? name : `${name} ${rest}`
}

function textOf(value: unknown): string {
  return typeof value === 'string' ? clean(value, 100) : ''
}

/** What one JSON line shows, or '' when it shows nothing. */
function fromLine(line: unknown): string {
  if (typeof line !== 'object' || line === null) return ''
  const row = line as Record<string, any>
  // claude stream-json: an assistant message of content blocks.
  const blocks = row.type === 'assistant' ? row.message?.content : undefined
  if (Array.isArray(blocks)) {
    const use = [...blocks].reverse().find(b => b?.type === 'tool_use')
    if (use !== undefined) return label(String(use.name ?? 'tool'), use.input)
    const text = [...blocks].reverse().find(b => b?.type === 'text' && textOf(b.text) !== '')
    return text === undefined ? '' : textOf(text.text)
  }
  // opencode json: a part that is a tool or a text.
  const part = row.part
  if (typeof part === 'object' && part !== null) {
    if (part.type === 'tool') return label(String(part.tool ?? 'tool'), part.state?.input)
    if (part.type === 'text') return textOf(part.text)
  }
  return ''
}

// A line cut by the tail (or too long to parse) still names its tool.
function scrape(line: string): string {
  const tools = [...line.matchAll(/"(?:name|tool)":"([A-Za-z_][A-Za-z0-9_.-]{0,40})"/g)]
  const last = tools.at(-1)
  if (last === undefined) return ''
  const rest = line.slice((last.index ?? 0) + last[0].length)
  const arg = /"(?:file_path|filePath|path|command)":"((?:[^"\\]|\\.){1,200})/.exec(rest)
  return label(last[1] ?? 'tool', arg === null ? undefined : { path: arg[1] })
}

/**
 * The newest activity in the tail of a worker log: the last tool or text of a
 * claude or opencode JSON stream, else the last non-empty line.
 */
export function activity(tail: string): string {
  const lines = tail.split('\n').filter(line => line.trim() !== '')
  let fallback = ''
  for (let i = lines.length - 1; i >= 0 && i >= lines.length - 40; i--) {
    const line = lines[i] ?? ''
    if (line.startsWith('{')) {
      let parsed: unknown
      try {
        parsed = JSON.parse(line)
      } catch {
        // cut at either end: the first line of a tail, or one still being written
        const scraped = scrape(line)
        if (scraped !== '') return scraped
        continue
      }
      const shown = fromLine(parsed)
      if (shown !== '') return shown
    } else if (fallback === '') {
      fallback = clean(line, 100)
    }
  }
  return fallback
}

// --- Formatting -----------------------------------------------------------

function endOf(run: Run, now: number): number {
  return run.state === 'running' ? now : (run.finished ?? now)
}

export function elapsed(run: Run, now: number): string {
  const end = endOf(run, now)
  const seconds = Math.max(0, Math.round(end - run.started))
  if (run.started === 0) return ''
  if (seconds < 60) return `${seconds}s`
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ${String(seconds % 60).padStart(2, '0')}s`
  return `${Math.floor(seconds / 3600)}h ${String(Math.floor((seconds % 3600) / 60)).padStart(2, '0')}m`
}

/** A thin bar of `width` cells: `filled` then `empty`; fraction is clamped to [0, 1]. */
export function bar(fraction: number, width: number): { filled: string; empty: string } {
  const cells = Number.isFinite(width) ? Math.max(1, Math.floor(width)) : 1
  const share = Number.isFinite(fraction) ? Math.min(1, Math.max(0, fraction)) : 0
  const full = Math.round(share * cells)

  return { filled: '━'.repeat(full), empty: '─'.repeat(cells - full) }
}

const DEFAULT_LIMIT = 2700 // seconds: the worker default of 45 minutes
const SCOUT_LIMIT = 600 // a scout gets 10 minutes

/** The run's time limit in seconds: its own, else its role's default (old status files). */
export function timeLimit(run: Run): number {
  if (run.timeoutSeconds !== null && run.timeoutSeconds > 0) return run.timeoutSeconds
  return run.role === 'scout' ? SCOUT_LIMIT : DEFAULT_LIMIT
}

/** Time spent over the run's limit, or null when it has not started. Can exceed 1. */
export function timeFraction(run: Run, now: number): number | null {
  if (run.started === 0) return null
  return Math.max(0, endOf(run, now) - run.started) / timeLimit(run)
}

/** A fraction as a whole percent, held to 0..100; a finished run shows 100%. */
export function percent(fraction: number, isFinished = false): string {
  if (isFinished) return '100%'
  const share = Number.isFinite(fraction) ? Math.min(1, Math.max(0, fraction)) : 0

  return `${Math.floor(share * 100)}%`
}

/** Tokens used over the run's budget, or null without a budget. Can exceed 1. */
export function tokenFraction(run: Run): number | null {
  if (run.budgetTokens === null || run.budgetTokens === 0) return null
  return ((run.tokensIn ?? 0) + (run.tokensOut ?? 0)) / run.budgetTokens
}

export function tokens(n: number | null): string {
  if (n === null) return '–'
  if (n < 1000) return String(n)
  if (n < 1e6) return `${(n / 1000).toFixed(n < 1e4 ? 1 : 0).replace(/\.0$/, '')}k`
  return `${(n / 1e6).toFixed(1).replace(/\.0$/, '')}M`
}

export function summary(runs: Run[]) {
  const running = runs.filter(run => run.state === 'running').length
  const done = runs.filter(run => run.state === 'completed').length
  const failed = runs.filter(run => run.state === 'failed' || run.state === 'stopped').length

  return { running, done, failed }
}

export function statusText(runs: Run[]): string | undefined {
  if (runs.length === 0) return undefined
  const { running, done, failed } = summary(runs)

  return `squad ${running}▶ ${done}✓ ${failed}✗`
}

// --- Layout ---------------------------------------------------------------

export type Shape = 'wide' | 'compact' | 'mini'

/** The layout the pane draws: the person's choice, else what the room allows. */
export function pickShape(choice: string, columns: number, rows: number, workers: number): Shape {
  if (choice === 'wide' || choice === 'compact' || choice === 'mini') return choice
  if (columns < 36) return 'mini'
  const cardRows = 4 * workers + 4
  if (columns >= 110) return cardRows > rows * 2 ? 'mini' : 'wide'
  return cardRows > rows ? 'mini' : 'compact'
}

// --- Permissions ----------------------------------------------------------

const FILE_TOOLS = new Set(['Read', 'Edit', 'Write', 'MultiEdit', 'NotebookEdit', 'Glob', 'Grep'])
const SHELL_TOOLS = new Set(['Bash', 'BashOutput', 'KillShell', 'PowerShell'])

export function kindOf(tool: string): Kind {
  if (FILE_TOOLS.has(tool)) return 'file'
  return SHELL_TOOLS.has(tool) ? 'shell' : 'other'
}

export function emptyPerms(): Perms {
  const zero = () => ({ allow: 0, ask: 0, deny: 0 })

  return { file: zero(), shell: zero(), other: zero() }
}

export function addVerdict(perms: Perms, tool: string, decision: string): Perms {
  if (decision !== 'allow' && decision !== 'ask' && decision !== 'deny') return perms
  const kind = kindOf(tool)

  return { ...perms, [kind]: { ...perms[kind], [decision]: perms[kind][decision] + 1 } }
}

// --- Plans ----------------------------------------------------------------

const BULLET = /^- ([A-Za-z0-9._-]+)(?: \(|:)/
const HEADING = /^### ([A-Za-z0-9._-]+)(?:\s|:|$)/

/** True when `path` is a file below `<workspace>/.squad/plans/`, with no `..` in it. */
export function isPlanPath(path: string, workspace: string): boolean {
  const root = `${workspace.replace(/\/+$/, '')}/.squad/plans/`

  return path.startsWith(root) && path.length > root.length && !path.split('/').includes('..')
}

/** Task ids of a plan's `## Tasks` section: top-level `- id (`, `- id:` and `### id` lines. */
export function parsePlanTasks(text: string): string[] {
  const ids: string[] = []
  let inTasks = false
  for (const line of text.split('\n')) {
    if (line.startsWith('## ')) {
      inTasks = /^##\s+Tasks\s*$/i.test(line)
      continue
    }
    if (!inTasks) continue
    const id = (BULLET.exec(line) ?? HEADING.exec(line))?.[1]
    if (id !== undefined && id.toLowerCase() !== 'none' && !ids.includes(id)) ids.push(id)
  }

  return ids
}

/**
 * Done out of total for one plan. With task ids: an id is done when this tab has a completed
 * run of that worker whose verify did not fail. Without: the plan's own runs.
 */
export function planCounts(ids: string[], runs: Run[], planRuns: Run[]): { done: number; total: number } {
  if (ids.length === 0) {
    return { done: planRuns.filter(run => run.state === 'completed').length, total: planRuns.length }
  }
  const passed = new Set(
    runs.filter(run => run.state === 'completed' && run.verify !== 'fail').map(run => run.id),
  )

  return { done: ids.filter(id => passed.has(id)).length, total: ids.length }
}

/** `3/5 tasks · 60%`; the band passes an empty unit for `3/5 · 60%`. */
export function progressText(done: number, total: number, unit = ' tasks'): string {
  return `${done}/${total}${unit} · ${percent(total === 0 ? 0 : done / total, total > 0 && done >= total)}`
}
