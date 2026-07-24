#!/usr/bin/env bash
#
# 把 SwiftPM 可执行文件打包成 macOS .app bundle。
# 默认编译当前机器架构；需要 universal 时显式传 --universal。
#
# 用法：
#   ./build.sh                 # 默认当前架构
#   ./build.sh --universal     # 编译 arm64 + x86_64
#   ./build.sh --native        # 只编译当前架构（兼容旧用法）
#   ./build.sh --clean         # 编译前先 swift package clean
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="DoubaoVoiceApp"
BUNDLE_NAME="豆包语音输入助手.app"
BUNDLE_ID="com.doubaovoiceapp.menubar"
DISPLAY_NAME="豆包语音输入助手"
EXECUTABLE_NAME="$APP_NAME"
DIST_DIR="$SCRIPT_DIR/dist"
BUNDLE_PATH="$DIST_DIR/$BUNDLE_NAME"
IDENTITY_FILE="$SCRIPT_DIR/.codesign-identity"

# ---- 签名身份 ----
#
# macOS 的辅助功能授权跟随签名身份：身份稳定，重装后不用重新授权。
# 取值顺序（找到即止）：
#   1. 环境变量 CODE_SIGN_IDENTITY
#   2. 仓库根目录 .codesign-identity 文件（不入库，写一行证书名即可）
#   3. 自动探测本机第一个可用的代码签名证书
#   4. ad-hoc 签名（"-"）：无需任何证书即可安装运行，
#      但每次重新编译安装后需要在「辅助功能」里重新授权一次
resolve_sign_identity() {
  if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
    echo "$CODE_SIGN_IDENTITY"
    return
  fi

  if [[ -f "$IDENTITY_FILE" ]]; then
    local from_file
    from_file="$(head -n 1 "$IDENTITY_FILE" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [[ -n "$from_file" ]]; then
      echo "$from_file"
      return
    fi
  fi

  local detected
  for kind in "Developer ID Application" "Apple Development" "Mac Developer"; do
    detected="$(security find-identity -v -p codesigning 2>/dev/null \
      | grep -o "\"$kind: [^\"]*\"" | head -n 1 | tr -d '"' || true)"
    if [[ -n "$detected" ]]; then
      echo "$detected"
      return
    fi
  done

  echo "-"
}

CODE_SIGN_IDENTITY="$(resolve_sign_identity)"

TARGET_ARCHS=("$(uname -m)")
DO_CLEAN=0

usage() {
  cat <<EOF
用法：
  $(basename "$0") [--native] [--universal] [--clean] [--help]

选项：
  --native     只编译本机架构（默认）
  --universal  编译 arm64 + x86_64
  --clean      编译前执行 swift package clean
  --help       显示此帮助
EOF
}

for arg in "$@"; do
  case "$arg" in
    --native)    TARGET_ARCHS=("$(uname -m)") ;;
    --universal) TARGET_ARCHS=("arm64" "x86_64") ;;
    --clean)     DO_CLEAN=1 ;;
    --help|-h)   usage; exit 0 ;;
    *) echo "[错误] 未知参数：$arg" >&2; usage; exit 1 ;;
  esac
done

info() { printf '[信息] %s\n' "$1"; }

if [[ "$DO_CLEAN" -eq 1 ]]; then
  info "执行 swift package clean"
  swift package clean
fi

# ---- 编译 ----
build_args=(-c release)
for arch in "${TARGET_ARCHS[@]}"; do
  build_args+=(--arch "$arch")
done

info "swift build ${build_args[*]}"
swift build "${build_args[@]}"

# ---- 找到产物路径 ----
if [[ ${#TARGET_ARCHS[@]} -gt 1 ]]; then
  EXECUTABLE_PATH=".build/apple/Products/Release/$EXECUTABLE_NAME"
else
  arch="${TARGET_ARCHS[0]}"
  candidates=(
    ".build/${arch}-apple-macosx/release/$EXECUTABLE_NAME"
    ".build/release/$EXECUTABLE_NAME"
    ".build/apple/Products/Release/$EXECUTABLE_NAME"
  )
  EXECUTABLE_PATH=""
  for path in "${candidates[@]}"; do
    if [[ -f "$path" ]]; then
      EXECUTABLE_PATH="$path"
      break
    fi
  done
fi

if [[ -z "$EXECUTABLE_PATH" || ! -f "$EXECUTABLE_PATH" ]]; then
  echo "[错误] 找不到编译产物" >&2
  exit 1
fi

info "可执行文件: $EXECUTABLE_PATH"

# ---- 组装 .app bundle ----
rm -rf "$BUNDLE_PATH"
mkdir -p "$BUNDLE_PATH/Contents/MacOS"
mkdir -p "$BUNDLE_PATH/Contents/Resources"

cp "$EXECUTABLE_PATH" "$BUNDLE_PATH/Contents/MacOS/$EXECUTABLE_NAME"
chmod +x "$BUNDLE_PATH/Contents/MacOS/$EXECUTABLE_NAME"

VERSION="${APP_VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

INFO_PLIST_TEMPLATE="$SCRIPT_DIR/Resources/Info.plist"
if [[ ! -f "$INFO_PLIST_TEMPLATE" ]]; then
  echo "[错误] 找不到 Info.plist 模板：$INFO_PLIST_TEMPLATE" >&2
  exit 1
fi

# 从 Resources/Info.plist 模板替换占位符，写入 bundle。
sed \
  -e "s|\${BUNDLE_DISPLAY_NAME}|$DISPLAY_NAME|g" \
  -e "s|\${BUNDLE_EXECUTABLE}|$EXECUTABLE_NAME|g" \
  -e "s|\${BUNDLE_IDENTIFIER}|$BUNDLE_ID|g" \
  -e "s|\${BUNDLE_SHORT_VERSION}|$VERSION|g" \
  -e "s|\${BUNDLE_VERSION}|$BUILD_NUMBER|g" \
  "$INFO_PLIST_TEMPLATE" > "$BUNDLE_PATH/Contents/Info.plist"

if [[ "$CODE_SIGN_IDENTITY" == "-" ]]; then
  info "未找到代码签名证书，使用 ad-hoc 签名"
  info "提示：ad-hoc 签名下，每次重新编译安装后需要在「系统设置 → 隐私与安全性 → 辅助功能」里重新授权一次；想避免这一步，见 README「常见问题」中的自签证书方法"
else
  info "codesign --sign \"$CODE_SIGN_IDENTITY\""
fi
codesign --force --deep --sign "$CODE_SIGN_IDENTITY" "$BUNDLE_PATH" >/dev/null

info "产物已生成: $BUNDLE_PATH"
file "$BUNDLE_PATH/Contents/MacOS/$EXECUTABLE_NAME"
