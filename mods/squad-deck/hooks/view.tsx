// The deck's drawing: calm, one accent, dim secondary text. Every function
// takes the surface's element table (`$.ui.resolve(e)`) and plain data.
import { bar, elapsed, percent, progressText, summary, timeFraction, timeLimit, tokenFraction, tokens } from './deck'
import type { Kind, Perms, PlanProgress, Run, Shape } from './deck'

type Ui = { Box: any; Text: any }

const ACCENT = 'suggestion'
const KINDS: Kind[] = ['file', 'shell', 'other']

function tone(run: Run): string | undefined {
  if (run.isScopeViolation) return 'warning'
  if (run.state === 'running') return ACCENT
  if (run.state === 'completed') return 'success'
  if (run.state === 'failed' || run.state === 'stopped') return 'error'
  return undefined
}

function isFinished(run: Run): boolean {
  return run.state === 'completed' || run.state === 'failed' || run.state === 'stopped'
}

// Accent until 80 %, warning from 80 %, error from 95 %; a finished run keeps its own tone.
function barTone(run: Run, fraction: number): string | undefined {
  if (isFinished(run)) return tone(run)
  if (fraction >= 0.95) return 'error'
  return fraction >= 0.8 ? 'warning' : ACCENT
}

function Bar({ Text }: Ui, fraction: number, width: number, color: string | undefined) {
  const { filled, empty } = bar(fraction, width)

  return (
    <Text>
      <Text color={color}>{filled}</Text>
      <Text dimColor>{empty}</Text>
    </Text>
  )
}

function Bars(ui: Ui, run: Run, now: number) {
  const { Text } = ui
  const time = timeFraction(run, now)
  const used = tokenFraction(run)
  if (time === null && used === null) return null

  return (
    <Text wrap="truncate-end">
      {'  '}
      {time !== null && Bar(ui, time, 10, barTone(run, time))}
      {time !== null && <Text color={barTone(run, time)}>{` ${percent(time, isFinished(run))}`}</Text>}
      {time !== null && (
        <Text dimColor>{` ${Math.floor((time * timeLimit(run)) / 60)}m/${Math.round(timeLimit(run) / 60)}m`}</Text>
      )}
      {time !== null && used !== null && '  '}
      {used !== null && Bar(ui, used, 10, barTone(run, used))}
      {used !== null && <Text color={barTone(run, used)}>{` ${percent(used, isFinished(run))}`}</Text>}
      {used !== null && (
        <Text dimColor>{` ${tokens((run.tokensIn ?? 0) + (run.tokensOut ?? 0))}/${tokens(run.budgetTokens)}`}</Text>
      )}
    </Text>
  )
}

function word(run: Run): string {
  return run.state === 'completed' ? 'done' : run.state
}

function checkTone(value: string): string | undefined {
  if (value === 'pass' || value === 'approved') return 'success'
  if (value === 'fail' || value === 'timeout') return 'error'
  return value === 'changes_requested' ? 'warning' : undefined
}

function detail(run: Run): string {
  return run.state === 'running' ? run.activity : run.title
}

function Card(ui: Ui, run: Run, now: number) {
  const { Box, Text } = ui
  const color = tone(run)
  const spent = elapsed(run, now)

  return (
    <Box key={run.id} flexDirection="column" marginBottom={1}>
      <Text wrap="truncate-end">
        <Text color={color}>● {word(run)} </Text>
        <Text bold>{run.id}</Text>
        <Text dimColor>
          {' '}
          {[[run.engine, run.model].filter(Boolean).join('·'), run.role].filter(Boolean).join('  ')}
        </Text>
      </Text>
      <Text wrap="truncate-end" dimColor>
        {'  '}
        {spent === '' ? '' : `${spent} · `}
        {tokens(run.tokensIn)} in / {tokens(run.tokensOut)} out
        {run.isScopeViolation ? ' · ' : ''}
        {run.isScopeViolation && <Text color="warning">scope violation</Text>}
        {run.verify !== '' && <Text dimColor> · verify </Text>}
        {run.verify !== '' && <Text color={checkTone(run.verify)}>{run.verify}</Text>}
        {run.verdict !== '' && <Text dimColor> · </Text>}
        {run.verdict !== '' && <Text color={checkTone(run.verdict)}>{run.verdict}</Text>}
      </Text>
      {Bars(ui, run, now)}
      <Text wrap="truncate-end" dimColor>
        {'  '}
        {detail(run)}
      </Text>
    </Box>
  )
}

function MiniRow({ Box, Text }: Ui, run: Run, now: number) {
  return (
    <Box key={run.id}>
      <Text wrap="truncate-end">
        <Text color={tone(run)}>● </Text>
        <Text bold>{run.id}</Text>
        <Text dimColor>
          {' '}
          {elapsed(run, now)} {detail(run)}
        </Text>
      </Text>
    </Box>
  )
}

