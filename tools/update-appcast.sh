#!/usr/bin/env bash
#
# 往 appcast.xml 里追加一条更新记录：给更新包算 EdDSA 签名，把版本号、下载地址
# 和更新说明拼成一个 <item>，插到 channel 最前面。
#
# 由 release workflow 在建完 GitHub Release 之后调用，改完的 appcast.xml 推回 main
# ——App 里的 SUFeedURL 指的就是它在 main 上的 raw 地址。
#
# 用法：
#   tools/update-appcast.sh \
#     --app "dist/豆包随时说.app" \
#     --zip dist/DoubaoVoiceApp-1.1.0.zip \
#     --url https://github.com/OWNER/REPO/releases/download/v1.1.0/DoubaoVoiceApp-1.1.0.zip \
#     --link https://github.com/OWNER/REPO/releases/tag/v1.1.0 \
#     [--notes-file notes.md] [--appcast appcast.xml]
#
# 签名私钥的取值顺序：环境变量 SPARKLE_PRIVATE_KEY → 本机钥匙串。
# CI 走前者（secret），本地手动补条目时走后者。
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

APP_PATH=""
ZIP_PATH=""
DOWNLOAD_URL=""
RELEASE_LINK=""
NOTES_FILE=""
APPCAST_PATH="$SCRIPT_DIR/appcast.xml"
MINIMUM_SYSTEM_VERSION="13.0.0"
ANCHOR="NEW_ITEM_ANCHOR"

info()  { printf '[信息] %s\n' "$1"; }
error() { printf '[错误] %s\n' "$1" >&2; }

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)        APP_PATH="$2"; shift 2 ;;
    --zip)        ZIP_PATH="$2"; shift 2 ;;
    --url)        DOWNLOAD_URL="$2"; shift 2 ;;
    --link)       RELEASE_LINK="$2"; shift 2 ;;
    --notes-file) NOTES_FILE="$2"; shift 2 ;;
    --appcast)    APPCAST_PATH="$2"; shift 2 ;;
    --help|-h)    usage; exit 0 ;;
    *) error "未知参数：$1"; usage; exit 1 ;;
  esac
done

for required in APP_PATH ZIP_PATH DOWNLOAD_URL RELEASE_LINK; do
  if [[ -z "${!required}" ]]; then
    error "缺少必填参数：--$(echo "$required" | tr 'A-Z_' 'a-z-' | sed 's/-path$//;s/-url$/&/')"
    usage
    exit 1
  fi
done

[[ -d "$APP_PATH" ]]      || { error "找不到 .app：$APP_PATH"; exit 1; }
[[ -f "$ZIP_PATH" ]]      || { error "找不到更新包：$ZIP_PATH"; exit 1; }
[[ -f "$APPCAST_PATH" ]]  || { error "找不到 appcast：$APPCAST_PATH"; exit 1; }

if ! grep -q "$ANCHOR" "$APPCAST_PATH"; then
  error "appcast 里找不到锚点注释 ${ANCHOR}，没法确定插入位置"
  exit 1
fi

SPARKLE_BIN="$SCRIPT_DIR/.build/artifacts/sparkle/Sparkle/bin"
if [[ ! -x "$SPARKLE_BIN/sign_update" ]]; then
  error "找不到 sign_update：${SPARKLE_BIN}（先跑一次 swift build 拉依赖）"
  exit 1
fi

# ---- 版本号 ----
#
# 一律从已打包的 .app 里读，保证 appcast 写的和用户真正装上的完全一致。
# sparkle:version 就是 CFBundleVersion，Sparkle 拿它比新旧。
plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$APP_PATH/Contents/Info.plist" 2>/dev/null || true
}

BUNDLE_VERSION="$(plist_value CFBundleVersion)"
SHORT_VERSION="$(plist_value CFBundleShortVersionString)"

if [[ -z "$BUNDLE_VERSION" || -z "$SHORT_VERSION" ]]; then
  error "从 $APP_PATH 读不出版本号"
  exit 1
fi

# ---- 签名 ----
#
# -p 只打印签名本身，方便脚本取值；length 用文件大小，两者都是 enclosure 的必填项。
# --ed-key-file - 表示私钥从 stdin 读（-s 传私钥的老写法已被 Sparkle 废弃）。
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  ED_SIGNATURE="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SPARKLE_BIN/sign_update" --ed-key-file - -p "$ZIP_PATH")"
else
  info "环境变量 SPARKLE_PRIVATE_KEY 未设置，改用本机钥匙串里的私钥"
  ED_SIGNATURE="$("$SPARKLE_BIN/sign_update" -p "$ZIP_PATH")"
fi

if [[ -z "$ED_SIGNATURE" ]]; then
  error "签名失败，拿不到 sparkle:edSignature"
  exit 1
fi

ZIP_LENGTH="$(stat -f%z "$ZIP_PATH")"
PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

