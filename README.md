# Debian XHTTP + Reality/CDN 部署包

这个工程包面向 Debian 12/13 的 IPv4 VPS。脚本只安装和配置官方 Xray-core、Debian Nginx 和官方 acme.sh，不包含 xpadding、ECH、Hysteria2、Mihomo 或其他扩展功能。

参考的协议拓扑来自 [my-xhttp-cdn-config](https://github.com/Yulinanami/my-xhttp-cdn-config)，脚本实现已经重新整理，只保留本项目需要的节点。

## 节点布局

| 端口 | 上行 | 下行 |
| --- | --- | --- |
| 2053、2083、2087、2096（可逐项跳过） | XHTTP + TLS + Cloudflare CDN | XHTTP + TLS + Cloudflare CDN |
| 另行手动指定的端口 | XHTTP + Reality，直连 VPS | XHTTP + Reality，直连 VPS |

上述端口中实际可用的端口，以及你手动指定的 Reality 端口，是 VPS 侧需要放行的 **TCP 入站端口**。VPS 访问外网时由 Xray 使用系统分配的出站端口，脚本不会限制这些端口。

Cloudflare 支持这四个 HTTPS 端口。可用端口由 Nginx 接收 TLS/HTTP/2，再分别转发给仅监听 `127.0.0.1` 的 Xray 入站；冲突端口会被单独跳过。你另外手动指定一个双向直连 Reality 端口，必须与这四个 CDN 端口不同；Xray 在该公网端口监听 Reality。Reality 回落站点只监听本机直连端口加 `10000` 的地址，不需要额外放行内部端口。

## 执行方式

提交工程后，在本地运行发布构建脚本。它会拒绝 dirty worktree，并从干净提交生成可复现的工具包：

```bash
bash scripts/build-release.sh
```

构建产物位于 `dist/releases/<完整源码 SHA>/`，包含独立工具目录和 `.tar.gz` 压缩包，目录内附有部署、更新、卸载脚本、版本解析辅助文件、说明和哈希清单。解压后将工具目录中的文件上传到自己的仓库根目录，再下载并执行脚本：

```bash
sudo install -d -m 755 /opt/xhttp-cdn-deploy
sudo curl -fsSL https://raw.githubusercontent.com/OWNER/REPOSITORY/main/deploy.sh -o /opt/xhttp-cdn-deploy/deploy.sh
sudo curl -fsSL https://raw.githubusercontent.com/OWNER/REPOSITORY/main/uninstall.sh -o /opt/xhttp-cdn-deploy/uninstall.sh
sudo curl -fsSL https://raw.githubusercontent.com/OWNER/REPOSITORY/main/update.sh -o /opt/xhttp-cdn-deploy/update.sh
sudo curl -fsSL https://raw.githubusercontent.com/OWNER/REPOSITORY/main/runtime-versions.sh -o /opt/xhttp-cdn-deploy/runtime-versions.sh
sudo bash /opt/xhttp-cdn-deploy/deploy.sh
```

脚本只接受 Debian 12、Debian 13 和 root 权限，并要求 VPS 上没有现存的 Xray 安装。部署和更新时会解析官方最新稳定版 Xray-core、当前 Xray 官方安装器提交、acme.sh 最新稳定版，以及 Debian 当前配置软件源提供的工具依赖版本。发布包本身可从源码提交复现；各次部署实际解析到的组件版本记录在 `/etc/xhttp-cdn-deploy/install-state.env`。脚本不会自动修改 `ufw`、nftables 或云厂商安全组，请确认实际生成的 CDN TCP 端口和你指定的 Reality TCP 端口已经放行：

```text
<实际 CDN 端口> <Reality 直连端口>
```

卸载时运行 `sudo bash /opt/xhttp-cdn-deploy/uninstall.sh --dry-run` 查看处理范围，再运行 `sudo bash /opt/xhttp-cdn-deploy/uninstall.sh` 并输入 `UNINSTALL` 确认；也可用 `--yes` 显式确认。脚本按部署记录的所有权清理文件和组件；部署后被修改、被其他配置使用或无法确认归属的资源会保留并报告。Cloudflare DNS 记录和防火墙规则需要手动管理，不会被卸载脚本修改。

更新时运行 `sudo bash /opt/xhttp-cdn-deploy/update.sh --dry-run` 检查当前配置并查看官方上游版本目标，再运行 `sudo bash /opt/xhttp-cdn-deploy/update.sh` 并输入 `UPDATE` 确认；也可用 `--yes` 显式确认。更新只处理 Xray、acme.sh、Nginx 和本工具依赖的 Debian 软件包，不执行整机升级，也不会重写节点配置、证书或客户端链接。部署时若提供自备证书且没有安装 acme.sh，更新会跳过 acme.sh。

## 运行前需要准备的输入

脚本不会随机生成身份参数。请提前准备：

1. 五个不同的 UUID。
2. 一套 Reality 私钥。
3. 一个 Reality Short ID。
4. 一个双向直连 Reality 端口，且不与 `2053`、`2083`、`2087`、`2096` 冲突。脚本接受 `1` 到 `55535` 之间的 TCP 端口，并会拒绝与四个 CDN 端口及其本机转发端口数值重叠的输入；还需确保你指定的端口和它加 `10000` 的本机回落端口没有被其他服务占用。直连端口冲突会停止部署。
5. 一个自己的灰云 Reality 域名（记录名 `a2`）。
6. 一个自己的橙云 CDN 域名（记录名 `a1`）。
7. 一个 Cloudflare API Token，或者已经签发好的 CDN 域名证书和私钥。
8. 一段节点基础别名；脚本会在末尾自动追加每个实际生成节点的端口号。

UUID 可以在 Windows PowerShell 中运行下面命令五次，复制五行结果到部署提示。输入顺序是 Reality 直连、2053、2083、2087、2096；五条必须互不相同。

```powershell
[guid]::NewGuid().ToString()
```

Reality 私钥可以在 Windows 上用同版本官方 Xray 运行 `xray.exe x25519` 后复制 `PrivateKey`，脚本会根据私钥计算公钥，不会要求你另外输入公钥。新版本 Xray 的输出通常同时显示 `PrivateKey` 和 `Password (PublicKey)`，这里只输入 `PrivateKey` 那一行的值。部署时所有变量都以明文显示在终端输入行中，包括 Reality 私钥和 Cloudflare API Token；Token 不会写入客户端文件或 Git 文件。

Short ID 必须是 2 到 16 位十六进制字符，并且长度为偶数。脚本提示的推荐默认值是：

```text
a1234567
```

这个默认值是 8 位十六进制字符串，符合规则；其中包含数字 `4`，而 Short ID 允许使用该数字。你可以直接回车接受，也可以输入自己的值。Short ID 不要使用 `0` 到 `f` 以外的字符。

XHTTP 路径默认是 `/xhttp`。它不是密码，脚本不会随机改变它；如果你要改，必须以 `/` 开头，且不能包含空格、`?` 或 `#`。

部署提示中的域名、端口、IPv4、UUID、私钥、Short ID 和路径如果校验失败，会立即重新询问对应输入；不需要重新运行脚本。五个 UUID 仍需一次粘贴五行。部署前如果某个 CDN 公网端口被非 Nginx 服务占用，或对应本机转发端口被占用，脚本只跳过这个 CDN 端口；被跳过端口的 UUID 不会生成链接。节点基础别名只需输入一次。

脚本不会询问 SSH 密码、订阅密码或 VLESS Encryption 密钥。本版本不启用 VLESS Encryption，因此不需要额外的 `decryption`/`encryption` 字符串。

## Cloudflare 设置

### 1. 添加 DNS 记录

在 Cloudflare 中打开目标域名所在的 Zone，添加两条 A 记录：

```text
类型：A
名称：a1
内容：VPS 公网 IPv4
代理状态：已代理（橙色云）

类型：A
名称：a2
内容：同一个 VPS 公网 IPv4
代理状态：仅 DNS（灰色云）
```

把实际完整域名输入脚本，例如 `a1.example.com` 和 `a2.example.com`。可用的 CDN 端口共用 `a1`，且上下行都经过 Cloudflare；`a2` 只用作另行指定的 Reality 直连端口 SNI。两个记录应属于同一个 Cloudflare Zone，因为 DNS-01 Token 只配置这个 Zone。不要给它们添加指向其他源站的 AAAA 记录；本包按 IPv4 VPS 设计。

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

部署时脚本会明文输入 Token。acme.sh 会把它保存在 VPS 的 root 配置中供自动续期使用，脚本不会把 Token 写入客户端文件或 Git 文件中。

### 4. 配置缓存绕过

Cloudflare 默认不会缓存 POST，但 XHTTP 路径建议明确加入 Cache Rule。规则表达式可以使用：

```text
(http.host eq "a1.example.com" and http.request.uri.path contains "/xhttp")
```

动作选择 Skip cache。把示例域名换成你的 `a1` 域名，把路径换成脚本最终使用的 XHTTP 路径。

### 5. 已有 Nginx 或面板共存

脚本不会停止或接管 1Panel、OpenResty、Nginx Proxy Manager 等已有服务。CDN 公网端口已经由同一个 Nginx 服务监听时，脚本会尝试复用它，但要求该服务实际加载 `/etc/nginx/conf.d/xhttp-cdn-deploy.conf`。如果公网端口被其他进程占用，脚本只跳过对应 CDN 端口；对应本机 Xray 转发端口被占用时也会跳过该端口。Reality 直连端口及其本机回落端口冲突会停止部署。

## TLS 证书

### 推荐：acme.sh DNS-01

脚本默认在没有可复用证书时使用官方 acme.sh 和 Cloudflare DNS-01：

1. 脚本明文询问 Cloudflare API Token。
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

通过文件路径导入的证书由你自行续期。续期后需手动安装新证书并重载 Nginx。部署脚本只用于新安装，已部署服务请使用独立更新脚本；首次部署已存在同域名的 acme.sh 谱系时会拒绝覆盖，避免修改其他服务的证书配置。

## Reality 伪装域名怎么选

本工程选择的是“Reality 请求失败时回落到 VPS 本机 Nginx TLS 站点”的拓扑，所以建议 Reality SNI 使用你自己的灰云子域名。灰云域名和橙云 CDN 域名都由你控制，脚本会申请同时覆盖两者的源站证书。

这里有两个不同概念：

- **CDN 域名**：必须是你自己的域名，DNS 指向 VPS，并开启 Cloudflare 橙云。它用于四个指定端口，且上下行都经过 CDN。
- **Reality 伪装/SNI 域名**：灰云 DNS 记录直接指向 VPS，作为 Reality TLS 握手里的 `serverName`，不经过 CDN。

Reality 为什么有些教程使用 Apple、Firefox 等公共站点？

Reality 可以把认证失败的 TLS 连接转发给外部真实站点作为 target，因此一些不同的部署会把公共站点的主机名作为 `serverName` 和转发目标。那些域名属于 Apple、Mozilla 等网站，不是用户自己的 DNS 记录，也不能把它们添加到自己的 Zone。

本工程的回落目标是 VPS 本机 Nginx，用于接收 Reality 回落和 Cloudflare 的标准 TLS 回源；Nginx 证书必须匹配 Reality SNI，所以本脚本要求使用你控制的灰云域名，并把它和 CDN 域名一起放入证书 SAN。不要在本脚本中输入 `www.apple.com`、`www.mozilla.org` 等第三方域名：你无法为它们签发源站证书。

Reality 域名的 DNS 必须是灰云直连，否则 Reality 流量也会被 Cloudflare 接管。Reality 域名和 CDN 域名必须不同。TLS DNS-01 验证不要求开放 VPS 的 80 端口。

## 客户端文件

部署完成后，实际生成的 v2rayN VLESS 链接保存在：

```text
/root/xhttp-cdn-deploy/client-v2rayn.txt
```

在 Windows v2rayN 中选择导入剪贴板或从文件导入即可。Reality 节点的上传和下载都直接连接 VPS IP；生成的 CDN 节点上传和下载都使用 Cloudflare CDN 域名及对应端口。

部署末尾会询问一段基础别名，并为实际生成的节点追加端口后缀，例如输入 `jp`，未跳过时会得到 `jp-3869`、`jp-2053`、`jp-2083`、`jp-2087` 和 `jp-2096`。

部署结束时脚本也会把实际生成的完整链接输出到终端，方便直接复制。链接中的 UUID 是访问凭据；终端录屏、远程会话记录、日志采集或复制历史可能留存这些链接，不要把输出贴到公开渠道。客户端文件只允许 root 读取。

## XHTTP 连接复用与隐私

每条客户端链接会在 XHTTP `extra` 中明确设置 XMUX，避免连接行为依赖客户端 Xray-core 对未设置值的默认处理：

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

这些范围来自 [Xray XHTTP 说明](https://github.com/XTLS/Xray-core/discussions/4113)。其中 `maxConcurrency` 达到范围内选定的并发上限后，客户端会创建新的 XMUX client；请求数和可复用时间也有上限。所有生成的客户端链接都使用同一组值。XMUX 是客户端连接池设置，不会改变服务端协议或端口布局。

本包显式写入完整参数，让客户端行为不依赖 Xray 各版本对 XMUX 默认值的处理。显式配置不代表能够规避封禁。`fp=chrome` 只模拟 TLS ClientHello，不等于 Chrome 浏览器的完整 TLS/HTTP/2 行为；目前没有可靠证据能把这类连接特征与特定封禁事件建立因果关系。

Reality 直连端口是否触发端口相关提示，以当前安装版 Xray 的配置检查结果为准；XMUX 参数不能消除这类网络风险。

CDN 节点的客户端 TLS 在 Cloudflare 边缘终止，再由 Cloudflare 另建 TLS 连接回源；`Full (strict)` 不是客户端到 VPS 的端到端 TLS。Cloudflare 能看到客户端 IP、连接时间和流量大小，也能读取边缘解密后的 HTTP/XHTTP 路径、头部和请求体字节。代理访问 HTTPS 网站时，目标网站的 TLS 内容仍由客户端加密到目标网站；非 TLS 目标流量没有这层端到端保护。Reality 直连节点可绕过 Cloudflare 这一跳，但 VPS 仍会处理并看到代理流量。

Nginx 对实际生成的 CDN 入口和 Reality 本机回落站点关闭访问日志，以减少本机保存的请求路径和来源记录。Nginx、Xray 或 systemd 的错误/服务日志仍可能记录运行故障信息。

## 配置和版本记录

受保护的部署参数保存在：

```text
/etc/xhttp-cdn-deploy/config.env
```

发布清单记录源码 commit、源码树、运行时版本解析渠道和工具包文件哈希。每次部署或更新会把实际安装的 Xray、Xray 安装器提交、acme.sh、Nginx 和 Debian 依赖版本写入 `install-state.env`；因此工具包构建可复现，运行时组件则跟随执行时的官方稳定版和 Debian 软件源。

生成的 Xray 配置位于 `/usr/local/etc/xray/config.json`，由 root 保有并按 Xray systemd 服务组授予只读权限；部署启动前会用该服务身份验证配置可读且可解析。Nginx 专用配置位于 `/etc/nginx/conf.d/xhttp-cdn-deploy.conf`。部署时会探测端口并在状态文件中记录 active/skipped CDN 端口；已有 Nginx 只有在实际加载该配置时才会复用。Reality 直连端口及其本机回落端口冲突会停止部署，CDN 端口冲突只影响对应节点。部署脚本只用于没有现存 Xray 安装和本工具状态目录的新 VPS；后续组件升级通过 `update.sh` 完成。