export function Totals({ Text }: Ui, runs: Run[]) {
  const { running, done, failed } = summary(runs)

  return (
    <Text wrap="truncate-end">
      <Text color={ACCENT}>{running} running</Text>
      <Text dimColor> · </Text>
      <Text color="success">{done} done</Text>
      <Text dimColor> · </Text>
      <Text color={failed > 0 ? 'error' : undefined} dimColor={failed === 0}>
        {failed} failed
      </Text>
    </Text>
  )
}

export function Chips({ Text }: Ui, perms: Perms) {
  const parts = KINDS.filter(kind => perms[kind].allow + perms[kind].ask + perms[kind].deny > 0)
  if (parts.length === 0) return <Text dimColor>No permission checks yet.</Text>

  return (
    <Text wrap="truncate-end">
      {parts.map((kind, i) => (
        <Text>
          {i > 0 && <Text dimColor> · </Text>}
          <Text dimColor>{kind} </Text>
          <Text color="success">{perms[kind].allow}✓</Text>
          {perms[kind].ask > 0 && <Text color="warning"> {perms[kind].ask}?</Text>}
          {perms[kind].deny > 0 && <Text color="error"> {perms[kind].deny}✗</Text>}
        </Text>
      ))}
    </Text>
  )
}

// One row per active plan: `name  ██████░░░░  3/5 tasks · 60%`.
export function PlanRows({ Box, Text }: Ui, plans: PlanProgress[]) {
  return plans.map(plan => {
    const isComplete = plan.total > 0 && plan.done >= plan.total
    const cells = Math.round((plan.total === 0 ? 0 : Math.min(1, plan.done / plan.total)) * 10)

    return (
      <Box key={`plan-${plan.name}`}>
        <Text wrap="truncate-end">
          <Text bold>{plan.name}</Text>
          <Text color={isComplete ? 'success' : ACCENT}>{`  ${'█'.repeat(cells)}`}</Text>
          <Text dimColor>{'░'.repeat(10 - cells)}</Text>
          <Text color={isComplete ? 'success' : ACCENT}>{`  ${progressText(plan.done, plan.total)}`}</Text>
        </Text>
      </Box>
    )
  })
}

export function Deck(
  ui: Ui,
  data: { runs: Run[]; now: number; perms: Perms; commands: string[]; plans: PlanProgress[]; shape: Shape },
) {
  const { Box, Text } = ui
  const { runs, now, perms, commands, plans, shape } = data
  const rows =
    shape === 'mini'
      ? runs.map(run => MiniRow(ui, run, now))
      : runs.map(run => Card(ui, run, now))
  // Wide: two columns, in reading order.
  const body =
    shape === 'wide'
      ? Array.from({ length: Math.ceil(rows.length / 2) }, (_, i) => (
          <Box key={`pair-${i}`} flexDirection="row" gap={2}>
            <Box width="50%">{rows[2 * i]}</Box>
            {rows[2 * i + 1] !== undefined && <Box width="50%">{rows[2 * i + 1]}</Box>}
          </Box>
        ))
      : rows

  return (
    <Box flexDirection="column">
      {runs.length === 0 ? (
        <Text dimColor>No squad workers in this session yet.</Text>
      ) : (
        <Box flexDirection="column">
          {Totals(ui, runs)}
          {plans.length > 0 && <Box flexDirection="column">{PlanRows(ui, plans)}</Box>}
          <Box flexDirection="column" marginTop={1}>
            {body}
          </Box>
        </Box>
      )}
      {Chips(ui, perms)}
      {commands.length > 0 && (
        <Box flexDirection="column" marginTop={1}>
          <Text dimColor>last commands</Text>
          {commands.map((command, i) => (
            <Text key={`cmd-${i}`} wrap="truncate-end" dimColor>
              {'  '}$ {command}
            </Text>
          ))}
        </Box>
      )}
    </Box>
  )
}

export function Band({ Box, Text }: Ui, runs: Run[], plan?: PlanProgress) {
  const newest = runs.find(run => run.state === 'running' && run.activity !== '')
  const finished = runs.filter(isFinished).length

  return (
    <Box flexDirection="column">
      <Box>
        <Text dimColor>squad: </Text>
        {Bar({ Box, Text }, (plan?.done ?? finished) / Math.max(1, plan?.total ?? runs.length), 8, ACCENT)}
        <Text dimColor>{` ${plan === undefined ? `${finished}/${runs.length}` : progressText(plan.done, plan.total, '')} · `}</Text>
        {Totals({ Box, Text }, runs)}
      </Box>
      {newest !== undefined && (
        <Text wrap="truncate-end" dimColor>
          {newest.id} · {newest.activity}
        </Text>
      )}
    </Box>
  )
}
