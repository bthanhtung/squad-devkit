// Pure helpers of the squad deck: parsing, redaction, formatting. No `$` here,
// so every function is testable on its own.

import type { Kind, Perms, Run as BaseRun, Verdict } from '../types'

export type { Kind, Perms, Verdict }
export type Run = BaseRun & { worktree?: string; merged?: boolean; discarded?: boolean; reason?: string }

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
    title: clean(f.title ?? '', 120),
    reason: clean(f.reason ?? '', 100),
    isScopeViolation: (f.scope_violation ?? '') !== '',
    log: f.log ?? '',
    activity: '',
    worktree: f.worktree ?? '',
    merged: (f.merged ?? '') !== '',
    discarded: (f.discarded ?? '') !== '',
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

/** Actionable latest runs, ordered by urgency and recency. */
export function needsYou(runs: Run[]) {
  const items: { run: Run; kind: 'failed' | 'verify' | 'merge'; reason: string; action: string }[] = []
  for (const run of pickRuns(runs, 0)) {
    if (run.state === 'running') continue
    if (['failed', 'stopped', 'lost', 'timeout', 'error'].includes(run.state)) {
      const detail = run.reason ? `: ${run.reason}` : ''
      items.push({
        run,
        kind: 'failed',
        reason: `worker ${run.state}${detail}`,
        action: `Say: inspect & rerun ${run.id}, or discard`,
      })
    } else if (run.verify === 'fail' || run.verify === 'timeout') {
      const reason = run.verify === 'timeout' ? 'verify timed out' : 'verify failed'
      const hint =
        run.verify === 'timeout'
          ? `Say: inspect/rerun verify ${run.id}, or discard`
          : `Say: fix ${run.id}, or discard`
      items.push({ run, kind: 'verify', reason, action: hint })
    } else if (run.state === 'completed' && !!run.worktree && !run.merged && !run.discarded) {
      items.push({
        run,
        kind: 'merge',
        reason: 'ready to merge',
        action: `Say: review & merge ${run.id} (or --merge ${run.id})`,
      })
    }
  }
  const rank = { failed: 0, verify: 1, merge: 2 }
  return items.sort((a, b) => rank[a.kind] - rank[b.kind] || b.run.started - a.run.started || a.run.id.localeCompare(b.run.id))
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

export function elapsed(run: Run, now: number): string {
  const end = run.state === 'running' ? now : (run.finished ?? now)
  const seconds = Math.max(0, Math.round(end - run.started))
  if (run.started === 0) return ''
  if (seconds < 60) return `${seconds}s`
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ${String(seconds % 60).padStart(2, '0')}s`
  return `${Math.floor(seconds / 3600)}h ${String(Math.floor((seconds % 3600) / 60)).padStart(2, '0')}m`
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
