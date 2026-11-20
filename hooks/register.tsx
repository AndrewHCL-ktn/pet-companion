import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Mood, MoodKind, PetTask, Stats, TaskStatus, Usage } from '../types'

const PANE = 'pet-companion'
const SETTINGS_PANE = 'pet-settings'
const TITLE = 'Claude娘'

const mood = atom(
  { plugin: 'pet-companion', key: 'mood' } as const,
  { kind: 'idle', detail: '', at: 0 } as Mood,
  { shape: 'mood-1' },
)
const tasks = atom({ plugin: 'pet-companion', key: 'tasks' } as const, [] as PetTask[], {
  shape: 'tasks-1',
})
const stats = atom(
  { plugin: 'pet-companion', key: 'stats' } as const,
  { turns: 0, tools: 0, lastTurnMs: 0 } as Stats,
  { shape: 'stats-1' },
)
const usage = atom(
  { plugin: 'pet-companion', key: 'usage' } as const,
  { window: 0, limits: [], startedAt: 0 } as Usage,
  { shape: 'usage-1' },
)

type $ = EngineInterface

// ---------- settings (userConfig, shown in Claude Code's settings menu) ----------

type Settings = {
  autoOpen: boolean
  size: 'small' | 'medium' | 'large' | 'huge'
  bubble: 'change' | 'always' | 'never'
  bubbleSeconds: number
  autoLevel: 'brief' | 'full'
  pokeLevel: 'brief' | 'full'
  sound: boolean
  soundVolume: number
  soundFile: string
  showUsage: boolean
  alwaysOnTop: boolean
  sidebar: boolean
}

const SIZE: Record<string, Settings['size']> = { 小: 'small', 中: 'medium', 大: 'large', 特大: 'huge' }
const BUBBLE: Record<string, Settings['bubble']> = {
  状态变化时显示: 'change',
  总是显示: 'always',
  隐藏: 'never',
}
const LEVEL: Record<string, 'brief' | 'full'> = { 简略: 'brief', 详细: 'full' }
const VOLUME: Record<string, number> = { 小: 0.3, 中: 0.6, 大: 1 }
const SECONDS: Record<string, number> = { '3秒': 3, '5秒': 5, '8秒': 8, '15秒': 15 }

const readSettings = (o: Record<string, unknown>): Settings => ({
  autoOpen: o.autoOpen !== false,
  size: SIZE[String(o.size)] ?? 'medium',
  bubble: BUBBLE[String(o.bubble)] ?? 'change',
  bubbleSeconds: SECONDS[String(o.bubbleSeconds)] ?? 5,
  autoLevel: LEVEL[String(o.autoLevel)] ?? 'brief',
  pokeLevel: LEVEL[String(o.pokeLevel)] ?? 'full',
  sound: o.sound !== false,
  soundVolume: VOLUME[String(o.soundVolume)] ?? 0.6,
  soundFile: typeof o.soundFile === 'string' ? o.soundFile.trim().replace(/^"|"$/g, '') : '',
  showUsage: o.showUsage !== false,
  alwaysOnTop: o.alwaysOnTop === true,
  sidebar: o.sidebar === true,
})

// ---------- text ----------

const MOOD_LABEL: Record<MoodKind, string> = {
  idle: '待机中',
  thinking: '思考中…',
  working: '工作中',
  waiting: '等你回应',
  done: '完成啦！',
  error: '出错了…',
  sleep: '睡着了 zzZ',
}
const MOOD_COLOR: Record<MoodKind, string> = {
  idle: '#c9763f',
  thinking: '#d9822b',
  working: '#e8692c',
  waiting: '#d4a017',
  done: '#3fa66b',
  error: '#d64545',
  sleep: '#8a8fa8',
}
const MOOD_LINE: Record<MoodKind, string> = {
  idle: '有什么要做的吗？交给我吧～',
  thinking: '让我想想……',
  working: '正在努力干活！',
  waiting: '需要你确认一下哦',
  done: '搞定了！夸夸我～',
  error: '呜……好像哪里不对',
  sleep: '（呼……呼……）',
}

