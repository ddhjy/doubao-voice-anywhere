#!/usr/bin/env bash
#
# 提交 Apple 公证并等待结果，被拒时打印完整日志再失败。
#
# 用法：
#   ./notarize.sh <文件>      # 只接受 .zip / .dmg / .pkg，裸 .app 不行
#
# 凭证走 App Store Connect API Key，从环境变量读：
#   NOTARY_KEY_PATH   AuthKey_XXXXXXXX.p8 的路径
#   NOTARY_KEY_ID     Key ID（10 位）
#   NOTARY_ISSUER_ID  Issuer ID（UUID）
#

set -euo pipefail

TARGET="${1:-}"

if [[ -z "$TARGET" ]]; then
  echo "[错误] 用法：$(basename "$0") <要公证的 zip/dmg/pkg>" >&2
  exit 1
fi

if [[ ! -f "$TARGET" ]]; then
  echo "[错误] 找不到文件：$TARGET" >&2
  exit 1
fi

for var in NOTARY_KEY_PATH NOTARY_KEY_ID NOTARY_ISSUER_ID; do
  if [[ -z "${!var:-}" ]]; then
    echo "[错误] 缺少环境变量 $var" >&2
    exit 1
  fi
done

info() { printf '[信息] %s\n' "$1"; }

notary_args=(
  --key "$NOTARY_KEY_PATH"
  --key-id "$NOTARY_KEY_ID"
  --issuer "$NOTARY_ISSUER_ID"
)

info "提交公证：$(basename "$TARGET")（等待 Apple 返回结果，通常 1-5 分钟）"

# notarytool 的退出码只反映"提交动作"成功与否：审核结果是 Invalid 时它照样
# 返回 0。所以必须解析 JSON 里的 status 自己判定。
submit_output="$(xcrun notarytool submit "$TARGET" "${notary_args[@]}" --wait --output-format json)"
echo "$submit_output"

read_field() {
  /usr/bin/python3 -c "import json,sys; print(json.load(sys.stdin).get('$1',''))" <<<"$submit_output"
}

status="$(read_field status)"
submission_id="$(read_field id)"

if [[ "$status" != "Accepted" ]]; then
  echo "[错误] 公证未通过，状态：${status:-未知}" >&2
  if [[ -n "$submission_id" ]]; then
    echo "---- notarytool log $submission_id ----" >&2
    xcrun notarytool log "$submission_id" "${notary_args[@]}" >&2 || true
  fi
  exit 1
fi

info "公证通过（submission id: ${submission_id}）"
