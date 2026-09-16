#!/usr/bin/env bash
# codex-watch.sh — ② 监听 + 取答复：等外部评审者（tmux 里的 Codex）跑完这一回合，把答复交回 agent。
#
# 零依赖：只用系统命令 tmux / ps / pgrep；不依赖任何插件、不经任何网络。
#
# 形态：把**完整**答复归档到 <工作区>/.codex_helper/state/answers/<时间戳>.md，并刷新稳定指针
#       answers/last-answer.md；然后在 stdout 打印一个短小、带机器可读字段的 **RELAY BLOCK**
#       （去向 + 路径 + 摘要 + 正文）。
#       当它作为【后台任务】运行时，宿主会在任务结束时唤醒发起它的 agent 并把输出推给它
#       ⇒ agent 读 answer_file、核验关键引用、再落地。
#       ⭐ 这就是「自动转发」：在宿主内的那一环是 **agent 本人**，不是任何插件。
#
# 用法:
#   scripts/codex-watch.sh                                   # 等结束 + 归档 + 打印 RELAY BLOCK
#   scripts/codex-watch.sh --answer <file.md>                # 用评审者落盘的答复文件当正文（推荐）
#   scripts/codex-watch.sh --require-answer-file             # 只认落盘文件，拿不到就退出 3
#   scripts/codex-watch.sh --print                           # 只看，不归档
#   scripts/codex-watch.sh --to <session-id>                 # 仅在 RELAY BLOCK 里标注去向（可选）
#
# 退出码: 0 已拿到答复 · 3 等回合结束超时（或要求落盘但文件不存在）· 4 Codex 报错标记/答复为空 · 5 参数/环境问题
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/relay-lib.sh"
relay_load_config
RELAY_TAG=watch

PRINT_ONLY=1      # 默认打印 RELAY BLOCK（agent 的后台任务靠 stdout 取答复）
SAVE=1            # 默认归档（宿主/会话挂掉也不丢正文）
DRY_RUN=0
FORWARD_ON_ERROR=0
REQUIRE_ANSWER_FILE=0
SAVE_FILE=""
SINCE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --answer)              ANSWER="${2:-}"; shift 2 ;;
    --save)                SAVE_FILE="${2:-}"; shift 2 ;;
    --no-save)             SAVE=0; shift ;;
    --no-print)            PRINT_ONLY=0; shift ;;
    --print)               PRINT_ONLY=1; shift ;;
    --to)                  TO="${2:-}"; shift 2 ;;
    --target)              TARGET="${2:-}"; shift 2 ;;
    --timeout)             TIMEOUT="${2:-}"; shift 2 ;;
    --poll)                POLL="${2:-}"; shift 2 ;;
    --settle)              SETTLE="${2:-}"; shift 2 ;;
    --max-chars)           MAX_CHARS="${2:-}"; shift 2 ;;
    --dry-run)             DRY_RUN=1; shift ;;
    --forward-on-error)    FORWARD_ON_ERROR=1; shift ;;
    --require-answer-file) REQUIRE_ANSWER_FILE=1; shift ;;
    --since)               SINCE="${2:-}"; shift 2 ;;   # 只认比这个标记文件更新的答复（防读到上一轮的旧答复）
    -h|--help)             sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 5 ;;
  esac
done

case "${TO:-}" in
  ""|session-*) ;;
  *) echo "⚠️ TO=$TO 不像会话 id（一般以 session- 开头）；仅作提示，仍继续。" >&2 ;;
esac

relay_ensure_dirs
relay_resolve_target || exit $?
relay_exit_copy_mode || { relay_log "面板处于回滚查看模式且无法自动退出"; exit 5; }   # 否则 capture-pane 看到的是回滚位置，忙/闲与正文都会失真

# --- 1) 等这一回合结束（连续 SETTLE 次空闲）--------------------------------
if relay_busy; then
  relay_log "Codex 正在运行，等待本回合结束…（$TARGET）"
else
  relay_log "Codex 当前空闲（本回合可能已结束或尚未开始）"
fi

start=$(date +%s)
elapsed() { echo $(( $(date +%s) - start )); }
idle_streak=0
while :; do
  if relay_busy; then idle_streak=0; else idle_streak=$((idle_streak+1)); fi
  [ "$idle_streak" -ge "$SETTLE" ] && break
  if [ "$(elapsed)" -gt "$TIMEOUT" ]; then relay_log "等待回合结束超时（${TIMEOUT}s）"; exit 3; fi
  sleep "$POLL"
done
relay_log "检测到已空闲（连续 $SETTLE 次）"
sleep 2   # 给评审者落盘的答复文件一点写完的时间

