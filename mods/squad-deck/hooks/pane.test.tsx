import { expect, mock, test } from 'claude-code/testing'

const DIR = '/w/.squad/workers'
const FILES: Record<string, string> = {
  'deck-1-1.status': [
    'worker=deck-1', 'manager=manager-1', 'engine=opencode', 'model=opencode-go/glm-5.3', 'role=dev', 'state=running',
    'started=1100', 'tokens_in=12345', 'tokens_out=900', `log=${DIR}/deck-1-1.log`,
  ].join('\n'),
  'rev-1-1.status': [
    'worker=rev-1', 'manager=manager-1', 'engine=claude', 'model=sonnet', 'role=reviewer', 'state=completed',
    'started=1050', 'finished=1090', 'verify=pass', 'verdict=approved', 'title=Review the deck',
  ].join('\n'),
  'old-1-1.status': 'worker=old-1\nmanager=manager-1\nengine=claude\nstate=completed\nstarted=10\n',
  'bad-1-1.status': 'worker=bad-1\nmanager=manager-1\nstate=failed\nstarted=1060\nscope_violation=src/x.ts\n',
}
const LOG =
  '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/src/app.ts"}}]}}\n'

const PANE = {
  plugin: 'squad-deck',
  component: 'Pane',
  requestId: 'squad-deck',
  props: { title: 'squad', isFocused: false, placement: 'dock', scroll: { offset: 0, bodyRows: 40 }, view: {} },
} as const

// Each hook here stands for the engine beneath the mod.
type Calls = {
  tails: string[][]
  status: (string | undefined)[]
  opened: string[]
  closed: string[]
  opens: any[]
  isDocked: boolean
  seats: boolean
  rev: number // bumped when a status file changes, so its mtime moves
}
type Env = Record<string, string>
const SQUAD_ENV: Env = { SQUAD_DEVKIT_SESSION_START: '1000', SQUAD_DEVKIT_WORKSPACE: '/w' }

function engine(on: any, calls: Calls, files: Record<string, string> = FILES, env: Env = SQUAD_ENV, hasWorkersDir = false) {
  const clock = mock.clock(on, { now: 1_200_000 })
  on('ui.close', (_: unknown, e: any) => (calls.closed.push(e.id), (calls.isDocked = false), { value: undefined }))
  on('command.register', () => ({ value: { command: 'deck' } }))
  on('ui.open', (_: unknown, e: any) => {
    calls.opened.push(e.id)
    calls.opens.push(e)
    calls.isDocked = true

    return { value: { isPlaced: calls.seats } }
  })
  on('ui.panes', () => ({
    value: calls.isDocked
      ? [{ id: 'squad-deck', title: 'squad', isShown: true, isFocused: false, isPlaced: calls.seats }]
      : [],
  }))
  on('ui.status', (_: unknown, e: any) => (calls.status.push(e.text), { value: undefined }))
  on('session.start', (_: unknown, e: any) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: '/elsewhere' }))
  on('env.get', (_: unknown, e: any) => ({
    value: env[e.name as string],
  }))
  on('fs.stat', (_: unknown, e: any) => {
    if (hasWorkersDir && e.path === '/elsewhere/.squad/workers') {
      return { value: { kind: 'dir', size: 0, mtimeMs: 1, isLink: false } }
    }
    const name = String(e.path).split('/').pop() ?? ''
    if (String(e.path).startsWith('/w/.squad/plans/') && name in files) {
      return { value: { kind: 'file', size: 1, mtimeMs: 5, isLink: false } }
    }
    throw new Error('ENOENT')
  })
  on('fs.list', (_: unknown, e: any) => ({
    value: e.path === DIR || e.path === '/elsewhere/.squad/workers'
      ? Object.keys(files).map((name, i) => ({ name, kind: 'file', size: 1, mtimeMs: 100 + i + calls.rev, isLink: false }))
      : [],
  }))
  on('fs.read', (_: unknown, e: any) => ({ value: files[String(e.path).split('/').pop() ?? ''] ?? '' }))
  on('process.run', (_: unknown, e: any) => {
    calls.tails.push([...e.argv])
    return { value: { exitCode: 0, stdout: LOG, stderr: '' } }
  })
  const kept = new Map<string, unknown>()
  on('store.get', (_: unknown, e: any) => ({ value: kept.get(e.key) }))
  on('store.set', (_: unknown, e: any) => (kept.set(e.key, e.value), { value: undefined }))
  on('store.delete', (_: unknown, e: any) => (kept.delete(e.key), { value: undefined }))
  on('tool.check', (_: unknown, e: any) => ({ decision: e.tool === 'Bash' ? 'ask' : 'allow' }))
  on('tool.call', () => ({ result: {} }))

  return clock
}

