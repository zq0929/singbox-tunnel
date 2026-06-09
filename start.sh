##!/bin/bash
set -e

# ================== 端口设置 ==================
export TUIC_PORT=${TUIC_PORT:-""}
export HY2_PORT=${HY2_PORT:-""}
export REALITY_PORT=${REALITY_PORT:-""}
export VLESS_WS_PORT=${VLESS_WS_PORT:-""}
export CF_TUNNEL_TOKEN=${CF_TUNNEL_TOKEN:-""}
export TUNNEL_WSPORT=${TUNNEL_WSPORT:-"56789"}
export TUNNEL_DOMAIN=${TUNNEL_DOMAIN:-"fr.tuge.ccwu.cc"}

# ================== 强制切换到脚本所在目录 ==================
cd "$(dirname "$0")"

# ================== 环境变量 & 绝对路径 ==================
export FILE_PATH="${PWD}/.npm"
export DATA_PATH="${PWD}/singbox_data"
mkdir -p "$FILE_PATH" "$DATA_PATH"

# ================== UUID 固定保存（核心逻辑）==================
UUID_FILE="${FILE_PATH}/uuid.txt"
if [ -f "$UUID_FILE" ]; then
  UUID=$(cat "$UUID_FILE")
  echo -e "\e[1;33m[UUID] 复用固定 UUID: $UUID\e[0m"
else
  UUID=$(cat /proc/sys/kernel/random/uuid)
  echo "$UUID" > "$UUID_FILE"
  chmod 600 "$UUID_FILE"
  echo -e "\e[1;32m[UUID] 首次生成并永久保存: $UUID\e[0m"
fi

# ================== 创建目录 ==================
[ ! -d "${FILE_PATH}" ] && mkdir -p "${FILE_PATH}"

# ================== 架构检测 & 下载 sing-box ==================
ARCH=$(uname -m)
BASE_URL=""
if [[ "$ARCH" == "arm"* ]] || [[ "$ARCH" == "aarch64" ]]; then
  BASE_URL="https://arm64.ssss.nyc.mn"
elif [[ "$ARCH" == "amd64"* ]] || [[ "$ARCH" == "x86_64" ]]; then
  BASE_URL="https://amd64.ssss.nyc.mn"
elif [[ "$ARCH" == "s390x" ]]; then
  BASE_URL="https://s390x.ssss.nyc.mn"
else
  echo "不支持的架构: $ARCH"
  exit 1
fi

FILE_INFOS=("sb sing-box")
declare -A FILE_MAP

