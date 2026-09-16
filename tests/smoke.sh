#!/usr/bin/env bash
# smoke.sh — codex-helper 自测。
#
#   bash tests/smoke.sh                    # 静态自检：不碰 tmux、不消耗任何评审者上下文（默认）
#   bash tests/smoke.sh --live <tmux目标>   # 额外对**真实** Codex 面板跑一次端到端（会消耗它一点上下文）
#   bash tests/smoke.sh --live <目标> <问题文件>
#
# 静态部分覆盖：脚本语法、工作区定位（含从子目录上溯）、零插件声明、状态栏解析容错、
#              配置幂等、文件稳定性判定（防读到半截答复）、外部依赖。
# 真实部分覆盖：投递 → 忙闲门控 → 等回合结束 → 从落盘文件取答复 → RELAY BLOCK。
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
SKILL="$(cd "$HERE/.." && pwd)"
S="$SKILL/scripts"

MODE="check"; LIVE_TARGET=""; LIVE_Q=""
while [ $# -gt 0 ]; do
  case "$1" in
    --live)   MODE="live"; LIVE_TARGET="${2:-}"; LIVE_Q="${3:-}"; shift $# ;;
    --check)  MODE="check"; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 5 ;;
  esac
done

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$*"; fail=$((fail+1)); }
step(){ printf '\n== %s ==\n' "$*"; }

WS="$(mktemp -d)"
cleanup() { rm -rf "$WS"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
step "1. 脚本语法"
for f in "$S"/*.sh "$HERE"/*.sh "$SKILL/install.sh"; do
  if bash -n "$f" 2>/dev/null; then ok "$(basename "$f")"; else bad "$(basename "$f") 语法错误"; bash -n "$f"; fi
done

# ---------------------------------------------------------------------------
step "2. 工作区定位与配置"
mkdir -p "$WS/.codex_helper"
out="$( cd "$WS" && CODEX_HELPER_WORKDIR="$WS" "$S/codex-config.sh" show 2>&1 )"
case "$out" in *"工作区        : $WS"*) ok "CODEX_HELPER_WORKDIR 生效" ;; *) bad "workdir 未按预期解析" ;; esac
mkdir -p "$WS/sub/deep"
out2="$( cd "$WS/sub/deep" && "$S/codex-config.sh" show 2>&1 )"
case "$out2" in *"工作区        : $WS"*) ok "从子目录上溯找到 .codex_helper" ;; *) bad "子目录上溯失败" ;; esac
case "$out2" in *"$WS/.codex_helper/state"*) ok "状态目录落在工作区 .codex_helper/ 下" ;; *) bad "状态目录不对" ;; esac
"$S/codex-config.sh" check >/dev/null 2>&1
grep -q "不依赖任何编辑器/宿主插件" <("$S/codex-config.sh" check 2>/dev/null) && ok "check 声明零插件依赖" || bad "check 未声明零插件依赖"

# ---------------------------------------------------------------------------
step "3. 状态栏解析容错"
. "$S/relay-lib.sh"
p1="$(relay_parse_statusbar '[mycodex:node*    "codex | my-project" 22:43 16-Sep-26')"
p2="$(relay_parse_statusbar '[mycodex] 0:node*  "codex | my-project" 22:43')"
p3="$(relay_parse_statusbar 'mycodex:0.0')"
[ "${p1%%$'\t'*}" = "mycodex:node" ] && [ "${p1#*$'\t'}" = "codex | my-project" ] && ok "无闭括号" || bad "无闭括号: [$p1]"
[ "${p2%%$'\t'*}" = "mycodex" ] && ok "带 ] 与窗口标记" || bad "带标记: [$p2]"
[ "${p3%%$'\t'*}" = "mycodex:0.0" ] && [ -z "${p3#*$'\t'}" ] && ok "无标题" || bad "无标题: [$p3]"
relay_parse_statusbar '' >/dev/null 2>&1
[ $? -eq 1 ] && ok "空串被拒" || bad "空串未被拒"

# ---------------------------------------------------------------------------
step "4. 配置读写幂等"
cd "$WS"
"$S/codex-config.sh" set-target tt-fake:0 >/dev/null 2>&1
"$S/codex-config.sh" set-target tt-fake:0 >/dev/null 2>&1
[ "$(grep -c '^TARGET=' "$WS/.codex_helper/config.env")" = "1" ] && ok "只有一行 TARGET=" || bad "TARGET 行数不对"
grep -q 'TARGET="${TARGET:-tt-fake:0}"' "$WS/.codex_helper/config.env" && ok "写成 \${VAR:-值}（保住优先级）" || bad "配置行格式不对"
"$S/codex-config.sh" init >/dev/null 2>&1 && ok "init 幂等（不覆盖已有配置）" || bad "init 失败"

# ---------------------------------------------------------------------------
step "5. 文件稳定性判定（防读到半截答复）"
f="$WS/half.md"
printf 'part1' > "$f"
( for i in 1 2 3 4 5 6 7 8; do sleep 0.3; printf 'x' >> "$f"; done ) &   # 持续增长 >2.4s
if relay_file_stable "$f" 3; then bad "还在持续增长的文件被判为稳定"; else ok "持续增长的文件被判为不稳定"; fi
wait
relay_file_stable "$f" 2 && ok "写完后判为稳定" || bad "写完后仍判为不稳定"

# ---------------------------------------------------------------------------
step "6. 外部依赖"
for c in tmux ps pgrep; do
  command -v "$c" >/dev/null 2>&1 && ok "$c（必需）" || bad "$c 缺失（必需）"
done
command -v flock >/dev/null 2>&1 && ok "flock（可选：同一工作区互斥）" || printf '  提示 无 flock：互斥失效\n'

# ---------------------------------------------------------------------------
if [ "$MODE" = "live" ]; then
  step "7. 真实端到端（会消耗 $LIVE_TARGET 一点上下文）"
  if [ -z "$LIVE_TARGET" ]; then
    bad "--live 需要 <tmux目标>（例：mycodex:0.0）"
  else
    LWS="$(mktemp -d)"; mkdir -p "$LWS/.codex_helper/state/rounds"
    if [ -n "$LIVE_Q" ]; then q="$LIVE_Q"; else
      q="$LWS/.codex_helper/state/rounds/LIVE-probe-question.md"
      printf '【连通性探针 · 非技术问题】这是一次中继链路自检，不需要你做任何事：请只回答一行 PROBE-OK。\n' > "$q"
    fi
    ( cd "$LWS" && TARGET="$LIVE_TARGET" "$S/codex-ask.sh" --question "$q" --round LIVE \
        --timeout 900 2>"$LWS/ask.err" >"$LWS/ask.out" )
    rc=$?
    [ "$rc" -eq 0 ] && ok "端到端退出码 0" || { bad "端到端 rc=$rc"; sed -n '1,8p' "$LWS/ask.err"; }
    grep -q '=== CODEX ANSWER READY ===' "$LWS/ask.out" && ok "有 RELAY BLOCK" || bad "缺 RELAY BLOCK"
    af="$(sed -n 's/^answer_file: //p' "$LWS/ask.out" | head -1)"
    [ -s "$af" ] && ok "answer_file 有内容（$(wc -c < "$af") 字节）" || bad "answer_file 为空"
    grep -q '^source: file:' "$LWS/ask.out" && ok "答复来自落盘文件（首选路径）" || printf '  提示 走了抓画面的退化路径（评审者未落盘）\n'
    rm -rf "$LWS"
  fi
fi

printf '\n== 结果 ==\n  通过 %s · 失败 %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
