# singbox-tunnel-deploy

在 [zq0929/singbox-tunnel](https://github.com/zq0929/singbox-tunnel) 基础上改的部署包，解决两件事：

1. **可以放外部申请的证书**——把证书丢进 `certs/` 就自动生效，不再每次启动被覆盖。
2. **默认保持进程伪装**（`[kworker/0:0]` / `[kworker/0:1]`），可用环境变量改名字或关掉。

另外顺手修掉了原版的一批问题：下载无校验、配置错误也打印"启动成功"、日志全丢弃、证书每次重签、TUIC 密码写死 `admin`、订阅里 `allowInsecure=1`、无崩溃重启等。

## 目录

```
start.sh              主逻辑
index.js              容器入口（spawn start.sh 并转发信号）
package.json
certs/                放证书的地方（见 certs/README.txt）
  fullchain.pem       你的证书链
  privkey.pem         你的私钥
tools/import-cert.sh  把 PEM / PFX 整理成上面的格式并校验
```

## 快速开始（Pterodactyl / KataBump 这类 Node.js 容器）

1. 把整个目录内容上传到容器（或推到你的 Git 仓库让面板拉取）。
2. 启动类型用 `npm start`（即 `node index.js`）。
3. 想用外部证书：把 `fullchain.pem`、`privkey.pem` 放进 `certs/`（第 2 节）。
4. 设置环境变量，比如：

```
PUBLIC_HOST=fr.example.com
TUIC_PORT=10001
HY2_PORT=10002
VLESS_WS_PORT=443
ENABLE_WS_TLS=1
```

首次启动会自动下载并校验 sing-box（官方 GitHub + SHA-256），生成 UUID、Reality 密钥，打印订阅链接到控制台，同时保存到 `.npm/list.txt` 和 `.npm/sub.txt`。

## 放你的证书（重点）

### 需要什么

| 要求 | 说明 |
|---|---|
| 域名证书 | 公网 CA 不会给纯 IP 签证书；证书 SAN 里必须有你连的域名 |
| 证书链 | 叶子证书 + 中间证书，**叶子在前**；缺中间证书时部分客户端握手失败 |
| 私钥 | 未加密（不能带 passphrase），与证书配对 |
| 权限 | 私钥 600；容器里通常只有你自己能读 |

Let's Encrypt / ZeroSSL 下载的 `fullchain.pem` + `privkey.pem` 正好就是这两个文件。阿里云/腾讯云下载的 nginx 包一般也是 `xxx.pem`（链）+ `xxx.key`。

### 放到哪

放到 `certs/`（和 `start.sh` 同级）：

```
certs/fullchain.pem
certs/privkey.pem
```

也认这些备选名字，**同一目录内必须成对**：

- 证书：`fullchain.pem` / `cert.pem` / `chain.pem`
- 私钥：`privkey.pem` / `key.pem` / `private.key`

搜索顺序：`$CERT_DIR` → `.npm/certs/` → `.npm/`。所以你也可以用 `CERT_DIR=/home/container/certs` 指到别处。

### 已经是 PFX/P12 或文件名乱七八糟

```bash
# PEM 三件套：证书 私钥 [中间证书]
./tools/import-cert.sh server.pem server.key chain.pem

# PFX（会提示输密码；也可以 PFX_PASSWORD=xxx 非交互）
./tools/import-cert.sh --pfx server.pfx

# 只检查 certs/ 里现有的是否合格
./tools/import-cert.sh --check
```

工具会拼好 `certs/fullchain.pem`、拷好 `certs/privkey.pem`、覆盖前备份成 `*.bak.<时间>`，并校验：能否解析、是否过期、证书与私钥是否配对、有没有 DNS SAN。

### 干跑确认

不用真启动就能看配置和订阅长什么样：

```bash
PUBLIC_HOST=fr.example.com TUIC_PORT=10001 HY2_PORT=10002 \
SINGBOX_BIN=/path/to/sing-box DRY_RUN=1 bash start.sh
```

通过时会打印 `使用已有证书: .../fullchain.pem（自签=0）`、`配置校验通过`，订阅里是 `allowInsecure=0`/`insecure=0`。
配置不会启动服务，但会写 `.npm/config.json`。

### 证书更新

覆盖 `certs/fullchain.pem`、`certs/privkey.pem` 后重启容器即可（sing-box 启动时读文件）。
脚本**不会**覆盖你放进来的证书；只有 `CERT_MODE=selfsigned` 才会自签。

### 常见坑

| 现象 | 原因 / 处理 |
|---|---|
| `找到证书但校验失败` | 证书过期、私钥不配对、或文件内容不是 PEM。脚本不会覆盖，修好再重启 |
| `只找到证书或私钥其中之一` | 成对放；不要只传一个 |
| 客户端提示证书链不完整 | 只放了叶子证书，补中间证书再拼成 fullchain |
| 客户端提示域名不匹配 | 连接用的域名不在 SAN 里；重新签发或在客户端改 SNI（不建议关校验） |
| `证书是域名证书，但未设置 PUBLIC_HOST` | 订阅会用公网 IP，SNI 对不上；设 `PUBLIC_HOST=你的域名` |
| Cloudflare Tunnel 模式放了证书没反应 | 正常。隧道模式 TLS 在 Cloudflare 边缘终止，sing-box 只监听 127.0.0.1 的明文 WS，证书用不上 |
| 启动即报 `TUIC_PORT: unbound variable` | 把默认值写成了 `${TUIC_PORT:20008}`。`${VAR:...}` 是子串/算术偏移，不是默认值；要写 `${TUIC_PORT:-20008}` |

## 进程伪装

默认开启：

- sing-box：`[kworker/0:0]`
- cloudflared：`[kworker/0:1]`

自定义 / 关闭：

```bash
SINGBOX_PROC_NAME='[kworker/0:0]'   # 改成别的
TUNNEL_PROC_NAME='[kworker/0:1]'
DISGUISE=0                          # 关掉伪装（排障时建议关）
```

原理是 `exec -a` 改 `argv[0]`，所以 `ps aux` / `ps -o args` 看到的是伪装名。**局限**：Linux 上 `/proc/<pid>/comm` 仍是真实二进制名（`sing-box`、`cloudflared`），`/proc/<pid>/exe` 也指向真实路径。

> 说明：伪装进程名通常是为了躲托管商的滥用检测，这可能违反 KataBump / Pterodactyl / Cloudflare 的服务条款，账号风险自负。要长期稳定，建议用自己的 VPS 或正规机场面板。

## 本地配置 config.env（推荐）

把域名、端口这些写在脚本同级的 `config.env`，`git pull` 更新脚本时不会丢，也不用改 `start.sh`：

```bash
# config.env
PUBLIC_HOST=fr.example.com
TLS_SNI=fr.example.com
TUIC_PORT=20008
TUIC_ZERO_RTT=1
DAILY_RESTART=1
```

```bash
chmod 600 config.env
```

`config.env` 在 `.gitignore` 里，不会被提交。规则：**同一项只在一边设置**（`config.env` 会覆盖面板注入的同名环境变量）。

## 环境变量

### 模式

| 变量 | 默认 | 说明 |
|---|---|---|
| `CF_TUNNEL_TOKEN` | 空 | 设了就进 Cloudflare Tunnel 模式 |
| `TUNNEL_DOMAIN` | 空 | 隧道对外域名（必填） |
| `TUNNEL_WSPORT` | `56789` | sing-box 本地 WS 监听端口，Cloudflare Public Hostname 指到这里 |

### 直连端口（设 0 或不设 = 关闭）

| 变量 | 说明 |
|---|---|
| `TUIC_PORT` | TUIC v5（UDP） |
| `HY2_PORT` | Hysteria2（UDP） |
| `VLESS_WS_PORT` | VLESS + WebSocket（TCP） |
| `REALITY_PORT` | VLESS + Reality（TCP） |
| `ENABLE_WS_TLS` | `1` 给直连 WS 加 TLS（用你的证书）；默认 `0` 明文 |
| `LISTEN_ADDR` | 默认 `0.0.0.0`，要 IPv6 设 `::` |

### 域名与证书

| 变量 | 默认 | 说明 |
|---|---|---|
| `PUBLIC_HOST` | 空 | 订阅里用的地址（域名或 IP）；配了证书就填域名 |
| `TLS_SNI` | 自动 | 默认从证书 SAN/CN 推导；可覆盖 |
| `WS_HOST` | `TLS_SNI` | WS 的 Host 头 |
| `WS_PATH` | `/speedtest.net` | WS 路径 |
| `CERT_MODE` | `auto` | `auto` 有证书就用、没有自签；`custom` 必须提供且校验；`selfsigned` 强制自签 |
| `CERT_DIR` | `./certs` | 证书搜索目录 |
| `CERT_PATH` / `KEY_PATH` | 空 | 显式指定证书/私钥（必须同时设） |
| `ALLOW_INSECURE` | 自动 | 自签证书自动 `1`，CA 证书自动 `0`；可手动覆盖 |

### 其它

| 变量 | 默认 | 说明 |
|---|---|---|
| `SINGBOX_VERSION` | `1.12.12` | 换版本必须同时给 `SINGBOX_SHA256` |
| `SINGBOX_SHA256` | 内置 | 覆盖官方二进制的期望哈希 |
| `SINGBOX_BIN` | 空 | 直接用现成二进制（调试/离线） |
| `CLOUDFLARED_VERSION` | `latest` | cloudflared 版本 |
| `CLOUDFLARED_SHA256` | 空 | 建议设置 |
| `LOG_LEVEL` | `warn` | sing-box 日志级别，排障用 `debug`/`info` |
| `DRY_RUN` | `0` | `1` = 只生成配置/订阅，不启动 |
| `DISGUISE` | `1` | 进程伪装开关 |
| `DAILY_RESTART` | `1` | 北京时间 00:03 重启一次 |
| `TUIC_PASSWORD` | 随机 | 不设则生成并保存到 `.npm/tuic-password.txt` |
| `TUIC_ZERO_RTT` | `0` | `1` = TUIC 启用 QUIC 0-RTT（省重连 RTT，有重放风险；客户端也要开） |

## TUIC 0-RTT

`TUIC_ZERO_RTT=1` 会在 TUIC inbound 里写 `"zero_rtt_handshake": true`。它只解决 QUIC 的握手延迟，**两端都要开才生效**：

- 服务端：`TUIC_ZERO_RTT=1`（本脚本）
- sing-box 客户端：outbound 加 `"zero_rtt_handshake": true`
- mihomo / Clash.Meta：`reduce-rtt: true`

TUIC 订阅链接里没有这个参数，自动订阅不会带，需要在客户端配置里手动打开。

注意：

- 只对**再次连接**有效（靠 TLS session ticket 复用），首次连接仍然 1 RTT。
- QUIC 0-RTT 的 early data 可以被重放，服务端可能重复处理；对安全性敏感的用途建议保持关闭（默认就是 `0`）。
- 服务端开、客户端没开 → 行为等于没开；客户端开、服务端没开 → 自动退回普通握手，不报错。
- `sing-box check` 会拦住拼错的字段名（例如 `zero_rtt_handshak` 会直接报 `unknown field`）。

## 排障

日志都在 `.npm/`：

```
.npm/run.log        启动脚本自己的日志
.npm/sing-box.log   sing-box 输出
.npm/cloudflared.log
.npm/config.json    生成的配置
.npm/list.txt       订阅链接（明文）
.npm/sub.txt        base64 订阅
```

常用：

```bash
DISGUISE=0 LOG_LEVEL=debug bash start.sh     # 前台跑，直接看输出
bash start.sh                                # 配置有问题会直接报错退出
sing-box check -c .npm/config.json           # 手工校验配置
```

## 端口与网络

- TUIC / Hysteria2 走 **UDP**，防火墙和 NAT 都要放行；Cloudflare 橙云代理不支持 UDP，要直连（灰云）。
- VLESS+WS / Reality 走 **TCP**。Reality 不能走 Cloudflare 代理。
- 走 Cloudflare 代理只支持 HTTP/WS 端口（443、2053、2083、2087、2096、8443）。
- Pterodactyl 需要在面板额外分配端口，容器内 `TUIC_PORT` 等要和分配的一致。

## 已实测

- 4 种直连 inbound 组合生成合法 JSON，官方 `sing-box check` 通过。
- 外部证书（自建 CA fullchain + 私钥）自动发现，`server_name` 正确，订阅 `allowInsecure=0`。
- 证书损坏/单文件/不配对 → 报错退出且不覆盖原文件。
- 真实启动后 `ps` 显示 `[kworker/0:0]`，SIGTERM 干净退出、端口无残留。
- 二次启动复用证书与 UUID，不重新生成。
- `TUIC_ZERO_RTT=1` 生成的配置含 `zero_rtt_handshake: true`，官方 `sing-box check` 通过；默认关闭时为 `false`。