download_file() {
  local URL=$1
  local FILENAME=$2
  if command -v curl >/dev/null 2>&1; then
    curl -L -sS -o "$FILENAME" "$URL" && echo -e "\e[1;32m下载 $FILENAME (curl)\e[0m"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$FILENAME" "$URL" && echo -e "\e[1;32m下载 $FILENAME (wget)\e[0m"
  else
    echo -e "\e[1;31m未找到 curl 或 wget\e[0m"
    exit 1
  fi
}

for entry in "${FILE_INFOS[@]}"; do
  URL=$(echo "$entry" | cut -d ' ' -f1)
  NAME=$(echo "$entry" | cut -d ' ' -f2)
  NEW_NAME="${FILE_PATH}/$(head /dev/urandom | tr -dc a-z0-9 | head -c6)"
  download_file "${BASE_URL}/${URL}" "$NEW_NAME"
  chmod +x "$NEW_NAME"
  FILE_MAP[$NAME]="$NEW_NAME"
done

# ================== 下载 cloudflared（隧道模式）==================
CF_TUNNEL_NAME=""
CLOUDFLARED_URL=""
if [ "$CF_TUNNEL_TOKEN" != "" ]; then
  if [[ "$ARCH" == "arm"* ]] || [[ "$ARCH" == "aarch64" ]]; then
    CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
  elif [[ "$ARCH" == "amd64"* ]] || [[ "$ARCH" == "x86_64" ]]; then
    CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
  else
    echo -e "\e[1;31m[Cloudflared] 不支持的架构: $ARCH\e[0m"
    exit 1
  fi
  CF_TUNNEL_NAME="${FILE_PATH}/$(head /dev/urandom | tr -dc a-z0-9 | head -c6)"
  download_file "$CLOUDFLARED_URL" "$CF_TUNNEL_NAME"
  chmod +x "$CF_TUNNEL_NAME"
  echo -e "\e[1;32m[Cloudflared] 下载完成\e[0m"
fi

# ================== 固定 Reality 密钥 ==================
KEY_FILE="${FILE_PATH}/key.txt"
if [ -f "$KEY_FILE" ]; then
  echo -e "\e[1;33m[密钥] 检测到已有密钥，复用...\e[0m"
  private_key=$(grep "PrivateKey:" "$KEY_FILE" | awk '{print $2}')
  public_key=$(grep "PublicKey:" "$KEY_FILE" | awk '{print $2}')
else
  echo -e "\e[1;33m[密钥] 首次生成 Reality 密钥对...\e[0m"
  output=$("${FILE_MAP[sing-box]}" generate reality-keypair)
  echo "$output" > "$KEY_FILE"
  private_key=$(echo "$output" | awk '/PrivateKey:/ {print $2}')
  public_key=$(echo "$output" | awk '/PublicKey:/ {print $2}')
  chmod 600 "$KEY_FILE"
  echo -e "\e[1;32m[密钥] 密钥已保存，重启后保持不变\e[0m"
fi

# ================== 生成证书（自签或固定）==================
if ! command -v openssl >/dev/null 2>&1; then
  cat > "${FILE_PATH}/private.key" <<'EOF'
-----BEGIN EC PARAMETERS-----
BgqghkjOPQQBw==
-----END EC PARAMETERS-----
-----BEGIN EC PRIVATE KEY-----
MHcCAQEEIM4792SEtPqIt1ywqTd/0bYidBqpYV/+siNnfBYsdUYsAoGCCqGSM49
AwEHoUQDQgAE1kHafPj07rJG+HboH2ekAI4r+e6TL38GWASAnngZreoQDF16ARa
/TsyLyFoPkhTxSbehH/OBEjHtSZGaDhMqQ==
-----END EC PRIVATE KEY-----
EOF
  cat > "${FILE_PATH}/cert.pem" <<'EOF'
-----BEGIN CERTIFICATE-----
MIIBejCCASGgAwIBAgIUFWeQL3556PNJLp/veCFxGNj9crkwCgYIKoZIzj0EAwIw
EzERMA8GA1UEAwwIYmluZy5jb20wHhcNMjUwMTAxMDEwMTAwWhcNMzUwMTAxMDEw
MTAwWjATMREwDwYDVQQDDAhiaW5nLmNvbTBNBgqgGzM9AgEGCCqGSM49AwEHA0IA
BNZB2nz49O6yRvh26B9npACOK/nuky9/BlgEgDZ54Ga3qEAxdeWv07Mi8h
d5IR8Um3oR/zQRIx7UmRmg4TKmjUzBRMB0GA1UdDgQWBQTV1cFID7UISE7PLTBR
BfGbgrkMNzAfBgNVHSMEGDAWgBTV1cFID7UISE7PLTBRBfGbgrkMNzAPBgNVHRMB
Af8EBTADAQH/MAoGCCqGSM49BAMCA0cAMEQCIARDAJvg0vd/ytrQVvEcSm6XTlB+
eQ6OFb9LbLYL9Zi+AiffoMbi4y/0YUQlTtz7as9S8/lciBF5VCUoVIKS+vX2g==
-----END CERTIFICATE-----
EOF
else
  openssl ecparam -genkey -name prime256v1 -out "${FILE_PATH}/private.key" 2>/dev/null
  openssl req -new -x509 -days 3650 -key "${FILE_PATH}/private.key" -out "${FILE_PATH}/cert.pem" -subj "/CN=bing.com" 2>/dev/null
fi
chmod 600 "${FILE_PATH}/private.key"

# ================== 生成 config.json（隧道模式 / 直连模式）==================
if [ "$CF_TUNNEL_TOKEN" != "" ]; then
  # 🚇 隧道模式：sing-box 只监听内网，通过 Cloudflare Tunnel 进入
  cat > "${FILE_PATH}/config.json" <<EOF
{
  "log": { "disabled": true },
  "inbounds": [{
    "type": "vless",
    "listen": "127.0.0.1",
    "listen_port": $TUNNEL_WSPORT,
    "users": [{"uuid": "$UUID"}],
    "transport": {
      "type": "ws",
      "path": "/speedtest.net",
      "headers": {
        "Host": "${TUNNEL_DOMAIN}"
      }
    }
  }],
  "outbounds": [{"type": "direct"}]
}
EOF
  echo -e "\e[1;32m[tunnel] 使用隧道模式，sing-box 仅监听 127.0.0.1:$TUNNEL_WSPORT\e[0m"
else
  # 🏠 直连模式：原有逻辑不变
  cat > "${FILE_PATH}/config.json" <<EOF
{
  "log": { "disabled": true },
  "inbounds": [$( \
    [ "$TUIC_PORT" != "" ] && [ "$TUIC_PORT" != "0" ] && echo "{
      \"type\": \"tuic\",
      \"listen\": \"::\",
      \"listen_port\": $TUIC_PORT,
      \"users\": [{\"uuid\": \"$UUID\", \"password\": \"admin\"}],
      \"congestion_control\": \"bbr\",
      \"tls\": {\"enabled\": true, \"alpn\": [\"h3\"], \"certificate_path\": \"${FILE_PATH}/cert.pem\", \"key_path\": \"${FILE_PATH}/private.key\"}
    },"; \
    [ "$HY2_PORT" != "" ] && [ "$HY2_PORT" != "0" ] && echo "{
      \"type\": \"hysteria2\",
      \"listen\": \"::\",
      \"listen_port\": $HY2_PORT,
      \"users\": [{\"password\": \"$UUID\"}],
      \"masquerade\": \"https://bing.com\",
      \"tls\": {\"enabled\": true, \"alpn\": [\"h3\"], \"certificate_path\": \"${FILE_PATH}/cert.pem\", \"key_path\": \"${FILE_PATH}/private.key\"}
    },"; \
    [ "$VLESS_WS_PORT" != "" ] && [ "$VLESS_WS_PORT" != "0" ] && echo "{
      \"type\": \"vless\",
      \"listen\": \"::\",
      \"listen_port\": $VLESS_WS_PORT,
      \"users\": [{\"uuid\": \"$UUID\"}],
      \"transport\": {
        \"type\": \"ws\",
        \"path\": \"/speedtest.net\",
        \"headers\": {
          \"Host\": \"${TUNNEL_DOMAIN}\"
        }
      }
    },"; \
    [ "$REALITY_PORT" != "" ] && [ "$REALITY_PORT" != "0" ] && echo "{
      \"type\": \"vless\",
      \"listen\": \"::\",
      \"listen_port\": $REALITY_PORT,
      \"users\": [{\"uuid\": \"$UUID\", \"flow\": \"xtls-rprx-vision\"}],
      \"tls\": {
        \"enabled\": true,
        \"server_name\": \"www.nazhumi.com\",
        \"reality\": {
          \"enabled\": true,
          \"handshake\": {\"server\": \"www.nazhumi.com\", \"server_port\": 443},
          \"private_key\": \"$private_key\",
          \"short_id\": [\"\"]
        }
      }
    }"; \
  )],
  "outbounds": [{"type": "direct"}]
}
EOF
  # 修复 JSON（直连模式数组可能有多余逗号）
  python3 -c "
