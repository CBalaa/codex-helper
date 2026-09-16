#!/usr/bin/env bash
# relay-lib.sh — codex-helper 的共享库（被 codex-{config,relay,watch,ask}.sh source）
#
# 布局约定（这个仓库是 **skill 仓库**，不含任何工作区特定内容）：
#   代码  <skill 仓库>/scripts/*.sh          ← 本文件所在目录
#   配置  <工作区>/.codex_helper/config.env  ← 仓库/机器特定，由工作区自己持有
#   状态  <工作区>/.codex_helper/state/      ← queue/ pending/ rounds/ answers/ inbox/ + 日志
#
# 工作区 = $CODEX_HELPER_WORKDIR，否则从 $PWD 逐级上溯找 .codex_helper/，都没有就取 $PWD。
# 配置优先级（高 → 低）：命令行参数 > 环境变量 > <工作区>/.codex_helper/config.env > 内置默认。
# config.env 必须写成 KEY="${KEY:-值}" 的形式，这条优先级才成立。
#
# 每个脚本的标准开头：
#   set -uo pipefail
#   . ".../relay-lib.sh"
#   relay_load_config          # ① 定位工作区 ② 载入 config.env ③ 落定默认值
#   ...解析命令行参数...        # ④ 命令行覆盖一切
#   relay_resolve_target       # ⑤ TARGET=auto 时自动发现 tmux 里的 Codex TUI

RELAY_LIB_SELF="${BASH_SOURCE[0]}"
RELAY_SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$RELAY_LIB_SELF")")" && pwd)"   # <skill>/scripts
RELAY_SKILL_ROOT="$(cd "$RELAY_SCRIPT_DIR/.." && pwd)"                            # <skill>

relay_log() { printf '[%s %s] %s\n' "${RELAY_TAG:-relay}" "$(date +%H:%M:%S)" "$*" >&2; }

# ---------------------------------------------------------------------------
# 工作区定位
# ---------------------------------------------------------------------------
relay_find_workspace() {
  local d
  if [ -n "${CODEX_HELPER_WORKDIR:-}" ]; then printf '%s\n' "$CODEX_HELPER_WORKDIR"; return 0; fi
  d="$PWD"
  while :; do
    if [ -d "$d/.codex_helper" ]; then printf '%s\n' "$d"; return 0; fi
    [ "$d" = "/" ] && break
    d="$(dirname "$d")"
  done
  printf '%s\n' "$PWD"     # 谁都没有就落在当前目录（第一次 init 会在那里建）
  return 0
}

# 路径解析：只依赖 $PWD 与环境，source 时就算好——这样不读配置的子命令（如 set-target）也能直接用。
WORKSPACE="$(relay_find_workspace)"
CH_DIR="$WORKSPACE/.codex_helper"
RELAY_CONFIG_FILE="${RELAY_CONFIG_FILE:-$CH_DIR/config.env}"

# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------
relay_load_config() {
  local f

  local f
  for f in "${RELAY_CONFIG:-}" "$RELAY_CONFIG_FILE"; do
    [ -n "$f" ] && [ -f "$f" ] && . "$f"
  done

  # 运行时状态：默认落在工作区自己的 .codex_helper/state（可被 config.env / 环境覆盖）。
  RELAY_DIR="${RELAY_DIR:-$CH_DIR/state}"
  QUEUE="${QUEUE:-$RELAY_DIR/queue}"
  PENDING="${PENDING:-$RELAY_DIR/pending}"
  INBOX="${INBOX:-$RELAY_DIR/inbox}"
  ROUNDS="${ROUNDS:-$RELAY_DIR/rounds}"          # 评审者按约定落盘的答复原文（问题里指定的那个路径）
  ANSWERS="${ANSWERS:-$RELAY_DIR/answers}"       # 本链路归档：<时间戳>.md + 稳定指针 last-answer.md
  LOG="${LOG:-$RELAY_DIR/codex-helper.log}"

  # tmux 里的外部评审者：auto = 自动发现（会话名会变，别硬编码）。
  TARGET="${TARGET:-auto}"
  # 多个 Codex 面板同时在跑时，用面板标题进一步筛选（对应 tmux 状态栏右侧那个 "..." 串）。
  TARGET_TITLE="${TARGET_TITLE:-}"
  # 答复送回哪个 DSH 会话：默认就是发起提问的当前会话。
  TO="${TO:-${DSH_SESSION_ID:-}}"
  ANSWER="${ANSWER:-}"

  TIMEOUT="${TIMEOUT:-1800}"      # 端到端等待上限（秒）
  POLL="${POLL:-5}"               # tmux 轮询间隔（秒）；监听判「回合结束」的最坏延迟 ≈ POLL×SETTLE
  SETTLE="${SETTLE:-3}"           # 连续 N 次空闲才认定「回合结束」
  MAX_CHARS="${MAX_CHARS:-20000}" # RELAY BLOCK 里正文的截断上限（归档文件始终是全文）
  FROM_NAME="${FROM_NAME:-codex-helper}"
  return 0
}

