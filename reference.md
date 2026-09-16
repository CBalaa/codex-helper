# reference — codex-helper 的实现细节与边界

> SKILL.md 是入口；这里放细节。**只在需要时读**。

## 1. 布局

```
<skill 仓库>/                       # 代码：所有工作区共用一份
├── SKILL.md
├── reference.md
├── README.md
├── config.env.example              # 配置模板
├── install.sh                      # 装成 skill + 初始化工作区
├── scripts/
│   ├── relay-lib.sh                # 共享库（工作区定位、tmux 门控、状态栏解析）
│   ├── codex-config.sh             # 配置/体检
│   ├── codex-ask.sh                # ①+②+③ 一条命令
│   ├── codex-relay.sh              # ① 空闲门控投递
│   └── codex-watch.sh              # ② 监听 + 取答复 + 归档
└── tests/
    └── smoke.sh                    # 自测

<工作区>/.codex_helper/              # 工作区自己持有（建议 gitignore）
├── config.env                      # TARGET / TARGET_TITLE / TO / 超时…
├── ask.lock                        # flock 互斥文件
└── state/
    ├── queue/                      # 待投问题（投递成功即删）
    ├── pending/                    # 投递失败留档，便于重投
    ├── rounds/<round>.md           # **评审者**按约定落盘的答复原文
    ├── rounds/<round>.md.sentinel  # 陈旧护栏：只认比它更新的答复
    ├── answers/<时间戳>.md          # 本链路归档（含来源头）
    ├── answers/last-answer.md      # 稳定指针：永远指向最近一次答复
    └── codex-helper.log
```

## 2. 退出码

| 码 | 出处 | 含义 | 处置 |
| --- | --- | --- | --- |
| 0 | 全部 | 成功（已投递 / 已拿到答复） | — |
| 2 | relay | 等评审者空闲超时 | 它可能正忙或卡住；看画面 |
| 3 | relay/watch | 投递失败 / 等回合结束超时 / 要求落盘但文件不新鲜 | 问题在 `pending/` 可重投 |
| 4 | watch | 画面有 `Reconnecting`/`Bad Gateway`/余额/拉黑，**或答复为空** | 不得当答复用 |
| 5 | 全部 | 参数/环境问题；**也用于 flock 抢锁失败** | 按提示修；抢锁失败就等或并批 |

## 3. RELAY BLOCK（stdout，机器可读）

```
=== CODEX ANSWER READY ===
target_session: <去向提示，可空>
answer_file: /…/answers/20260916T225058-3620241.md     ← 正文只认这个
source: file:/…/rounds/R7.md                            ← file: 优先；pane 是退化路径
chars: 15321
tmux: test:0.0
next_hop: 读 answer_file 的正文 → 核验关键引用 → 落地/转给需要它的人
checklist: ① 读 answer_file ② 核验 ③ 再落地 ④ 冲突就带反例再问一轮
=== ANSWER (truncated at 20000 chars) ===
…
=== END ===
```

## 4. 投递前的四道门（都实现在脚本里，不要手工绕过）

1. **忙闲门控**：`capture-pane -S -12` 里**连续 2 次**看不到忙标记才算空闲。
   投递成功的判据是画面**重新出现**忙标记，而不是"回车发出去几次"。
2. **回滚模式**：面板若在 copy-mode/view-mode（右上角 `xxx/xxx`），
   `capture-pane` 看到的是**回滚位置**而不是实时画面 ⇒ 忙闲判断与正文抽取都会失真。
   脚本会先 `send-keys -X cancel`（失败再 `copy-mode -q`）自动退出该模式；退不掉就拒投。
3. **人因门**：有人挂在那个 tmux 会话上、且 `window_activity` 在 `HUMAN_GUARD`（默认 15s）内
   → 暂缓投递（怕打扰正在打字的人）。实测：窗口空闲时 `window_activity` 不跳，所以这个门不会误锁。
4. **互斥**：`flock` 抢 `ask.lock`，抢不到直接 exit 5。两个 watcher 会抓到同一条答复。

## 5. 陈旧答复护栏

复用同一轮名字（`--round R7`）时，上一轮的 `R7.md` 还在。所以 `codex-ask.sh` 在投递前写一个
`R7.md.sentinel`，`codex-watch.sh --since <sentinel>` 只认**比它更新**的答复文件；
不够新就当作"没有答复"（退化为抓画面，或 `--require-answer-file` 时 exit 3）。

## 6. 故障排查

| 现象 | 原因 | 处置 |
| --- | --- | --- |
| `tmux 目标不存在` | 会话改名 / tmux 服务器重启 | `codex-config.sh discover` → `set-target` / `set-title` |
| 自动发现命中多个 | 有多个 Codex 面板 | `set-title '<状态栏右侧标题子串>'` 唯一确定（脚本拒绝猜） |
| relay 一直「暂缓投递：有人挂在会话上…」 | 有人正在那个 pane 里打字 | 等它停手；或 `HUMAN_GUARD=0` 显式关掉这道门 |
| relay 报「提交失败（8 次 C-m 后仍未进入 Working）」 | 粘贴吞了回车 / 正文含忙标记串 | 看画面里有没有完整问题文本；重跑 |
| watch rc=3 且提示「不比标记新」 | 评审者没写答复文件（只有旧文件） | 看画面确认它是否真的答了；必要时重投 |
| watch rc=4 | 画面有 provider 报错 / 答复为空 | 看 provider 状态；确认问题真的投进去了 |
| 答复里混着上一轮内容 | 走了抓画面的退化路径 | 检查问题里的「回复方式」段是否被删掉 |
| 抢锁 exit 5 | 另一个 agent 正在问 | 等它结束，或把问题并进同一批；**不要绕锁** |

## 7. 已知边界（诚实清单）

- **屏幕抓取是启发式的**：忙闲判断靠字符串。若**问题正文本身**包含忙标记串，注入后它会永久留在
  画面里 ⇒ 门控会一直认为它忙。提问时避开这个字符串即可（脚本无法替你判断）。
- **抓画面取答复会混入上一轮内容**：所以问题里必须带「请把答复写入 <文件>」这一段（`codex-ask.sh`
  自动追加；`--no-trailer` 会关掉它，别关）。
- **长回合 / 超时**：`TIMEOUT` 默认 1800s，端到端等待；评审者答得慢就调大。
- **provider 故障**不是「拒绝回答」：带间隔重试（例 6 次 × 5 分钟，**一旦答复文件出现就停**），
  全失败就停下汇报，别无限打。
- **后台任务是"取回"的唯一载体**：如果你的宿主没有后台任务/唤醒能力，就只能前台等或人工看文件。
- **不做跨会话推送**：脚本发不了会话消息（那需要宿主内插件）。要转给别人时，是**你**去转。

## 8. 自测

```bash
bash tests/smoke.sh                    # 静态自检（不碰 tmux、不消耗评审者）
bash tests/smoke.sh --live test:0.0   # 可选：对真实 Codex 跑一次端到端（消耗一点上下文）
```
覆盖：语法、工作区定位与上溯、状态栏解析容错、配置幂等、回滚模式自动退出、
端到端（投递 → 忙闲门控 → 回合结束 → 落盘 → RELAY BLOCK → 稳定指针）、陈旧护栏。
