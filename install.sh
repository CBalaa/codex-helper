#!/usr/bin/env bash
# install.sh — 把本仓库装成一个 skill，并为某个工作区初始化 .codex_helper/。
#
#   ./install.sh                  # 装 skill 到 ~/.dsh/skills/ + 初始化当前目录为工作区
#   ./install.sh skill [目录]      # 只装 skill（默认 ~/.dsh/skills）
#   ./install.sh workspace [目录]  # 只初始化工作区（默认当前目录）
#   ./install.sh legacy-links     # 把 ~/.dsh-relay/codex-*.sh 指向本 skill（兼容旧路径）
#
# 安装 = 在 skills 目录建一个指向本仓库的**符号链接**：仓库仍是唯一副本，改一处即生效。
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
SKILL_NAME="codex-helper"
SKILLS_DIR="$HOME/.dsh/skills"
LEGACY_DIR="$HOME/.dsh-relay"

log() { printf '[install] %s\n' "$*"; }
die() { printf '[install] 错误: %s\n' "$*" >&2; exit 1; }

install_skill() {
  local dir="${1:-$SKILLS_DIR}"
  mkdir -p "$dir" || die "无法创建 $dir"
  local link="$dir/$SKILL_NAME"
  if [ -L "$link" ]; then rm -f "$link"; elif [ -e "$link" ]; then die "$link 已存在且不是符号链接，先自行处理"; fi
  ln -s "$HERE" "$link"
  log "skill 已安装: $link -> $HERE"
  [ -f "$link/SKILL.md" ] && log "SKILL.md 可读 ✓（新会话的 skill 目录里会出现 $SKILL_NAME）"
}

init_workspace() {
  local ws="${1:-$PWD}"
  [ -d "$ws" ] || die "工作区不存在: $ws"
  local ch="$ws/.codex_helper"
  mkdir -p "$ch/state"/{queue,pending,rounds,answers} || die "无法创建 $ch"
  if [ ! -f "$ch/config.env" ]; then
    cp "$HERE/config.env.example" "$ch/config.env"
    log "已创建 $ch/config.env（来自 config.env.example）"
  else
    log "配置已存在，未覆盖: $ch/config.env"
  fi
  log "工作区已初始化: $ws"
  printf '  建议把下面这行加进 %s/.gitignore：\n    /.codex_helper/\n' "$ws"
  printf '  自检：%s/scripts/codex-config.sh check\n' "$HERE"
}

legacy_links() {
  mkdir -p "$LEGACY_DIR" || die "无法创建 $LEGACY_DIR"
  local f
  for f in codex-config.sh codex-ask.sh codex-relay.sh codex-watch.sh; do
    ln -sfn "$HERE/scripts/$f" "$LEGACY_DIR/$f"
    log "兼容链接: $LEGACY_DIR/$f"
  done
  log "注意：$LEGACY_DIR 只保留运行时状态即可；配置现在按工作区放在 <工作区>/.codex_helper/"
}

case "${1:-all}" in
  skill)      install_skill "${2:-}" ;;
  workspace)  init_workspace "${2:-}" ;;
  legacy-links) legacy_links ;;
  all)        install_skill "$SKILLS_DIR"; init_workspace "$PWD" ;;
  -h|--help)  sed -n '2,12p' "$0" ;;
  *)          die "未知参数: $1（可用: skill / workspace / legacy-links / all）" ;;
esac