async function boot(
  $: any,
  on: any,
  files: Record<string, string> = FILES,
  isDocked = true,
  env: Env = SQUAD_ENV,
  hasWorkersDir = false,
  seats = true,
) {
  const calls: Calls = { tails: [], status: [], opened: [], closed: [], opens: [], isDocked, seats, rev: 0 }
  const clock = engine(on, calls, files, env, hasWorkersDir)
  await $.session.start({ cwd: '/elsewhere', surface: 'terminal', isInteractive: true })

  return Object.assign(calls, { clock })
}

test('the deck reads this session\'s workers and observes the manager', async ($, on) => {
  const calls = await boot($, on)
  // Only the log of the running worker is read, and only its last 16 KB, without a shell.
  expect(calls.tails).toEqual([['tail', '-c', '16384', `${DIR}/deck-1-1.log`]])
  // old-1 started before the session; deck-1 runs, rev-1 is done, bad-1 failed.
  expect(calls.status.at(-1)).toBe('squad 1▶ 1✓ 1✗')

  const check = await $.tool.check({ tool: 'Bash', input: { command: 'ls' }, tool_use_id: 't1' })
  expect(check.decision).toBe('ask')
  expect((await $.tool.check({ tool: 'Read', input: {}, tool_use_id: 't2' })).decision).toBe('allow')
  await $.tool.call({ tool: 'Bash', command: 'GITHUB_TOKEN=hunter2value npm test' })
  await $.tool.call({ tool: 'Bash', command: 'curl -H "Authorization: Bearer abc123def456" x' })
  for (let i = 0; i < 6; i++) await $.tool.call({ tool: 'Bash', command: `echo ${i}` })

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal', props: { ...PANE.props, bodyColumns: 60 } })
  const drawn = JSON.stringify(await ui.drawn())
  expect(drawn).toContain('deck-1')
  expect(drawn).toContain('Edit /src/app.ts')
  expect(drawn).toContain('"12k"')
  expect(drawn).not.toContain('old-1')
  expect(drawn).not.toContain('hunter2value')
  expect(drawn).not.toContain('abc123def456')
  // The last five commands only: the two redacted ones scrolled out, echo 1..5 remain.
  expect(drawn).toContain('echo 5')
  expect(drawn).not.toContain('echo 0')
  expect(drawn).toContain('shell')
  await ui.unmount()
})

test('the secrets of a command are redacted in what the pane keeps', async ($, on) => {
  await boot($, on)
  await $.tool.call({ tool: 'Bash', command: 'GITHUB_TOKEN=hunter2value npm test' })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal', props: { ...PANE.props, bodyColumns: 60 } })
  const drawn = JSON.stringify(await ui.drawn())
  expect(drawn).toContain('GITHUB_TOKEN=***')
  expect(drawn).not.toContain('hunter2value')
  await ui.unmount()
})

test('the pane draws wide, compact and mini', async ($, on) => {
  await boot($, on)
  const draw = async (bodyColumns: number) => {
    const ui = await $.ui.mount({ ...PANE, surface: 'terminal', props: { ...PANE.props, bodyColumns } })
    const drawn = JSON.stringify(await ui.drawn())
    const cards = (await ui.findAll({ type: 'Text', text: /in \/ .* out/ })).length
    await ui.unmount()

    return { drawn, cards }
  }

  const wide = await draw(120)
  expect(wide.drawn).toContain('"width":"50%"')
  expect(wide.cards).toBe(3)

  const compact = await draw(60)
  expect(compact.drawn).not.toContain('"width":"50%"')
  expect(compact.cards).toBe(3)

  const mini = await draw(30)
  expect(mini.cards).toBe(0)
  expect(mini.drawn).toContain('deck-1')
  expect(mini.drawn).toContain('rev-1')
  expect(mini.drawn).toContain('bad-1')
})

