#!/usr/bin/env bash
#
# 导出菜单栏图标：用无头 Chrome 跑 tools/StatusIcon.html，把页面算出的两张 PNG 写回 Resources/。
# 设计和每个像素的取值都在那一页里，这里只负责把「导出」那两个链接里的图片落盘。
#
# 用法：
#   tools/export-status-icon.sh
#   CHROME=/path/to/chrome tools/export-status-icon.sh    # Chrome 不在默认位置时
#

set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOURCES_DIR="$(dirname "$TOOLS_DIR")/Resources"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

if [[ ! -x "$CHROME" ]]; then
  echo "[错误] 找不到 Chrome：${CHROME}（用 CHROME=... 指定路径，或在浏览器里打开 tools/StatusIcon.html 点「导出」里的两个链接）" >&2
  exit 1
fi

dom="$("$CHROME" --headless=new --disable-gpu --dump-dom "file://$TOOLS_DIR/StatusIcon.html" 2>/dev/null)"

for name in "StatusIcon.png" "StatusIcon@2x.png"; do
  pattern="${name//./\\.}"
  data="$(sed -n "s|.*download=\"$pattern\"[^>]*href=\"data:image/png;base64,\([^\"]*\)\".*|\1|p" <<<"$dom" | head -n 1)"
  if [[ -z "$data" ]]; then
    echo "[错误] 页面里没有 ${name} 的导出链接，检查 tools/StatusIcon.html 是否报错" >&2
    exit 1
  fi
  base64 --decode <<<"$data" > "$RESOURCES_DIR/$name"
  printf '[信息] 已写入 Resources/%s（%s）\n' "$name" \
    "$(sips -g pixelWidth -g pixelHeight "$RESOURCES_DIR/$name" | awk '/pixel/ { printf "%s%s", sep, $2; sep = " × " }')"
done
