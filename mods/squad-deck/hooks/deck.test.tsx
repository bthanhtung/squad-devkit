import { expect, test } from 'claude-code/testing'

import {
  activity,
  addVerdict,
  bar,
  clean,
  elapsed,
  emptyPerms,
  isPlanPath,
  parsePlanTasks,
  parseStatus,
  percent,
  pickRuns,
  pickShape,
  planCounts,
  progressText,
  redact,
  statusText,
  strip,
  timeFraction,
  timeLimit,
  tokenFraction,
  tokens,
} from './deck'

const STATUS = [
  'worker=deck-1',
  'manager=manager-2',
  'engine=opencode',
  'model=opencode-go/deepseek-v4-pro',
  'actual_model=unknown',
  'role=dev',
  'state=running',
  'started=1100',
  'tokens_in=12345',
  'tokens_out=900',
  'verify=pass',
  'verdict=approved',
  'title=## Goal: a deck',
  'scope_violation=',
  'log=/w/.squad/workers/deck-1-1.log',
  '',
].join('\n')

const status = (id: string, state: string, started: number, extra = '') =>
  `worker=${id}\nengine=claude\nmodel=sonnet\nrole=dev\nstate=${state}\nstarted=${started}\n${extra}`

// --- Status parsing -------------------------------------------------------

test('a complete status file is parsed', () => {
  const run = parseStatus(STATUS)
  expect(run?.id).toBe('deck-1')
  expect(run?.manager).toBe('manager-2')
  expect(run?.engine).toBe('opencode')
  expect(run?.model).toBe('opencode-go/deepseek-v4-pro')
  expect(run?.state).toBe('running')
  expect(run?.started).toBe(1100)
  expect(run?.tokensIn).toBe(12345)
  expect(run?.tokensOut).toBe(900)
  expect(run?.verify).toBe('pass')
  expect(run?.verdict).toBe('approved')
  expect(run?.isScopeViolation).toBe(false)
  expect(run?.finished).toBe(null)
})

test('a partial status file never throws and keeps what it has', () => {
  expect(parseStatus('')).toBe(null)
  expect(parseStatus('garbage\n=\n===x')).toBe(null)
  // No worker key: the file name stands in for the id.
  expect(parseStatus('state=runn', 'ag-02')?.id).toBe('ag-02')
  const run = parseStatus('worker=cut-1\nstate=completed\nstarted=12x\ntokens_in=')
  expect(run?.state).toBe('completed')
  expect(run?.started).toBe(0)
  expect(run?.tokensIn).toBe(null)
  expect(parseStatus('worker=x\nstate=BAD STATE\n')?.state).toBe('unknown')
})

test('the actual model wins over the requested one', () => {
  const run = parseStatus('worker=a\nmodel=sonnet\nactual_model=claude-sonnet-5-5\n')
  expect(run?.model).toBe('claude-sonnet-5-5')
})

test('a scope violation is flagged', () => {
  expect(parseStatus('worker=a\nscope_violation=src/x.ts\n')?.isScopeViolation).toBe(true)
})

test('only the newest status per worker is kept, running first', () => {
  const runs = [
    parseStatus(status('a', 'failed', 1100)),
    parseStatus(status('a', 'running', 1200)),
    parseStatus(status('b', 'completed', 1300)),
    parseStatus(status('c', 'completed', 1150)),
  ].filter(run => run !== null)
  const picked = pickRuns(runs, 0)
  expect(picked.map(run => `${run.id}:${run.state}`)).toEqual(['a:running', 'b:completed', 'c:completed'])
})

test('runs before the session start are filtered out', () => {
  const runs = [
    parseStatus(status('old', 'completed', 999)),
    parseStatus(status('edge', 'completed', 1000)),
    parseStatus(status('new', 'running', 1001)),
  ].filter(run => run !== null)
  expect(pickRuns(runs, 1000).map(run => run.id)).toEqual(['new', 'edge'])
})

// --- Activity -------------------------------------------------------------

const claudeLine = (content: unknown[]) => JSON.stringify({ type: 'assistant', message: { content } })

test('activity: the last tool_use of a claude stream-json tail', () => {
  const tail = [
    '{"type":"assistant","message":{"content":[{"type":"tex', // cut by the tail
    claudeLine([{ type: 'tool_use', name: 'Read', input: { file_path: '/a.ts' } }]),
    claudeLine([{ type: 'tool_use', name: 'Edit', input: { file_path: '/src/app.ts', old_string: 'x' } }]),
    JSON.stringify({ type: 'user', message: { content: [{ type: 'tool_result' }] } }),
    '',
  ].join('\n')
  expect(activity(tail)).toBe('Edit /src/app.ts')
})