const TOOL_VERB: Record<string, string> = {
  Bash: '执行命令',
  PowerShell: '执行命令',
  Read: '阅读文件',
  Write: '写入文件',
  Edit: '修改文件',
  Glob: '查找文件',
  Grep: '搜索代码',
  WebFetch: '浏览网页',
  WebSearch: '上网搜索',
  Agent: '派出小助手',
  Task: '派出小助手',
  TodoWrite: '整理任务清单',
  TaskCreate: '新建任务',
  TaskUpdate: '更新任务',
  NotebookEdit: '修改笔记本',
  Skill: '翻阅技能书',
  ToolSearch: '查找工具',
}

const short = (s: string, n = 48) => {
  const one = s.replace(/\s+/g, ' ').trim()
  return one.length > n ? one.slice(0, n - 1) + '…' : one
}

const describeTool = (e: Record<string, unknown>, tool: string): string => {
  const verb =
    TOOL_VERB[tool] ??
    (tool.startsWith('mcp__') ? '调用 ' + tool.split('__').slice(-1)[0] : '使用 ' + tool)
  const arg =
    (typeof e.description === 'string' && e.description) ||
    (typeof e.command === 'string' && e.command) ||
    (typeof e.file_path === 'string' && e.file_path.split(/[\\/]/).pop()) ||
    (typeof e.pattern === 'string' && e.pattern) ||
    (typeof e.query === 'string' && e.query) ||
    (typeof e.url === 'string' && e.url) ||
    ''
  return arg ? `${verb}：${short(String(arg))}` : verb
}

const fmtTokens = (n?: number) =>
  n === undefined ? '—' : n >= 1000 ? `${(n / 1000).toFixed(n >= 100_000 ? 0 : 1)}k` : String(n)

const fmtDuration = (ms: number) => {
  const s = Math.max(0, Math.round(ms / 1000))
  if (s < 60) return `${s}秒`
  const m = Math.floor(s / 60)
  if (m < 60) return `${m}分${s % 60}秒`
  return `${Math.floor(m / 60)}小时${m % 60}分`
}

const LIMIT_LABEL: Record<string, string> = {
  five_hour: '5 小时额度',
  seven_day: '7 天额度',
  spend_limit: '消费上限',
}