test('with no workers the status line is cleared and the band stays out of the way', async ($, on) => {
  const calls = await boot($, on, {})
  expect(calls.tails).toEqual([])
  expect(calls.status.at(-1)).toBe(undefined)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal', props: { ...PANE.props, bodyColumns: 60 } })
  expect((await ui.find({ type: 'Text', text: /No squad workers/ }))?.text).toContain('No squad workers')
  await ui.unmount()
})

test('an idle squad session clears the status line on its first refresh', async ($, on) => {
  // A reload leaves the previous load's line on screen; the first refresh must clear it.
  const calls = await boot($, on, {})
  expect(calls.status).toEqual([undefined])
})

test('the band above the prompt shows the totals and the newest activity', async ($, on) => {
  await boot($, on, FILES, false, SQUAD_ENV, false, false)
  const band = await $.ui.mount({
    plugin: 'squad-deck',
    component: 'AbovePrompt',
    requestId: 'band',
    surface: 'terminal',
    props: { hasSurvey: false, isCollapsed: false, isWorking: false, maxRows: 6, bodyColumns: 80, scroll: { offset: 0, bodyRows: 6 } },
  } as any)
  expect((await band.find({ type: 'Text', text: /1 running.*1 done.*1 failed/ }))?.text).toBe('1 running · 1 done · 1 failed')
  expect(JSON.stringify(await band.drawn())).toContain(' 2/3 · ')
  expect((await band.find({ type: 'Text', text: /deck-1 · Edit/ }))?.text).toBe('deck-1 · Edit /src/app.ts')
  await band.unmount()
})

test('the elapsed time of a running worker follows the 2 s refresh', async ($, on) => {
  const { clock } = await boot($, on)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal', props: { ...PANE.props, bodyColumns: 60 } })
  expect((await ui.find({ type: 'Text', text: /1m 40s/ }))?.text).toContain('1m 40s')
  await clock.advance(60_000)
  expect((await ui.find({ type: 'Text', text: /2m 40s/ }))?.text).toContain('2m 40s')
  await ui.unmount()
})

test('/deck opens, closes and sets the layout', async ($, on) => {
  const calls = await boot($, on)
  const run = async (args: string) => (await $.command.run({ command: 'deck', args } as any)).text
  expect(await run('')).toBe('Squad deck opened.')
  expect(await run('layout mini')).toBe('Squad deck layout: mini.')
  expect(await run('layout huge')).toContain('Usage: /deck')
  expect(await run('close')).toBe('Squad deck closed.')
  expect(calls.opened.length).toBeGreaterThan(0)
  expect(calls.opens.every((one: any) => one.backgroundColor === 'transparent')).toBe(true)

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal', props: { ...PANE.props, bodyColumns: 120 } })
  expect((await ui.findAll({ type: 'Text', text: /in \/ .* out/ })).length).toBe(0)
  await ui.unmount()
})

test('a session that is not a squad session only gets /deck', async ($, on) => {
  const calls = await boot($, on, FILES, true, {})
  expect(calls.opened).toEqual([])
  expect(calls.status).toEqual([])
  expect(calls.tails).toEqual([])
  await $.tool.call({ tool: 'Bash', command: 'ls' })
  await calls.clock.advance(10_000)
  expect(calls.status).toEqual([])
  const band = await $.ui.mount({
    plugin: 'squad-deck',
    component: 'AbovePrompt',
    requestId: 'band',
    surface: 'terminal',
    props: { hasSurvey: false, isCollapsed: false, isWorking: false, maxRows: 6, bodyColumns: 80, scroll: { offset: 0, bodyRows: 6 } },
  } as any)
  expect(await band.find({ type: 'Text', text: /running/ })).toBeUndefined()
  await band.unmount()

  // /deck open still works there and starts the refresh on demand.
  const out = await $.command.run({ command: 'deck', args: 'open' } as any)
  expect(out.text).toBe('Squad deck opened.')
  expect(calls.opened).toEqual(['squad-deck'])
})

test('a .squad/workers folder in the session directory makes it a squad session', async ($, on) => {
  const calls = await boot($, on, FILES, false, { SQUAD_DEVKIT_SESSION_START: '1000' }, true)
  expect(calls.opened).toContain('squad-deck')
})