test('activity: Bash commands are cut to 60 characters', () => {
  const command = `echo ${'x'.repeat(100)}`
  const shown = activity(claudeLine([{ type: 'tool_use', name: 'Bash', input: { command } }]))
  expect(shown.startsWith('Bash echo xxx')).toBe(true)
  expect(shown.length).toBe('Bash '.length + 60)
})

test('activity: the last text when there is no tool', () => {
  expect(activity(claudeLine([{ type: 'text', text: 'Running the tests now' }]))).toBe('Running the tests now')
})

test('activity: the last tool or text of an opencode tail', () => {
  const tool = JSON.stringify({
    type: 'tool_use',
    part: { type: 'tool', tool: 'read', state: { status: 'completed', input: { path: '/x/y.sh' }, output: 'big' } },
  })
  const text = JSON.stringify({ type: 'text', part: { type: 'text', text: 'Done reading' } })
  expect(activity(`${tool}\n`)).toBe('read /x/y.sh')
  expect(activity(`${tool}\n${text}\n`)).toBe('Done reading')
  expect(activity(`{"type":"step_start","part":{"type":"step-start"}}\n${tool}\n`)).toBe('read /x/y.sh')
})

test('activity: a line cut by the tail still names its tool', () => {
  const cut = '{"part":{"tool":"bash","state":{"input":{"command":"npm test"},"output":"aaaaaaaa'
  expect(activity(cut)).toBe('bash npm test')
})

test('activity: plain logs show the last non-empty line, cleaned', () => {
  expect(activity('first\n\x1b[32mgreen line\x1b[0m\n\n')).toBe('green line')
  expect(activity('')).toBe('')
})

// --- Cleaning and redaction ----------------------------------------------

test('ANSI sequences and control characters are stripped', () => {
  expect(strip('\x1b[31mred\x1b[0m \x1b]0;title\x07ok\x00\x07‮!')).toBe('red ok!')
  expect(clean('a\r\nb\tc')).toBe('a b c')
})

const GITHUB = `ghp_${'a1B2c3D4e5'.repeat(3)}`
const PAT = `github_pat_${'A1b2C3d4E5f6'.repeat(3)}`
const JWT = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r'
const TELEGRAM = '123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw_0'
const CASES: [string, string, string][] = [
  ['bearer', 'curl -H "Authorization: Bearer abc123def456"', 'abc123def456'],
  ['bearer alone', 'echo Bearer abcdef123456', 'abcdef123456'],
  ['basic auth header', "curl -H 'authorization: Basic dXNlcjpwYXNz'", 'dXNlcjpwYXNz'],
  ['_TOKEN=', 'GITHUB_TOKEN=hunter2value npm publish', 'hunter2value'],
  ['_KEY=', 'export STRIPE_KEY="s3cret value" && run', 's3cret value'],
  ['_SECRET=', 'CLIENT_SECRET=abc.def run', 'abc.def'],
  ['PASSWORD=', 'PASSWORD=p4ssw0rd mysql', 'p4ssw0rd'],
  ['ghp_', `git push https://x:${GITHUB}@github.com/a/b`, GITHUB],
  ['gho_', `echo gho_${'Zz9Yy8Xx7W'.repeat(3)}`, 'gho_Zz9Yy8Xx7W'],
  ['github_pat_', `echo ${PAT}`, PAT],
  ['sk-', 'echo sk-ant-api03-abcdefghijklmnop1234', 'sk-ant-api03'],
  ['AKIA', 'aws s3 ls AKIAIOSFODNN7EXAMPLE', 'AKIAIOSFODNN7EXAMPLE'],
  ['xoxb-', 'curl -d token=x xoxb-1234567890-abcdefghij', 'xoxb-1234567890'],
  ['xoxp-', 'echo xoxp-1234567890-abcdefghij', 'xoxp-1234567890'],
  ['JWT', `echo ${JWT}`, JWT.slice(0, 20)],
  ['PEM', 'echo "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA\n-----END RSA PRIVATE KEY-----"', 'MIIEowIBAAKCAQEA'],
  ['telegram', `curl https://api.telegram.org/bot${TELEGRAM}/getMe`, TELEGRAM],
  ['url credentials', 'git clone https://me:hunter2@host/r.git', 'hunter2'],
]

