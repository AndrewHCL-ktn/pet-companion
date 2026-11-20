import { expect, test } from 'claude-code/testing'

const PANE = {
  plugin: 'pet-companion',
  component: 'Pane',
  requestId: 'pet-companion',
  props: {
    title: 'Claude娘',
    isFocused: false,
    bodyColumns: 44,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 40 },
    view: {},
  },
} as const

// a 1x1 transparent PNG
const PNG =
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='

declare const setTimeout: (f: (v?: unknown) => void, ms: number) => unknown

let spawned: string[][] = []
let writes: unknown[] = []

const stubEngine = (on: any) => {
  spawned = []
  writes = []
  on('command.register', () => ({ value: { command: 'pet' } }))
  on('clock.now', () => ({ value: 1_000_000 }))
  on('clock.after', () => ({ value: {} }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.status', () => ({ value: undefined }))
  on('ui.log', () => ({ value: undefined }))
  on('store.get', () => ({ value: undefined }))
  on('store.set', () => ({ value: undefined }))
  on('fs.read', () => ({ value: { base64: PNG } }))
  on('fs.exists', () => ({ value: false }))
  on('clock.every', () => ({ value: {} }))
  on('process.run', (_: unknown, e: any) => {
    const argv: string[] = e.argv ?? []
    if (argv.some(a => a.endsWith('launch.ps1'))) spawned.push(argv)
    return { value: { exitCode: 0, stdout: 'started\r\n', stderr: '' } }
  })
  on('session.usage', () => ({
    value: {
      startedAt: 0,
      context: { tokens: 42_000, window: 200_000, percent: 21 },
      rateLimits: [{ kind: 'five_hour', percentUsed: 37.5, resetsAt: '2026-11-19T18:00:00Z' }],
      cost: { usd: 1.23 },
    },
  }))
  on('session.start', (_: unknown, e: any) => ({ cwd: e.cwd }))
  on('process.hookEnv', () => ({
    value: { CLAUDE_PLUGIN_DATA: '/plugins/data/pet-companion', CLAUDE_CODE_SESSION_ID: 's1', CLAUDE_PID: '42' },
  }))
  on('fs.write', (_: unknown, e: any) => {
    writes.push(e)
    return { value: undefined }
  })
  on('process.spawn', async function* (_: unknown, e: any) {
    spawned.push(e.argv)
    // the window stays up for a moment, as a real one would
    await new Promise(r => setTimeout(r, 300))
    return { value: { code: 0 } }
  })
  on('tool.call', (_: unknown, e: any) =>
    e.tool === 'TaskCreate' ? { result: { task: { id: '1', subject: e.subject } } } : { result: {} },
  )
}

test('the pane draws the pet, tasks and usage on every surface', { options: { autoOpen: false } }, async ($, on) => {
  stubEngine(on)
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  await $.tool.call({
    tool: 'TodoWrite',
    todos: [
      { content: 'Read the code', status: 'completed', activeForm: 'Reading the code' },
      { content: 'Write the fix', status: 'in_progress', activeForm: 'Writing the fix' },
      { content: 'Run the tests', status: 'pending', activeForm: 'Running the tests' },
    ],
  })

  for (const surface of ['terminal', 'desktop', 'vscode', 'mobile'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect((await ui.find({ type: 'Text', text: /任务进度/ }))?.text).toContain('任务进度')
    expect((await ui.find({ type: 'Text', text: /▶/ }))?.text).toContain('Writing the fix')
    expect((await ui.find({ type: 'Text', text: /Run the tests/ }))?.text).toContain('○')
    expect((await ui.find({ type: 'Text', text: /花费估算/ }))?.text).toContain('1.23')
    await ui.unmount()
  }
})

test('the floating pet opens at start with the chosen settings', { options: { size: '大', bubble: '总是显示', bubbleSeconds: '8秒' } }, async ($, on) => {
  stubEngine(on)
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  await new Promise(r => setTimeout(r, 20))
  expect(spawned.length).toBe(1)
  const argv = spawned[0] ?? []
  expect(argv[0]).toBe('powershell.exe')
  expect(argv.join(' ')).toContain('launch.ps1')
  expect(argv.join(' ')).toContain('pet-companion-shared')
  const text = JSON.stringify(writes)
  expect(text).toContain('large')
  expect(text).toContain('always')
  expect(text).toContain('bubbleSeconds\\":8')
  expect(text).toContain('剩 62.5%')
  expect(text).toContain('topmost\\":false')
})

test('no pet window when auto-open is off, and /pet summons it', { options: { autoOpen: false } }, async ($, on) => {
  stubEngine(on)
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  await new Promise(r => setTimeout(r, 20))
  expect(spawned.length).toBe(0)
  const out = await $.command.run({ command: 'pet', args: '' } as any)
  expect(JSON.stringify(out)).toContain('桌面')
  expect(spawned.length).toBe(1)
})

test('/pet hide asks the window to wave goodbye before it closes', async ($, on) => {
  stubEngine(on)
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  await new Promise(r => setTimeout(r, 20))
  expect(spawned.length).toBe(1)
  writes = []
  const out = await $.command.run({ command: 'pet', args: 'hide' } as any)
  expect(JSON.stringify(out)).toContain('休息')
  expect(JSON.stringify(writes)).toContain('farewell\\":true')
})

test('the chime settings reach the window', { options: { sound: true, soundVolume: '大', soundFile: 'C:\sounds\mine.mp3' } }, async ($, on) => {
  stubEngine(on)
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  await new Promise(r => setTimeout(r, 20))
  const text = JSON.stringify(writes)
  expect(text).toContain('sound\\":true')
  expect(text).toContain('soundVolume\\":1')
  expect(text).toContain('mine.mp3')
})
