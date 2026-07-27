#!/usr/bin/env bash
#
# 把构建产物安装到 ~/Applications 并启动。
#
# 用法：
#   ./install-app.sh                    # 默认安装到 ~/Applications
#   ./install-app.sh --dev              # 安装开发版「豆包随时说 Dev」（与正式版共存）
#   ./install-app.sh --system           # 安装到 /Applications（需要管理员权限）
#   ./install-app.sh --no-launch        # 安装但不启动
#   ./install-app.sh --skip-build       # 跳过编译，直接复制 dist 中已有的产物
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RELEASE_BUNDLE_NAME="豆包随时说.app"
DEV_BUNDLE_NAME="豆包随时说 Dev.app"
BUNDLE_NAME="$RELEASE_BUNDLE_NAME"
# 2026-07 改名前的包名；安装时自动退出旧进程并清理旧包
LEGACY_BUNDLE_NAME="豆包语音输入助手.app"
BUNDLE_ID="com.doubaovoiceapp.menubar"
EXECUTABLE_NAME="DoubaoVoiceApp"
TARGET_DIR="$HOME/Applications"
DO_LAUNCH=1
DO_BUILD=1
DEV_BUILD=0

usage() {
  cat <<EOF
用法：
  $(basename "$0") [--dev] [--system] [--no-launch] [--skip-build] [--help]

选项：
  --dev           构建并安装开发版「豆包随时说 Dev」：独立 bundle ID，
                  辅助功能授权、配置、登录项、日志都与正式版隔离，
                  可以和 GitHub Release 正式版共存（但不要同时运行）
  --system        安装到 /Applications（默认安装到 ~/Applications）
  --no-launch     安装后不自动启动
  --skip-build    跳过 ./build.sh，直接复制 dist 中已有的产物
  --help          显示帮助
EOF
}

for arg in "$@"; do
  case "$arg" in
    --dev)        DEV_BUILD=1 ;;
    --system)     TARGET_DIR="/Applications" ;;
    --no-launch)  DO_LAUNCH=0 ;;
    --skip-build) DO_BUILD=0 ;;
    --help|-h)    usage; exit 0 ;;
    *) echo "[错误] 未知参数：$arg" >&2; usage; exit 1 ;;
  esac
done

if [[ "$DEV_BUILD" -eq 1 ]]; then
  BUNDLE_NAME="$DEV_BUNDLE_NAME"
  BUNDLE_ID="com.doubaovoiceapp.menubar.dev"
fi
DIST_BUNDLE="$SCRIPT_DIR/dist/$BUNDLE_NAME"

info() { printf '[信息] %s\n' "$1"; }
error() { printf '[错误] %s\n' "$1" >&2; }

if [[ "$DO_BUILD" -eq 1 ]]; then
  build_args=()
  [[ "$DEV_BUILD" -eq 1 ]] && build_args+=(--dev)
  info "执行 ./build.sh ${build_args[*]}"
  ./build.sh ${build_args[@]+"${build_args[@]}"}
fi

if [[ ! -d "$DIST_BUNDLE" ]]; then
  error "找不到产物：${DIST_BUNDLE}，请先执行 ./build.sh"
  exit 1
fi

mkdir -p "$TARGET_DIR"
TARGET_BUNDLE="$TARGET_DIR/$BUNDLE_NAME"
TARGET_PROCESS_PATH="$TARGET_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
DIST_PROCESS_PATH="$DIST_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"

kill_existing_instances() {
  local pids=()
  local pid
  # 正式版和开发版都退出：两个版本同时运行会都响应说话快捷键（双触发）。
  local paths=(
    "$TARGET_PROCESS_PATH"
    "$DIST_PROCESS_PATH"
    "$HOME/Applications/$RELEASE_BUNDLE_NAME/Contents/MacOS/$EXECUTABLE_NAME"
    "/Applications/$RELEASE_BUNDLE_NAME/Contents/MacOS/$EXECUTABLE_NAME"
    "$HOME/Applications/$DEV_BUNDLE_NAME/Contents/MacOS/$EXECUTABLE_NAME"
    "/Applications/$DEV_BUNDLE_NAME/Contents/MacOS/$EXECUTABLE_NAME"
    "$HOME/Applications/$LEGACY_BUNDLE_NAME/Contents/MacOS/$EXECUTABLE_NAME"
    "/Applications/$LEGACY_BUNDLE_NAME/Contents/MacOS/$EXECUTABLE_NAME"
  )

  local path
  for path in "${paths[@]}"; do
    while IFS= read -r pid; do
      [[ -n "$pid" ]] && pids+=("$pid")
    done < <(pgrep -f "$path" || true)
  done

  if [[ ${#pids[@]} -gt 0 ]]; then
    info "检测到旧实例，正在退出"
    kill "${pids[@]}" 2>/dev/null || true
    sleep 1
    kill -9 "${pids[@]}" 2>/dev/null || true
  fi
}

# 清理改名前的旧包（显示名从「豆包语音输入助手」改为「豆包随时说」）。
remove_legacy_bundles() {
  local dir legacy
  for dir in "$HOME/Applications" "/Applications"; do
    legacy="$dir/$LEGACY_BUNDLE_NAME"
    if [[ -d "$legacy" ]]; then
      if rm -rf "$legacy" 2>/dev/null; then
        info "已清理旧版本包：$legacy"
      else
        error "无法删除旧版本包：${legacy}，请手动移除"
      fi
    fi
  done
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

# ---- 关闭旧实例并清理旧名包 ----
kill_existing_instances
remove_legacy_bundles

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
  DISPLAY_NAME="${BUNDLE_NAME%.app}"
  LOG_FILE_NAME="app.log"
  [[ "$DEV_BUILD" -eq 1 ]] && LOG_FILE_NAME="app-dev.log"

  info "启动应用"
  open -n "$TARGET_BUNDLE"
  activate_installed_app || true
  cat <<EOF

应用已启动，将在屏幕右上角的菜单栏出现一个麦克风图标。

第一次运行时：
  1. 系统会弹出"辅助功能"权限请求；点击"打开系统设置"，把
     "$DISPLAY_NAME" 加入授权列表，并打开开关。
  2. 授权后应用会自动开始监听（几秒内生效）；如果没生效，
     点菜单栏图标 -> "重新连接键盘监听"。
  3. 之后轻按一次 Fn 启动豆包语音；再按一次结束。
  4. 快捷键、日常输入法与输入源轮换可在菜单栏 -> "设置…" 里配置。

日志位置：~/Library/Logs/DoubaoVoiceApp/$LOG_FILE_NAME
EOF

  if [[ "$DEV_BUILD" -eq 1 ]]; then
    cat <<EOF
提示：若正式版之前在运行，已被自动退出（两个版本会抢同一个快捷键）；
      开发验证结束后，从启动台 / Raycast 重新打开"豆包随时说"即可。
EOF
  fi
fi
