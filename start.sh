#!/usr/bin/env bash
# =============================================================================
# singbox-tunnel 修复版启动脚本（在原作者 start.sh 基础上重写）
#
# 主要改动：
#   1. sing-box 只从官方 GitHub 下载，并强制 SHA-256 校验（可覆盖）。
#   2. 支持自定义证书：CERT_PATH / KEY_PATH / TLS_SNI；不再每次启动覆盖证书。
#   3. 启动前用 `sing-box check` 校验配置，失败直接报错，不再“假成功”。
#   4. 日志落盘（不再 2>/dev/null 吞掉所有错误），进程退出自动拉起。
#   5. 生成合法 JSON（不再依赖 sing-box 对尾逗号的宽松解析 / python3）。
#   6. 端口 / 域名 / 路径输入校验；UUID、TUIC 密码、Reality 密钥持久化。
#   7. SIGTERM/SIGINT 清理子进程；支持 DRY_RUN=1 只生成配置不启动。
#
# 用法示例：
#   直连 + 自己的证书（TUIC/Hysteria2/VLESS-WS-TLS）：
#     TUIC_PORT=10001 HY2_PORT=10002 VLESS_WS_PORT=443 ENABLE_WS_TLS=1 \
#     PUBLIC_HOST=fr.example.com TLS_SNI=fr.example.com \
#     CERT_PATH=/home/container/certs/fullchain.pem \
#     KEY_PATH=/home/container/certs/privkey.pem \
#     bash start.sh
#
#   Cloudflare Tunnel（不需要证书）：
#     CF_TUNNEL_TOKEN=eyJ... TUNNEL_DOMAIN=fr.example.com bash start.sh
# =============================================================================
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 可选本地配置：把域名/端口/证书变量写在 config.env（已在 .gitignore 中忽略）。
# 这样 git pull 更新脚本不会覆盖你的设置。
if [ -f "$SCRIPT_DIR/config.env" ]; then
  # shellcheck disable=SC1091
  set -a
  . "$SCRIPT_DIR/config.env"
  set +a
fi

# ------------------------------ 路径与日志 ---------------------------------
FILE_PATH="${FILE_PATH:-$SCRIPT_DIR/.npm}"
DATA_PATH="${DATA_PATH:-$SCRIPT_DIR/singbox_data}"
mkdir -p "$FILE_PATH" "$DATA_PATH"

LOG_FILE="${LOG_FILE:-$FILE_PATH/run.log}"
SINGBOX_LOG="${SINGBOX_LOG:-$FILE_PATH/sing-box.log}"
TUNNEL_LOG="${TUNNEL_LOG:-$FILE_PATH/cloudflared.log}"

log()  { printf '%s [start] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }
warn() { log "WARN: $*"; }
die()  { log "ERROR: $*"; exit 1; }

# ------------------------------ 环境变量 -----------------------------------
TUIC_PORT="${TUIC_PORT:-}"
HY2_PORT="${HY2_PORT:-}"
VLESS_WS_PORT="${VLESS_WS_PORT:-}"
REALITY_PORT="${REALITY_PORT:-}"

CF_TUNNEL_TOKEN="${CF_TUNNEL_TOKEN:-}"
TUNNEL_WSPORT="${TUNNEL_WSPORT:-56789}"
TUNNEL_DOMAIN="${TUNNEL_DOMAIN:-}"

# 对外域名 / 证书 SNI。PUBLIC_HOST 用于生成订阅里的地址，TLS_SNI 用于证书匹配。
PUBLIC_HOST="${PUBLIC_HOST:-$TUNNEL_DOMAIN}"
TLS_SNI="${TLS_SNI:-}"
WS_HOST="${WS_HOST:-}"                 # 直连 WS 的 Host 头，默认取 TLS_SNI/PUBLIC_HOST
WS_PATH="${WS_PATH:-/speedtest.net}"
ENABLE_WS_TLS="${ENABLE_WS_TLS:-0}"    # 直连 VLESS+WS 是否启用 TLS（1/0）
LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0}"  # 需要 IPv6 可设为 ::

# 证书：
#   auto       = 自动发现（CERT_DIR / .npm），找到就校验收；找不到才自签。绝不覆盖已有证书
#   custom     = 必须通过 CERT_PATH + KEY_PATH 显式指定，缺失/不匹配直接报错
#   selfsigned = 强制使用自签证书（已有且有效则复用）
CERT_MODE="${CERT_MODE:-auto}"
CERT_DIR="${CERT_DIR:-$SCRIPT_DIR/certs}"   # 外部证书默认放这里
CERT_PATH="${CERT_PATH:-}"                   # 显式指定优先
KEY_PATH="${KEY_PATH:-}"
ALLOW_INSECURE="${ALLOW_INSECURE:-}"   # 留空 = 自签证书自动用 insecure；0/1 可覆盖

# 进程伪装（保持原项目行为，默认开启）
SINGBOX_PROC_NAME="${SINGBOX_PROC_NAME:-[kworker/0:0]}"
TUNNEL_PROC_NAME="${TUNNEL_PROC_NAME:-[kworker/0:1]}"

TUIC_PASSWORD="${TUIC_PASSWORD:-}"
REALITY_SNI="${REALITY_SNI:-www.nazhumi.com}"
REALITY_SHORT_ID="${REALITY_SHORT_ID:-}"

# 下载与版本
SINGBOX_VERSION="${SINGBOX_VERSION:-1.12.12}"
SINGBOX_SHA256="${SINGBOX_SHA256:-}"
SINGBOX_TARBALL_URL="${SINGBOX_TARBALL_URL:-}"
SINGBOX_BINARY_URL="${SINGBOX_BINARY_URL:-}"
SINGBOX_BIN="${SINGBOX_BIN:-}"          # 调试用：直接指定已存在的 sing-box
CLOUDFLARED_VERSION="${CLOUDFLARED_VERSION:-latest}"
CLOUDFLARED_SHA256="${CLOUDFLARED_SHA256:-}"
CLOUDFLARED_BIN="${CLOUDFLARED_BIN:-}"