relay_ensure_dirs() {
  mkdir -p "$RELAY_DIR" "$QUEUE" "$PENDING" "$INBOX" "$ROUNDS" "$ANSWERS" 2>/dev/null || true
}

# 往 config.env 写一行 KEY="${KEY:-值}"（幂等：先删同 key 的旧行）。
relay_set_kv() { # $1=文件 $2=KEY $3=值
  local f="$1" k="$2" v="$3" tmp
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  [ -f "$f" ] || : > "$f"
  tmp="$(mktemp)"
  grep -v "^[[:space:]]*${k}=" "$f" > "$tmp" 2>/dev/null || true
  printf '%s="${%s:-%s}"\n' "$k" "$k" "$v" >> "$tmp"
  mv "$tmp" "$f"
}

# ---------------------------------------------------------------------------
# tmux 目标：发现 / 校验 / 观察
# ---------------------------------------------------------------------------
# 一个 pane 里是否跑着 Codex TUI（含子进程；codex-code-mode-host 不算命中）。
relay_pane_has_codex() { # $1 = pane_pid
  local pid="$1" cmd kids k
  cmd="$(ps -o cmd= -p "$pid" 2>/dev/null || true)"
  case "$cmd" in
    */bin/codex|*/bin/codex\ *|codex|codex\ *) return 0 ;;
  esac
  kids="$(pgrep -P "$pid" 2>/dev/null || true)"
  for k in $kids; do relay_pane_has_codex "$k" && return 0; done
  return 1
}

# 打印跑着 Codex 的面板：<target>\t<面板标题>，一行一个。
relay_discover_panes() {
  # ⚠️ 面板标题**可能含换行**：Codex TUI 会把标题动态写成「<spinner> <当前活动> | <目录>」，
  #    里面有换行。所以在 tmux 格式里用 ASCII 0x1f/0x1e 当分隔符（不用换行/制表），
  #    读出来后再把标题里的换行/制表抹成空格——否则按行解析会被标题拆散。
  local rec tgt rest pid title fmt
  command -v tmux >/dev/null 2>&1 || return 0
  fmt="$(printf '%s\x1f%s\x1f%s\x1e' '#{session_name}:#{window_index}.#{pane_index}' '#{pane_pid}' '#{pane_title}')"
  while IFS= read -r -d $'\x1e' rec; do
    [ -n "$rec" ] || continue
    tgt="${rec%%$'\x1f'*}"; rest="${rec#*$'\x1f'}"
    pid="${rest%%$'\x1f'*}"; title="${rest#*$'\x1f'}"
    title="${title//$'\n'/ }"
    title="${title//$'\r'/ }"
    title="${title//$'\t'/ }"
    [ -n "$tgt" ] || continue
    relay_pane_has_codex "$pid" && printf '%s\t%s\n' "$tgt" "$title"
  done < <(tmux list-panes -a -F "$fmt" 2>/dev/null)
  return 0
}

