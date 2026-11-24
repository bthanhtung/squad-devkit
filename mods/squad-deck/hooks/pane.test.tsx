import { expect, mock, test } from 'claude-code/testing'

const DIR = '/w/.squad/workers'
const FILES: Record<string, string> = {
  'deck-1-1.status': [
    'worker=deck-1', 'engine=opencode', 'model=opencode-go/glm-5.3', 'role=dev', 'state=running',
    'started=1100', 'tokens_in=12345', 'tokens_out=900', `log=${DIR}/deck-1-1.log`,
  ].join('\n'),
  'rev-1-1.status': [
    'worker=rev-1', 'engine=claude', 'model=sonnet', 'role=reviewer', 'state=completed',
    'started=1050', 'finished=1090', 'verify=pass', 'verdict=approved', 'title=Review the deck',
  ].join('\n'),
  'old-1-1.status': 'worker=old-1\nengine=claude\nstate=completed\nstarted=10\n',
  'bad-1-1.status': 'worker=bad-1\nstate=failed\nstarted=1060\nscope_violation=src/x.ts\n',
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
type Calls = { tails: string[][]; status: (string | undefined)[]; opened: string[]; isDocked: boolean }
type Env = Record<string, string>
const SQUAD_ENV: Env = { SQUAD_DEVKIT_SESSION_START: '1000', SQUAD_DEVKIT_WORKSPACE: '/w' }

function engine(on: any, calls: Calls, files = FILES, env: Env = SQUAD_ENV, hasWorkersDir = false) {
  const clock = mock.clock(on, { now: 1_200_000 })
  on('ui.close', () => ({ value: undefined }))
  on('command.register', () => ({ value: { command: 'deck' } }))
  on('ui.open', (_: unknown, e: any) => (calls.opened.push(e.id), { value: { isPlaced: true } }))
  on('ui.panes', () => ({
    value: calls.isDocked
      ? [{ id: 'squad-deck', title: 'squad', isShown: true, isFocused: false, isPlaced: true }]
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
    throw new Error('ENOENT')
  })
  on('fs.list', (_: unknown, e: any) => ({
    value: e.path === DIR
      ? Object.keys(files).map((name, i) => ({ name, kind: 'file', size: 1, mtimeMs: 100 + i, isLink: false }))
      : [],
  }))
  on('fs.read', (_: unknown, e: any) => ({ value: files[String(e.path).split('/').pop() ?? ''] ?? '' }))
  on('process.run', (_: unknown, e: any) => {
    calls.tails.push([...e.argv])
    return { value: { exitCode: 0, stdout: LOG, stderr: '' } }
  })
  on('tool.check', (_: unknown, e: any) => ({ decision: e.tool === 'Bash' ? 'ask' : 'allow' }))
  on('tool.call', () => ({ result: {} }))

  return clock
}

async function boot($: any, on: any, files = FILES, isDocked = true, env: Env = SQUAD_ENV, hasWorkersDir = false) {
  const calls: Calls = { tails: [], status: [], opened: [], isDocked }
  const clock = engine(on, calls, files, env, hasWorkersDir)
  await $.session.start({ cwd: '/elsewhere', surface: 'terminal', isInteractive: true })

  return { ...calls, clock }
}

test('the deck reads this session\'s workers, observes the manager and opens its pane', async ($, on) => {
  const calls = await boot($, on)
  expect(calls.opened).toContain('squad-deck')
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

test('the band above the prompt shows the totals and the newest activity', async ($, on) => {
  await boot($, on, FILES, false)
  const band = await $.ui.mount({
    plugin: 'squad-deck',
    component: 'AbovePrompt',
    requestId: 'band',
    surface: 'terminal',
    props: { hasSurvey: false, isCollapsed: false, isWorking: false, maxRows: 6, bodyColumns: 80, scroll: { offset: 0, bodyRows: 6 } },
  } as any)
  expect((await band.find({ type: 'Text', text: /1 running.*1 done.*1 failed/ }))?.text).toBe('1 running · 1 done · 1 failed')
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
  expect(calls.opened.length).toBeGreaterThan(1)

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
  const calls = await boot($, on, FILES, true, {}, true)
  expect(calls.opened).toContain('squad-deck')
})

test('SQUAD_MANAGER_ID alone makes it a squad session', async ($, on) => {
  const calls = await boot($, on, FILES, true, { SQUAD_MANAGER_ID: 'manager-1' })
  expect(calls.opened).toContain('squad-deck')
})

test('needs you is shown for actionable runs and hidden when empty', async ($, on) => {
  await boot($, on, FILES)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal', props: { ...PANE.props, bodyColumns: 80 } })
  const drawn = JSON.stringify(await ui.drawn())
  expect(drawn).toContain('Needs you (1)')
  expect(drawn).toContain('worker failed')
  expect(drawn).toContain('Say: inspect & rerun')
  await ui.unmount()
})

test('needs you is hidden when no runs need attention', async ($, on) => {
  await boot($, on, { 'ok.status': 'worker=ok\nstate=completed\nstarted=1100\n' })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal', props: { ...PANE.props, bodyColumns: 80 } })
  expect(JSON.stringify(await ui.drawn())).not.toContain('Needs you')
  await ui.unmount()
})