LOG_LEVEL="${LOG_LEVEL:-warn}"          # trace/debug/info/warn/error/fatal/panic/disabled
TUNNEL_LOGLEVEL="${TUNNEL_LOGLEVEL:-warn}"
DISGUISE="${DISGUISE:-1}"               # 1 = 伪装进程名；注意这通常违反托管商 ToS
DAILY_RESTART="${DAILY_RESTART:-1}"
DRY_RUN="${DRY_RUN:-0}"

# TUIC 0-RTT：降低重连握手延迟（QUIC early data）。服务端开启只代表"允许接收"，
# 客户端也必须开启（sing-box: zero_rtt_handshake / mihomo: reduce-rtt）才生效。
TUIC_ZERO_RTT="${TUIC_ZERO_RTT:-0}"      # 1 = 开启，0 = 关闭（默认关闭，0-RTT 有重放风险）

# ------------------------------ 基础校验 -----------------------------------

validate_port() {
  local name="$1" value="$2"
  [ -z "$value" ] && return 0
  [[ "$value" =~ ^[0-9]+$ ]] || die "$name 必须是数字，当前值: $value"
  (( value >= 1 && value <= 65535 )) || die "$name 超出范围 (1-65535): $value"
}

validate_domain() {
  local name="$1" value="$2"
  [ -z "$value" ] && return 0
  [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] \
    || die "$name 不是合法域名: $value"
}

# “0” 等价于未设置
[ "$TUIC_PORT" = "0" ] && TUIC_PORT=""
[ "$HY2_PORT" = "0" ] && HY2_PORT=""
[ "$VLESS_WS_PORT" = "0" ] && VLESS_WS_PORT=""
[ "$REALITY_PORT" = "0" ] && REALITY_PORT=""

validate_port TUIC_PORT "$TUIC_PORT"
validate_port HY2_PORT "$HY2_PORT"
validate_port VLESS_WS_PORT "$VLESS_WS_PORT"
validate_port REALITY_PORT "$REALITY_PORT"
validate_port TUNNEL_WSPORT "$TUNNEL_WSPORT"

validate_domain TUNNEL_DOMAIN "$TUNNEL_DOMAIN"
validate_domain PUBLIC_HOST "$PUBLIC_HOST"
validate_domain WS_HOST "$WS_HOST"
validate_domain TLS_SNI "$TLS_SNI"
validate_domain REALITY_SNI "$REALITY_SNI"

[[ "$WS_PATH" =~ ^/[A-Za-z0-9._~/-]*$ ]] || die "WS_PATH 必须以 / 开头且只含安全字符: $WS_PATH"
[[ "$REALITY_SHORT_ID" =~ ^[0-9a-fA-F]{0,16}$ ]] || die "REALITY_SHORT_ID 必须是 0-16 位十六进制"
[[ "$ENABLE_WS_TLS" =~ ^[01]$ ]] || die "ENABLE_WS_TLS 只能是 0 或 1"
[[ "$DISGUISE" =~ ^[01]$ ]] || die "DISGUISE 只能是 0 或 1"
[[ "$DAILY_RESTART" =~ ^[01]$ ]] || die "DAILY_RESTART 只能是 0 或 1"
[[ "$DRY_RUN" =~ ^[01]$ ]] || die "DRY_RUN 只能是 0 或 1"
[[ "$TUIC_ZERO_RTT" =~ ^[01]$ ]] || die "TUIC_ZERO_RTT 只能是 0 或 1"
[[ "$LISTEN_ADDR" =~ ^[0-9a-fA-F:.]+$ ]] || die "LISTEN_ADDR 非法: $LISTEN_ADDR"

# 模式与必填项
MODE="direct"
[ -n "$CF_TUNNEL_TOKEN" ] && MODE="tunnel"

if [ "$MODE" = "tunnel" ]; then
  TUNNEL_DOMAIN="${TUNNEL_DOMAIN:-$PUBLIC_HOST}"
  [ -n "$TUNNEL_DOMAIN" ] || die "隧道模式必须设置 TUNNEL_DOMAIN 或 PUBLIC_HOST"
  PUBLIC_HOST="${PUBLIC_HOST:-$TUNNEL_DOMAIN}"
  if [ -n "$TUIC_PORT$HY2_PORT$VLESS_WS_PORT$REALITY_PORT" ]; then
    warn "隧道模式只支持 VLESS+WS；TUIC/HY2/VLESS-WS/REALITY 端口设置将被忽略"
  fi
  TUIC_PORT=""
  HY2_PORT=""
  VLESS_WS_PORT=""
  REALITY_PORT=""
else
  PUBLIC_HOST="${PUBLIC_HOST:-$TUNNEL_DOMAIN}"
  [ -n "$TUIC_PORT$HY2_PORT$VLESS_WS_PORT$REALITY_PORT" ] || \
    die "直连模式至少需要设置 TUIC_PORT / HY2_PORT / VLESS_WS_PORT / REALITY_PORT 之一"
fi

# 端口重复检查
port_list=$(printf '%s\n' "$TUIC_PORT" "$HY2_PORT" "$VLESS_WS_PORT" "$REALITY_PORT" | sed '/^$/d')
if [ -n "$port_list" ]; then
  dup=$(printf '%s\n' "$port_list" | sort | uniq -d || true)
  [ -z "$dup" ] || die "端口重复: $dup"
fi

# TLS_SNI / WS_HOST 的默认值在证书解析之后确定（见“证书处理”小节）

case "$LOG_LEVEL" in
  trace|debug|info|warn|error|fatal|panic|disabled) ;;
  *) die "LOG_LEVEL 非法: $LOG_LEVEL" ;;