import json, sys
with open('${FILE_PATH}/config.json') as f:
    d = json.load(f)
with open('${FILE_PATH}/config.json', 'w') as f:
    json.dump(d, f, indent=2)
" 2>/dev/null || true
fi

# ================== 启动 sing-box（进程名已伪装）==================
if [ "$CF_TUNNEL_TOKEN" != "" ]; then
  # 隧道模式：不绑定平台端口，sing-box 只走内网
  (exec -a "[kworker/0:0]" "${FILE_MAP[sing-box]}" run -c "${FILE_PATH}/config.json") 2>/dev/null &
  SINGBOX_PID=$!
  echo "[SING-BOX] 启动完成 PID=$SINGBOX_PID (内网模式)"

  # 启动 Cloudflare Tunnel（抑制冗长日志，进程名伪装）
  (export TUNNEL_LOGLEVEL=warn; exec -a "[kworker/0:1]" "${CF_TUNNEL_NAME}" tunnel --no-autoupdate run --token "${CF_TUNNEL_TOKEN}") 2>/dev/null &
  TUNNEL_PID=$!
  echo "[TUNNEL] Cloudflare Tunnel 启动完成 PID=$TUNNEL_PID"
  echo -e "\e[1;32m✅ 隧道已连接，请确保 Cloudflare Zero Trust 中配置:\e[0m"
  echo -e "   Service → HTTP   URL → \e[1;33mlocalhost:$TUNNEL_WSPORT\e[0m"
  echo -e "   域名 → \e[1;33m${TUNNEL_DOMAIN}\e[0m"
else
  (exec -a "[kworker/0:0]" "${FILE_MAP[sing-box]}" run -c "${FILE_PATH}/config.json") 2>/dev/null &
  SINGBOX_PID=$!
  echo "[SING-BOX] 启动完成 PID=$SINGBOX_PID"
