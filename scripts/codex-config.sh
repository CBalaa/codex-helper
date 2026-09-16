#!/usr/bin/env bash
# codex-config.sh — 配置/体检入口：把「tmux 里的外部评审者是谁」变成一条命令。
#
# 对话里最省事的用法：用户把 tmux **状态栏那一行**原样粘过来，agent 跑：
#   scripts/codex-config.sh from-statusbar '[mycodex:node*   "codex | my-project" 22:43 16-Sep-26'
# 它会：解析出「会话:窗口」与「面板标题」→ 会话还在就写死会话；会话改名了就改用面板标题定位
# （面板标题就是状态栏右边那个带引号的串），并把结果写进 <工作区>/.codex_helper/config.env。
#
# 子命令:
#   show                        打印生效配置 + 工作区/路径 + 所有 Codex 面板候选（含标题）
#   discover                    列出所有跑着 Codex TUI 的 tmux 目标
#   init                        建 <工作区>/.codex_helper/{config.env,state/…}
#   from-statusbar '<状态栏>'      按用户粘贴的状态栏配置（推荐）
#   set-target <tmux目标|auto>   写 TARGET（auto = 自动发现）
#   set-title <标题子串|->       写 TARGET_TITLE（多面板时用标题筛选；- 表示清空）
#   set-to <session-id|->       写 TO（可选：只用于在 RELAY BLOCK 里标注去向）
#   set <KEY> <值>              写任意键（TIMEOUT/POLL/SETTLE/MAX_CHARS…）
#   check                       体检：语法、依赖、tmux 目标、目录、配置文件
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/relay-lib.sh"

cmd="${1:-show}"; shift 2>/dev/null || true

ensure_config() {
  if [ ! -f "$RELAY_CONFIG_FILE" ] && [ -f "$RELAY_SKILL_ROOT/config.env.example" ]; then
    cp "$RELAY_SKILL_ROOT/config.env.example" "$RELAY_CONFIG_FILE"
    echo "已创建 $RELAY_CONFIG_FILE（来自 $RELAY_SKILL_ROOT/config.env.example）"
  fi
}

show_candidates() {
  local panes
  panes="$(relay_discover_panes)"
  if [ -z "$panes" ]; then echo "  （无：没有任何 tmux 面板在跑 Codex TUI）"; return 0; fi
  while IFS=$'\t' read -r tgt title; do
    [ -n "$tgt" ] || continue
    printf '  %-18s 标题=[%s]\n' "$tgt" "$title"
  done <<< "$panes"
  return 0
}