esac

# ------------------------------ 工具函数 -----------------------------------

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$1" | awk '{print $NF}'
  else
    die "找不到 sha256sum / shasum / openssl，无法校验下载文件"
  fi
}

fetch() {
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 10 --max-time 300 -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --timeout=30 -O "$out" "$url"
  else
    die "缺少 curl 或 wget"
  fi
}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# ------------------------------ 架构与下载 ---------------------------------

case "$(uname -m)" in
  x86_64|amd64)
    ARCH="amd64"
    DEFAULT_SHA256="ab92d1b3f0b72a84e42aa4ab4d081bbac8e07740de5ac65ecedabb1112a73772"
    ;;
  aarch64|arm64)
    ARCH="arm64"
    DEFAULT_SHA256="fa22109e484fc89221451f49a4dd6933d2140a105170a368471837186405e0ee"
    ;;
  *)
    die "不支持的架构: $(uname -m)（仅支持 x86_64 / aarch64；armv7 请自行编译）"
    ;;
esac

CACHE_DIR="$FILE_PATH/bin"
mkdir -p "$CACHE_DIR"

# 安装 sing-box
if [ -z "$SINGBOX_BIN" ]; then
  SINGBOX_BIN="$CACHE_DIR/sing-box-${SINGBOX_VERSION}-${ARCH}"
  EXPECTED_SHA="${SINGBOX_SHA256:-$DEFAULT_SHA256}"

  if [ -x "$SINGBOX_BIN" ] && [ "$(sha256_of "$SINGBOX_BIN")" = "$EXPECTED_SHA" ]; then
    log "复用已校验的 sing-box: $SINGBOX_BIN"
  else
    tmp_dir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp_dir'" EXIT

    if [ -n "$SINGBOX_BINARY_URL" ]; then
      [ -n "$SINGBOX_SHA256" ] || die "使用 SINGBOX_BINARY_URL 时必须提供 SINGBOX_SHA256（或改用官方压缩包）"
      log "下载 sing-box 二进制: $SINGBOX_BINARY_URL"
      fetch "$SINGBOX_BINARY_URL" "$tmp_dir/sing-box.bin"
      actual=$(sha256_of "$tmp_dir/sing-box.bin")
      [ "$actual" = "$EXPECTED_SHA" ] || die "sing-box SHA-256 校验失败（期望 $EXPECTED_SHA，实际 $actual）"
      install -m 700 "$tmp_dir/sing-box.bin" "$SINGBOX_BIN" 2>/dev/null \
        || { cp "$tmp_dir/sing-box.bin" "$SINGBOX_BIN" && chmod 700 "$SINGBOX_BIN"; }
    else
      [ "$SINGBOX_VERSION" = "1.12.12" ] || [ -n "$SINGBOX_SHA256" ] \
        || die "自定义 SINGBOX_VERSION 时必须提供 SINGBOX_SHA256"
      tarball_url="${SINGBOX_TARBALL_URL:-https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-${ARCH}.tar.gz}"
      log "下载 sing-box: $tarball_url"
      fetch "$tarball_url" "$tmp_dir/sing-box.tar.gz"
      tar -xzf "$tmp_dir/sing-box.tar.gz" -C "$tmp_dir"
      src="$tmp_dir/sing-box-${SINGBOX_VERSION}-linux-${ARCH}/sing-box"
      [ -f "$src" ] || die "压缩包内未找到预期路径: sing-box-${SINGBOX_VERSION}-linux-${ARCH}/sing-box"
      actual=$(sha256_of "$src")
      [ "$actual" = "$EXPECTED_SHA" ] || die "sing-box SHA-256 校验失败（期望 $EXPECTED_SHA，实际 $actual）"
      install -m 700 "$src" "$SINGBOX_BIN" 2>/dev/null \
        || { cp "$src" "$SINGBOX_BIN" && chmod 700 "$SINGBOX_BIN"; }
    fi

    rm -rf "$tmp_dir"
    trap - EXIT
    log "sing-box 安装完成: $SINGBOX_BIN"
  fi
else
  [ -x "$SINGBOX_BIN" ] || die "SINGBOX_BIN 不存在或不可执行: $SINGBOX_BIN"
  log "使用指定的 sing-box: $SINGBOX_BIN"
fi

# ------------------------------ UUID / 密码 --------------------------------

UUID_FILE="$FILE_PATH/uuid.txt"
if [ -s "$UUID_FILE" ]; then
  UUID=$(<"$UUID_FILE")
  log "复用固定 UUID: $UUID"
else
  if [ -r /proc/sys/kernel/random/uuid ]; then
    UUID=$(cat /proc/sys/kernel/random/uuid)
  elif command -v uuidgen >/dev/null 2>&1; then
    UUID=$(uuidgen | tr 'A-F' 'a-f')
  else
    UUID=$("$SINGBOX_BIN" generate uuid)
  fi
  printf '%s\n' "$UUID" > "$UUID_FILE"
  chmod 600 "$UUID_FILE"
  log "首次生成并保存 UUID: $UUID"