test('SQUAD_MANAGER_ID alone makes it a squad session', async ($, on) => {
  const calls = await boot($, on, FILES, false, {
    SQUAD_MANAGER_ID: 'manager-1',
    SQUAD_DEVKIT_SESSION_START: '1000',
  })
  expect(calls.opened).toContain('squad-deck')
})

// --- Per tab, and open only while work runs --------------------------------

const worker = (id: string, manager: string, state: string, started: number) =>
  `worker=${id}\nmanager=${manager}\nengine=claude\nstate=${state}\nstarted=${started}\n`
const drawPane = async ($: any) => {
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal', props: { ...PANE.props, bodyColumns: 60 } })
  const drawn = JSON.stringify(await ui.drawn())
  await ui.unmount()

  return drawn
}
const TWO = {
  'a-1-1.status': worker('a-1', 'manager-1', 'completed', 1100),
  'b-1-1.status': worker('b-1', 'manager-2', 'completed', 1100),
}

test('each tab shows only the runs of its own manager', async ($, on) => {
  await boot($, on, TWO, true, { ...SQUAD_ENV, SQUAD_MANAGER_ID: 'manager-1' })
  const mine = await drawPane($)
  expect(mine).toContain('a-1')
  expect(mine).not.toContain('b-1')
})

test('the other manager sees only its own run', async ($, on) => {
  await boot($, on, TWO, true, { ...SQUAD_ENV, SQUAD_MANAGER_ID: 'manager-2' })
  const theirs = await drawPane($)
  expect(theirs).toContain('b-1')
  expect(theirs).not.toContain('a-1')
})

test('without a manager id both managers\' runs show', async ($, on) => {
  await boot($, on, TWO, true, SQUAD_ENV)
  const both = await drawPane($)
  expect(both).toContain('a-1')
  expect(both).toContain('b-1')
})

test('the 30-run cap counts only this tab\'s runs', async ($, on) => {
  const files: Record<string, string> = { 'mine-1-1.status': worker('mine-1', 'manager-1', 'completed', 1100) }
  // The other tab's files sort newer, so a cap before the filter would drop mine-1.
  for (let i = 0; i < 40; i++) files[`z${i}-1-1.status`] = worker(`z${i}`, 'manager-2', 'completed', 1100)
  await boot($, on, files, true, { ...SQUAD_ENV, SQUAD_MANAGER_ID: 'manager-1' })
  expect(await drawPane($)).toContain('mine-1')
})

test('no pane opens at session start, and one opens once a run turns running', async ($, on) => {
  const files = { 'a-1-1.status': worker('a-1', 'manager-1', 'completed', 1100) }
  const calls = await boot($, on, files, false)
  expect(calls.opened).toEqual([])
  files['a-1-1.status'] = worker('a-1', 'manager-1', 'running', 1100)
  calls.rev += 1
  await calls.clock.advance(10_000)
  expect(calls.opened).toEqual(['squad-deck'])
  expect(calls.opens[0].backgroundColor).toBe('transparent')
  // Still running: no second open.
  await calls.clock.advance(10_000)
  expect(calls.opened).toEqual(['squad-deck'])
})

test('the pane closes 60 s after the last run stops, and the status line clears', async ($, on) => {
  const files = { 'a-1-1.status': worker('a-1', 'manager-1', 'running', 1100) }
  const calls = await boot($, on, files, false)
  expect(calls.opened).toEqual(['squad-deck'])
  files['a-1-1.status'] = worker('a-1', 'manager-1', 'completed', 1100)
  calls.rev += 1
  await calls.clock.advance(30_000)
  expect(calls.closed).toEqual([])
  expect(calls.status.at(-1)).toBe('squad 0▶ 1✓ 0✗')
  await calls.clock.advance(40_000)
  expect(calls.closed).toEqual(['squad-deck'])
  expect(calls.status.at(-1)).toBe(undefined)
})