case "$cmd" in
  init)
    ensure_config
    relay_load_config; relay_ensure_dirs
    echo "工作区: $WORKSPACE"
    echo "配置  : $RELAY_CONFIG_FILE"
    echo "状态  : $RELAY_DIR"
    ls -d "$QUEUE" "$PENDING" "$ROUNDS" "$ANSWERS" 2>/dev/null
    ;;

  discover)
    relay_load_config
    found="$(relay_discover_target)"
    if [ -z "$found" ]; then
      echo "没有任何 tmux 面板在跑 Codex TUI。" >&2
      echo "先确认评审者会话：tmux ls && tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_pid}'" >&2
      exit 5
    fi
    printf '%s\n' "$found"
    n="$(printf '%s\n' "$found" | grep -c .)"
    [ "$n" -gt 1 ] && echo "⚠️ 命中 $n 个：请用 set-title 指定标题子串，或用 set-target 指定其中一个。" >&2
    exit 0
    ;;

  from-statusbar)
    [ $# -ge 1 ] || { echo "用法: codex-config.sh from-statusbar '<状态栏整行>'" >&2; exit 5; }
    relay_load_config
    parsed="$(relay_parse_statusbar "$1")" || {
      echo "解析失败：请把状态栏整行原样粘进来（形如 [mycodex:node*  \"codex | my-project\" 22:43 16-Sep-26）" >&2
      exit 5
    }
    sw="${parsed%%$'\t'*}"; title="${parsed#*$'\t'}"
    ensure_config
    echo "状态栏解析：会话:窗口 = [$sw]  面板标题 = [${title:-<无>}]"
    if command -v tmux >/dev/null 2>&1 && tmux list-panes -t "$sw" >/dev/null 2>&1; then
      relay_set_kv "$RELAY_CONFIG_FILE" TARGET "$sw"
      [ -n "$title" ] && relay_set_kv "$RELAY_CONFIG_FILE" TARGET_TITLE "$title"
      echo "→ 该会话在当前 tmux 服务器上存在，已写 TARGET=$sw"
      exit 0
    fi
    echo "→ 当前 tmux 服务器上没有名为 [$sw] 的会话（会话被改名或服务器重启过），改用面板标题定位。"
    panes="$(relay_discover_panes)"
    if [ -n "$title" ]; then
      matched="$(printf '%s\n' "$panes" | relay_filter_by_title "$title")"
      n="$(printf '%s\n' "$matched" | grep -c . 2>/dev/null || true)"
      case "${n:-0}" in
        1) relay_set_kv "$RELAY_CONFIG_FILE" TARGET "auto"
           relay_set_kv "$RELAY_CONFIG_FILE" TARGET_TITLE "$title"
           echo "→ 命中唯一面板：$(printf '%s' "$matched" | cut -f1)（标题含 '$title'）"
           echo "   已写 TARGET=auto + TARGET_TITLE=$title（会话再改名也不用管）"
           exit 0 ;;
        0) echo "→ 没有面板的标题含 '$title'。当前候选：" >&2; show_candidates >&2; exit 5 ;;
        *) echo "→ 标题 '$title' 命中多个面板，拒绝猜测：" >&2; relay_print_panes "$matched" >&2; exit 5 ;;
      esac
    fi
    n="$(printf '%s\n' "$panes" | grep -c . 2>/dev/null || true)"
    if [ "${n:-0}" -eq 1 ]; then
      relay_set_kv "$RELAY_CONFIG_FILE" TARGET "auto"
      echo "→ 状态栏里没解析出标题，但全场只有一个 Codex 面板：$(printf '%s' "$panes" | cut -f1)；已写 TARGET=auto"
      exit 0
    fi
    echo "→ 状态栏里没解析出标题，且有多个候选，无法确定：" >&2; show_candidates >&2; exit 5
    ;;

  set-target)
    [ $# -ge 1 ] || { echo "用法: codex-config.sh set-target <会话:窗口[.面板]|auto>" >&2; exit 5; }
    ensure_config
    relay_set_kv "$RELAY_CONFIG_FILE" TARGET "$1"
    echo "TARGET=$1 已写入 $RELAY_CONFIG_FILE"
    ;;

  set-title)
    [ $# -ge 1 ] || { echo "用法: codex-config.sh set-title <标题子串|->" >&2; exit 5; }
    ensure_config
    v="$1"; [ "$v" = "-" ] && v=""
    relay_set_kv "$RELAY_CONFIG_FILE" TARGET_TITLE "$v"
    echo "TARGET_TITLE=$v 已写入 $RELAY_CONFIG_FILE（多面板时按面板标题筛选）"
    ;;

  set-to)
    [ $# -ge 1 ] || { echo "用法: codex-config.sh set-to <session-id|->" >&2; exit 5; }
    ensure_config
    v="$1"; [ "$v" = "-" ] && v=""
    relay_set_kv "$RELAY_CONFIG_FILE" TO "$v"
    echo "TO=$v 已写入 $RELAY_CONFIG_FILE（可选，仅用于在 RELAY BLOCK 里标注去向）"
    ;;

  set)
    [ $# -ge 2 ] || { echo "用法: codex-config.sh set <KEY> <值>" >&2; exit 5; }
    ensure_config
    relay_set_kv "$RELAY_CONFIG_FILE" "$1" "$2"
    echo "$1=$2 已写入 $RELAY_CONFIG_FILE"
    ;;

  show)
    relay_load_config
    if [ -f "$RELAY_CONFIG_FILE" ]; then cfg="$RELAY_CONFIG_FILE"; else cfg="$RELAY_CONFIG_FILE（不存在，用内置默认；可先跑 init）"; fi
    echo "skill 位置    : $RELAY_SKILL_ROOT"
    echo "工作区        : $WORKSPACE"
    echo "配置文件      : $cfg"
    echo "状态目录      : $RELAY_DIR"
    echo "  queue       : $QUEUE"
    echo "  pending     : $PENDING"
    echo "  rounds      : $ROUNDS   （评审者按约定落盘的答复原文）"
    echo "  answers     : $ANSWERS   （本链路归档 + last-answer.md 稳定指针）"
    echo "评审者配置    : TARGET=${TARGET} $([ "$TARGET" = auto ] && echo '（auto：自动发现）' || echo '（显式指定）')  TARGET_TITLE=${TARGET_TITLE:-<未设>}"
    echo "Codex 面板候选:"
    show_candidates
    if relay_resolve_target 2>/dev/null; then
      echo "解析后目标    : $TARGET"
      if relay_busy; then echo "当前状态      : 忙（Working…）—— 投递会等它跑完"; else echo "当前状态      : 空闲"; fi
      relay_errored && echo "⚠️ 画面里有报错标记（Reconnecting/余额/拉黑…）"
    else
      echo "解析后目标    : ⚠️ 无法解析（见上面 stderr，可先 from-statusbar 或 set-target）"
    fi
    echo "去向提示      : ${TO:-<空>}（可选；默认取 \$DSH_SESSION_ID=${DSH_SESSION_ID:-未设置}）"
    echo "等待参数      : TIMEOUT=$TIMEOUT POLL=$POLL SETTLE=$SETTLE MAX_CHARS=$MAX_CHARS"
    ;;

  check)
    rc=0
    echo "== 1. 脚本语法 =="
    for f in "$RELAY_SCRIPT_DIR"/*.sh; do
      if bash -n "$f" 2>/dev/null; then echo "  ok   $(basename "$f")"; else echo "  FAIL $(basename "$f")"; bash -n "$f"; rc=1; fi
    done
    echo "== 2. 外部依赖（只用系统命令，零插件）=="
    for c in tmux ps pgrep; do
      if command -v "$c" >/dev/null 2>&1; then echo "  ok   $c（必需）"; else echo "  FAIL $c（必需）"; rc=1; fi
    done
    if command -v flock >/dev/null 2>&1; then echo "  ok   flock（可选：同一工作区互斥）"; else echo "  提示 无 flock：互斥失效，多 agent 并行时需自行协调"; fi
    echo "== 3. tmux 目标 =="
    relay_load_config
    if relay_resolve_target; then echo "  ok   目标=$TARGET"; else echo "  FAIL 无法解析评审者目标"; rc=1; fi
    echo "== 4. 工作区与目录 =="
    echo "  ok   工作区=$WORKSPACE"
    relay_ensure_dirs
    for d in "$CH_DIR" "$RELAY_DIR" "$QUEUE" "$PENDING" "$ROUNDS" "$ANSWERS"; do
      [ -d "$d" ] && echo "  ok   $d" || { echo "  FAIL $d"; rc=1; }
    done
    echo "== 5. 配置文件 =="
    [ -f "$RELAY_CONFIG_FILE" ] && echo "  ok   $RELAY_CONFIG_FILE" || echo "  提示 尚未创建（先跑 init）"
    echo "== 6. 插件依赖 =="
    echo "  无：本 skill 只用 tmux/ps/pgrep/flock 与「后台任务结束唤醒 agent」，不依赖任何编辑器/宿主插件。"
    exit "$rc"
    ;;

  -h|--help|help|"")
    sed -n '2,19p' "$0"
    ;;

  *)
    echo "未知子命令: $cmd（可用：show discover init from-statusbar set-target set-title set-to set check）" >&2
    exit 5
    ;;
esac