fi
[[ "$UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
  || die "uuid.txt 内容不是合法 UUID: $UUID"

PASS_FILE="$FILE_PATH/tuic-password.txt"
if [ -n "$TUIC_PASSWORD" ]; then
  :
elif [ -s "$PASS_FILE" ]; then
  TUIC_PASSWORD=$(<"$PASS_FILE")
else
  if command -v openssl >/dev/null 2>&1; then
    TUIC_PASSWORD=$(openssl rand -hex 16)
  else
    TUIC_PASSWORD=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)
  fi
  printf '%s\n' "$TUIC_PASSWORD" > "$PASS_FILE"
  chmod 600 "$PASS_FILE"
fi
[[ "$TUIC_PASSWORD" =~ ^[A-Za-z0-9]+$ ]] || die "TUIC_PASSWORD 只能是字母数字"

# ------------------------------ 证书处理 -----------------------------------

validate_cert_pair() {
  [ -s "$CERT_PATH" ] && [ -s "$KEY_PATH" ] || return 1
  command -v openssl >/dev/null 2>&1 || return 0   # 没有 openssl 时交给 sing-box check
  openssl x509 -in "$CERT_PATH" -noout -checkend 0 >/dev/null 2>&1 || return 1
  openssl pkey -in "$KEY_PATH" -noout >/dev/null 2>&1 || return 1
  local cert_pub key_pub
  cert_pub=$(openssl x509 -in "$CERT_PATH" -noout -pubkey 2>/dev/null \
    | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256 2>/dev/null || true)
  key_pub=$(openssl pkey -in "$KEY_PATH" -pubout -outform DER 2>/dev/null \
    | openssl dgst -sha256 2>/dev/null || true)
  [ -n "$cert_pub" ] && [ "$cert_pub" = "$key_pub" ]
}

detect_self_signed() {
  SELF_SIGNED=0
  command -v openssl >/dev/null 2>&1 || return 0
  [ -s "$CERT_PATH" ] || return 0
  local subject issuer
  subject=$(openssl x509 -in "$CERT_PATH" -noout -subject -nameopt RFC2253 2>/dev/null | sed 's/^subject=//')
  issuer=$(openssl x509 -in "$CERT_PATH" -noout -issuer -nameopt RFC2253 2>/dev/null | sed 's/^issuer=//')
  if [ -n "$subject" ] && [ "$subject" = "$issuer" ]; then
    SELF_SIGNED=1
  fi
  return 0
}

generate_self_signed() {
  # 此时 TLS_SNI 可能还没最终确定（证书域名要生成后才知道），因此准备一个可用名字
  local cn_name="${TLS_SNI:-${PUBLIC_HOST:-www.bing.com}}"
  local san="DNS:$cn_name"
  log "生成自签证书（CN=$cn_name）"
  mkdir -p "$(dirname "$CERT_PATH")" "$(dirname "$KEY_PATH")"
  local ok=0
  if command -v openssl >/dev/null 2>&1; then
    [[ "$cn_name" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && san="IP:$cn_name"

    # 用显式配置文件写 SAN：兼容 LibreSSL / OpenSSL 1.1.1 / 3.x，
    # 且不依赖系统默认 openssl.cnf（容器里经常缺失）。
    local cnf
    cnf=$(mktemp)
    cat > "$cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3_req

[dn]
CN = $cn_name

[v3_req]
basicConstraints = CA:TRUE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = $san
EOF

    if openssl ecparam -genkey -name prime256v1 -out "$KEY_PATH" 2>/dev/null \
      && openssl req -x509 -new -key "$KEY_PATH" -out "$CERT_PATH" \
           -config "$cnf" -extensions v3_req -days 3650 -sha256 >>"$LOG_FILE" 2>&1; then
      ok=1
    else
      warn "openssl 生成证书失败，尝试 sing-box 内置生成"
    fi
    rm -f "$cnf"
  fi

  if [ "$ok" -ne 1 ]; then
    local out
    out=$("$SINGBOX_BIN" generate tls-keypair "$cn_name" -m 120) \
      || die "openssl 与 sing-box 均无法生成自签证书"
    printf '%s\n' "$out" | awk '/BEGIN PRIVATE KEY/,/END PRIVATE KEY/' > "$KEY_PATH"
    printf '%s\n' "$out" | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' > "$CERT_PATH"
    [ -s "$KEY_PATH" ] && [ -s "$CERT_PATH" ] || die "解析 sing-box 生成的证书失败"
  fi

  chmod 600 "$KEY_PATH" "$CERT_PATH"
  SELF_SIGNED=1

  if command -v openssl >/dev/null 2>&1 \
    && ! openssl x509 -in "$CERT_PATH" -noout -checkhost "$cn_name" >/dev/null 2>&1; then
    warn "自签证书未覆盖 $cn_name，请确认 TLS_SNI / PUBLIC_HOST 设置"
  fi
}

# 候选路径中取第一个存在的非空文件
first_existing() {
  local f
  for f in "$@"; do
    [ -s "$f" ] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

# 从证书里取第一个域名：优先 SAN，其次 CN
cert_first_name() {
  [ -s "${CERT_PATH:-}" ] || return 1
  command -v openssl >/dev/null 2>&1 || return 1
  local text name
  text=$(openssl x509 -in "$CERT_PATH" -noout -text 2>/dev/null || true)
  [ -n "$text" ] || return 1
  name=$(printf '%s\n' "$text" \
    | awk '/Subject Alternative Name/{getline; print; exit}' \
    | tr ',' '\n' | sed -n 's/.*DNS:\([^ ,]*\).*/\1/p' | head -n1)
  if [ -z "$name" ]; then
    name=$(printf '%s\n' "$text" \
      | sed -n 's/.*Subject:.*CN *= *\([^,]*\).*/\1/p' | head -n1)
  fi
  [ -n "$name" ] && printf '%s' "$name"
}

# 自动发现证书：CERT_DIR（部署目录/certs）→ FILE_PATH/certs → FILE_PATH 自身
# 每个目录内必须成对，避免把 A 目录的证书和 B 目录的私钥拼在一起
discover_cert() {
  local dir c k
  for dir in "$CERT_DIR" "$FILE_PATH/certs"; do
    [ -d "$dir" ] || continue
    c=$(first_existing "$dir/fullchain.pem" "$dir/cert.pem" "$dir/chain.pem" || true)
    k=$(first_existing "$dir/privkey.pem" "$dir/key.pem" "$dir/private.key" || true)
    if [ -n "$c" ] && [ -n "$k" ]; then
      CERT_PATH="$c"
      KEY_PATH="$k"
      CERT_ORIGIN="auto"
      return 0
    fi
    if [ -n "$c" ] || [ -n "$k" ]; then
      die "在 $dir 只找到证书或私钥其中之一（cert=${c:-无} key=${k:-无}）；两者必须同时存在"
    fi
  done

  c=$(first_existing "$FILE_PATH/fullchain.pem" "$FILE_PATH/cert.pem" || true)
  k=$(first_existing "$FILE_PATH/privkey.pem" "$FILE_PATH/private.key" || true)
  if [ -n "$c" ] && [ -n "$k" ]; then
    CERT_PATH="$c"
    KEY_PATH="$k"
    CERT_ORIGIN="auto"
  elif [ -n "$c" ] || [ -n "$k" ]; then
    die "只找到证书或私钥其中之一（cert=${c:-无} key=${k:-无}）；请成对放到 $CERT_DIR/ 或同时设置 CERT_PATH/KEY_PATH"
  fi
}

if [ "$MODE" = "tunnel" ]; then
  # Cloudflare 在边缘终止 TLS，本机只有明文 HTTP/WS，证书既不需要也不生效
  log "隧道模式：TLS 由 Cloudflare 终止，跳过证书处理（自有证书在此模式下无效）"
  SELF_SIGNED=0
  INSECURE=0
else
  case "$CERT_MODE" in
    auto|custom|selfsigned) ;;
    *) die "CERT_MODE 只能是 auto / custom / selfsigned" ;;
  esac

  # 显式路径必须成对
  if [ -n "$CERT_PATH" ] || [ -n "$KEY_PATH" ]; then
    [ -n "$CERT_PATH" ] && [ -n "$KEY_PATH" ] \
      || die "CERT_PATH 与 KEY_PATH 必须同时设置（cert=${CERT_PATH:-无} key=${KEY_PATH:-无}）"
  elif [ "$CERT_MODE" != "custom" ]; then
    discover_cert
  fi

  case "$CERT_MODE" in
    custom)
      [ -s "$CERT_PATH" ] && [ -s "$KEY_PATH" ] \
        || die "CERT_MODE=custom 但文件不存在: $CERT_PATH / $KEY_PATH"
      validate_cert_pair \
        || die "证书/私钥校验失败（过期、不匹配或格式错误）：$CERT_PATH / $KEY_PATH"
      detect_self_signed
      log "使用自定义证书: $CERT_PATH"
      ;;

    selfsigned)
      if [ -s "$CERT_PATH" ] && [ -s "$KEY_PATH" ] && validate_cert_pair; then
        detect_self_signed
        log "复用已有自签证书: $CERT_PATH"
      else
        CERT_PATH="$FILE_PATH/cert.pem"
        KEY_PATH="$FILE_PATH/private.key"
        generate_self_signed
      fi
      ;;

    auto)
      if [ -n "$CERT_PATH" ]; then
        # 找到了就绝不覆盖；坏了就报错，让用户自己决定
        validate_cert_pair || die "找到证书（$CERT_PATH）但校验失败：可能已过期、与私钥不匹配或格式错误。脚本不会覆盖它；请修复/删除后重试，或设 CERT_MODE=selfsigned 重新自签"
        detect_self_signed
        if [ "${CERT_ORIGIN:-}" = "auto" ]; then
          log "自动发现证书: $CERT_PATH（自签=$SELF_SIGNED）"
        else
          log "使用证书: $CERT_PATH（自签=$SELF_SIGNED）"
        fi
      else
        CERT_PATH="$FILE_PATH/cert.pem"
        KEY_PATH="$FILE_PATH/private.key"
        generate_self_signed
      fi
      ;;
  esac

  chmod 600 "$KEY_PATH" 2>/dev/null || true

  if [ -z "$ALLOW_INSECURE" ]; then
    INSECURE="$SELF_SIGNED"
  else
    [[ "$ALLOW_INSECURE" =~ ^[01]$ ]] || die "ALLOW_INSECURE 只能是 0 或 1"
    INSECURE="$ALLOW_INSECURE"
  fi
  if [ "$INSECURE" = "1" ] && [ "$SELF_SIGNED" = "0" ]; then
    warn "ALLOW_INSECURE=1 会跳过证书校验，存在中间人风险"
  fi
  if [ "$SELF_SIGNED" = "1" ] && [ "$INSECURE" = "0" ]; then
    warn "使用自签证书但 ALLOW_INSECURE=0，客户端大概率无法连接"
  fi

  if [ "$SELF_SIGNED" = "0" ] && [ -n "$TLS_SNI" ] && command -v openssl >/dev/null 2>&1; then
    if ! openssl x509 -in "$CERT_PATH" -noout -checkhost "$TLS_SNI" >/dev/null 2>&1; then
      warn "证书 SAN 可能不包含 $TLS_SNI，客户端严格校验时会失败"
    fi
  fi
