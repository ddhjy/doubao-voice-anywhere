#!/usr/bin/env bash
#
# 把 dist 里的 .app 打成可分发的 DMG（打开后拖到 Applications 即安装）。
#
# 用法：
#   ./package-dmg.sh                    # 打包 dist 中已有的产物
#   APP_VERSION=1.2.0 ./package-dmg.sh  # 指定版本号，只影响 DMG 文件名
#   DMG_VERSION=1.2.0-beta1 ./package-dmg.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BUNDLE_NAME="豆包随时说.app"
VOLUME_NAME="豆包随时说"
DIST_DIR="$SCRIPT_DIR/dist"
BUNDLE_PATH="$DIST_DIR/$BUNDLE_NAME"
# 预发布 tag（v1.2.0-beta1）下 Info.plist 只能写 1.2.0，DMG 文件名却该保留
# 完整版本，所以两者分开：DMG_VERSION 未设时退回 APP_VERSION。
VERSION="${DMG_VERSION:-${APP_VERSION:-1.0.0}}"
# DMG 文件名保持 ASCII：GitHub Release 的下载链接不会变成一长串百分号转义。
DMG_PATH="$DIST_DIR/DoubaoVoiceApp-$VERSION.dmg"

# shellcheck source=codesign-lib.sh
source "$SCRIPT_DIR/codesign-lib.sh"
CODE_SIGN_IDENTITY="$(resolve_sign_identity)"

info() { printf '[信息] %s\n' "$1"; }

if [[ ! -d "$BUNDLE_PATH" ]]; then
  echo "[错误] 找不到产物：${BUNDLE_PATH}，请先执行 ./build.sh" >&2
  exit 1
fi

STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT

# ditto 而不是 cp -R：保留签名依赖的扩展属性与符号链接。
ditto "$BUNDLE_PATH" "$STAGING_DIR/$BUNDLE_NAME"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"
info "生成 DMG：$(basename "$DMG_PATH")"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG_PATH" >/dev/null

# DMG 本身也要签：Gatekeeper 会单独校验磁盘映像的签名，
# 未签名的映像即使里面的 app 已公证，打开时仍会多一道警告。
if [[ "$CODE_SIGN_IDENTITY" != "-" ]]; then
  dmg_sign_args=(--force --sign "$CODE_SIGN_IDENTITY")
  # 与 build.sh 同一个开关：时间戳要联网，本地默认关，CI 里置 1。
  if [[ "${CODE_SIGN_TIMESTAMP:-0}" == "1" ]]; then
    dmg_sign_args+=(--timestamp)
  fi
  info "codesign --sign \"$CODE_SIGN_IDENTITY\""
  codesign "${dmg_sign_args[@]}" "$DMG_PATH" >/dev/null
else
  info "未找到代码签名证书，DMG 不签名"
fi

info "产物已生成：$DMG_PATH"
