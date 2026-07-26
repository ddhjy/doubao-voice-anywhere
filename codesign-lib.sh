#!/usr/bin/env bash
#
# 代码签名身份解析。由 build.sh / package-dmg.sh source 使用，不单独执行。
#
# macOS 的辅助功能授权跟随签名身份：身份稳定，重装后不用重新授权。

CODESIGN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODESIGN_IDENTITY_FILE="$CODESIGN_LIB_DIR/.codesign-identity"

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

  if [[ -f "$CODESIGN_IDENTITY_FILE" ]]; then
    local from_file
    from_file="$(head -n 1 "$CODESIGN_IDENTITY_FILE" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
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