fi  # MODE=direct 证书处理结束

# ---------------------- TLS_SNI / WS_HOST 最终默认值 ----------------------
# 未显式设置 TLS_SNI 时，优先用证书自身域名；其次 PUBLIC_HOST；最后回退 www.bing.com
if [ -z "$TLS_SNI" ]; then
  DETECTED_NAME=""
  [ "$MODE" = "direct" ] && DETECTED_NAME=$(cert_first_name || true)
  TLS_SNI="${DETECTED_NAME:-${PUBLIC_HOST:-}}"
fi
[ -z "$TLS_SNI" ] && TLS_SNI="www.bing.com"
[ -z "$WS_HOST" ] && WS_HOST="$TLS_SNI"

validate_domain TLS_SNI "$TLS_SNI"
validate_domain WS_HOST "$WS_HOST"

if [ -n "$PUBLIC_HOST" ] && [ "$PUBLIC_HOST" != "$TLS_SNI" ]; then
  warn "PUBLIC_HOST ($PUBLIC_HOST) 与证书域名 TLS_SNI ($TLS_SNI) 不一致：订阅里地址用前者、SNI 用后者，请确认是否预期"
fi

if [ "$MODE" = "direct" ] && [ -z "$PUBLIC_HOST" ] \
  && ! [[ "$TLS_SNI" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  warn "证书是域名证书（$TLS_SNI），但未设置 PUBLIC_HOST，订阅会使用公网 IP，SNI 必然不匹配；建议设置 PUBLIC_HOST=$TLS_SNI"
fi

if [ "$TUIC_ZERO_RTT" = "1" ]; then
  log "TUIC 0-RTT 已启用（客户端也需开启：sing-box zero_rtt_handshake / mihomo reduce-rtt）"
fi

if [ "$DISGUISE" = "1" ]; then
  log "进程伪装已开启: sing-box='$SINGBOX_PROC_NAME' cloudflared='$TUNNEL_PROC_NAME'（Linux 上 /proc/PID/comm 仍是真实二进制名）"
fi

# ------------------------------ Reality 密钥 -------------------------------

private_key=""
public_key=""
if [ -n "$REALITY_PORT" ]; then
  KEY_FILE="$FILE_PATH/key.txt"
  if [ -s "$KEY_FILE" ]; then
    private_key=$(awk '/PrivateKey:/ {print $2}' "$KEY_FILE")
    public_key=$(awk '/PublicKey:/ {print $2}' "$KEY_FILE")
    log "复用已有 Reality 密钥"
  else
    out=$("$SINGBOX_BIN" generate reality-keypair) || die "生成 Reality 密钥失败"
    printf '%s\n' "$out" > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    private_key=$(printf '%s\n' "$out" | awk '/PrivateKey:/ {print $2}')
    public_key=$(printf '%s\n' "$out" | awk '/PublicKey:/ {print $2}')
    log "首次生成 Reality 密钥"
  fi
  [ -n "$private_key" ] && [ -n "$public_key" ] || die "Reality 密钥文件损坏: $KEY_FILE"
fi

# ------------------------------ 生成配置 -----------------------------------

CONFIG="$FILE_PATH/config.json"
CERT_JSON=$(json_escape "$CERT_PATH")
KEY_JSON=$(json_escape "$KEY_PATH")
TLS_SNI_JSON=$(json_escape "$TLS_SNI")
WS_PATH_JSON=$(json_escape "$WS_PATH")
WS_HOST_JSON=$(json_escape "$WS_HOST")
TUNNEL_HOST_JSON=$(json_escape "${TUNNEL_DOMAIN:-$PUBLIC_HOST}")
REALITY_SNI_JSON=$(json_escape "$REALITY_SNI")
REALITY_SHORT_JSON=$(json_escape "$REALITY_SHORT_ID")

# VLESS+WS 的 headers 片段（Host 为空则省略）
ws_headers() {
  if [ -n "$WS_HOST" ]; then
    printf ',\n        "headers": {"Host": "%s"}' "$WS_HOST_JSON"
  fi
}

if [ "$TUIC_ZERO_RTT" = "1" ]; then
  ZERO_RTT_JSON="true"
else
  ZERO_RTT_JSON="false"
fi

INBOUNDS=()

if [ "$MODE" = "tunnel" ]; then
  INBOUNDS+=("$(cat <<EOF
    {
      "type": "vless",
      "listen": "127.0.0.1",
      "listen_port": $TUNNEL_WSPORT,
      "users": [{"uuid": "$UUID"}],
      "transport": {
        "type": "ws",
        "path": "$WS_PATH_JSON"$(ws_headers)
      }
    }
EOF
)")
else
  if [ -n "$TUIC_PORT" ]; then
    INBOUNDS+=("$(cat <<EOF
    {
      "type": "tuic",
      "listen": "$LISTEN_ADDR",
      "listen_port": $TUIC_PORT,
      "users": [{"uuid": "$UUID", "password": "$TUIC_PASSWORD"}],
      "congestion_control": "bbr",
      "zero_rtt_handshake": $ZERO_RTT_JSON,
      "tls": {
        "enabled": true,
        "server_name": "$TLS_SNI_JSON",
        "alpn": ["h3"],
        "certificate_path": "$CERT_JSON",
        "key_path": "$KEY_JSON"
      }
    }
EOF
)")
  fi

  if [ -n "$HY2_PORT" ]; then
    INBOUNDS+=("$(cat <<EOF
    {
      "type": "hysteria2",
      "listen": "$LISTEN_ADDR",
      "listen_port": $HY2_PORT,
      "users": [{"password": "$UUID"}],
      "masquerade": "https://bing.com",
      "tls": {
        "enabled": true,
        "server_name": "$TLS_SNI_JSON",
        "alpn": ["h3"],
        "certificate_path": "$CERT_JSON",
        "key_path": "$KEY_JSON"
      }
    }
EOF
)")
  fi

  if [ -n "$VLESS_WS_PORT" ]; then
    ws_tls=""
    if [ "$ENABLE_WS_TLS" = "1" ]; then
      ws_tls=',
      "tls": {
        "enabled": true,
        "server_name": "'"$TLS_SNI_JSON"'",
        "certificate_path": "'"$CERT_JSON"'",
        "key_path": "'"$KEY_JSON"'"
      }'
    fi
    INBOUNDS+=("$(cat <<EOF
    {
      "type": "vless",
      "listen": "$LISTEN_ADDR",
      "listen_port": $VLESS_WS_PORT,
      "users": [{"uuid": "$UUID"}],
      "transport": {
        "type": "ws",
        "path": "$WS_PATH_JSON"$(ws_headers)
      }$ws_tls
    }
EOF
)")
  fi

  if [ -n "$REALITY_PORT" ]; then
    INBOUNDS+=("$(cat <<EOF
    {
      "type": "vless",
      "listen": "$LISTEN_ADDR",
      "listen_port": $REALITY_PORT,
      "users": [{"uuid": "$UUID", "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true,
        "server_name": "$REALITY_SNI_JSON",
        "reality": {
          "enabled": true,
          "handshake": {"server": "$REALITY_SNI_JSON", "server_port": 443},
          "private_key": "$private_key",
          "short_id": ["$REALITY_SHORT_JSON"]
        }
      }
    }
EOF
)")
  fi
fi

[ "${#INBOUNDS[@]}" -gt 0 ] || die "没有生成任何入站配置"

INBOUNDS_JSON=""
for inbound in "${INBOUNDS[@]}"; do
  if [ -n "$INBOUNDS_JSON" ]; then
    INBOUNDS_JSON+=$',\n'
  fi
  INBOUNDS_JSON+="$inbound"
done

if [ "$LOG_LEVEL" = "disabled" ]; then
  LOG_JSON='{"disabled": true}'
else
  LOG_JSON="{\"level\": \"$LOG_LEVEL\", \"timestamp\": true}"
fi

cat > "$CONFIG.tmp" <<EOF
{
  "log": $LOG_JSON,
  "inbounds": [
$INBOUNDS_JSON
  ],
  "outbounds": [{"type": "direct"}]
}
EOF
mv -f "$CONFIG.tmp" "$CONFIG"
chmod 600 "$CONFIG"

# 启动前校验，避免“配置错了还打印启动成功”
if ! check_output=$("$SINGBOX_BIN" check -c "$CONFIG" 2>&1); then
  log "sing-box 配置校验失败："
  printf '%s\n' "$check_output" | tee -a "$LOG_FILE" >&2
  exit 1
fi
log "配置校验通过: $CONFIG"

# ------------------------------ 订阅 ---------------------------------------

PATH_ENC=$(printf '%s' "$WS_PATH" | sed 's|/|%2F|g')

IP=""
if [ -z "$PUBLIC_HOST" ] && [ "$MODE" = "direct" ]; then
  IP=$(curl -4 -s --max-time 3 https://api.ipify.org 2>/dev/null || true)
  if ! [[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    IP=$(curl -4 -s --max-time 3 https://ipv4.ip.sb 2>/dev/null || true)
  fi
  if ! [[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    warn "无法获取公网 IPv4，请在订阅里手动替换 YOUR_SERVER_IP"
    IP="YOUR_SERVER_IP"
  fi
fi

LINK_HOST="${PUBLIC_HOST:-$IP}"

ISP=$(curl -s --max-time 3 https://speed.cloudflare.com/meta 2>/dev/null \
  | sed -n 's/.*"asOrganization":"\([^"]*\)".*/\1/p' | head -n1 || true)
ISP=${ISP:-UNKNOWN}
ISP=${ISP// /_}

LIST="$FILE_PATH/list.txt"
SUB="$FILE_PATH/sub.txt"
: > "$LIST"

if [ "$MODE" = "tunnel" ]; then
  printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&type=ws&path=%s&host=%s#VLESS-WS-Tunnel\n' \
    "$UUID" "$TUNNEL_DOMAIN" "$TUNNEL_DOMAIN" "$PATH_ENC" "$TUNNEL_DOMAIN" >> "$LIST"
else
  if [ -n "$TUIC_PORT" ]; then
    printf 'tuic://%s:%s@%s:%s?sni=%s&alpn=h3&congestion_control=bbr&allowInsecure=%s#TUIC-%s\n' \
      "$UUID" "$TUIC_PASSWORD" "$LINK_HOST" "$TUIC_PORT" "$TLS_SNI" "$INSECURE" "$ISP" >> "$LIST"
  fi
  if [ -n "$HY2_PORT" ]; then
    printf 'hysteria2://%s@%s:%s/?sni=%s&insecure=%s#Hysteria2-%s\n' \
      "$UUID" "$LINK_HOST" "$HY2_PORT" "$TLS_SNI" "$INSECURE" "$ISP" >> "$LIST"
  fi
  if [ -n "$VLESS_WS_PORT" ]; then
    if [ "$ENABLE_WS_TLS" = "1" ]; then
      printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&type=ws&path=%s&host=%s&allowInsecure=%s#VLESS-WS-%s\n' \
        "$UUID" "$LINK_HOST" "$VLESS_WS_PORT" "$TLS_SNI" "$PATH_ENC" "$WS_HOST" "$INSECURE" "$ISP" >> "$LIST"
    else
      printf 'vless://%s@%s:%s?encryption=none&security=none&type=ws&path=%s&host=%s#VLESS-WS-%s\n' \
        "$UUID" "$LINK_HOST" "$VLESS_WS_PORT" "$PATH_ENC" "$WS_HOST" "$ISP" >> "$LIST"
    fi
  fi
  if [ -n "$REALITY_PORT" ]; then
    printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=firefox&pbk=%s&sid=%s&type=tcp#Reality-%s\n' \
      "$UUID" "$LINK_HOST" "$REALITY_PORT" "$REALITY_SNI" "$public_key" "$REALITY_SHORT_ID" "$ISP" >> "$LIST"
  fi
fi

if command -v base64 >/dev/null 2>&1; then
  base64 < "$LIST" | tr -d '\n' > "$SUB"
elif command -v openssl >/dev/null 2>&1; then
  openssl base64 -A -in "$LIST" -out "$SUB"
else
  die "缺少 base64 / openssl，无法生成订阅"
fi
chmod 600 "$LIST" "$SUB"

log "订阅链接："
while IFS= read -r link; do
  printf '%s\n' "$link" | tee -a "$LOG_FILE"
done < "$LIST"
log "已保存: $SUB"

[ "$DRY_RUN" = "1" ] && { log "DRY_RUN=1，不启动服务"; exit 0; }

# ------------------------------ 启动与守护 ---------------------------------

stop_pid() {
  local pid="${1:-}"
  [ -n "$pid" ] || return 0
  kill "$pid" 2>/dev/null || true
  local i
  for i in 1 2 3 4 5; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 1
  done
  kill -9 "$pid" 2>/dev/null || true
}

SINGBOX_PID=""
TUNNEL_PID=""

start_singbox() {
  if [ "$DISGUISE" = "1" ]; then
    ( exec -a "$SINGBOX_PROC_NAME" "$SINGBOX_BIN" run -c "$CONFIG" >>"$SINGBOX_LOG" 2>&1 ) &
  else
    "$SINGBOX_BIN" run -c "$CONFIG" >>"$SINGBOX_LOG" 2>&1 &
  fi
  SINGBOX_PID=$!
  sleep 2
  if ! kill -0 "$SINGBOX_PID" 2>/dev/null; then
    log "sing-box 启动失败，最近日志："
    tail -n 30 "$SINGBOX_LOG" 2>/dev/null | tee -a "$LOG_FILE" || true
    return 1
  fi
  log "sing-box 已启动 PID=$SINGBOX_PID"
}

start_tunnel() {
  if [ "$DISGUISE" = "1" ]; then
    ( export TUNNEL_TOKEN="$CF_TUNNEL_TOKEN"
      exec -a "$TUNNEL_PROC_NAME" "$CLOUDFLARED_BIN" tunnel --no-autoupdate --loglevel "$TUNNEL_LOGLEVEL" run \
        >>"$TUNNEL_LOG" 2>&1 ) &
  else
    ( export TUNNEL_TOKEN="$CF_TUNNEL_TOKEN"
      exec "$CLOUDFLARED_BIN" tunnel --no-autoupdate --loglevel "$TUNNEL_LOGLEVEL" run \
        >>"$TUNNEL_LOG" 2>&1 ) &
  fi
  TUNNEL_PID=$!
  sleep 3
  if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
    log "cloudflared 启动失败，最近日志："
    tail -n 30 "$TUNNEL_LOG" 2>/dev/null | tee -a "$LOG_FILE" || true
    return 1
  fi
  log "cloudflared 已启动 PID=$TUNNEL_PID"
}

cleanup() {
  local code=$?
  trap - EXIT INT TERM
  log "收到退出信号，清理子进程..."
  stop_pid "${TUNNEL_PID:-}"
  stop_pid "${SINGBOX_PID:-}"
  exit "$code"
}
trap cleanup EXIT INT TERM

# cloudflared 按需下载
if [ "$MODE" = "tunnel" ] && [ -z "$CLOUDFLARED_BIN" ]; then
  CLOUDFLARED_BIN="$CACHE_DIR/cloudflared-linux-${ARCH}-${CLOUDFLARED_VERSION}"
  if [ ! -x "$CLOUDFLARED_BIN" ]; then
    if [ "$CLOUDFLARED_VERSION" = "latest" ]; then
      cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}"
    else
      cf_url="https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${ARCH}"
    fi
    log "下载 cloudflared: $cf_url"
    tmp_cf=$(mktemp)
    fetch "$cf_url" "$tmp_cf" || { rm -f "$tmp_cf"; die "cloudflared 下载失败"; }
    if [ -n "$CLOUDFLARED_SHA256" ]; then
      actual=$(sha256_of "$tmp_cf")
      [ "$actual" = "$CLOUDFLARED_SHA256" ] || { rm -f "$tmp_cf"; die "cloudflared SHA-256 校验失败"; }
    else
      warn "未设置 CLOUDFLARED_SHA256，cloudflared 未做完整性校验"
    fi
    chmod 700 "$tmp_cf"
    mv -f "$tmp_cf" "$CLOUDFLARED_BIN"
  fi
fi

# 每次启动前轮转日志，避免无限增长
[ -f "$SINGBOX_LOG" ] && mv -f "$SINGBOX_LOG" "$SINGBOX_LOG.1" 2>/dev/null || true
[ -f "$TUNNEL_LOG" ]  && mv -f "$TUNNEL_LOG"  "$TUNNEL_LOG.1"  2>/dev/null || true

start_singbox || die "sing-box 无法启动"
if [ "$MODE" = "tunnel" ]; then
  start_tunnel || die "cloudflared 无法启动"
  log "请确认 Cloudflare Zero Trust 的 Public Hostname 指向 HTTP localhost:$TUNNEL_WSPORT"
fi

LAST_RESTART_DAY=-1
while true; do
  now_ts=$(date +%s)
  beijing_ts=$(( now_ts + 28800 ))
  H=$(( (beijing_ts / 3600) % 24 ))
  M=$(( (beijing_ts / 60) % 60 ))
  D=$(( beijing_ts / 86400 ))

  if [ "$DAILY_RESTART" = "1" ] && [ "$H" -eq 0 ] && [ "$M" -eq 3 ] && [ "$D" -ne "$LAST_RESTART_DAY" ]; then
    LAST_RESTART_DAY=$D
    log "北京时间 00:03，执行每日重启"
    stop_pid "$SINGBOX_PID"
    start_singbox || warn "sing-box 重启失败，稍后重试"
    if [ "$MODE" = "tunnel" ]; then
      stop_pid "$TUNNEL_PID"
      start_tunnel || warn "cloudflared 重启失败，稍后重试"
    fi
  fi

  if ! kill -0 "$SINGBOX_PID" 2>/dev/null; then
    log "sing-box 已退出，2 秒后重启"
    sleep 2
    start_singbox || warn "sing-box 重启失败，稍后重试"
  fi

  if [ "$MODE" = "tunnel" ] && ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
    log "cloudflared 已退出，2 秒后重启"
    sleep 2
    start_tunnel || warn "cloudflared 重启失败，稍后重试"
  fi

  sleep 5
done
