#!/usr/bin/env bash
# 把外部申请的证书整理成 start.sh 需要的格式。
#
# 用法：
#   ./tools/import-cert.sh cert.pem privkey.pem [chain.pem]     # 已有 PEM
#   ./tools/import-cert.sh --pfx cert.pfx                       # 从 pfx/p12 转换
#   PFX_PASSWORD=xxx ./tools/import-cert.sh --pfx cert.pfx      # 非交互
#   ./tools/import-cert.sh --check                              # 只检查 certs/ 里的证书
#
# 输出（覆盖前会备份为 *.bak）：
#   certs/fullchain.pem   叶子证书 + 中间证书
#   certs/privkey.pem     未加密私钥，权限 600
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_DIR="${CERT_DIR:-$ROOT/certs}"
OUT_CERT="$CERT_DIR/fullchain.pem"
OUT_KEY="$CERT_DIR/privkey.pem"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '[cert] %s\n' "$*"; }

command -v openssl >/dev/null 2>&1 || die "需要 openssl"

backup() {
  local f="$1"
  if [ -f "$f" ]; then
    cp -p "$f" "$f.bak.$(date +%Y%m%d%H%M%S)"
    info "已备份 $f"
  fi
  return 0
}

validate() {
  [ -s "$OUT_CERT" ] || die "缺少 $OUT_CERT"
  [ -s "$OUT_KEY" ] || die "缺少 $OUT_KEY"

  openssl x509 -in "$OUT_CERT" -noout >/dev/null 2>&1 || die "证书无法解析: $OUT_CERT"
  openssl pkey -in "$OUT_KEY" -noout >/dev/null 2>&1 || die "私钥无法解析（是否带密码？）: $OUT_KEY"
  openssl x509 -in "$OUT_CERT" -noout -checkend 0 >/dev/null 2>&1 || die "证书已过期"

  local c k
  c=$(openssl x509 -in "$OUT_CERT" -noout -pubkey | openssl pkey -pubin -outform DER | openssl dgst -sha256)
  k=$(openssl pkey -in "$OUT_KEY" -pubout -outform DER | openssl dgst -sha256)
  [ "$c" = "$k" ] || die "证书与私钥不匹配"

  local names
  names=$(openssl x509 -in "$OUT_CERT" -noout -text \
    | awk '/Subject Alternative Name/{getline; print; exit}' \
    | tr ',' '\n' | sed -n 's/.*DNS:\([^ ,]*\).*/\1/p' | paste -sd ' ' -)
  [ -n "$names" ] || die "证书没有 DNS SAN；现代客户端会拒绝，请重新签发带 SAN 的证书"

  chmod 600 "$OUT_KEY"
  chmod 644 "$OUT_CERT"
  info "校验通过"
  info "证书域名(SAN): $names"
  openssl x509 -in "$OUT_CERT" -noout -subject -dates | sed 's/^/  /'
  echo
  info "已写入：$OUT_CERT"
  info "        $OUT_KEY"
  echo
  echo "下一步："
  echo "  1) 设置 PUBLIC_HOST=<你的域名>（订阅地址用它）"
  echo "  2) TLS_SNI 默认会从证书 SAN 自动取；需要覆盖时再显式设置"
  echo "  3) 重启容器；或先 DRY_RUN=1 bash start.sh 检查配置"
}

check_only() {
  [ -s "$OUT_CERT" ] && [ -s "$OUT_KEY" ] || die "$CERT_DIR 下没有成对的 fullchain.pem / privkey.pem"
  validate
}

import_pem() {
  local cert="$1" key="$2" chain="${3:-}"
  [ -s "$cert" ] || die "证书不存在: $cert"
  [ -s "$key" ] || die "私钥不存在: $key"
  [ -z "$chain" ] || [ -s "$chain" ] || die "中间证书不存在: $chain"

  mkdir -p "$CERT_DIR"
  backup "$OUT_CERT"
  backup "$OUT_KEY"

  cp "$cert" "$OUT_CERT"
  if [ -n "$chain" ]; then
    cat "$chain" >> "$OUT_CERT"
    info "已拼接证书链: $(basename "$cert") + $(basename "$chain")"
  else
    info "只提供了单张证书；如果客户端报链不完整，请补 chain.pem"
  fi
  cp "$key" "$OUT_KEY"
  validate
}

import_pfx() {
  local pfx="$1"
  [ -s "$pfx" ] || die "pfx 不存在: $pfx"
  mkdir -p "$CERT_DIR"

  local tmp
  tmp=$(mktemp -d)
  trap "rm -rf '$tmp'" EXIT

  local passin=()
  if [ -n "${PFX_PASSWORD:-}" ]; then
    passin=(-passin "env:PFX_PASSWORD")
  fi

  openssl pkcs12 -in "$pfx" -clcerts -nokeys "${passin[@]}" -out "$tmp/leaf.pem" 2>/dev/null \
    || die "从 pfx 提取证书失败（密码错误？）"
  openssl pkcs12 -in "$pfx" -nocerts -nodes "${passin[@]}" -out "$tmp/key.pem" 2>/dev/null \
    || die "从 pfx 提取私钥失败"
  openssl pkcs12 -in "$pfx" -cacerts -nokeys "${passin[@]}" -out "$tmp/chain.pem" 2>/dev/null || true

  backup "$OUT_CERT"
  backup "$OUT_KEY"
  cp "$tmp/leaf.pem" "$OUT_CERT"
  if [ -s "$tmp/chain.pem" ] && grep -q "BEGIN CERTIFICATE" "$tmp/chain.pem"; then
    cat "$tmp/chain.pem" >> "$OUT_CERT"
  fi
  cp "$tmp/key.pem" "$OUT_KEY"
  rm -rf "$tmp"
  trap - EXIT
  validate
}

case "${1:-}" in
  ""|-h|--help)
    sed -n '2,20p' "$0"
    ;;
  --check)
    check_only
    ;;
  --pfx)
    [ -n "${2:-}" ] || die "用法: $0 --pfx cert.pfx"
    import_pfx "$2"
    ;;
  *)
    import_pem "${1:-}" "${2:-}" "${3:-}"
    ;;
esac