const fmtReset = (iso?: string) => {
  if (!iso) return undefined
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return undefined
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${d.getMonth() + 1}/${d.getDate()} ${pad(d.getHours())}:${pad(d.getMinutes())} 重置`
}

// how much of a rate-limit window is left, 0 to 100, one decimal at most
const remaining = (used: number) => Math.max(0, Math.round((100 - used) * 10) / 10)
const remainingColor = (left: number) => (left <= 10 ? '#d64545' : left <= 30 ? '#d4a017' : '#3fa66b')

const limitColor = (p: number) => (p >= 90 ? '#d64545' : p >= 70 ? '#d4a017' : '#e8692c')

const quietly = async (work: () => Promise<unknown>) => {
  try {
    await work()
  } catch {
    // the pet never gets in the way of real work
  }
}

// ---------- tasks ----------

const planStatus = (s: unknown): TaskStatus =>
  s === 'completed' ? 'completed' : s === 'in_progress' ? 'in_progress' : 'pending'

const applyPlan = async ($: $, input: Record<string, unknown>) => {
  const items = input.items
  if (Array.isArray(items)) {
    await update($, tasks, () =>
      items.map((it: any, i: number) => ({
        id: `plan-${i}`,
        text: String(it?.content ?? ''),
        status: planStatus(it?.status),
      })),
    )
    return
  }
  await update($, tasks, list => {
    const cur = list.findIndex(t => t.status === 'in_progress')
    const nxt = list.findIndex((t, i) => i > cur && t.status === 'pending')
    const done = new Set(Array.isArray(input.done) ? (input.done as number[]).map(n => n - 1) : [])
    const start = typeof input.start === 'number' ? input.start - 1 : -1
    return list.map((t, i): PetTask => {
      let status = t.status
      if (input.advance === true && i === cur) status = 'completed'
      if (input.advance === true && i === nxt) status = 'in_progress'
      if (done.has(i)) status = 'completed'
      if (start >= 0 && status === 'in_progress' && i !== start) status = 'pending'
      if (i === start) status = 'in_progress'
      return { ...t, status }
    })
  })
}

// ---------- module state (starts over on a reload, as the window does) ----------

let settings: Settings = readSettings({})
let configVersion = 0

// ---- the floating window ----
// set while the window says goodbye before it is closed
let isFarewell = false
let stateFile: string | undefined
let writeTimer: { cancel: () => void } | undefined

const writeState = async ($: $) => {
  if (stateFile === undefined) return
  const m = await read($, mood)
  const list = await read($, tasks)
  const st = await read($, stats)
  const u = await read($, usage)
  const done = list.filter(t => t.status === 'completed').length
  const current = list.find(t => t.status === 'in_progress')
  const rows: { label: string; percent: number; right: string; color: string }[] = []
  if (u.contextPercent !== undefined) {
    rows.push({
      label: '上下文',
      percent: u.contextPercent,
      right: `${u.contextPercent}% · ${fmtTokens(u.contextTokens)}/${fmtTokens(u.window)}`,
      color: limitColor(u.contextPercent),
    })
  }
  for (const l of u.limits) {
    const reset = fmtReset(l.resetsAt)
    const left = remaining(l.percent)
    rows.push({
      label: `${LIMIT_LABEL[l.kind] ?? l.kind}剩余`,
      percent: left,
      right: reset ? `剩 ${left}% · ${reset}` : `剩 ${left}%`,
      color: remainingColor(left),
    })
  }
  const note = [
    u.usd !== undefined ? `花费估算 $${u.usd.toFixed(2)}` : '',
    `本会话 ${st.turns} 轮 · ${st.tools} 次工具`,
  ]
    .filter(Boolean)
    .join(' · ')
  const state = {
    farewell: isFarewell,
    mood: m.kind,
    label: MOOD_LABEL[m.kind],
    line: MOOD_LINE[m.kind],
    detail: m.detail,
    color: MOOD_COLOR[m.kind],
    tasks:
      list.length === 0
        ? { done: 0, total: 0, text: '' }
        : {
            done,
            total: list.length,
            text: current
              ? `▶ ${short(current.text, 30)}`
              : done === list.length
                ? '✓ 全部完成'
                : `○ ${short(list.find(t => t.status === 'pending')?.text ?? '', 30)}`,
          },
    usage: { rows, note },
    config: {
      size: settings.size,
      bubble: settings.bubble,
      bubbleSeconds: settings.bubbleSeconds,
      autoLevel: settings.autoLevel,
      pokeLevel: settings.pokeLevel,
      sound: settings.sound,
      soundVolume: settings.soundVolume,
      soundFile: settings.soundFile,
      showUsage: settings.showUsage,
      topmost: settings.alwaysOnTop,
      version: configVersion,
    },
  }
  await $.fs.write(stateFile, JSON.stringify(state))
}

// coalesce bursts of changes into one write
const pushState = ($: $) => {
  writeTimer?.cancel()
  writeTimer = $.clock.after(120, () => void quietly(() => writeState($)))
}

// One pet for the whole computer, however many sessions run: every session writes its state to a
// shared folder, the window shows the freshest one, and a lock lets only one window live.
let sharedDir: string | undefined
const HIDDEN = 'hidden'

const findSharedDir = async ($: $): Promise<string | undefined> => {
  if (sharedDir !== undefined) return sharedDir
  const env = await $.process.hookEnv()
  const data = env.CLAUDE_PLUGIN_DATA
  if (!data) return undefined
  // beside this plugin's own data folder, so every copy of the plugin finds the same one
  const parent = data.replace(/[\\/]+$/, '').replace(/[\\/][^\\/]+$/, '')
  sharedDir = `${parent}/pet-companion-shared`
  stateFile = `${sharedDir}/state-${env.CLAUDE_CODE_SESSION_ID ?? 'main'}.json`
  return sharedDir
}

const isHidden = async ($: $) => {
  const dir = await findSharedDir($)
  return dir !== undefined && (await $.fs.exists(`${dir}/${HIDDEN}`))
}

// The window is started on its own (window/launch.ps1), not as this session's child: the desktop
// app stops a session's process in Chat mode or when it sits idle, and she should stay. She lives
// as long as the Claude app does; a lock keeps her to one window.
const startPet = async ($: $): Promise<string> => {
  const dir = await findSharedDir($)
  const root = $.plugin.root
  if (dir === undefined || stateFile === undefined) return '找不到插件数据目录，桌宠没能启动。'
  isFarewell = false
  await writeState($)
  const run = await $.process.run(
    [
      'powershell.exe',
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      `${root}/window/launch.ps1`,
      '-StateDir',
      dir,
      '-AssetDir',
      `${root}/assets/float`,
      '-PrefsFile',
      `${dir}/window.json`,
    ],
    { timeoutMs: 20_000 },
  )
  const said = run.stdout.trim()
  if (said.endsWith('running')) return '桌宠已经在桌面上啦。'
  if (run.exitCode !== 0 || !said.endsWith('started')) {
    $.ui.log(`pet launch: ${said} ${run.stderr}`.trim(), { to: 'debug' })
    return '桌宠没能启动，稍后再输入 /pet 试试。'
  }
  return 'Claude娘来到你的桌面啦！可以用鼠标把她拖到任何地方。'
}

// /pet: she comes back, wherever she was put away
const summonPet = async ($: $): Promise<string> => {
  const dir = await findSharedDir($)
  if (dir !== undefined && (await $.fs.exists(`${dir}/${HIDDEN}`))) {
    await $.process.run(['cmd.exe', '/c', 'del', '/q', `${dir}/${HIDDEN}`.replace(/\//g, '\\')]).catch(() => undefined)
  }
  return startPet($)
}

// /pet hide: whichever session showed her, the window reads this session's goodbye (the freshest
// state) and waves, fades and closes by itself; the marker keeps other sessions from calling her back
const stopPet = async ($: $) => {
  const dir = await findSharedDir($)
  if (dir !== undefined) await quietly(() => $.fs.write(`${dir}/${HIDDEN}`, 'hidden by /pet hide'))
  isFarewell = true
  await quietly(() => writeState($))
}

// ---- mood with timers ----
let settleTimer: { cancel: () => void } | undefined
let sleepTimer: { cancel: () => void } | undefined

const refreshStatus = async ($: $) => {
  const m = await read($, mood)
  const u = await read($, usage)
  const ctx = u.contextPercent !== undefined ? ` · 上下文 ${u.contextPercent}%` : ''
  $.ui.status(`🧡 Claude娘 · ${MOOD_LABEL[m.kind]}${ctx}`)
}

const setMood = async ($: $, kind: MoodKind, detail = '') => {
  settleTimer?.cancel()
  sleepTimer?.cancel()
  const at = await $.clock.now()
  await update($, mood, () => ({ kind, detail, at }))
  await refreshStatus($)
  pushState($)
  if (kind === 'done' || kind === 'error') {
    settleTimer = $.clock.after(15_000, () => void quietly(() => setMood($, 'idle')))
  }
  if (kind === 'idle') {
    sleepTimer = $.clock.after(5 * 60_000, () => void quietly(() => setMood($, 'sleep')))
  }
}

const pullUsage = async ($: $) => {
  const u = await $.session.usage()
  await update($, usage, () => ({
    contextPercent: u.context.percent,
    contextTokens: u.context.tokens,
    window: u.context.window,
    limits: u.rateLimits.map(r => ({ kind: r.kind, percent: r.percentUsed, resetsAt: r.resetsAt })),
    usd: u.cost?.usd,
    startedAt: u.startedAt,
  }))
  pushState($)
}

const setTasks = async ($: $, fn: (list: PetTask[]) => PetTask[]) => {
  await update($, tasks, fn)
  pushState($)
}

const sprites = new Map<string, string>()
const sprite = async ($: $, name: string): Promise<string | undefined> => {
  const hit = sprites.get(name)
  if (hit !== undefined) return hit
  try {
    const { base64 } = (await $.fs.read(`${$.plugin.root}/assets/${name}.png`, {
      as: 'bytes',
    })) as { base64: string }
    sprites.set(name, base64)
    return base64
  } catch {
    return undefined
  }
}

const ANIM: Record<MoodKind, string> = {
  idle: 'bob 3.2s ease-in-out infinite',
  thinking: 'sway 2.6s ease-in-out infinite',
  working: 'busy 0.5s ease-in-out infinite',
  waiting: 'tilt 1.8s ease-in-out infinite',
  done: 'hop 0.9s ease-out infinite',
  error: 'shake 0.45s ease-in-out 4',
  sleep: 'breathe 4s ease-in-out infinite',
}

const svgFor = (b64: string, w: number, h: number, kind: MoodKind) => {
  const pad = 10
  const W = w + pad * 2
  const H = h + pad * 2
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}">
<style>
@keyframes bob{0%,100%{transform:translateY(0)}50%{transform:translateY(-4px)}}
@keyframes sway{0%,100%{transform:rotate(-1.5deg)}50%{transform:rotate(1.5deg)}}
@keyframes busy{0%,100%{transform:translateY(0)}50%{transform:translateY(-2px)}}
@keyframes tilt{0%,100%{transform:rotate(0)}30%{transform:rotate(-3deg)}60%{transform:rotate(2deg)}}
@keyframes hop{0%,100%{transform:translateY(0)}35%{transform:translateY(-10px)}55%{transform:translateY(0)}}
@keyframes shake{0%,100%{transform:translateX(0)}25%{transform:translateX(-4px)}75%{transform:translateX(4px)}}
@keyframes breathe{0%,100%{transform:scale(1,1)}50%{transform:scale(1.01,0.985)}}
.c{animation:${ANIM[kind]};transform-origin:${W / 2}px ${H - pad}px;transform-box:view-box}
</style>
<ellipse cx="${W / 2}" cy="${H - pad - 2}" rx="${w * 0.32}" ry="6" fill="#000" opacity="0.13"/>
<g class="c"><image href="data:image/png;base64,${b64}" x="${pad}" y="${pad}" width="${w}" height="${h}"/></g>
</svg>`
}


