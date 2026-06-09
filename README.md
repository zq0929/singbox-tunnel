# Singbox Node.js

在 KataBump / Pterodactyl 等 Node.js 容器中一键部署 sing-box 代理，支持直连和 Cloudflare Tunnel 两种模式。

## 特性

- 🚀 **一键部署** —— 自动下载 sing-box、生成配置、启动运行
- 🔄 **每日自动重启** —— 北京时间 00:03 自动重启，保持连接稳定
- 🛡️ **进程伪装** —— 进程名显示为 `[kworker/0:0]`，与内核线程无异
- 🔌 **双模式**：
  - **直连模式** —— 传统端口监听（TUIC / Hysteria2 / VLESS+WS / Reality）
  - **隧道模式** —— 通过 Cloudflare Tunnel 零入站端口运行，厂商扫不到任何端口
- 🪪 **固定 UUID** —— 首次运行自动生成并保存，重启不变

## 支持协议

| 协议 | 直连模式 | 隧道模式 | 说明 |
|------|---------|---------|------|
| **VLESS+WebSocket** | ✅ | ✅ | 走 Cloudflare CDN，伪装域名 + 自定义路径 |
| **VLESS+REALITY** | ✅ | ❌ | TLS 伪装，抗 DPI 检测 |
| **TUIC v5** | ✅ | ❌ | QUIC 协议，低延迟 |
| **Hysteria2** | ✅ | ❌ | QUIC 协议，抗丢包 |

## 使用方式

### 直连模式（传统端口监听）

```bash
TUIC_PORT=10001 HY2_PORT=10002 VLESS_WS_PORT=10003 REALITY_PORT=10004 bash start.sh
```

### 隧道模式（推荐，零入站端口）

```bash
CF_TUNNEL_TOKEN=eyJ...你的Token bash start.sh
```

### 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `TUIC_PORT` | `""` | TUIC 监听端口（直连模式） |
| `HY2_PORT` | `""` | Hysteria2 监听端口（直连模式） |
| `VLESS_WS_PORT` | `""` | VLESS+WS 监听端口（直连模式） |
| `REALITY_PORT` | `""` | Reality 监听端口（直连模式） |
| `CF_TUNNEL_TOKEN` | `""` | Cloudflare Tunnel Token（设置后启用隧道模式） |
| `TUNNEL_WSPORT` | `56789` | 隧道模式下 sing-box 内网监听端口 |
| `TUNNEL_DOMAIN` | `fr.tuge.ccwu.cc` | 隧道域名，用于订阅链接生成 |

## Cloudflare Tunnel 配置

### 1. 创建隧道

打开 [Cloudflare Zero Trust](https://one.dash.cloudflare.com/) → **Networks** → **Tunnels** → **Create a tunnel**，选择 `cloudflared`，命名后复制 Token。

### 2. 运行

```bash
CF_TUNNEL_TOKEN=eyJ...你的Token bash start.sh
```

### 3. 配置域名指向

隧道创建后，在 Tunnel 配置页面添加 **Public Hostname**：

| 字段 | 值 |
|------|-----|
| Subdomain | `fr` |
| Domain | `你的域名.com` |
| Type | `HTTP` |
| URL | `localhost:56789` |

> `56789` 是 `TUNNEL_WSPORT` 默认值，可自定义。

### 4. 订阅链接

启动后会自动打印，格式：

```
vless://UUID@你的域名:443?encryption=none&security=tls&sni=你的域名&type=ws&path=%2Fspeedtest.net&host=你的域名#VLESS-WS-Tunnel
```

## 部署到 KataBump

1. 在 KataBump 创建 **Node.js** 服务器
2. 将本仓库文件上传或 Git 导入
3. **Startup 设置**中不需要配置端口（隧道模式无需入站端口）
4. **Startup 命令**保持默认 `node index.js`
5. **环境变量**添加 `CF_TUNNEL_TOKEN` 为你的 Tunnel Token
6. 启动

## 目录结构

```
├── start.sh       # 主启动脚本
├── index.js       # Node.js 入口
├── package.json   # 依赖配置
├── .npm/          # 运行数据目录（自动生成）
│   ├── config.json        # sing-box 配置
│   ├── uuid.txt           # 固定 UUID
│   ├── key.txt            # Reality 密钥对
│   ├── cert.pem           # 自签证书
│   ├── private.key        # 证书私钥
│   ├── list.txt           # 订阅链接列表
│   └── sub.txt            # Base64 编码订阅
└── singbox_data/   # 运行时数据
```

## 安全说明

- **进程名已伪装** —— `ps aux` 显示为 `[kworker/0:0]`，非 `sing-box` 或 `cloudflared`
- **二进制随机名** —— 每次下载文件名随机（6 位字母数字）
- **CF Tunnel 模式** —— 零入站端口，端口扫描结果为 0
- **日志已精简** —— 不打印 Token、不打印连接细节
- **建议配合 `TUNNEL_DOMAIN` 变量** —— 避免在日志/配置中硬编码域名

## 注意事项

- 直连模式下需要平台分配端口
- 隧道模式下不需要端口，但容器需能出站访问 Cloudflare
- `CF_TUNNEL_TOKEN` 请妥善保管，泄露后可在 CF 后台 Revoke
- 免费机器主要风险是**流量超限**而非协议被识别，请合理使用

## License

MIT
