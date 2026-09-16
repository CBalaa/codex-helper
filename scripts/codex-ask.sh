#!/usr/bin/env bash
# codex-ask.sh — ③ 一条命令走完「提问 → 监听 → 自动取答复」。
#
#   ① 把问题（+ 回复方式段 + 边界声明）写成队列项
#   ② codex-relay.sh 在 Codex 空闲时投递（绝不打断它正在跑的回合）
#   ③ codex-watch.sh 等这一回合结束 → 抽取答复 → 归档 + 打印 RELAY BLOCK
#
# 零依赖：只用系统命令 tmux / ps / pgrep（flock 可选，用于互斥）；不依赖任何插件、不经网络。
# ⭐ 正确用法：把它挂成【后台任务】（DSH: run_in_background: true），然后结束当前回合。
#    任务跑完时宿主会自动唤醒发起它的 agent，agent 读 stdout 的 RELAY BLOCK 与 answer_file 再落地。
#    脚本本身不需要、也无法给会话发消息——在宿主内的那一环就是 **agent 本人**。
#
# 用法:
#   scripts/codex-ask.sh --round R7 <<'EOF'
#     问题正文……
#   EOF
#   scripts/codex-ask.sh --question q.txt --round R7 --timeout 3600
#   scripts/codex-ask.sh --question q.txt --dry-run          # 全链路演练：不投、不写盘
#   scripts/codex-ask.sh --question q.txt --no-trailer       # 不自动追加回复方式/边界段
#
# 退出码: 0 拿到答复 · 2 等 Codex 空闲超时 · 3 投递失败/等答复超时 · 4 Codex 报错标记 · 5 参数问题
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/relay-lib.sh"
relay_load_config
RELAY_TAG=ask

QUESTION_FILE=""
ROUND=""
DRY_RUN=0
NO_TRAILER=0
RELAY="${RELAY:-$RELAY_SCRIPT_DIR/codex-relay.sh}"
WATCH="${WATCH:-$RELAY_SCRIPT_DIR/codex-watch.sh}"

while [ $# -gt 0 ]; do
  case "$1" in
    --question)   QUESTION_FILE="${2:-}"; shift 2 ;;
    --round)      ROUND="${2:-}"; shift 2 ;;
    --target)     TARGET="${2:-}"; shift 2 ;;
    --timeout)    TIMEOUT="${2:-}"; shift 2 ;;
    --poll)       POLL="${2:-}"; shift 2 ;;
    --settle)     SETTLE="${2:-}"; shift 2 ;;
    --max-chars)  MAX_CHARS="${2:-}"; shift 2 ;;
    --to)         TO="${2:-}"; shift 2 ;;
    --answer)     ANSWER="${2:-}"; shift 2 ;;
    --no-trailer) NO_TRAILER=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -h|--help)    sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 5 ;;
  esac
done

[ -x "$RELAY" ] || { echo "找不到可执行的 $RELAY" >&2; exit 5; }
[ -x "$WATCH" ] || { echo "找不到可执行的 $WATCH" >&2; exit 5; }

# --- ① 取问题正文 -----------------------------------------------------------
if [ -n "$QUESTION_FILE" ]; then
  [ -s "$QUESTION_FILE" ] || { echo "问题文件不存在或为空: $QUESTION_FILE" >&2; exit 5; }
  question="$(cat "$QUESTION_FILE")"
else
  question="$(cat)"
fi
[ -n "${question//[[:space:]]/}" ] || { echo "问题为空（用 --question <file> 或 stdin）" >&2; exit 5; }

target_was_auto=0
[ -z "$TARGET" ] || [ "$TARGET" = auto ] && target_was_auto=1
relay_ensure_dirs
relay_resolve_target || exit $?

# --- 互斥：同一条链路上同时只允许一次提问 -----------------------------------
# 为什么需要：两个 agent 同时问，会各自起一个 watcher，抓到的可能是同一条答复
# （重复投递、张冠李戴），而且会互相打断对 tmux 的观察。评审者上下文是稀缺资源，
# 本来就该「攒够一批再问」。非阻塞抢锁，抢不到就明确报错，绝不排队等待。
if command -v flock >/dev/null 2>&1; then
  LOCK="${LOCK:-$CH_DIR/ask.lock}"
  exec 9>"$LOCK"        # 注意：exec 上的重定向会永久生效，绝不能在这里写 2>/dev/null（会把整个脚本的 stderr 吞掉）
  if ! flock -n 9 2>/dev/null; then
    echo "已有一次提问/监听在进行中（锁：$LOCK）。" >&2
    echo "评审者上下文稀缺：等它结束，或把问题攒进同一批。要看现状：$RELAY_SCRIPT_DIR/codex-watch.sh --print" >&2
    exit 5
  fi