relay_discover_target() { relay_discover_panes | cut -f1; }

# 打印面板候选：参数为 <target>\t<title>（多行），无参数则读 stdin。标题里的空白已抹平，可安全按行打印。
relay_print_panes() {
  local data
  if [ $# -gt 0 ]; then data="$1"; else data="$(cat)"; fi
  while IFS=$'\t' read -r t p; do
    [ -n "$t" ] || continue
    printf '  %-18s 标题=[%s]\n' "$t" "$p"
  done <<< "$data"
  return 0
}

# 面板标题过滤（大小写不敏感的子串匹配）。
relay_filter_by_title() { # $1=标题子串；stdin = <target>\t<title>
  local want; want="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  while IFS=$'\t' read -r tgt title; do
    [ -n "$tgt" ] || continue
    case "$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]')" in
      *"$want"*) printf '%s\t%s\n' "$tgt" "$title" ;;
    esac
  done
  return 0
}

# TARGET=auto → 唯一命中才采用；0 个或多个都报错退出（绝不猜）。
relay_resolve_target() {
  command -v tmux >/dev/null 2>&1 || { echo "找不到 tmux" >&2; return 5; }
  if [ -z "$TARGET" ] || [ "$TARGET" = "auto" ]; then
    local panes n
    panes="$(relay_discover_panes)"
    n="$(printf '%s\n' "$panes" | grep -c . 2>/dev/null || true)"
    if [ "${n:-0}" -gt 1 ] && [ -n "$TARGET_TITLE" ]; then
      local filtered fn
      filtered="$(printf '%s\n' "$panes" | relay_filter_by_title "$TARGET_TITLE")"
      fn="$(printf '%s\n' "$filtered" | grep -c . 2>/dev/null || true)"
      panes="$filtered"; n="${fn:-0}"
    fi
    if [ "${n:-0}" -eq 0 ]; then
      echo "自动发现失败：没有（符合条件的）tmux 面板在跑 Codex TUI。" >&2
      echo "  ① 看看候选：$RELAY_SCRIPT_DIR/codex-config.sh show" >&2
      echo "  ② 显式指定：$RELAY_SCRIPT_DIR/codex-config.sh set-target <会话:窗口[.面板]>" >&2
      return 5
    fi
    if [ "${n:-0}" -gt 1 ]; then
      echo "自动发现命中多个 Codex 面板，拒绝猜测。把状态栏右侧的标题子串配进去即可唯一确定：" >&2
      relay_print_panes "$panes" >&2
      echo "  $RELAY_SCRIPT_DIR/codex-config.sh set-title '<标题子串，如 ttloop>'" >&2
      return 5
    fi
    TARGET="${panes%%$'\t'*}"
  fi
  tmux list-panes -t "$TARGET" >/dev/null 2>&1 || { echo "tmux 目标不存在: $TARGET" >&2; return 5; }
  return 0
}

relay_pane() { tmux capture-pane -p -t "$TARGET" -S -"${1:-40}" 2>/dev/null || true; }
relay_busy() { relay_pane 12 | grep -q 'Working ('; }
relay_errored() {
  relay_pane 25 | grep -qE 'Reconnecting|Bad Gateway|INSUFFICIENT_BALANCE|临时拉黑|unexpected status'
}