test('a pane pinned by /deck open stays open when nothing runs', async ($, on) => {
  const files = { 'a-1-1.status': worker('a-1', 'manager-1', 'running', 1100) }
  const calls = await boot($, on, files, false)
  await $.command.run({ command: 'deck', args: 'open' } as any)
  files['a-1-1.status'] = worker('a-1', 'manager-1', 'completed', 1100)
  calls.rev += 1
  await calls.clock.advance(180_000)
  expect(calls.closed).toEqual([])
  // /deck close unpins and closes it.
  await $.command.run({ command: 'deck', args: 'close' } as any)
  expect(calls.closed).toEqual(['squad-deck'])
})

test('a pane the person closed reopens for a new run only', async ($, on) => {
  const files: Record<string, string> = { 'a-1-1.status': worker('a-1', 'manager-1', 'running', 1100) }
  const calls = await boot($, on, files, false)
  expect(calls.opened).toEqual(['squad-deck'])
  // The person's close mark: the pane is gone and this module did not close it.
  calls.isDocked = false
  await calls.clock.advance(20_000)
  expect(calls.opened).toEqual(['squad-deck'])
  files['b-1-1.status'] = worker('b-1', 'manager-1', 'running', 1150)
  calls.rev += 1
  await calls.clock.advance(10_000)
  expect(calls.opened).toEqual(['squad-deck', 'squad-deck'])
})

test('the band and the status line are hidden while nothing runs', async ($, on) => {
  const files = { 'a-1-1.status': worker('a-1', 'manager-1', 'completed', 1100) }
  const calls = await boot($, on, files, false, SQUAD_ENV, false, false)
  expect(calls.status.at(-1)).toBe(undefined)
  const band = await $.ui.mount({
    plugin: 'squad-deck',
    component: 'AbovePrompt',
    requestId: 'band',
    surface: 'terminal',
    props: { hasSurvey: false, isCollapsed: false, isWorking: false, maxRows: 6, bodyColumns: 80, scroll: { offset: 0, bodyRows: 6 } },
  } as any)
  expect(await band.find({ type: 'Text', text: /done/ })).toBeUndefined()
  await band.unmount()
})

const BARS = 'worker=a-1\nmanager=manager-1\nengine=claude\nstate=running\nstarted=1100\ntimeout_seconds=200\ntokens_in=100000\ntokens_out=20000\n'

test('a card shows the time bar and no token bar without a budget', async ($, on) => {
  await boot($, on, { 'a-1-1.status': BARS })
  const drawn = await drawPane($)
  expect(drawn).toContain('━')
  expect(drawn).toContain('1m/3m')
  expect(drawn).not.toContain('600k')
})

test('a card with a budget also shows the token bar', async ($, on) => {
  await boot($, on, { 'a-1-1.status': `${BARS}budget_tokens=600000\n` })
  expect(await drawPane($)).toContain('120k/600k')
})

test('a card shows the time % of its limit, and the token % beside a budget', async ($, on) => {
  // 100 s of 200 s; 120k of 600k tokens.
  await boot($, on, { 'a-1-1.status': `${BARS}budget_tokens=600000\n` })
  const drawn = await drawPane($)
  expect(drawn).toContain(' 50%')
  expect(drawn).toContain(' 20%')
})

test('a card without a timeout uses the 45-minute default', async ($, on) => {
  await boot($, on, { 'a-1-1.status': worker('a-1', 'manager-1', 'running', 1100) })
  const drawn = await drawPane($)
  expect(drawn).toContain('──────────')
  expect(drawn).toContain(' 3%')
  expect(drawn).toContain('1m/45m')
})

test('a finished card shows 100%', async ($, on) => {
  const done = `${worker('a-1', 'manager-1', 'completed', 1100)}finished=1150\ntimeout_seconds=200\n`
  await boot($, on, { 'a-1-1.status': done })
  expect(await drawPane($)).toContain(' 100%')
})

// --- Plan progress ----------------------------------------------------------

const PLAN_FILE = '# P\n## Tasks\n- dev-1 (x): a\n- dev-2: b\n- dev-3: c\n## Notes\n- late-1 (x)\n'
const planned = (id: string, state: string, plan: string, extra = '') =>
  `${worker(id, 'manager-1', state, 1100)}plan=${plan}\n${extra}`
const PLAN_ENV = { ...SQUAD_ENV, SQUAD_MANAGER_ID: 'manager-1' }
const mountBand = ($: any) =>
  $.ui.mount({
    plugin: 'squad-deck',
    component: 'AbovePrompt',
    requestId: 'band',
    surface: 'terminal',
    props: { hasSurvey: false, isCollapsed: false, isWorking: false, maxRows: 6, bodyColumns: 80, scroll: { offset: 0, bodyRows: 6 } },
  } as any)

