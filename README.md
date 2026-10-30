# Debian XHTTP + Reality/CDN 四节点部署包

这个工程包面向 Debian 12/13 的 IPv4 VPS。脚本只安装和配置官方 Xray-core、Debian Nginx 和官方 acme.sh，不包含 xpadding、ECH、Hysteria2、Mihomo 或其他扩展功能。

参考的协议拓扑来自 [my-xhttp-cdn-config](https://github.com/Yulinanami/my-xhttp-cdn-config)，脚本实现已经重新整理，只保留本项目需要的四个节点。

## 节点布局

| VPS 端口 | 上行 | 下行 |
| ---: | --- | --- |
| 2053 | XHTTP + Reality，直连 VPS | XHTTP + Reality，直连 VPS |
| 2083 | XHTTP + Reality，直连 VPS | XHTTP + TLS + Cloudflare CDN |
| 2087 | XHTTP + Reality，直连 VPS | XHTTP + TLS + Cloudflare CDN |
| 2096 | XHTTP + Reality，直连 VPS | XHTTP + TLS + Cloudflare CDN |

四个端口都是 VPS 侧需要放行的 **TCP 入站端口**。VPS 访问外网时由 Xray 使用系统分配的出站端口，脚本不会限制这些端口。

Cloudflare 支持 2053、2083、2087、2096 这些 HTTPS 端口。脚本只让 Xray 监听公网端口，Nginx 的 TLS 回落端口只监听 `127.0.0.1`，不会额外要求你开放内部端口。

## 执行方式

提交工程后，在本地运行发布构建脚本。它会拒绝 dirty worktree，在干净提交上生成固定 Xray/acme.sh 版本的发布包：

```bash
bash scripts/build-release.sh
```

若要重建历史版本，可将清单中的版本和安装器提交作为输入传给构建脚本：

```bash
XHTTP_BUILD_XRAY_VERSION=v26.10.21 \
XHTTP_BUILD_ACME_VERSION=3.1.6 \
XHTTP_BUILD_XRAY_INSTALL_REF=e42df6a772e60dd7b058f852262c4dbeb0bc231d \
bash scripts/build-release.sh
```

将生成的 `dist/xhttp-cdn-deploy/` 文件夹内容上传到自己的 GitHub 仓库根目录，然后可以下载并执行：

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/REPOSITORY/main/deploy.sh -o /tmp/xhttp-cdn-deploy.sh
sudo bash /tmp/xhttp-cdn-deploy.sh
```

也可以直接使用管道执行。脚本会从 `/dev/tty` 读取交互输入：

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/REPOSITORY/main/deploy.sh | sudo bash
```

脚本只接受 Debian 12、Debian 13 和 root 权限。发布包固定 Xray-core、Xray 官方安装器提交和 acme.sh 版本；Nginx 与系统依赖使用 Debian 官方软件源最新可用版本。实际安装的组件版本和源 Git SHA 可在发布清单及 `/etc/xhttp-cdn-deploy/config.env` 中核对。脚本不会自动修改 `ufw`、nftables 或云厂商安全组，请在脚本结束后确认以下 TCP 端口已经放行：

```text
2053 2083 2087 2096
```

## 运行前需要准备的输入

脚本不会随机生成身份参数。请提前准备：

1. 四个不同的 UUID。
2. 一套 Reality 私钥。
3. 一个 Reality Short ID。
4. 一个 Reality 伪装/SNI 域名。
5. 一个自己的 Cloudflare 橙云域名。
6. 一个 Cloudflare API Token，或者已经签发好的 CDN 域名证书和私钥。

UUID 可以在 Windows PowerShell 中运行下面命令四次，每次复制一条不同结果：

```powershell
[guid]::NewGuid().ToString()
```

Reality 私钥可以在 Windows 上用同版本官方 Xray 运行 `xray.exe x25519` 后复制 `PrivateKey`，脚本会根据私钥计算公钥，不会要求你另外输入公钥。新版本 Xray 的输出通常同时显示 `PrivateKey` 和 `Password (PublicKey)`，这里只输入 `PrivateKey` 那一行的值。

Short ID 必须是 2 到 16 位十六进制字符，并且长度为偶数。脚本提示的推荐默认值是：

```text
a1234567
```

这个默认值是 8 位十六进制字符串，符合规则；其中包含数字 `4`，而 Short ID 允许使用该数字。你可以直接回车接受，也可以输入自己的值。Short ID 不要使用 `0` 到 `f` 以外的字符。

XHTTP 路径默认是 `/xhttp`。它不是密码，脚本不会随机改变它；如果你要改，必须以 `/` 开头，且不能包含空格、`?` 或 `#`。

脚本不会询问 SSH 密码、订阅密码或 VLESS Encryption 密钥。本版本不启用 VLESS Encryption，因此不需要额外的 `decryption`/`encryption` 字符串。

## Cloudflare 设置

### 1. 添加 CDN DNS 记录

在 Cloudflare 中打开目标域名所在的 Zone，添加两条 A 记录：

```text
类型：A
名称：cdn
内容：VPS 公网 IPv4
代理状态：已代理（橙色云）

类型：A
名称：reality
内容：同一个 VPS 公网 IPv4
代理状态：仅 DNS（灰色云）
```

把实际记录名输入脚本，例如 `cdn.example.com` 和 `reality.example.com`。脚本只使用一个 CDN 域名，2083、2087、2096 三个节点共用它。两个子域名应属于同一个 Cloudflare Zone，因为 DNS-01 Token 只配置这个 Zone。不要给这两个域名添加指向其他源站的 AAAA 记录；本包按 IPv4 VPS 设计。

### 2. 设置 TLS 模式和 gRPC

在 Cloudflare 中设置：

```text
SSL/TLS -> Overview -> Encryption mode: Full (strict)
Network -> gRPC: On
```

`Full (strict)` 要求 Cloudflare 到 VPS 的源站证书有效，并且证书覆盖 CDN 域名。脚本申请的证书还会覆盖灰云 Reality 域名，以便本机 Nginx 正确处理 Reality 回落。脚本默认使用 DNS-01 申请公开可信证书，因此不需要开放 80 端口。

### 3. 创建最小权限 API Token

在 Cloudflare 右上角头像 -> **My Profile** -> **API Tokens** -> **Create Token**，创建 Custom token：

权限选择：

```text
Zone - DNS - Edit
Zone - Zone - Read
```

Zone Resources 只选择同时包含两个子域名的那一个 Zone。不要使用 Global API Key，也不要把 Token 写进 GitHub 仓库。

部署时脚本会隐藏输入 Token。acme.sh 会把它保存在 VPS 的 root 配置中供自动续期使用，脚本不会把 Token 打印到终端、客户端文件或 Git 文件中。

### 4. 配置缓存绕过

Cloudflare 默认不会缓存 POST，但 XHTTP 路径建议明确加入 Cache Rule。规则表达式可以使用：

```text
(http.host eq "cdn.example.com" and http.request.uri.path contains "/xhttp")
```

动作选择 Skip cache。把示例域名换成你的 CDN 域名，把路径换成脚本最终使用的 XHTTP 路径。

## TLS 证书

### 推荐：acme.sh DNS-01

脚本默认在没有可复用证书时使用官方 acme.sh 和 Cloudflare DNS-01：

1. 脚本隐藏询问 Cloudflare API Token。
2. acme.sh 创建 `_acme-challenge` TXT 记录。
3. Let's Encrypt 验证并签发同时覆盖灰云 Reality 域名和橙云 CDN 域名的证书。
4. 证书安装到 `/etc/xhttp-cdn-deploy/tls/`。
5. acme.sh 自动续期，续期后执行 `systemctl reload nginx`。

Windows 客户端只验证 CDN 域名和 Cloudflare 边缘证书。证书续期不会改变域名、端口、UUID、Reality 公钥或 XHTTP 路径，所以客户端配置不需要修改。

### 复用已有证书

如果你已经有证书，脚本可以询问证书 PEM 文件和私钥 PEM 文件的绝对路径。脚本会检查：

- 证书未过期。
- 证书 SAN 同时覆盖灰云 Reality 域名和橙云 CDN 域名。
- 证书公钥和私钥匹配。

也可以在 Cloudflare 中申请 **Origin CA** 证书后输入文件路径。Origin CA 证书只需要被 Cloudflare 信任，适合 `Full (strict)` 回源；Windows 客户端不会直接连接这个源站证书。不要把 Origin CA 私钥上传到 GitHub。

通过文件路径导入的证书由你自行续期。续期后重新运行脚本，在询问是否替换当前源站证书时回答 `y`，再提供更新后的证书和私钥绝对路径；acme.sh DNS-01 模式才会自动续期并重载 Nginx。

## Reality 伪装域名怎么选

本工程选择的是“Reality 请求失败时回落到 VPS 本机 Nginx TLS 站点”的拓扑，所以建议 Reality SNI 使用你自己的灰云子域名。灰云域名和橙云 CDN 域名都由你控制，脚本会申请同时覆盖两者的源站证书。

这里有两个不同概念：

- **CDN 域名**：必须是你自己的域名，DNS 指向 VPS，并开启 Cloudflare 橙云。它用于 2083、2087、2096 的下行 TLS/CDN。
- **Reality 伪装/SNI 域名**：灰云 DNS 记录直接指向 VPS，作为 Reality TLS 握手里的 `serverName`，不经过 CDN。

Reality 为什么有些教程使用 Apple、Firefox 等公共站点？

Reality 可以把认证失败的 TLS 连接转发给外部真实站点作为 target，因此一些不同的部署会把公共站点的主机名作为 `serverName` 和转发目标。那些域名属于 Apple、Mozilla 等网站，不是用户自己的 DNS 记录，也不能把它们添加到自己的 Zone。

本工程的回落目标是 VPS 本机 Nginx，用于同时接收 Reality 回落和 Cloudflare 的标准 TLS 回源；Nginx 证书必须匹配 Reality SNI，所以本脚本要求使用你控制的灰云域名，并把它和 CDN 域名一起放入证书 SAN。不要在本脚本中输入 `www.apple.com`、`www.mozilla.org` 等第三方域名：你无法为它们签发源站证书。

Reality 域名的 DNS 必须是灰云直连，否则 2053 的直连流量也会被 Cloudflare 接管。Reality 域名和 CDN 域名必须不同。TLS DNS-01 验证不要求开放 VPS 的 80 端口。

## 客户端文件

部署完成后，四条 v2rayN VLESS 链接保存在：

```text
/root/xhttp-cdn-deploy/client-v2rayn.txt
```

在 Windows v2rayN 中选择导入剪贴板或从文件导入即可。2053 节点的上传和下载都直接连接 VPS；另外三个节点的上传连接 VPS IP，下载地址使用 Cloudflare CDN 域名和对应端口。

部署结束时脚本也会把四条完整链接输出到终端，方便直接复制。链接中的 UUID 是访问凭据；终端录屏、远程会话记录、日志采集或复制历史可能留存这些链接，不要把输出贴到公开渠道。客户端文件只允许 root 读取。

## XHTTP 连接复用与隐私

四条客户端链接会在 XHTTP `extra` 中明确设置 XMUX，避免连接行为依赖客户端 Xray-core 对未设置值的默认处理：

```json
{
  "maxConcurrency": "16-32",
  "maxConnections": 0,
  "cMaxReuseTimes": 0,
  "hMaxRequestTimes": "600-900",
  "hMaxReusableSecs": "1800-3000",
  "hKeepAlivePeriod": 0
}
```

这些范围来自 [Xray XHTTP 说明](https://github.com/XTLS/Xray-core/discussions/4113)。其中 `maxConcurrency` 达到范围内选定的并发上限后，客户端会创建新的 XMUX client；请求数和可复用时间也有上限。2083、2087、2096 的上行 Reality 和下行 TLS/CDN 都配置同一组值。XMUX 是客户端连接池设置，不会改变服务端协议或端口布局。

Xray `v26.10.29` 的 [XMUX 单元测试](https://github.com/XTLS/Xray-core/blob/v26.10.29/transport/internet/splithttp/mux_test.go)直接用空 `XmuxConfig` 测试连接池，结果是 64 个并发请求共用一个 XMUX client；这不是完整 XHTTP 配置的默认值。官方 XHTTP 配置构建器在整个 `xmux` 块缺省时会补入 `maxConnections=3`、`hMaxRequestTimes=600-900` 和 `hMaxReusableSecs=1800-3000`。本包显式写入完整参数，避免客户端行为依赖这类默认处理差异。显式配置不代表能够规避封禁。`fp=chrome` 只模拟 TLS ClientHello，不等于 Chrome 浏览器的完整 TLS/HTTP/2 行为；目前没有可靠证据能把这类连接特征与特定封禁事件建立因果关系。

另需留意：官方 Xray `v26.10.29` 检查配置时会提示 Reality 监听非 443 端口会增加 IP 被封锁的可能性。本工程的四个指定端口都不是 443，因此这个提示适用于所有节点；XMUX 参数不能消除该风险。

三个 CDN 节点的客户端 TLS 在 Cloudflare 边缘终止，再由 Cloudflare 另建 TLS 连接回源；`Full (strict)` 不是客户端到 VPS 的端到端 TLS。Cloudflare 能看到客户端 IP、连接时间和流量大小，也能读取边缘解密后的 HTTP/XHTTP 路径、头部和请求体字节。代理访问 HTTPS 网站时，目标网站的 TLS 内容仍由客户端加密到目标网站；非 TLS 目标流量没有这层端到端保护。2053 直连可绕过 Cloudflare 这一跳，但 VPS 仍会处理并看到代理流量。

Nginx 对这四个入口关闭访问日志，以减少本机保存的请求路径和来源记录。Nginx、Xray 或 systemd 的错误/服务日志仍可能记录运行故障信息。

## 配置和版本记录

受保护的部署参数保存在：

```text
/etc/xhttp-cdn-deploy/config.env
```

发布构建会把当时最新的官方稳定 Xray-core 版本、Xray 官方安装器提交和 acme.sh release tag 固定进生成的 `deploy.sh` 与 `release-manifest.txt`。Nginx、curl 等依赖使用 Debian 官方软件源版本。实际安装版本会写入 `config.env`，方便排查和复现部署结果。

生成的 Xray 配置位于 `/usr/local/etc/xray/config.json`，Nginx 专用配置位于 `/etc/nginx/conf.d/xhttp-cdn-deploy.conf`。重复运行脚本前应确认四个公网端口没有被其他服务占用；脚本会备份它管理的旧配置到 `/etc/xhttp-cdn-deploy/backups/`。