# 从用户粘贴的 tmux 状态栏里解析身份：回显 "会话:窗口<TAB>面板标题"。
# 容错：可能没有闭括号、可能带 * / - 等窗口标记、整行里还有时间日期。
relay_parse_statusbar() { # $1 = 形如 [tt-loop-10:node*   "ttloop | tt-loop" 22:43 16-Sep-26
  local raw="$1" sw title
  sw="${raw#"${raw%%[![:space:]]*}"}"   # 去掉前导空白
  sw="${sw#\[}"                          # 去掉开头的 [
  sw="${sw%%[[:space:]]*}"                # 取到第一个空白为止（会话:窗口）
  sw="${sw%%\]*}"                         # 去掉可能粘着的 ]
  sw="${sw%%\**}"                         # 去掉窗口标记 *
  title=""
  case "$raw" in
    *\"*\"*) title="${raw#*\"}"; title="${title%%\"*}" ;;
  esac
  [ -n "$sw" ] || return 1
  printf '%s\t%s\n' "$sw" "$title"
  return 0
}

# ---------------------------------------------------------------------------
# 杂项
# ---------------------------------------------------------------------------
# --- 投递前的安全门（除了「忙不忙」，还要防「打扰人」）------------------------
# 实测（2026-09-16，本机 tt-loop-13 空闲 20s）：window_activity 在无人操作时**不跳**，
# 所以「窗口最近有活动 + 有人挂在这个会话上」是判断「有人正在这个 pane 里打字」的可靠信号。
relay_session_name() { tmux display-message -p -t "$TARGET" '#{session_name}' 2>/dev/null || true; }

relay_window_activity_age() { # 秒；取不到就给一个很大的值（不阻塞投递）
  local a now
  a="$(tmux display-message -p -t "$TARGET" '#{window_activity}' 2>/dev/null || true)"
  case "$a" in ''|*[!0-9]*) echo 999999; return 0 ;; esac
  now="$(date +%s)"
  echo $(( now - a ))
}

# 文件是否「写完」：连续两次采样的字节数一致（防读到半截）。
relay_file_stable() {
  local f="$1" tries="${2:-5}" i prev cur
  prev=""
  for i in $(seq 1 "$tries"); do
    cur="$(wc -c < "$f" 2>/dev/null || echo -1)"
    [ -n "$prev" ] && [ "$cur" = "$prev" ] && return 0
    prev="$cur"; sleep 1
  done
  return 1
}

relay_pane_in_mode() {
  [ "$(tmux display-message -p -t "$TARGET" '#{pane_in_mode}' 2>/dev/null || echo 0)" = "1" ]
}

# 面板处于 copy-mode/view-mode（回滚查看，右上角有 xxx/xxx 标记）时必须先退出：
#   ① capture-pane 看到的是**回滚位置**而不是实时画面 ⇒ 忙/闲判断与正文抽取都会失真；
#   ② 注入会把文本粘到错误的地方。
# 实测（2026-09-16）：`send-keys -X cancel` 与 `copy-mode -q` 都能把 in_mode 从 1 变 0。
# 返回 1 表示「现在仍处于该模式」。
relay_exit_copy_mode() {
  relay_pane_in_mode || return 0
  relay_log "面板处于回滚查看模式（copy-mode/view-mode），自动退出"
  tmux send-keys -t "$TARGET" -X cancel 2>/dev/null || true
  sleep 0.3
  if relay_pane_in_mode; then
    tmux copy-mode -q -t "$TARGET" 2>/dev/null || true
    sleep 0.3
  fi
  relay_pane_in_mode && { relay_log "⚠️ 仍未能退出该模式"; return 1; }
  return 0
}

# 若返回 0（并打印原因），表示此刻不该往这个 pane 里注入。
relay_inject_blocked_reason() {
  local sess n age
  relay_exit_copy_mode || { echo "面板处于回滚查看模式且自动退出失败"; return 0; }
  sess="$(relay_session_name)"
  n="$(tmux list-clients -F '#{client_session}' 2>/dev/null | grep -cx "$sess" || true)"
  if [ "${n:-0}" -ge 1 ]; then
    age="$(relay_window_activity_age)"
    if [ "$age" -lt "${HUMAN_GUARD:-15}" ]; then
      echo "有人挂在会话 $sess 上，且窗口 ${age}s 前刚有过活动（可能在打字）"
      return 0
    fi
  fi
  return 1
}

# 默认答复落盘路径（评审者按约定写这里；比抓终端画面可靠）。
relay_answer_path() { # $1 = 轮次标识（默认时间戳）
  printf '%s/%s.md\n' "$ROUNDS" "${1:-$(date +%Y%m%dT%H%M%S)}"
}

relay_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