test('an active plan draws a progress row, and the band shows the same figure', async ($, on) => {
  const files = {
    'sample.md': PLAN_FILE,
    'dev-1-1.status': planned('dev-1', 'completed', '/w/.squad/plans/sample.md', 'verify=pass\nfinished=1150\n'),
    'dev-2-1.status': planned('dev-2', 'completed', '/w/.squad/plans/sample.md', 'verify=fail\nfinished=1150\n'),
    'dev-3-1.status': planned('dev-3', 'running', '/w/.squad/plans/sample.md'),
  }
  await boot($, on, files, false, PLAN_ENV, false, false)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal', props: { ...PANE.props, bodyColumns: 60 } })
  const row = await ui.find({ type: 'Text', text: /1\/3 tasks · 33%/ })
  expect(row?.text).toContain('sample')
  expect(row?.text).toContain('█')
  await ui.unmount()
  const band = await mountBand($)
  expect(JSON.stringify(await band.drawn())).toContain(' 1/3 · 33% · ')
  await band.unmount()
})

test('a plan outside .squad/plans is ignored and its runs give the figure', async ($, on) => {
  const files = {
    'dev-1-1.status': planned('dev-1', 'completed', '/etc/sample.md', 'finished=1150\n'),
    'dev-2-1.status': planned('dev-2', 'running', '/etc/sample.md'),
  }
  await boot($, on, files, true, PLAN_ENV)
  expect(await drawPane($)).toContain('1/2 tasks · 50%')
})

test('a plan with no active run draws no row', async ($, on) => {
  const old = planned('dev-1', 'completed', '/w/.squad/plans/sample.md', 'finished=1000\n')
  await boot($, on, { 'sample.md': PLAN_FILE, 'dev-1-1.status': old }, true, PLAN_ENV)
  expect(await drawPane($)).not.toContain('tasks ·')
})

// --- Width ------------------------------------------------------------------

// /deck with the terminal's width as command.run reports it.
const deckRun = ($: any, args: string, columns = 160) =>
  $.command.run({ command: 'deck', args, presentation: { isFullscreen: true, columns } } as any)

test('the default dock is 30% of the terminal columns', async ($, on) => {
  const calls = await boot($, on, {})
  expect((await deckRun($, 'open', 160)).text).toBe('Squad deck opened.')
  expect(calls.opens.at(-1).columns).toBe(48)
  expect(calls.opens.at(-1).backgroundColor).toBe('transparent')
})

test('the default dock is clamped to 24 and 60 columns', async ($, on) => {
  const calls = await boot($, on, {})
  await deckRun($, 'open', 60)
  expect(calls.opens.at(-1).columns).toBe(24)
  await deckRun($, 'open', 300)
  expect(calls.opens.at(-1).columns).toBe(60)
})

test('the dock is 40 columns while the terminal width is not yet known', async ($, on) => {
  // The running worker opens the pane at session start, before any command or render.
  const calls = await boot($, on, FILES, false)
  expect(calls.opened).toEqual(['squad-deck'])
  expect(calls.opens[0].columns).toBe(40)
})

test('/deck width sets the dock, reopens it, and a bare /deck width resets it', async ($, on) => {
  const calls = await boot($, on, {})
  await deckRun($, 'open', 160)
  expect((await deckRun($, 'width 50')).text).toBe('Squad deck width: 50.')
  expect(calls.opens.at(-1).columns).toBe(50)
  expect((await deckRun($, 'width')).text).toBe('Squad deck width: default.')
  expect(calls.opens.at(-1).columns).toBe(48)
})

test('/deck width rejects values outside 24..120 and leaves a closed dock shut', async ($, on) => {
  const calls = await boot($, on, {}, false)
  expect((await deckRun($, 'width 10')).text).toContain('Usage: /deck width')
  expect((await deckRun($, 'width 121')).text).toContain('Usage: /deck width')
  expect((await deckRun($, 'width 50')).text).toBe('Squad deck width: 50.')
  expect(calls.opened).toEqual([])
})
