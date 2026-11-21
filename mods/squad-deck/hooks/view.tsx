// The deck's drawing: calm, one accent, dim secondary text. Every function
// takes the surface's element table (`$.ui.resolve(e)`) and plain data.
import { elapsed, summary, tokens } from './deck'
import type { Kind, Perms, Run, Shape } from './deck'

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

function Card({ Box, Text }: Ui, run: Run, now: number) {
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

export function Deck(
  ui: Ui,
  data: { runs: Run[]; now: number; perms: Perms; commands: string[]; shape: Shape },
) {
  const { Box, Text } = ui
  const { runs, now, perms, commands, shape } = data
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

export function Band({ Box, Text }: Ui, runs: Run[]) {
  const newest = runs.find(run => run.state === 'running' && run.activity !== '')

  return (
    <Box flexDirection="column">
      <Box>
        <Text dimColor>squad: </Text>
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
