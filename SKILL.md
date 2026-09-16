---
name: codex-helper
description: Use when an agent is stuck on a hard technical or contract problem it cannot settle from the workspace alone, and a Codex TUI is running in a tmux pane that can act as an independent reviewer. Triggers include a choice between two implementation paths that cannot be decided internally, needing independent falsification of a conclusion you already reached, repeated failure at one spot with no new evidence left, an irreversible decision (data format, external contract, retiring semantics), or the user saying 问一下 codex / 找外部评审者 / tmux 里那个 Codex.
---

# codex-helper

## Overview

把一个 tmux 面板里的 **Codex TUI 当外部评审者**：投递问题 → 等它答完 → 把答复取回你自己的会话。
**不打断它、不轮询、不依赖任何插件。**

零插件：只用 `tmux` / `ps` / `pgrep`（`flock` 可选）。所谓「自动取回」靠的是
**你自己的后台任务**——脚本跑完时宿主唤醒你，你再读它写下的文件。脚本本身无法给会话发消息。

## 什么时候用

**默认不问。** 四条同时成立才值得问：

1. 本地已经挖不出新证据（不是懒得查）；
2. 答案是**二选一/多选一**，且会改变你下一步怎么写；
3. 不是读一遍代码或跑一次测试就能定的；
4. 触及不可逆决定，或需要独立**证伪**你已下的结论。

**不问**：命名/风格/格式；跑一次就知道的；求认同（"我这样对吗"）；已问过且无新证据；进度汇报。
**只问不派活**：它是顾问不是施工队——不要让它改代码、跑构建、提 PR、动文件。
唯一允许它写的是它自己的答复文件。

## 用之前（每个工作区一次）

```bash
<skill>/scripts/codex-config.sh show          # 看工作区、配置、候选面板（含面板标题）
<skill>/scripts/codex-config.sh check         # 体检：依赖 / 目标 / 目录
```
目标**不要硬编码**：默认 `TARGET=auto` 按进程树自动发现。用户粘来 tmux 状态栏那一行时：
```bash
<skill>/scripts/codex-config.sh from-statusbar '[mycodex:node*  "codex | my-project" 22:43 16-Sep-26'
```
配置与运行时状态都落在 `<工作区>/.codex_helper/`（`config.env` + `state/`），不进版本库。

## 标准动作

```bash
# ① 写自包含问题到文件，② 挂成后台任务（关键：绝不在前台阻塞）
<skill>/scripts/codex-ask.sh --question <问题文件> --round R7 --timeout 3600
```
- 宿主后台任务结束时**自动唤醒你** → 读 stdout 的 `=== CODEX ANSWER READY ===` 块；
- ⭐ **正文只认 `answer_file`**（stdout 里的正文会被 `MAX_CHARS` 截断）；
- **先核验**其中 load-bearing 的引用（行号 / 哈希 / 交叉核算）再落地；答复是假设，不是裁定；
- 报错标记或空答复 ⇒ 一律当「未作答」，不得当结论用。

## 问题必须自包含（最容易犯错的一条）

你和它在**同一个工作区，但不共享对话上下文**：它没有你的聊天记录。所以：

- 写清「现象原文 + 你已经查过/排除了什么 + 你要什么形状的答案」；
- **禁止对话黑话**：`第 14 轮`、`S7`、`那条路径`、`我们刚才说的 X`、临时造的名字——它一律不知道；
- 有仓库内证据就给 `file:line` + 命令 + 读数；改写过的说法标明「这是提问方的归纳」；
- 它答不上来时，它应当说"不确定"，而不是猜——正文里可以直接这么要求。

## Red flags

- 想直接 `tmux send-keys` 手工投递 → 那会打断它、也会绕过空闲门控；用脚本；
- 想在前台等答复 → 你的回合会被卡住；挂后台，结束回合，让宿主唤醒你；
- 想省事问一句"这样对吗" → 这是骚扰，不是请教；
- 拿到答复直接照做 → 先核验；与已有读数冲突时带反例再问一轮，或升级给用户；
- 看到 `Working (` 还在屏幕上就认为它忙 → 它可能只是**问题正文里**出现了这几个字。

细节（退出码、故障排查、设计边界）见 [reference.md](reference.md)。