# ---- 更新说明 ----
#
# GitHub 生成的 release notes 是 markdown，Sparkle 的更新窗口吃 HTML，
# 这里做一次够用的转换：标题、无序列表、段落，其余按普通段落处理。
markdown_to_html() {
  awk '
    function escape(s) {
      gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s)
      # GitHub 自动生成的 notes 末尾必带 **Full Changelog**，成对的 ** 转成加粗。
      while (match(s, /\*\*[^*]+\*\*/)) {
        bold = substr(s, RSTART + 2, RLENGTH - 4)
        s = substr(s, 1, RSTART - 1) "<strong>" bold "</strong>" substr(s, RSTART + RLENGTH)
      }
      return s
    }
    function close_list() { if (in_list) { print "  </ul>"; in_list = 0 } }
    {
      line = $0
      sub(/[ \t]+$/, "", line)

      if (line == "") { close_list(); next }

      if (match(line, /^#{1,6} /)) {
        close_list()
        level = RLENGTH - 1
        text = substr(line, RLENGTH + 1)
        # markdown 的一级标题在更新窗口里过大，整体降两级。
        tag = (level <= 2) ? "h3" : "h4"
        printf "  <%s>%s</%s>\n", tag, escape(text), tag
        next
      }

      if (match(line, /^[-*+] /)) {
        if (!in_list) { print "  <ul>"; in_list = 1 }
        printf "    <li>%s</li>\n", escape(substr(line, RLENGTH + 1))
        next
      }

      close_list()
      printf "  <p>%s</p>\n", escape(line)
    }
    END { close_list() }
  '
}

if [[ -n "$NOTES_FILE" && -f "$NOTES_FILE" ]]; then
  NOTES_HTML="$(markdown_to_html < "$NOTES_FILE")"
else
  NOTES_HTML=""
fi

if [[ -z "$NOTES_HTML" ]]; then
  NOTES_HTML="  <p>详见 <a href=\"$RELEASE_LINK\">GitHub Release</a>。</p>"
fi

# ---- 拼 item 并插进 appcast ----
#
# CDATA 里不能出现 ]]>，GitHub 的 release notes 理论上不会有，保险起见还是拆开。
NOTES_HTML="${NOTES_HTML//]]>/]]&gt;}"

ITEM_FILE="$(mktemp)"
trap 'rm -f "$ITEM_FILE"' EXIT

cat > "$ITEM_FILE" <<ITEM
    <item>
      <title>$SHORT_VERSION</title>
      <link>$RELEASE_LINK</link>
      <sparkle:version>$BUNDLE_VERSION</sparkle:version>
      <sparkle:shortVersionString>$SHORT_VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM_SYSTEM_VERSION</sparkle:minimumSystemVersion>
      <pubDate>$PUB_DATE</pubDate>
      <description><![CDATA[
$NOTES_HTML
      ]]></description>
      <enclosure url="$DOWNLOAD_URL" length="$ZIP_LENGTH" type="application/octet-stream" sparkle:edSignature="$ED_SIGNATURE" />
    </item>
ITEM

# 同版本重复发布（比如公证失败后重跑）时先删掉旧条目，避免 appcast 里出现两条。
if grep -q "<sparkle:shortVersionString>$SHORT_VERSION</sparkle:shortVersionString>" "$APPCAST_PATH"; then
  info "appcast 里已有 ${SHORT_VERSION}，先移除旧条目"
  awk -v version="$SHORT_VERSION" '
    /<item>/ { buffering = 1; buffer = $0 ORS; next }
    buffering {
      buffer = buffer $0 ORS
      if ($0 ~ "<sparkle:shortVersionString>" version "</sparkle:shortVersionString>") { stale = 1 }
      if ($0 ~ /<\/item>/) {
        if (!stale) printf "%s", buffer
        buffering = 0; stale = 0; buffer = ""
      }
      next
    }
    { print }
  ' "$APPCAST_PATH" > "$APPCAST_PATH.tmp"
  mv "$APPCAST_PATH.tmp" "$APPCAST_PATH"
fi

awk -v anchor="$ANCHOR" -v item_file="$ITEM_FILE" '
  { print }
  index($0, anchor) && !inserted {
    while ((getline line < item_file) > 0) print line
    close(item_file)
    inserted = 1
  }
' "$APPCAST_PATH" > "$APPCAST_PATH.tmp"
mv "$APPCAST_PATH.tmp" "$APPCAST_PATH"

# 语法过一遍，别把坏掉的 feed 推上去——那会让所有用户的更新检查直接失败。
if ! xmllint --noout "$APPCAST_PATH" 2>/dev/null; then
  error "生成的 appcast 不是合法 XML，已保留现场：$APPCAST_PATH"
  exit 1
fi

info "已写入 appcast：${SHORT_VERSION}（CFBundleVersion ${BUNDLE_VERSION}，${ZIP_LENGTH} 字节）"
info "  签名: $ED_SIGNATURE"
info "  下载: $DOWNLOAD_URL"
