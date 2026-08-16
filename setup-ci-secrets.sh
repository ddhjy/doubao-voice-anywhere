#!/usr/bin/env bash
#
# 把 Developer ID 证书、公证凭证和 Sparkle 更新签名私钥写进 GitHub Actions
# Secrets，供 release.yml 用。
#
# 用法：
#   ./setup-ci-secrets.sh                 # 三样都配
#   ./setup-ci-secrets.sh --cert-only     # 只配签名证书
#   ./setup-ci-secrets.sh --notary-only   # 只配公证凭证
#   ./setup-ci-secrets.sh --sparkle-only  # 只配 Sparkle 更新签名私钥
#
# 密钥一律走管道交给 gh，不落仓库、不经过命令行参数（免得出现在 ps 输出里）。
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DO_CERT=1
DO_NOTARY=1
DO_SPARKLE=1

for arg in "$@"; do
  case "$arg" in
    --cert-only)    DO_NOTARY=0; DO_SPARKLE=0 ;;
    --notary-only)  DO_CERT=0; DO_SPARKLE=0 ;;
    --sparkle-only) DO_CERT=0; DO_NOTARY=0 ;;
    --help|-h)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "[错误] 未知参数：$arg" >&2; exit 1 ;;
  esac
done

info()  { printf '[信息] %s\n' "$1"; }
warn()  { printf '[注意] %s\n' "$1" >&2; }
error() { printf '[错误] %s\n' "$1" >&2; }
step()  { printf '\n===== %s =====\n' "$1"; }

ask() {
  local prompt="$1" varname="$2" answer
  read -r -p "$prompt" answer
  printf -v "$varname" '%s' "$answer"
}

ask_secret() {
  local prompt="$1" varname="$2" answer
  read -r -s -p "$prompt" answer
  echo
  printf -v "$varname" '%s' "$answer"
}

confirm() {
  local answer
  read -r -p "$1 [y/N] " answer
  [[ "$answer" == "y" || "$answer" == "Y" ]]
}