// ---------- settings panel: writes the same userConfig rows the settings menu shows ----------

type Field = keyof Settings
const FIELD_ROWS: { field: Field; label: string; options: string[] }[] = [
  { field: 'autoOpen', label: '启动时自动打开桌宠', options: ['开', '关'] },
  { field: 'size', label: '桌宠大小', options: ['小', '中', '大', '特大'] },
  { field: 'bubble', label: '对话气泡', options: ['状态变化时显示', '总是显示', '隐藏'] },
  { field: 'bubbleSeconds', label: '气泡停留时间', options: ['3秒', '5秒', '8秒', '15秒'] },
  { field: 'autoLevel', label: '自动弹出与悬停时显示', options: ['简略', '详细'] },
  { field: 'pokeLevel', label: '双击时显示', options: ['详细', '简略'] },
  { field: 'sound', label: '任务完成提示音', options: ['开', '关'] },
  { field: 'soundVolume', label: '提示音音量', options: ['小', '中', '大'] },
  { field: 'showUsage', label: '气泡中显示用量', options: ['开', '关'] },
  { field: 'alwaysOnTop', label: '桌宠置顶', options: ['开', '关'] },
  { field: 'sidebar', label: '同时打开侧边栏面板', options: ['开', '关'] },
]

const shownValue = (field: Field): string => {
  const v = settings[field]
  if (typeof v === 'boolean') return v ? '开' : '关'
  if (field === 'size') return Object.keys(SIZE).find(k => SIZE[k] === v) ?? '中'
  if (field === 'bubbleSeconds') return `${v}秒`
  if (field === 'autoLevel' || field === 'pokeLevel') return v === 'full' ? '详细' : '简略'
  if (field === 'soundVolume') return Object.keys(VOLUME).find(k => VOLUME[k] === v) ?? '中'
  if (field === 'soundFile') return String(v)
  return Object.keys(BUBBLE).find(k => BUBBLE[k] === v) ?? '状态变化时显示'
}

