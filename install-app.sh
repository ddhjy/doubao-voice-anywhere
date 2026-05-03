#!/usr/bin/env bash
#
# 把构建产物安装到 ~/Applications 并启动。
#
# 用法：
#   ./install-app.sh                    # 默认安装到 ~/Applications
#   ./install-app.sh --system           # 安装到 /Applications（需要管理员权限）
#   ./install-app.sh --no-launch        # 安装但不启动
#   ./install-app.sh --skip-build       # 跳过编译，直接复制 dist 中已有的产物
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BUNDLE_NAME="豆包语音输入助手.app"
BUNDLE_ID="com.doubaovoiceapp.menubar"
EXECUTABLE_NAME="DoubaoVoiceApp"
DIST_BUNDLE="$SCRIPT_DIR/dist/$BUNDLE_NAME"
TARGET_DIR="$HOME/Applications"
DO_LAUNCH=1
DO_BUILD=1

usage() {
  cat <<EOF
用法：
  $(basename "$0") [--system] [--no-launch] [--skip-build] [--help]

选项：
  --system        安装到 /Applications（默认安装到 ~/Applications）
  --no-launch     安装后不自动启动
  --skip-build    跳过 ./build.sh，直接复制 dist 中已有的产物
  --help          显示帮助
EOF
}

for arg in "$@"; do
  case "$arg" in
    --system)     TARGET_DIR="/Applications" ;;
    --no-launch)  DO_LAUNCH=0 ;;
    --skip-build) DO_BUILD=0 ;;
    --help|-h)    usage; exit 0 ;;
    *) echo "[错误] 未知参数：$arg" >&2; usage; exit 1 ;;
  esac
done

info() { printf '[信息] %s\n' "$1"; }
error() { printf '[错误] %s\n' "$1" >&2; }

if [[ "$DO_BUILD" -eq 1 ]]; then
  info "执行 ./build.sh"
  ./build.sh
fi

if [[ ! -d "$DIST_BUNDLE" ]]; then
  error "找不到产物：$DIST_BUNDLE，请先执行 ./build.sh"
  exit 1
fi

mkdir -p "$TARGET_DIR"
TARGET_BUNDLE="$TARGET_DIR/$BUNDLE_NAME"
TARGET_PROCESS_PATH="$TARGET_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
DIST_PROCESS_PATH="$DIST_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"

kill_existing_instances() {
  local pids=()
  local pid

  while IFS= read -r pid; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done < <(pgrep -f "$TARGET_PROCESS_PATH" || true)

  while IFS= read -r pid; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done < <(pgrep -f "$DIST_PROCESS_PATH" || true)

  if [[ ${#pids[@]} -gt 0 ]]; then
    info "检测到旧实例，正在退出"
    kill "${pids[@]}" 2>/dev/null || true
    sleep 1
    kill -9 "${pids[@]}" 2>/dev/null || true
  fi
}

activate_installed_app() {
  local attempt

  for attempt in {1..10}; do
    if osascript <<APPLESCRIPT >/dev/null 2>&1
tell application id "$BUNDLE_ID"
    activate
end tell
APPLESCRIPT
    then
      return 0
    fi

    sleep 0.3
  done

  return 1
}

# ---- 关闭旧实例 ----
kill_existing_instances

# ---- 复制 ----
if [[ -d "$TARGET_BUNDLE" ]]; then
  info "覆盖旧版本：$TARGET_BUNDLE"
  rm -rf "$TARGET_BUNDLE"
fi

ditto "$DIST_BUNDLE" "$TARGET_BUNDLE"
xattr -dr com.apple.quarantine "$TARGET_BUNDLE" >/dev/null 2>&1 || true
codesign --verify --deep --strict "$TARGET_BUNDLE" >/dev/null

info "已安装到：$TARGET_BUNDLE"

# ---- 启动 ----
if [[ "$DO_LAUNCH" -eq 1 ]]; then
  info "启动应用"
  open -n "$TARGET_BUNDLE"
  activate_installed_app || true
  cat <<EOF

应用已启动，将在屏幕右上角的菜单栏出现一个麦克风图标。

第一次运行时：
  1. 系统会弹出"辅助功能"权限请求；点击"打开系统设置"，把
     "豆包语音输入助手" 加入授权列表，并打开开关。
  2. 授权后，菜单栏图标 -> "重新启动事件监听" 即可生效。
  3. 之后轻按一次 Fn 启动豆包语音；再按一次结束。
  4. Ctrl+Space 仅在 Squirrel - Simplified 与 U.S. 之间切换。

日志位置：~/Library/Logs/DoubaoVoiceApp/app.log
EOF
fi