for (const [name, input, secret] of CASES) {
  test(`redaction: ${name}`, () => {
    const out = redact(input)
    expect(out.includes(secret)).toBe(false)
    expect(out).toContain('***')
    expect(clean(input, 400).includes(secret)).toBe(false)
  })
}

test('redaction leaves ordinary commands alone', () => {
  const plain = 'git status --short && ls -la src/monkey.ts tokens_in=5'
  expect(redact(plain)).toBe(plain)
})

// --- Formatting and layout -----------------------------------------------

test('elapsed, tokens and the status line text', () => {
  const run = parseStatus(status('a', 'running', 1000))!
  expect(elapsed(run, 1042)).toBe('42s')
  expect(elapsed(run, 1000 + 3 * 60 + 5)).toBe('3m 05s')
  const done = parseStatus(status('a', 'completed', 1000, 'finished=1090\n'))!
  expect(elapsed(done, 99999)).toBe('1m 30s')
  expect([tokens(null), tokens(950), tokens(1234), tokens(48000), tokens(2_500_000)]).toEqual([
    '–',
    '950',
    '1.2k',
    '48k',
    '2.5M',
  ])
  expect(statusText([])).toBe(undefined)
  const runs = [
    parseStatus(status('a', 'running', 1)),
    parseStatus(status('b', 'running', 1)),
    parseStatus(status('c', 'completed', 1)),
    parseStatus(status('d', 'failed', 1)),
    parseStatus(status('e', 'stopped', 1)),
  ].filter(run => run !== null)
  expect(statusText(runs)).toBe('squad 2▶ 1✓ 2✗')
})

test('the layout follows the width unless the person chose one', () => {
  expect(pickShape('auto', 120, 40, 4)).toBe('wide')
  expect(pickShape('auto', 60, 40, 4)).toBe('compact')
  expect(pickShape('auto', 30, 40, 1)).toBe('mini')
  expect(pickShape('auto', 60, 10, 6)).toBe('mini')
  expect(pickShape('mini', 120, 40, 1)).toBe('mini')
  expect(pickShape('wide', 40, 40, 1)).toBe('wide')
})

test('permission verdicts are counted per kind', () => {
  let perms = emptyPerms()
  perms = addVerdict(perms, 'Read', 'allow')
  perms = addVerdict(perms, 'Edit', 'ask')
  perms = addVerdict(perms, 'Bash', 'deny')
  perms = addVerdict(perms, 'mcp__x__y', 'allow')
  perms = addVerdict(perms, 'Bash', 'nonsense')
  expect(perms.file).toEqual({ allow: 1, ask: 1, deny: 0 })
  expect(perms.shell).toEqual({ allow: 0, ask: 0, deny: 1 })
  expect(perms.other).toEqual({ allow: 1, ask: 0, deny: 0 })
})

test('bar clamps and rounds', () => {
  const cells = (f: number, w: number) => {
    const { filled, empty } = bar(f, w)
    return `${filled}|${empty}`
  }
  expect(cells(0, 4)).toBe('|────')
  expect(cells(0.5, 4)).toBe('━━|──')
  expect(cells(1, 4)).toBe('━━━━|')
  expect(cells(1.7, 4)).toBe('━━━━|')
  expect(cells(-1, 4)).toBe('|────')
  expect(cells(Number.NaN, 4)).toBe('|────')
  expect(cells(Infinity, 4)).toBe('|────')
  expect(cells(0.9, 1)).toBe('━|')
  expect(cells(0.2, 1)).toBe('|─')
})

test('timeout and budget are parsed, and null when missing or garbage', () => {
  const run = parseStatus(status('a', 'running', 1000, 'timeout_seconds=2700\nbudget_tokens=600000\n'))!
  expect(run.timeoutSeconds).toBe(2700)
  expect(run.budgetTokens).toBe(600000)
  const none = parseStatus(status('a', 'running', 1000))!
  expect(none.timeoutSeconds).toBe(null)
  expect(none.budgetTokens).toBe(null)
  const bad = parseStatus(status('a', 'running', 1000, 'timeout_seconds=soon\nbudget_tokens=-5\n'))!
  expect(bad.timeoutSeconds).toBe(null)
  expect(bad.budgetTokens).toBe(null)
})