fi

# ================== 获取 IP & ISP ==================
IP=$(curl -s --max-time 2 ipv4.ip.sb || curl -s --max-time 1 api.ipify.org || echo "IP_ERROR")
ISP=$(curl -s --max-time 2 https://speed.cloudflare.com/meta | awk -F'"' '{print $26"-"$18}' || echo "0.0")

# ================== 生成订阅 ==================
> "${FILE_PATH}/list.txt"

if [ "$CF_TUNNEL_TOKEN" != "" ]; then
  # 🚇 隧道模式：走 Cloudflare 域名，无需端口
  echo "vless://${UUID}@${TUNNEL_DOMAIN}:443?encryption=none&security=tls&sni=${TUNNEL_DOMAIN}&type=ws&path=%2Fspeedtest.net&host=${TUNNEL_DOMAIN}#VLESS-WS-Tunnel" >> "${FILE_PATH}/list.txt"
else
  # 🏠 直连模式：用 IP 端口
  [ "$TUIC_PORT" != "" ] && [ "$TUIC_PORT" != "0" ] && echo "tuic://${UUID}:admin@${IP}:${TUIC_PORT}?sni=www.bing.com&alpn=h3&congestion_control=bbr&allowInsecure=1#TUIC-${ISP}" >> "${FILE_PATH}/list.txt"
  [ "$HY2_PORT" != "" ] && [ "$HY2_PORT" != "0" ] && echo "hysteria2://${UUID}@${IP}:${HY2_PORT}/?sni=www.bing.com&insecure=1#Hysteria2-${ISP}" >> "${FILE_PATH}/list.txt"
  [ "$VLESS_WS_PORT" != "" ] && [ "$VLESS_WS_PORT" != "0" ] && echo "vless://${UUID}@${IP}:${VLESS_WS_PORT}?encryption=none&type=ws&path=%2Fspeedtest.net&host=${TUNNEL_DOMAIN}#VLESS-WS-${ISP}" >> "${FILE_PATH}/list.txt"
  [ "$REALITY_PORT" != "" ] && [ "$REALITY_PORT" != "0" ] && echo "vless://${UUID}@${IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.nazhumi.com&fp=firefox&pbk=${public_key}&type=tcp#Reality-${ISP}" >> "${FILE_PATH}/list.txt"
fi

base64 "${FILE_PATH}/list.txt" | tr -d '\n' > "${FILE_PATH}/sub.txt"
cat "${FILE_PATH}/list.txt"
echo -e "\n\e[1;32m${FILE_PATH}/sub.txt 已保存\e[0m"

# ================== 启动定时重启（前台阻塞） ==================
schedule_restart() {
  echo "[定时重启:Sing-box] 已启动（北京时间 00:03）"
  LAST_RESTART_DAY=-1

  while true; do
    now_ts=$(date +%s)
    beijing_ts=$((now_ts + 28800))
    H=$(( (beijing_ts / 3600) % 24 ))
    M=$(( (beijing_ts / 60) % 60 ))
    D=$(( beijing_ts / 86400 ))

    # ---- 时间匹配 → 重启 ----
    if [ "$H" -eq 00 ] && [ "$M" -eq 03 ] && [ "$D" -ne "$LAST_RESTART_DAY" ]; then
      echo "[定时重启] 到达 00:03 → 重启服务"
      LAST_RESTART_DAY=$D

      kill "$SINGBOX_PID" 2>/dev/null || true
      sleep 2
      (exec -a "[kworker/0:0]" "${FILE_MAP[sing-box]}" run -c "${FILE_PATH}/config.json") 2>/dev/null &
      SINGBOX_PID=$!
      echo "[Sing-box] 重启完成 PID: $SINGBOX_PID"

      if [ "$CF_TUNNEL_TOKEN" != "" ] && [ "$TUNNEL_PID" != "" ]; then
        kill "$TUNNEL_PID" 2>/dev/null || true
        sleep 2
        (export TUNNEL_LOGLEVEL=warn; exec -a "[kworker/0:1]" "${CF_TUNNEL_NAME}" tunnel --no-autoupdate run --token "${CF_TUNNEL_TOKEN}") 2>/dev/null &
        TUNNEL_PID=$!
        echo "[Tunnel] 重启完成 PID: $TUNNEL_PID"
      fi
    fi

    sleep 1
  done
}

# ★★★ 关键：保持脚本前台运行，不能退出
schedule_restart
