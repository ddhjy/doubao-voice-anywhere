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
BUNDLE_NAME="豆包随时说.app"
BUNDLE_ID="com.doubaovoiceapp.menubar"
DISPLAY_NAME="豆包随时说"
EXECUTABLE_NAME="$APP_NAME"
DIST_DIR="$SCRIPT_DIR/dist"
BUNDLE_PATH="$DIST_DIR/$BUNDLE_NAME"

# shellcheck source=codesign-lib.sh
source "$SCRIPT_DIR/codesign-lib.sh"
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
#
# 逐个架构编译再 lipo 合并，而不是一条 swift build --arch arm64 --arch x86_64：
# 后者会切到 Xcode build system，Xcode 26 上必崩在
# "The Xcode build system has terminated due to an error"。
arch_slices=()
for arch in "${TARGET_ARCHS[@]}"; do
  info "swift build -c release --arch $arch"
  swift build -c release --arch "$arch"

  slice=""
  for candidate in \
    ".build/${arch}-apple-macosx/release/$EXECUTABLE_NAME" \
    ".build/release/$EXECUTABLE_NAME"; do
    if [[ -f "$candidate" ]]; then
      slice="$candidate"
      break
    fi
  done

  if [[ -z "$slice" ]]; then
    echo "[错误] 找不到 $arch 架构的编译产物" >&2
    exit 1
  fi
  arch_slices+=("$slice")
done

if [[ ${#arch_slices[@]} -gt 1 ]]; then
  EXECUTABLE_PATH=".build/universal/$EXECUTABLE_NAME"
  mkdir -p "$(dirname "$EXECUTABLE_PATH")"
  info "lipo 合并：${TARGET_ARCHS[*]}"
  lipo -create -output "$EXECUTABLE_PATH" "${arch_slices[@]}"
else
  EXECUTABLE_PATH="${arch_slices[0]}"
fi

info "可执行文件: $EXECUTABLE_PATH"

# ---- 组装 .app bundle ----
rm -rf "$BUNDLE_PATH"
mkdir -p "$BUNDLE_PATH/Contents/MacOS"
mkdir -p "$BUNDLE_PATH/Contents/Resources"

cp "$EXECUTABLE_PATH" "$BUNDLE_PATH/Contents/MacOS/$EXECUTABLE_NAME"
chmod +x "$BUNDLE_PATH/Contents/MacOS/$EXECUTABLE_NAME"

# ---- 编译 MediaRemote 桥接 helper（语音输入时暂停/恢复媒体播放用）----
#
# mrbridge.dylib 不由主程序加载，而是运行时交给系统自带的 /usr/bin/perl
# （Apple 平台二进制）加载执行：macOS 15.4 起只有 Apple 平台二进制能拿到
# 真实的「正在播放」状态，详见 Helper/MediaRemoteBridge/mrbridge.m。
HELPER_SRC_DIR="$SCRIPT_DIR/Helper/MediaRemoteBridge"
helper_arch_flags=()
for arch in "${TARGET_ARCHS[@]}"; do
  helper_arch_flags+=(-arch "$arch")
done
info "编译 mrbridge.dylib（${TARGET_ARCHS[*]}）"
clang "${helper_arch_flags[@]}" -dynamiclib -fobjc-arc -O2 \
  -mmacosx-version-min=13.0 \
  -framework Foundation \
  -o "$BUNDLE_PATH/Contents/Resources/mrbridge.dylib" \
  "$HELPER_SRC_DIR/mrbridge.m"
cp "$HELPER_SRC_DIR/mrbridge-host.pl" "$BUNDLE_PATH/Contents/Resources/"

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

# ---- 签名 ----
#
# 不用 --deep：Apple 明确说它不适合分发签名，且会把外层的 options 原样套给
# 嵌套代码。嵌套代码（mrbridge.dylib）必须先签，再签外层 bundle。
sign_args=(--force --sign "$CODE_SIGN_IDENTITY")

if [[ "$CODE_SIGN_IDENTITY" == "-" ]]; then
  info "未找到代码签名证书，使用 ad-hoc 签名"
  info "提示：ad-hoc 签名下，每次重新编译安装后需要在「系统设置 → 隐私与安全性 → 辅助功能」里重新授权一次；想避免这一步，见 README「常见问题」中的自签证书方法"
else
  # 公证要求 Hardened Runtime，ad-hoc 签名不支持。
  sign_args+=(--options runtime)

  # 安全时间戳同样是公证的硬性要求，但要联网访问 Apple 时间戳服务器：
  # 断网时 codesign 会直接失败。所以本地默认关，CI 里显式置 1。
  if [[ "${CODE_SIGN_TIMESTAMP:-0}" == "1" ]]; then
    sign_args+=(--timestamp)
  fi

  info "codesign --sign \"$CODE_SIGN_IDENTITY\"（Hardened Runtime）"
fi

codesign "${sign_args[@]}" "$BUNDLE_PATH/Contents/Resources/mrbridge.dylib" >/dev/null
codesign "${sign_args[@]}" "$BUNDLE_PATH" >/dev/null

info "产物已生成: $BUNDLE_PATH"
file "$BUNDLE_PATH/Contents/MacOS/$EXECUTABLE_NAME"