test('timeFraction and tokenFraction', () => {
  const run = parseStatus(status('a', 'running', 1000, 'timeout_seconds=1000\nbudget_tokens=2000\ntokens_in=500\ntokens_out=500\n'))!
  expect(timeFraction(run, 1250)).toBe(0.25)
  expect(tokenFraction(run)).toBe(0.5)
  const done = parseStatus(status('a', 'completed', 1000, 'finished=1500\ntimeout_seconds=1000\n'))!
  expect(timeFraction(done, 99999)).toBe(0.5)
  const bare = parseStatus(status('a', 'running', 1000))!
  expect(timeFraction(bare, 1250)).toBe(250 / 2700)
  expect(tokenFraction(bare)).toBe(null)
  const unstarted = parseStatus('worker=a\nstate=running\ntimeout_seconds=60\nbudget_tokens=0\n')!
  expect(timeFraction(unstarted, 1250)).toBe(null)
  expect(tokenFraction(unstarted)).toBe(null)
})

test('the time limit falls back to 45 minutes, or 10 for a scout, and the % text follows', () => {
  const old = parseStatus(status('a', 'running', 1000))!
  expect(timeLimit(old)).toBe(2700)
  expect(timeLimit(parseStatus(status('a', 'running', 1000, 'timeout_seconds=300\n'))!)).toBe(300)
  const scout = parseStatus('worker=s\nrole=scout\nstate=running\nstarted=1000\n')!
  expect(timeLimit(scout)).toBe(600)
  expect(percent(timeFraction(scout, 1300)!)).toBe('50%')
  expect(percent(timeFraction(old, 1000 + 1350)!)).toBe('50%')
  expect(percent(timeFraction(old, 1000 + 99999)!)).toBe('100%')
  expect(percent(0.42)).toBe('42%')
  expect(percent(0.2, true)).toBe('100%')
  expect(percent(Number.NaN)).toBe('0%')
})

const PLAN = [
  '# Plan',
  '## Goal',
  '- not-a-task (in goal)',
  '## Tasks',
  '- dev-1 (opencode): first',
  '  - nested-1 (x)',
  '- dev-2: second',
  '- None',
  '- None: nothing',
  '### test-1',
  '### rev.2 — review',
  '- dev-1 (again)',
  '## Notes',
  '- late-1 (after)',
].join('\n')

test('plan tasks come from bullets and ### headings of the Tasks section', () => {
  expect(parsePlanTasks(PLAN)).toEqual(['dev-1', 'dev-2', 'test-1', 'rev.2'])
  expect(parsePlanTasks('## Tasks\nNone\n- None\n')).toEqual([])
  expect(parsePlanTasks('# Only a title')).toEqual([])
})

test('a plan path must be a file under the workspace plans folder', () => {
  expect(isPlanPath('/w/.squad/plans/a.md', '/w')).toBe(true)
  expect(isPlanPath('/w/.squad/plans/a.md', '/w/')).toBe(true)
  expect(isPlanPath('/w/.squad/plans/', '/w')).toBe(false)
  expect(isPlanPath('/etc/passwd', '/w')).toBe(false)
  expect(isPlanPath('/w/.squad/plans/../../secret', '/w')).toBe(false)
  expect(isPlanPath('/other/.squad/plans/a.md', '/w')).toBe(false)
})

test('done counting skips failed verification and falls back to the plan runs', () => {
  const runs = [
    parseStatus(status('dev-1', 'completed', 1, 'verify=pass\n'))!,
    parseStatus(status('dev-2', 'completed', 1, 'verify=fail\n'))!,
    parseStatus(status('test-1', 'running', 1))!,
    parseStatus(status('x-1', 'completed', 1))!,
  ]
  expect(planCounts(['dev-1', 'dev-2', 'test-1', 'rev.2'], runs, runs)).toEqual({ done: 1, total: 4 })
  expect(planCounts([], runs, runs.slice(0, 3))).toEqual({ done: 2, total: 3 })
})

test('progress text for the plan rows and the band', () => {
  expect(progressText(3, 5)).toBe('3/5 tasks · 60%')
  expect(progressText(3, 5, '')).toBe('3/5 · 60%')
  expect(progressText(5, 5)).toBe('5/5 tasks · 100%')
  expect(progressText(0, 0)).toBe('0/0 tasks · 0%')
})
