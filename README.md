# pet-companion · Claude娘桌宠

A Claude Code mod that puts a chibi "Claude娘" on your desktop: a transparent window you can drag anywhere (Windows). She stays while the Claude app is open, in Code and in Chat, and dozes off when no session is at work.

- **桌面桌宠**：独立于 Claude Code 窗口，可用鼠标拖到屏幕任何位置，位置会被记住。
- **状态差分**：随 Claude 的状态换表情——待机、思考、工作、等你回应、完成、出错、睡着（空闲 5 分钟后）。
- **对话气泡**：显示当前状态、正在做什么、任务进度条，以及用量（上下文、5 小时 / 7 天额度、花费估算）。
- **小动作**：出现时挥手打招呼，收起时挥手说拜拜再淡出，双击时被摸头会害羞地蹭一蹭。
- **右键菜单**：临时调整大小、气泡、置顶，回到右下角，或收起桌宠；双击查看完整的详细信息，读秒后自动收起。

## 安装

在 Claude Code 的输入框里输入：

```
/plugin install pet-companion --marketplace AndrewHCL-ktn/pet-companion
```

提示添加插件市场时输入 `y`，再选择安装范围（推荐 user，所有项目都会有她）。装好后开一个新会话，Claude娘就会出现在桌面上。

需要 Windows（桌宠窗口用 Windows PowerShell 与 WPF 绘制）；其他系统可以用 `/pet panel` 在侧边栏查看。

## 设置

在 Claude Code 的设置菜单（`/config`）、`/plugin configure pet-companion@pet-companion`，或输入 `/pet settings` 打开的设置面板中修改：

| 设置 | 默认 |
| --- | --- |
| 启动时自动打开桌宠 | 开 |
| 桌宠大小（小 / 中 / 大 / 特大） | 中 |
| 对话气泡（状态变化时显示 / 总是显示 / 隐藏） | 状态变化时显示 |
| 气泡停留时间（3 / 5 / 8 / 15 秒） | 5 秒 |
| 自动弹出与悬停时显示（简略 / 详细） | 简略：状态、正在做什么、任务进度 |
| 双击时显示（详细 / 简略） | 详细：全部信息，含用量 |
| 气泡中显示用量 | 开 |
| 桌宠置顶 | 关（与 Claude Code 窗口同级） |
| 同时打开侧边栏面板 | 关 |
| 任务完成提示音 | 开 |
| 提示音音量（小 / 中 / 大） | 中 |
| 自定义提示音文件 | 空（用默认的"叮～"） |

## 命令

- `/pet` 召唤桌宠，`/pet hide` 收起，`/pet settings` 打开设置，`/pet panel` 打开侧边栏详细面板。
- `/pet sound C:\路径\你的音效.mp3` 换成自己的提示音，`/pet sound` 恢复默认。也可以在桌宠上右键 → 提示音 → 选择自定义提示音。

## 提示音

默认提示音 `assets/sounds/done.wav` 是为这个插件合成的原创音效，随插件一起以 MIT 协议发布。

Images in `assets/` are the author's own character art.