# 展开 ~ 并去掉拖拽文件到终端时带上的引号和尾随空格。
normalize_path() {
  local raw="$1"
  raw="${raw%"${raw##*[![:space:]]}"}"
  raw="${raw#\'}"; raw="${raw%\'}"
  raw="${raw#\"}"; raw="${raw%\"}"
  raw="${raw/#\~/$HOME}"
  printf '%s' "$raw"
}

set_secret() {
  local name="$1"
  if gh secret set "$name"; then
    info "已写入 secret：$name"
  else
    error "写入 secret 失败：$name"
    exit 1
  fi
}

# ---- 前置检查 ----

for cmd in gh /usr/bin/openssl base64; do
  if ! command -v "$cmd" > /dev/null 2>&1; then
    error "缺少命令：$cmd"
    exit 1
  fi
done

if ! gh auth status > /dev/null 2>&1; then
  error "gh 未登录，先执行 gh auth login"
  exit 1
fi

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
info "目标仓库：$REPO"
if ! confirm "确认往这个仓库写 secrets？"; then
  info "已取消"
  exit 0
fi

# ---- 一、签名证书 ----

if [[ "$DO_CERT" -eq 1 ]]; then
  step "1/3 Developer ID 签名证书"

  DEFAULT_IDENTITY=""
  if [[ -f "$SCRIPT_DIR/.codesign-identity" ]]; then
    DEFAULT_IDENTITY="$(head -n 1 "$SCRIPT_DIR/.codesign-identity" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  fi

  if [[ -n "$DEFAULT_IDENTITY" ]]; then
    info "本地 .codesign-identity 里的身份：$DEFAULT_IDENTITY"
    ask "直接用它？留空即确认，否则输入完整证书名：" INPUT_IDENTITY
    SIGN_IDENTITY="${INPUT_IDENTITY:-$DEFAULT_IDENTITY}"
  else
    security find-identity -v -p codesigning || true
    ask "输入要用的完整证书名（形如 Developer ID Application: 你的名字 (TEAMID)）：" SIGN_IDENTITY
  fi

  if [[ -z "$SIGN_IDENTITY" ]]; then
    error "证书名不能为空"
    exit 1
  fi

  cat <<GUIDE

私钥没法用命令行只导出单张证书（security export 会把钥匙串里所有身份一起导出），
所以这一步得手动走一次「钥匙串访问」：

  1. 打开「钥匙串访问」，左侧选「登录」钥匙串 + 上方选「我的证书」
  2. 找到并选中：$SIGN_IDENTITY
     （只选这一张，别多选——你钥匙串里还有其他账号的 Developer ID 证书）
  3. 右键 →「导出"$SIGN_IDENTITY"…」，格式选「个人信息交换 (.p12)」
  4. 存到一个临时位置，设一个导出密码（下一步要输，配完可以删掉 .p12）

GUIDE

  if confirm "现在打开「钥匙串访问」？"; then
    open -a "Keychain Access" || true
  fi

  P12_INPUT=""
  while [[ -z "$P12_INPUT" ]]; do
    ask "导出好的 .p12 文件路径（可直接把文件拖进终端）：" P12_RAW
    P12_INPUT="$(normalize_path "$P12_RAW")"
    if [[ ! -f "$P12_INPUT" ]]; then
      warn "找不到文件：$P12_INPUT"
      P12_INPUT=""
    fi
  done

  ask_secret "该 .p12 的导出密码：" P12_PASSWORD

  # 校验：密码对不对、私钥在不在、里头到底装了哪几张证书。
  # 这个钥匙串里有多个账号的 Developer ID 证书，误导出别人的私钥就麻烦了。
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT

  if ! /usr/bin/openssl pkcs12 -in "$P12_INPUT" -passin "pass:$P12_PASSWORD" \
       -nokeys -out "$TMP_DIR/certs.pem" 2> "$TMP_DIR/err.log"; then
    error "读不出 .p12，多半是密码不对；openssl 输出："
    cat "$TMP_DIR/err.log" >&2
    exit 1
  fi

  if ! /usr/bin/openssl pkcs12 -in "$P12_INPUT" -passin "pass:$P12_PASSWORD" \
       -nocerts -noout 2> /dev/null; then
    error ".p12 里没有私钥，导出时请选中证书条目本身（展开后带小钥匙的那一项）"
    exit 1
  fi

  awk -v dir="$TMP_DIR" '
    /BEGIN CERTIFICATE/ { n++ }
    n { print > (dir "/cert" n ".pem") }
  ' "$TMP_DIR/certs.pem"

  echo
  info ".p12 里包含的证书："
  FOUND_TARGET=0
  FOREIGN_IDENTITIES=()
  SEEN_FINGERPRINTS=""
  for pem in "$TMP_DIR"/cert*.pem; do
    [[ -f "$pem" ]] || continue

    # 取 CN 必须用 -nameopt multiline：LibreSSL 默认把 subject 打成
    # /UID=…/CN=…/OU=… 这种斜杠分隔，按逗号切会把 CN 后面的字段一并吃进来。
    cn="$(/usr/bin/openssl x509 -in "$pem" -noout -subject -nameopt multiline 2> /dev/null \
      | sed -n 's/^[[:space:]]*commonName[[:space:]]*=[[:space:]]*//p')"
    [[ -n "$cn" ]] || continue

    # 钥匙串导出常把同一张证书带出两份，按指纹去重，免得看着像多导了东西。
    fingerprint="$(/usr/bin/openssl x509 -in "$pem" -noout -fingerprint 2> /dev/null || true)"
    if [[ -n "$fingerprint" ]]; then
      case "$SEEN_FINGERPRINTS" in
        *"|$fingerprint|"*) continue ;;
      esac
      SEEN_FINGERPRINTS="$SEEN_FINGERPRINTS|$fingerprint|"
    fi

    expires="$(/usr/bin/openssl x509 -in "$pem" -noout -enddate 2> /dev/null | sed 's/^notAfter=//')"
    printf '  - %s（有效期至 %s）\n' "$cn" "${expires:-未知}"

    if [[ "$cn" == "$SIGN_IDENTITY" ]]; then
      FOUND_TARGET=1
    elif [[ "$cn" == "Developer ID Application:"* || "$cn" == "Apple Development:"* ]]; then
      FOREIGN_IDENTITIES+=("$cn")
    fi
  done
  echo

  if [[ "$FOUND_TARGET" -eq 0 ]]; then
    error ".p12 里找不到目标证书：$SIGN_IDENTITY"
    exit 1
  fi

  if [[ ${#FOREIGN_IDENTITIES[@]} -gt 0 ]]; then
    warn "这个 .p12 还带着另外 ${#FOREIGN_IDENTITIES[@]} 张签名证书（连同私钥）："
    for cn in "${FOREIGN_IDENTITIES[@]}"; do
      warn "    $cn"
    done
    warn "上传等于把这些私钥也交给 GitHub。建议回「钥匙串访问」只选中一张重新导出。"
    if ! confirm "仍然继续上传？"; then
      info "已取消"
      exit 0
    fi
  fi

  base64 < "$P12_INPUT" | tr -d '\n' | set_secret MACOS_CERTIFICATE_P12
  printf '%s' "$P12_PASSWORD" | set_secret MACOS_CERTIFICATE_PASSWORD
  printf '%s' "$SIGN_IDENTITY" | set_secret MACOS_SIGN_IDENTITY

  echo
  info "证书部分完成，本地那份 .p12 现在可以删了：$P12_INPUT"
fi

# ---- 二、公证凭证 ----

if [[ "$DO_NOTARY" -eq 1 ]]; then
  step "2/3 公证凭证（App Store Connect API Key）"

  cat <<'GUIDE'

还没有 API Key 的话：

  1. 打开 https://appstoreconnect.apple.com/access/integrations/api
  2. 选「团队密钥」标签页 →「+」生成密钥，名称随意，角色选「开发者」
  3. 下载 AuthKey_XXXXXXXXXX.p8（只能下载一次，存好）
  4. Issuer ID 就在同一页面顶部，形如 57246542-96fe-1a63-e053-0824d011072a

GUIDE

  if confirm "现在在浏览器打开 App Store Connect？"; then
    open "https://appstoreconnect.apple.com/access/integrations/api" || true
  fi

  P8_INPUT=""
  while [[ -z "$P8_INPUT" ]]; do
    ask "AuthKey_XXXXXXXXXX.p8 的路径（可直接拖进终端）：" P8_RAW
    P8_INPUT="$(normalize_path "$P8_RAW")"
    if [[ ! -f "$P8_INPUT" ]]; then
      warn "找不到文件：$P8_INPUT"
      P8_INPUT=""
    fi
  done

  # Key ID 就藏在文件名里：AuthKey_ABCDE12345.p8
  P8_BASENAME="$(basename "$P8_INPUT")"
  GUESSED_KEY_ID=""
  if [[ "$P8_BASENAME" =~ ^AuthKey_([A-Z0-9]+)\.p8$ ]]; then
    GUESSED_KEY_ID="${BASH_REMATCH[1]}"
  fi

  if [[ -n "$GUESSED_KEY_ID" ]]; then
    ask "Key ID（从文件名认出是 ${GUESSED_KEY_ID}，留空即确认）：" INPUT_KEY_ID
    API_KEY_ID="${INPUT_KEY_ID:-$GUESSED_KEY_ID}"
  else
    ask "Key ID（10 位大写字母数字）：" API_KEY_ID
  fi

  ask "Issuer ID（UUID）：" API_ISSUER_ID

  if [[ -z "$API_KEY_ID" || -z "$API_ISSUER_ID" ]]; then
    error "Key ID 和 Issuer ID 都不能为空"
    exit 1
  fi

  base64 < "$P8_INPUT" | tr -d '\n' | set_secret APPLE_API_KEY_P8
  printf '%s' "$API_KEY_ID" | set_secret APPLE_API_KEY_ID
  printf '%s' "$API_ISSUER_ID" | set_secret APPLE_API_ISSUER_ID
fi

# ---- 三、Sparkle 更新签名私钥 ----
#
# 自动更新靠这把 EdDSA 私钥给更新包签名，公钥（SUPublicEDKey）写死在
# Resources/Info.plist 里。两者必须配对：换了私钥就得同步换公钥，
# 否则老用户校验不过、收不到更新。

if [[ "$DO_SPARKLE" -eq 1 ]]; then
  step "3/3 Sparkle 更新签名私钥"

  SPARKLE_BIN="$SCRIPT_DIR/.build/artifacts/sparkle/Sparkle/bin"
  if [[ ! -x "$SPARKLE_BIN/generate_keys" ]]; then
    info "Sparkle 工具还没下载，执行 swift build 拉一次依赖"
    swift build > /dev/null
  fi
  if [[ ! -x "$SPARKLE_BIN/generate_keys" ]]; then
    error "找不到 generate_keys：$SPARKLE_BIN"
    exit 1
  fi

  # 一把私钥可以服务多个 App（Sparkle 官方建议），钥匙串里已有就直接复用，
  # 不带参数跑 generate_keys 也只会沿用已有的、不会覆盖。
  if PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" -p 2> /dev/null)" && [[ -n "$PUBLIC_KEY" ]]; then
    info "复用钥匙串里已有的签名密钥"
  else
    info "钥匙串里还没有签名密钥，现在生成一把"
    "$SPARKLE_BIN/generate_keys"
    PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" -p)"
  fi

  # 核对公钥和 Info.plist 里写死的那个是否一致，不一致就是要么改错了、
  # 要么在另一台机器上生成过新密钥。
  PLIST_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" \
    "$SCRIPT_DIR/Resources/Info.plist" 2> /dev/null || true)"

  info "钥匙串里的公钥：$PUBLIC_KEY"
  if [[ -z "$PLIST_PUBLIC_KEY" ]]; then
    warn "Resources/Info.plist 里没有 SUPublicEDKey，请把上面这行公钥填进去"
  elif [[ "$PLIST_PUBLIC_KEY" != "$PUBLIC_KEY" ]]; then
    error "和 Resources/Info.plist 里的 SUPublicEDKey 对不上："
    error "    Info.plist: $PLIST_PUBLIC_KEY"
    error "    钥匙串:     $PUBLIC_KEY"
    error "用错私钥签出来的更新包，用户端校验不过。确认该用哪一把再继续。"
    exit 1
  else
    info "与 Resources/Info.plist 里的 SUPublicEDKey 一致"
  fi

  # -x 只能写文件，不能输出到 stdout；用临时文件中转，读完立刻删。
  SPARKLE_TMP="$(mktemp -d)"
  trap 'rm -rf "$SPARKLE_TMP"' EXIT
  SPARKLE_KEY_FILE="$SPARKLE_TMP/sparkle_private_key"

  if ! "$SPARKLE_BIN/generate_keys" -x "$SPARKLE_KEY_FILE" > /dev/null; then
    error "导出私钥失败（钥匙串弹窗要选「始终允许」）"
    exit 1
  fi

  tr -d '\n' < "$SPARKLE_KEY_FILE" | set_secret SPARKLE_PRIVATE_KEY
  rm -f "$SPARKLE_KEY_FILE"
fi

# ---- 收尾 ----

step "当前仓库 secrets"
gh secret list

cat <<'DONE'

配置完成。之后把应用代码推到 main 就会自动发版；需要指定版本时：

  git tag v1.0.0 && git push origin v1.0.0

Release 工作流会自动编译 universal 包、用你的证书签名、送去 Apple 公证，
最后把 DMG 挂到 GitHub Release 上。进度看：gh run watch
DONE