fi

stamp_id="${ROUND:-$(date +%Y%m%dT%H%M%S)}"
[ -n "$ANSWER" ] || ANSWER="$ROUNDS/$stamp_id.md"

# 回复方式 + 边界：让评审者把答复**落盘**（终端画面会截断、混入状态栏与上一轮旧内容），
# 并明确它只做顾问、不动仓库。
if [ "$NO_TRAILER" -eq 0 ]; then
  question="$(printf '%s\n\n---\n【回复方式】请把最终答复完整写入文件（不是只在这里复述）：\n%s\n写完后一句话确认即可。\n【上下文】你只有这个工作区，没有提问方的对话历史：正文里若出现你无法从仓库确认的说法，请直接指出，不要猜。\n【边界】只请你就上面的问题给出解答：不要修改仓库里的任何文件、不要跑构建、不要做代码改动。\n唯一允许你写的是上面那个答复文件。\n' "$question" "$ANSWER")"
fi

# --- ② 投递（空闲门控）------------------------------------------------------
item="$QUEUE/$stamp_id-$$.txt"
if [ "$DRY_RUN" -eq 1 ]; then
  relay_log "dry-run：工作区 = $WORKSPACE（配置 $RELAY_CONFIG_FILE）"
  relay_log "dry-run：评审者目标 = $TARGET（$([ "$target_was_auto" -eq 1 ] && echo 自动发现 || echo 显式指定)）"
  relay_log "dry-run：答复落盘 = $ANSWER"
  relay_log "dry-run：会写入队列项 $item（${#question} 字符）"
  relay_log "dry-run：会执行 $RELAY --target $TARGET --queue $QUEUE"
  relay_log "dry-run：会执行 $WATCH --target $TARGET --answer $ANSWER"
  relay_log "dry-run：**不投递、不写盘**。下面是将被送进 tmux 的完整正文："
  printf '%s\n' "$question"
  exit 0
fi

printf '%s' "$question" > "$item"
relay_log "已入队：$item（${#question} 字符）"

# 陈旧答复护栏：留一个标记文件，watch 只认比它更新的答复文件。
# （复用同一轮名字 --round R7 时，上一轮的 R7.md 还在，不设标记就会把旧答复当成新的。）
ANSWER_MARK="${ANSWER}.sentinel"
: > "$ANSWER_MARK" 2>/dev/null || true

relay_log "调用 relay（只在 Codex 空闲时投递，绝不打断）…"
TARGET="$TARGET" QUEUE="$QUEUE" TIMEOUT="$TIMEOUT" POLL="$POLL" bash "$RELAY"
relay_rc=$?
if [ "$relay_rc" -ne 0 ]; then
  if [ -f "$item" ]; then
    mv "$item" "$PENDING/$(basename "$item")" 2>/dev/null || true
    relay_log "投递未成功（relay rc=$relay_rc）⇒ 队列项已移入 $PENDING/ 以便重投"
  else
    relay_log "投递未成功（relay rc=$relay_rc）"
  fi
  exit "$relay_rc"
fi
relay_log "投递完成"

# --- ③ 等回合结束 + 取答复（归档 + 打印 RELAY BLOCK）-------------------------
"$WATCH" --target "$TARGET" --answer "$ANSWER" --timeout "$TIMEOUT" --poll "$POLL" \
  --settle "$SETTLE" --max-chars "$MAX_CHARS" --to "$TO" --since "$ANSWER_MARK"
watch_rc=$?

case "$watch_rc" in
  0) relay_log "完成：答复已打印到 stdout 并归档到 $ANSWERS/（评审者原文：$ANSWER）" ;;
  3) relay_log "超时：未在 ${TIMEOUT}s 内拿到答复（问题仍在 $PENDING/ 或需人工看 tmux）" ;;
  4) relay_log "Codex 侧出现错误标记或答复为空：未交付（建议先看 tmux 画面再决定重投）" ;;
  *) relay_log "异常退出：rc=$watch_rc" ;;
esac
exit "$watch_rc"
