import { expect, test } from 'claude-code/testing'

import {
  activity,
  addVerdict,
  clean,
  elapsed,
  emptyPerms,
  parseStatus,
  pickRuns,
  pickShape,
  redact,
  statusText,
  strip,
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