# --- 2) 报错判定：宁可报「没拿到答复」，也不要把错误文本当裁定 --------------
if relay_errored; then
  relay_log "⚠️ 画面里出现 Codex/provider 报错标记"
  if [ "$FORWARD_ON_ERROR" -eq 0 ]; then
    relay_log "默认策略【不交付】。要看原文加 --forward-on-error。"
    exit 4
  fi
fi

# --- 3) 取答复正文：优先用落盘文件（终端画面会截断、混进状态栏与上一轮旧内容）---
body=""
source_kind="pane"
answer_usable=1
[ -s "${ANSWER:-}" ] || answer_usable=0
if [ "$answer_usable" -eq 1 ] && [ -n "${SINCE:-}" ] && [ -e "$SINCE" ] && [ ! "$ANSWER" -nt "$SINCE" ]; then
  relay_log "⚠️ 答复文件不比标记新（可能是上一轮的旧答复）：$ANSWER"
  answer_usable=0
fi
# 完整性：连续两次采样的字节数一致，才算「写完了」（防读到半截文件）。
if [ "$answer_usable" -eq 1 ] && ! relay_file_stable "$ANSWER"; then
  relay_log "⚠️ 答复文件在采样期间还在变（疑似未写完）：$ANSWER"
  answer_usable=0
fi
if [ "$answer_usable" -eq 1 ]; then
  body="$(cat "$ANSWER")"
  source_kind="file:$ANSWER"
elif [ "$REQUIRE_ANSWER_FILE" -eq 1 ]; then
  relay_log "要求落盘答复，但文件不存在/为空/不比标记新: ${ANSWER:-<未指定>}"
  exit 3
else
  body="$(relay_pane 200 \
    | grep -vE '^ *[›»] |^ *gpt-|ctrl \+ /|Context .* left|^ *─+$' \
    | sed -e 's/[[:space:]]*$//' \
    | awk 'NF{last=NR} {lines[NR]=$0} END{for(i=1;i<=last;i++) print lines[i]}')"
fi

if [ -z "${body//[[:space:]]/}" ]; then
  relay_log "答复为空（文件与画面都没拿到内容）"
  exit 4
fi

stamp="$(relay_now)"
chars="${#body}"
message="$(printf '【来自外部评审者（tmux:%s）· %s · 来源=%s】\n\n%s\n' "$TARGET" "$stamp" "$source_kind" "$body")"

# --- 4) 归档完整正文（stdout 只放摘要 + 截断正文）---------------------------
answer_file=""
if [ "$SAVE" -eq 1 ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    answer_file="$ANSWERS/<dry-run-未写>.md"
  else
    [ -n "$SAVE_FILE" ] || SAVE_FILE="$ANSWERS/$(date +%Y%m%dT%H%M%S)-$$.md"
    mkdir -p "$(dirname "$SAVE_FILE")" "$ANSWERS" 2>/dev/null || true
    printf '%s' "$message" > "$SAVE_FILE"
    cp -f "$SAVE_FILE" "$ANSWERS/last-answer.md" 2>/dev/null || true
    answer_file="$SAVE_FILE"
    relay_log "答复已归档: $SAVE_FILE（稳定指针 $ANSWERS/last-answer.md）"
  fi
fi

# --- 5) RELAY BLOCK：后台任务结束时被推给发起它的 agent，必须短且自足 -------
if [ "$PRINT_ONLY" -eq 1 ]; then
  printf '\n=== CODEX ANSWER READY ===\n'
  printf 'target_session: %s\n' "${TO:-<未指定：由转发者决定去向>}"
  printf 'answer_file: %s\n' "${answer_file:-<未落盘>}"
  printf 'source: %s\n' "$source_kind"
  printf 'chars: %s\n' "$chars"
  printf 'tmux: %s\n' "$TARGET"
  printf 'next_hop: 读 answer_file 的正文 → 核验关键引用 → 落地/转给需要它的人\n'
  printf 'checklist: ① 读 answer_file ② 核验其中的哈希/行号/交叉核算 ③ 再落地 ④ 与已有证据冲突就带反例再问一轮\n'
  printf '=== ANSWER (truncated at %s chars) ===\n' "$MAX_CHARS"
  if [ "$chars" -gt "$MAX_CHARS" ]; then
    printf '%s\n…[truncated; full text in answer_file]\n' "$(printf '%s' "$body" | head -c "$MAX_CHARS")"
  else
    printf '%s\n' "$body"
  fi
  printf '=== END ===\n'
fi

if [ "$DRY_RUN" -eq 1 ]; then
  relay_log "dry-run：--save=$SAVE --print=$PRINT_ONLY（未写盘）"
fi

if [ "$SAVE" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
  printf '%s [watch] answer=%s target=%s chars=%s source=%s\n' \
    "$stamp" "$answer_file" "${TO:-<none>}" "$chars" "$source_kind" >> "$LOG" 2>/dev/null || true
fi
exit 0
