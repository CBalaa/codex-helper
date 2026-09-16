# codex-helper

把 tmux 里那个 **Codex TUI 当成外部评审者**：投递难题 → 等它答完 → 把答复取回**你自己的会话**。
**不打断它、不轮询、不依赖任何插件。**

```
        ① 写自包含问题          ② 空闲门控投递            ③ 等回合结束
agent ───────────────► queue/*.txt ──► tmux(Codex) ──► rounds/<round>.md
  ▲                                                        │
  └────── 宿主唤醒（后台任务结束） ◄── ④ 归档 + RELAY BLOCK ┘
              ⑤ 核验 → 落地/转给需要它的人
```

## 为什么不需要插件

脚本能驱动、也能观察 tmux，但**脚本无法给会话发消息**（那需要宿主进程内的东西，比如 DSH 的
`ctx.dshBridge`；`dsh` CLI 没有这个入口）。所以链路里"在宿主内的那一环"就是 **agent 本人**：
把脚本挂成**后台任务**，任务结束时宿主唤醒 agent，agent 再读文件。

外部依赖只有系统命令：`tmux`、`ps`、`pgrep`（`flock` 可选，用于同一工作区互斥）。
不依赖任何编辑器/宿主插件，不联网。

## 安装

```bash
./install.sh              # ① 装成 skill（~/.dsh/skills/codex-helper → 本仓库）
                          # ② 把当前目录初始化为工作区（建 .codex_helper/）
./install.sh legacy-links # 可选：让 ~/.dsh-relay/codex-*.sh 也指向本 skill
```

安装用的是**符号链接**：本仓库始终是唯一副本，改一处即生效。

## 快速开始

```bash
S=<skill>/scripts
$S/codex-config.sh show            # 看候选面板、工作区、配置
# 目标不用硬编码：默认 auto 自动发现；用户粘来 tmux 状态栏就能配
$S/codex-config.sh from-statusbar '[mycodex:node*  "codex | my-project" 22:43 16-Sep-26'

# 提问（写成文件，然后**挂后台任务**——不要在前台等）
$S/codex-ask.sh --question q.md --round R7 --timeout 3600
```

跑完 stdout 会有一个机器可读的 `=== CODEX ANSWER READY ===` 块；**正文读 `answer_file`**。

## 配置与状态都在工作区里

```
<工作区>/.codex_helper/config.env   # TARGET / TARGET_TITLE / 超时 / HUMAN_GUARD…
<工作区>/.codex_helper/state/       # queue/ pending/ rounds/ answers/ + 日志
```
建议把 `/.codex_helper/` 加进工作区的 `.gitignore`。工作区由 `$CODEX_HELPER_WORKDIR` 指定，
否则从 `$PWD` 逐级上溯找 `.codex_helper/`。

## 四道安全门（不会打扰人，也不会打断 Codex）

1. **忙闲门控**：连续两次抓屏看不到忙标记才算空闲；投递成功也以画面重新出现忙标记为判据；
2. **回滚模式**：面板在 copy-mode/view-mode（右上角 `xxx/xxx`）时，`capture-pane` 看到的是回滚
   位置而不是实时画面 —— 脚本会**先自动退出该模式**，退不掉就拒投；
3. **人因门**：有人挂在该会话上、且窗口最近十几秒有过活动 ⇒ 暂缓投递（怕打扰正在打字的人）；
4. **互斥**：`flock` 抢锁，抢不到直接退出（两个 watcher 会抓到同一条答复）。

外加**陈旧答复护栏**：复用同一轮名字时，只认比 sentinel 更新的答复文件。

## 自测

```bash
bash tests/smoke.sh                  # 静态自检：不碰 tmux、不消耗评审者上下文
bash tests/smoke.sh --live mycodex:0.0   # 可选：对真实 Codex 跑一次端到端（消耗一点上下文）
```

## 文档分工

- **`SKILL.md`** — agent 入口：什么时候该问、标准动作、问题自包含要求、红线。
- **`reference.md`** — 实现细节：布局、退出码、RELAY BLOCK 字段、故障排查、**已知边界**。
- 本 `README.md` — 人读的概览。
