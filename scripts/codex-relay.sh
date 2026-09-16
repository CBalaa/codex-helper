#!/usr/bin/env bash
# codex-relay.sh — ① 投递：把 queue/*.txt 里的问题送给 tmux 里的外部评审者（Codex TUI）。
#
# 铁律：**绝不打断 Codex 正在跑的回合**。本脚本只在「连续 2 次轮询都抓不到 Working (」
# 判定为空闲时才投递；投递是否成功也以「画面进入 Working (」为判据，而不是以回车次数。
#
# 用法:
#   scripts/codex-relay.sh                      # 用配置里的 TARGET（默认 auto 自动发现）
#   scripts/codex-relay.sh --target tt-loop-13:0
#   echo "问题正文" > <RELAY_DIR>/queue/001.txt && scripts/codex-relay.sh
#
# 退出码: 0 队列已清空 · 2 等空闲超时 · 3 提交失败（8 次 C-m 后仍未进入 Working）· 5 参数/环境问题
set -uo pipefail
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/relay-lib.sh"   # readlink -f：经 ~/.dsh-relay 的旧符号链接调用时也能定位仓库
relay_load_config
RELAY_TAG=relay

while [ $# -gt 0 ]; do
  case "$1" in
    --target)   TARGET="${2:-}"; shift 2 ;;
    --queue)    QUEUE="${2:-}"; shift 2 ;;
    --timeout)  TIMEOUT="${2:-}"; shift 2 ;;
    --poll)     POLL="${2:-}"; shift 2 ;;
    --tail)     TAIL="${2:-}"; shift 2 ;;
    -h|--help)  sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 5 ;;
  esac
done
TAIL="${TAIL:-180}"

relay_ensure_dirs
relay_resolve_target || exit $?
[ -d "$QUEUE" ] || { echo "队列目录不存在: $QUEUE（先跑 codex-config.sh init）" >&2; exit 5; }

start=$(date +%s)
elapsed() { echo $(( $(date +%s) - start )); }

wait_idle() { # 连续 2 次空闲、且没有人在动这个 pane，才允许投递
  local n=0 reason
  while :; do
    if relay_busy; then n=0; else n=$((n+1)); fi
    if [ "$n" -ge 2 ]; then
      if reason="$(relay_inject_blocked_reason)"; then
        relay_log "暂缓投递：$reason（继续等，HUMAN_GUARD=${HUMAN_GUARD:-15}s）"
        n=0
      else
        return 0
      fi
    fi
    [ "$(elapsed)" -gt "$TIMEOUT" ] && { relay_log "等待 $TARGET 空闲超时（${TIMEOUT}s）"; return 1; }
    sleep "$POLL"
  done
}

submit() { # $1 = 队列文件
  local f="$1" i
  relay_exit_copy_mode || true   # 万一等待期间有人上翻进了回滚模式，投递前再退一次
  tmux send-keys -t "$TARGET" -l "$(cat "$f")"
  for i in 1 2 3 4 5 6 7 8; do
    sleep 3; tmux send-keys -t "$TARGET" C-m; sleep 3
    if relay_busy; then relay_log "已提交 $(basename "$f")（第 $i 次 C-m 生效）"; return 0; fi
  done
  relay_log "提交失败（8 次 C-m 后仍未进入 Working）：$(basename "$f")"
  return 1
}

sent=0
while :; do
  f=$(/bin/ls "$QUEUE"/*.txt 2>/dev/null | head -1)
  # ⭐ 先看队列再看忙闲：刚投完且队列已空 ⇒ **立刻收工**，不要再等它把这一回合跑完。
  #    （实测踩过：旧顺序会在投递后白等整轮 6m51s，让「监听」迟迟才开始。）
  if [ -z "$f" ]; then
    if [ "$sent" -ge 1 ]; then relay_log "队列已清空，投递完成，收工（不等它答完；监听随后接管）"; break; fi
    [ "$(elapsed)" -gt "$TIMEOUT" ] && { relay_log "空队列等待超时"; break; }
    sleep "$POLL"
    continue
  fi
  wait_idle || exit 2
  relay_log "发送队列项：$(basename "$f") → $TARGET"
  if submit "$f"; then rm -f "$f"; sent=1; else exit 3; fi
done

echo "=== 队列剩余（$QUEUE）==="
/bin/ls -1 "$QUEUE" 2>/dev/null | grep . || echo "(空)"
echo "=== $TARGET 末 $TAIL 行 ==="
tmux capture-pane -p -t "$TARGET" -S -"$TAIL"