let settingsNote = ''

const changeSetting = async ($: $, field: Field, shown: string) => {
  const value = shown === '开' ? true : shown === '关' ? false : shown
  const rows = await $.config.list()
  const row = rows.find(r => r.key.startsWith('pet-companion') && r.key.endsWith(`.${field}`))
  if (row === undefined) {
    settingsNote = '没找到这个设置项（插件需要先装进 Claude Code 的设置里）'
    return
  }
  const res = (await $.config.set({ key: row.key, value } as any)) as { deny?: string }
  settingsNote = res.deny ? `没能保存：${res.deny}` : '已保存，桌宠马上换好～'
}

// ---------- register ----------

export const register: Register = (on, options) => {
  settings = readSettings((options ?? {}) as Record<string, unknown>)
  // changes whenever the settings change, so the window drops its own right-click choices
  configVersion = [...JSON.stringify(settings)].reduce((h, c) => (h * 31 + c.charCodeAt(0)) | 0, 7)

  const isMain = (e: unknown) => (e as { agentId?: string }).agentId === undefined

  // ---- session ----

  on('session.start', async ($, e, next) => {
    await quietly(() =>
      $.command.register({
        name: 'pet',
        description: '召唤 Claude娘桌宠；hide 收起，settings 打开设置，sound <文件> 换提示音，panel 打开侧边栏面板',
        argumentHint: '[hide|settings|sound <文件>|panel]',
      }),
    )
    void quietly(async () => {
      await pullUsage($)
      await setMood($, 'idle')
    })
    if (settings.autoOpen) {
      void quietly(async () => {
        await findSharedDir($)
        if (!(await isHidden($))) await startPet($)
      })
    }
    if (settings.sidebar) void $.ui.open({ id: PANE, title: TITLE })
    return next(e)
  })

  on('command.run', { command: 'pet' }, async ($, e) => {
    const arg = String((e as { args?: string }).args ?? '').trim().toLowerCase()
    if (arg === 'hide' || arg === '收起' || arg === 'off') {
      await stopPet($)
      return { text: 'Claude娘先去休息啦，输入 /pet 随时叫她回来。' }
    }
    if (arg === 'sound' || arg.startsWith('sound ') || arg.startsWith('提示音')) {
      const raw = String((e as { args?: string }).args ?? '').trim()
      const path = raw.replace(/^(sound|提示音)\s*/i, '').trim().replace(/^"|"$/g, '')
      if (path !== '' && !/\.(wav|mp3|wma|m4a)$/i.test(path)) {
        return { text: '提示音需要是 .wav / .mp3 / .wma / .m4a 文件。' }
      }
      if (path !== '' && !(await $.fs.exists(path))) {
        return { text: `找不到这个文件：${path}` }
      }
      await changeSetting($, 'soundFile', path)
      return {
        text: path === '' ? '已恢复默认提示音。' : `提示音已换成：${path}（${settingsNote}）`,
      }
    }
    if (arg === 'settings' || arg === '设置' || arg === 'config') {
      await $.ui.open({ id: SETTINGS_PANE, title: 'Claude娘设置' })
      return { text: '已打开 Claude娘设置。' }
    }
    if (arg === 'panel' || arg === '面板') {
      await $.ui.open({ id: PANE, title: TITLE })
      return { text: '已在侧边栏打开 Claude娘面板。' }
    }
    const text = await summonPet($).catch(err => `桌宠启动失败：${String(err)}`)
    return { text }
  })

  on('prompt.submit', async ($, e, next) => {
    await quietly(() => setMood($, 'thinking', '收到新任务'))
    return next(e)
  }).catch(($, e, next) => (next.called ? undefined : next(e)))

  on('turn.start', async ($, e, next) => {
    if (isMain(e)) {
      await quietly(async () => {
        const m = await read($, mood)
        if (m.kind !== 'thinking') await setMood($, 'thinking')
      })
    }
    return next(e)
  })

  on('tool.check', async ($, e, next) => {
    const verdict = await next(e)
    if (isMain(e) && verdict.decision === 'ask') {
      await quietly(() => setMood($, 'waiting', `等你批准：${describeTool(e as any, e.tool)}`))
    }
    return verdict
  }).catch(($, e, next) => (next.called ? undefined : next(e)))

  on('tool.call', async ($, e, next) => {
    const input = e as unknown as Record<string, unknown>
    const tool = e.tool
    const main = isMain(e)
    await quietly(async () => {
      if (main) {
        await update($, stats, s => ({ ...s, tools: s.tools + 1 }))
        if (tool === 'AskUserQuestion' || tool === 'ExitPlanMode') {
          await setMood($, 'waiting', tool === 'AskUserQuestion' ? '有问题想问你' : '计划等你过目')
        } else {
          await setMood($, 'working', describeTool(input, tool))
        }
      }
      // task tracking: TodoWrite, TaskCreate/TaskUpdate, the desktop app's plan list
      if (tool === 'TodoWrite' && Array.isArray(input.todos)) {
        await setTasks($, () =>
          (input.todos as any[]).map((t, i) => ({
            id: `todo-${i}`,
            text: String(t.status === 'in_progress' && t.activeForm ? t.activeForm : t.content),
            status: planStatus(t.status),
          })),
        )
      } else if (tool.endsWith('update_plan') && tool.startsWith('mcp__')) {
        await applyPlan($, input)
        pushState($)      } else if (tool.endsWith('wrap_up') && tool.startsWith('mcp__')) {
        // the desktop app checks off its task list when a turn wraps up
        await setTasks($, list => list.map(t => ({ ...t, status: 'completed' as const })))
      }
    })

    const ran = await next(e)

    await quietly(async () => {
      const res = (ran as { result?: any }) ?? {}
      if (tool === 'TaskCreate' && res.result?.task?.id) {
        const id = String(res.result.task.id)
        await setTasks($, list => [
          ...list.filter(t => !t.id.startsWith('todo-') && !t.id.startsWith('plan-')),
          { id, text: String(input.subject ?? res.result.task.subject ?? ''), status: 'pending' },
        ])
      } else if (tool === 'TaskUpdate' && typeof input.taskId === 'string') {
        const id = input.taskId
        await setTasks($, list =>
          input.status === 'deleted'
            ? list.filter(t => t.id !== id)
            : list.map(t =>
                t.id === id
                  ? {
                      ...t,
                      text: String(input.subject ?? t.text),
                      status: input.status ? planStatus(input.status) : t.status,
                    }
                  : t,
              ),
        )
      }
      if (main) {
        const m = await read($, mood)
        if (m.kind === 'waiting' || m.kind === 'working') await setMood($, 'thinking')
      }
    })
    return ran
  }).catch(($, e, next) => (next.called ? undefined : next(e)))

  on('turn.complete', async ($, e, next) => {
    if (isMain(e)) {
      await quietly(async () => {
        await update($, stats, s => ({ ...s, turns: s.turns + 1, lastTurnMs: e.durationMs }))
        if (e.reason === 'error' || e.reason === 'refusal') {
          await setMood($, 'error', e.reason === 'error' ? 'API 出错了' : '这个我做不到…')
        } else if (e.reason === 'aborted') {
          await setMood($, 'idle', '被打断了，随时继续～')
        } else {
          await setMood($, 'done', `用时 ${fmtDuration(e.durationMs)}`)
        }
        void quietly(async () => {
          await pullUsage($)
          await refreshStatus($)
        })
      })
    }
    return next(e)
  })

  on('session.measure', async ($, e, next) => {
    await quietly(async () => {
      await update($, usage, u => ({
        ...u,
        contextPercent: e.context.percent,
        contextTokens: e.context.tokens,
        window: e.context.window,
        limits: e.rateLimits.map(r => ({ kind: r.kind, percent: r.percentUsed, resetsAt: r.resetsAt })),
        usd: e.cost?.usd ?? u.usd,
      }))
      if (e.changed.includes('context')) await refreshStatus($)
      pushState($)
    })
    return next(e)
  })

  // ---------- optional sidebar pane ----------

  on('ui.render', { component: 'Pane', requestId: SETTINGS_PANE }, async ($, e) => {
    const { Box, Text, Select } = $.ui.resolve(e) as any
    return (
      <Box flexDirection="column" gap={1}>
        <Text bold>🧡 Claude娘设置</Text>
        <Text dimColor>这些设置也会出现在 Claude Code 的设置菜单（/config）里，改动后桌宠会自动刷新。</Text>
        {FIELD_ROWS.map(row => (
          <Select
            key={`set-${row.field}`}
            label={row.label}
            value={shownValue(row.field)}
            options={row.options.map(o => ({ key: o, value: o, label: o }))}
            onSelect={(value: string) =>
              void quietly(async () => {
                await changeSetting($, row.field, value)
                $.ui.invalidate("ui.render")
              })
            }
          />
        ))}
        {settingsNote !== '' && <Text color="#3fa66b">{settingsNote}</Text>}
        <Text dimColor>小技巧：鼠标停在桌宠身上会显示气泡；右键可临时调整大小、气泡和置顶；双击查看完整的详细信息；右键 → 提示音 可以试听或换成你自己的音效（也可输入 /pet sound 文件路径）。</Text>
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button, Progress } = $.ui.resolve(e)
    const m = await read($, mood)
    const list = await read($, tasks)
    const st = await read($, stats)
    const u = await read($, usage)
    const now = await $.clock.now()

    const name = `chibi-${m.kind}`
    const b64 = await sprite($, name)
    const surface = e.surface
    const figure =
      b64 === undefined ? (
        <Text dimColor>（立绘加载失败：{name}）</Text>
      ) : surface === 'terminal' ? (
        (() => {
          const { Image } = $.ui.resolve(e) as any
          return <Image source={{ png: b64 }} columns={22} rows={11} alt={`Claude娘 · ${MOOD_LABEL[m.kind]}`} />
        })()
      ) : (
        (() => {
          const { Svg } = $.ui.resolve(e) as any
          return (
            <Svg
              source={svgFor(b64, 180, 176, m.kind)}
              alt={`Claude娘（${MOOD_LABEL[m.kind]}）`}
              width={200}
              height={196}
            />
          )
        })()
      )

    const done = list.filter(t => t.status === 'completed').length
    const current = list.find(t => t.status === 'in_progress')
    const color = MOOD_COLOR[m.kind]
    const since = m.at ? fmtDuration(now - m.at) : ''

    return (
      <Box flexDirection="column" gap={1}>
        <Box flexDirection="column" alignItems="center">
          {figure}
          <Button
            key="summon"
            label="召唤桌面桌宠"
            variant="primary"
            onPress={() => void quietly(() => summonPet($))}
          />
        </Box>

        <Box flexDirection="column" borderStyle="round" borderColor={color} paddingX={1}>
          <Text bold color={color}>
            {MOOD_LABEL[m.kind]}
            {since ? <Text dimColor> · {since}前</Text> : ''}
          </Text>
          <Text italic>「{MOOD_LINE[m.kind]}」</Text>
          {m.detail !== '' && (
            <Text dimColor wrap="truncate-end">
              {m.detail}
            </Text>
          )}
        </Box>

        <Box flexDirection="column">
          <Text bold>📋 任务进度</Text>
          {list.length === 0 ? (
            <Text dimColor>还没有任务清单</Text>
          ) : (
            <Box flexDirection="column">
              <Progress
                label={current ? short(current.text, 30) : done === list.length ? '全部完成' : '任务'}
                value={done}
                max={list.length}
                valueText={`${done}/${list.length}`}
                color={done === list.length ? '#3fa66b' : '#e8692c'}
              />
              {list.slice(0, 12).map(t => (
                <Text
                  key={`t-${t.id}`}
                  dimColor={t.status === 'completed'}
                  strikethrough={t.status === 'completed'}
                  bold={t.status === 'in_progress'}
                  color={t.status === 'in_progress' ? '#e8692c' : undefined}
                  wrap="truncate-end"
                >
                  {t.status === 'completed' ? '✓ ' : t.status === 'in_progress' ? '▶ ' : '○ '}
                  {t.text}
                </Text>
              ))}
              {list.length > 12 && <Text dimColor>…还有 {list.length - 12} 项</Text>}
            </Box>
          )}
        </Box>

        <Box flexDirection="column">
          <Text bold>📊 用量</Text>
          <Progress
            label="上下文窗口"
            value={u.contextPercent ?? 0}
            max={100}
            valueText={
              u.contextPercent === undefined
                ? '尚无数据'
                : `${u.contextPercent}% · ${fmtTokens(u.contextTokens)}/${fmtTokens(u.window)}`
            }
            color={limitColor(u.contextPercent ?? 0)}
          />
          {u.limits.map(l => (
            <Box key={`l-${l.kind}`} flexDirection="column">
              <Progress
                label={`${LIMIT_LABEL[l.kind] ?? l.kind}剩余`}
                value={remaining(l.percent)}
                max={100}
                valueText={`剩 ${remaining(l.percent)}%`}
                color={remainingColor(remaining(l.percent))}
              />
              {fmtReset(l.resetsAt) && <Text dimColor>  {fmtReset(l.resetsAt)}</Text>}
            </Box>
          ))}
          {u.limits.length === 0 && <Text dimColor>额度窗口：暂无读数（非订阅账户或尚未请求）</Text>}
          {u.usd !== undefined && <Text>花费估算：${u.usd.toFixed(2)}（客户端估算，非账单）</Text>}
          <Text dimColor>
            本会话 {st.turns} 轮 · {st.tools} 次工具调用
            {u.startedAt ? ` · 已开 ${fmtDuration(now - u.startedAt)}` : ''}
            {st.lastTurnMs ? ` · 上轮 ${fmtDuration(st.lastTurnMs)}` : ''}
          </Text>
        </Box>
      </Box>
    )
  })
}
