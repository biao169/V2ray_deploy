# V2ray_deploy · VPSKit

用于 Debian / Ubuntu 小型 VPS 的单文件终端管理工具。当前版本：**1.6.0**。

仓库：[biao169/V2ray_deploy](https://github.com/biao169/V2ray_deploy)。将 `vpskit.sh` 和本文件放在仓库 `main` 分支根目录即可；运行脚本不依赖 README 或其他配套脚本。

## 1. 安装与打开面板

支持 Debian 12+、Ubuntu 18.04+，amd64 / arm64，要求 systemd、Bash 4.4+，以 root 运行，不创建新系统账户。旧 Ubuntu 需要可用的软件源和基础库。

适合 512MB 内存、10GB 硬盘 VPS 上的小型静态网站和少量代理连接；实际占用取决于流量与应用。部署向导要求至少 500MB 可用磁盘空间。面板无需常驻 Web 服务。

先进入 root 终端（已经是 root 则跳过）：

```bash
sudo -i
```

如果系统没有 curl，先安装：

```bash
apt-get update && apt-get install -y curl
```

一键运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/biao169/V2ray_deploy/main/vpskit.sh)
```

也可以先下载到本地、检查语法后运行，下载失败会停止后续步骤：

```bash
curl -fL https://raw.githubusercontent.com/biao169/V2ray_deploy/main/vpskit.sh -o vpskit.sh && bash -n vpskit.sh && bash vpskit.sh
```

安装后，在终端输入以下命令打开面板：

```bash
sudo vpskit
```

**从旧仓库版本迁移：** 先将新版脚本上传到新仓库，再运行一次上面的新地址一键命令。脚本会保留现有配置并更新管理入口。旧版本内置的更新地址仍指向旧仓库，因此首次迁移不要只依赖旧版 `vpskit update manager`。

## 2. 第一次部署怎么选

| 方案 | 代理方式 | 要求与端口 |
| --- | --- | --- |
| A | VLESS + REALITY + Vision | 代理本身无需自有证书，默认公网端口从 8443 选择；可另外部署网站 |
| B | 默认 VLESS + XHTTP + TLS（H2），可选 Cloudflare H3 | 需要自有域名、Nginx 和有效证书；网站与客户端共用 443，Xray 监听本机内部端口 |

1. 主菜单选择 **1：部署与安装 → 1：继续部署向导**。
2. 选择 A 或 B；填写连接地址、自有域名、证书联系邮箱等。
3. 网站可选轻量模板、自建静态网站、本机应用反向代理、常用网站或自定义 HTTPS 跳转。
4. 选择网站访问方式。首次选择方案 B 推荐 Cloudflare 橙云 + DNS-01，直连网站推荐 HTTP-01；沿用 Let's Encrypt / ECC P-256。后续保留你选择的验证方式，支持 Cloudflare、DNSPod 自动 DNS 验证。
5. 按提示安装组件、签发证书、添加节点，最后导出客户端链接。
6. 检查系统防火墙和云安全组，从客户端测试连接。

方案、域名和偏好会保存；输入错误可以原地重输，回车使用默认值，输入 `:q` 取消当前操作。失败后重新进入向导，已完成步骤会跳过。面板显示的是本机状态，不能替代公网连通性验证。

REALITY 的目标域名与自有网站域名分别保存。网站跳转只是浏览器跳转，不等于 REALITY 握手伪装。导出的节点链接包含访问凭据，请勿公开。

## 3. 防火墙端口管理

主菜单选择 **10：防火墙端口管理**，或执行：

```bash
sudo vpskit firewall          # 防火墙菜单
sudo vpskit firewall status   # 状态、zone和规则记录
sudo vpskit firewall open     # 交互输入端口及tcp/udp/both，确认开放
sudo vpskit firewall close    # 交互输入端口及协议，确认阻止新入站连接
sudo vpskit firewall sync     # 预览并放行当前网站、节点所需端口
sudo vpskit firewall cleanup  # 撤销本工具添加的防火墙规则
```

- 支持**已安装并启用的 UFW 或 firewalld**。不会自动安装、启用、禁用或重置整机防火墙；同时启用两者时拒绝更改，避免规则冲突。原生 nftables / iptables 不在本版直接管理范围内。
- UFW 使用带标记的入站规则；firewalld 需要选择公网网卡/来源所属的 zone，同时修改运行时和永久配置。firewalld 需支持富规则的 priority 参数，不支持时会停止操作并报错。
- 保护 22 和检测到的 SSH 端口，这些 TCP 端口由系统单独管理。不会为清理代理端口而停止 SSH。
- `sync` 放行网站的 80/443、启用节点的公网 TCP 端口，以及 Shadowsocks 的 UDP 端口；不会放行 WS/XHTTP 的本机内部端口或本机网站应用端口。
- `sync` 只添加所需放行规则，不会自动关闭停用/删除节点的旧端口。关闭旧端口请使用 `close`；以后重新启用该节点，可再次 `sync`。
- “关闭”通过阻止规则限制新连接，已有连接可能继续。关闭 80/443 会影响网站、WS 或 HTTP 证书验证。其他高优先级规则、Docker 网络和云安全组仍可能影响最终结果，请从外网测试。
- 保留已有外部规则。若同类外部 UFW 规则已存在，脚本会提示保留，需要核对其优先级；不会宣称端口已经通过公网验收。
- 操作中断或部分失败时，记录保留，可重试同一操作或执行 `cleanup`。完整卸载会清理本工具记录的规则，不卸载系统防火墙。若原代理端口后来改成 SSH，清理会停止，要求先建立独立 SSH 放行规则。

**使用 HTTP-01 签发前要放通 80；DNS-01 无需为签发开放 80。** 如果部署卡在 HTTP 验证，返回防火墙菜单开放 80/443，检查域名及云安全组，然后继续部署。若 UFW/firewalld 未启用，先由管理员配置 SSH 放行和整机策略，再启用其中一个；不要在远程终端盲目重置防火墙。

## 4. 查看配置文件在哪里

主菜单选择 **9：配置文件与目录**，或执行：

```bash
sudo vpskit paths
```

命令显示路径及“存在 / 未创建 / 链接目标缺失”等状态，只显示位置，不输出密码、UUID、Token 或私钥内容。未安装时也可运行 `bash vpskit.sh paths` 查看预设位置。

| 内容 | 默认路径 |
| --- | --- |
| 管理脚本 / 唤醒入口 | `/opt/vpskit/vpskit.sh` / `/usr/local/bin/vpskit` |
| Xray 配置 / 程序 | `/opt/vpskit/config/xray.json` / `/opt/vpskit/bin/xray` |
| Nginx 配置 / 程序 | `/opt/vpskit/config/nginx.conf` / `/opt/vpskit/nginx/usr/sbin/nginx` |
| 节点、域名和偏好 | `/opt/vpskit/data/state.json` |
| 网站内容 | `/opt/vpskit/www/你的域名/` |
| 当前证书链 / 私钥 | `/opt/vpskit/certs/你的域名/current/fullchain.pem` / `key.pem` |
| acme.sh 程序 / 账户配置 | `/opt/vpskit/acme/acme.sh` / `/opt/vpskit/acme/config/` |
| ACME 证书存储 | `/opt/vpskit/acme/certstore/` |
| Xray / Nginx / 管理日志 | `/opt/vpskit/logs/xray.log` / `nginx.log` / `manage.log` |
| Cloudflare 网段 / AOP 公共 CA | `/opt/vpskit/config/edge/` |
| Swap 文件 / 归属记录 | `/opt/vpskit/swap/swapfile` / `/opt/vpskit/data/swap.json` |
| Swap 开机服务 | `/etc/systemd/system/opt-vpskit-swap-swapfile.swap` |
| 防火墙操作记录 | `/opt/vpskit/data/firewall.json` |
| 配置回滚快照 | `/opt/vpskit/backup/last/` |
| 服务及续期任务 | `/etc/systemd/system/vpskit-*.service`、`vpskit-maintain.timer` |
| 系统防火墙配置 | `/etc/ufw/` 或 `/etc/firewalld/`，由对应系统工具管理 |

这里的 Nginx 是脚本独立安装的实例，配置在 `/opt/vpskit/config/nginx.conf`。Xray/Nginx 配置由面板生成，手动修改可能在下一次操作时被覆盖；网站内容可以自行编辑。状态文件、配置和证书目录可能包含凭据，不要提交到公开仓库。

## 5. 常用命令

```bash
sudo vpskit install                 # 继续部署向导
sudo vpskit wizard configure        # 修改方案和默认值，继续部署时应用
sudo vpskit wizard status           # 逐步进度
sudo vpskit node add                # 添加节点或共享入口用户
sudo vpskit node list               # 带序号的节点列表
sudo vpskit node export             # 选择节点并导出链接
sudo vpskit node edit               # 更换UUID或密码
sudo vpskit node port               # 按序号选择，修改入口端口
sudo vpskit node address            # 修改连接域名、IPv4或IPv6；保留证书域名/SNI
sudo vpskit node enable             # 启用节点
sudo vpskit node disable            # 停用节点
sudo vpskit node delete             # 删除节点
sudo vpskit site add                # 添加或继续配置网站
sudo vpskit site edit               # 修改网站内容类型
sudo vpskit cert settings           # 修改证书验证等设置
sudo vpskit cert status             # 证书到期情况
sudo vpskit cert issue              # 签发或重试签发
sudo vpskit cert renew              # 按到期策略检查续期
sudo vpskit status                 # 本机运行状态
sudo vpskit doctor                 # 配置、DNS、HTTPS等诊断
sudo vpskit logs xray               # 代理日志；也支持nginx/manager/cert
sudo vpskit optimize               # BBR、MTU探测、静态网站gzip菜单
```

更改端口后还需执行 `vpskit firewall sync`，并同步修改客户端及云安全组。证书定时任务每小时触发检查，按到期策略续期，不是每小时重新签发。

## 6. 更新与卸载

```bash
sudo vpskit update manager          # 更新管理脚本，下次打开面板生效
sudo vpskit update xray             # 独立更新Xray
sudo vpskit update nginx            # 独立更新Nginx
sudo vpskit update acme             # 独立更新证书工具
sudo vpskit update all              # 依次更新已安装组件及管理脚本
sudo vpskit uninstall xray          # 独立卸载Xray，同时删除代理节点
sudo vpskit uninstall nginx         # 有网站/节点依赖时拒绝卸载
sudo vpskit uninstall acme          # 有证书依赖时拒绝卸载
sudo vpskit uninstall all           # 确认后完整卸载
```

完整卸载会删除本工具的网站、节点、证书、日志、备份、服务和入口，并撤销其网络调优及记录的防火墙规则，安全停用并删除本工具的 Swap；先另行备份需要保留的内容。外部防火墙、外部规则、系统共享日志、原有依赖以及自行下载的源码文件不属于本工具清理范围。

本版本做过 Bash/ShellCheck、旧版 Bash 4.4 / jq 1.5、节点交互、配置与本机代理连接，以及隔离的防火墙、Swap 命令/状态测试。1.5.0 另通过本机 Nginx 的爬虫策略、限流、真实 IP 信任边界、缓存、AOP 客户端证书和 WS 连通性测试。真实 VPS 的防火墙内核规则、systemd 启动、ACME 签发、Cloudflare 线上回源、Swap 激活及重启恢复仍需现场验收。

## 7. 节点序号、IPv4 / IPv6 与面板颜色

节点列表显示 `[1]`、`[2]` 等序号。导出、改凭据、改端口、改地址、停用、删除和添加共享用户都可按序号选择；错误序号可以重新输入。删除会先显示选中名称，再要求确认。删除后序号会重新排列，以最新列表为准。

```bash
sudo vpskit node list
sudo vpskit node delete             # 交互输入序号，确认后删除
sudo vpskit node export 2           # 导出当前第2个节点
sudo vpskit node address            # 交互输入序号和新的连接地址
```

CLI 仍兼容旧的节点名称；若存在纯数字名称，显式命令参数优先按名称匹配，交互菜单始终按序号选择。

- REALITY、Shadowsocks、VMess 独立 WS 可直接填写 VPS 的 IPv4 / IPv6，无需自有代理域名。
- XHTTP H2 / WS+TLS / TCP+TLS 可以把连接地址设成 IP，但仍保留有有效证书的域名作为 **TLS SNI**，XHTTP/WS 同时保留该域名作为 **Host**，不会关闭证书校验。
- IPv6 输入示例：`2001:db8::10`，不输入方括号；导出的 URI 会按格式自动加括号。示例地址仅供说明，必须换成实际地址。独立入口的 IPv6 连接要求系统已启用 IPv6，并选择 `::` 监听。
- 同入口的多个用户共享连接地址、监听地址和端口；修改这些参数会同步影响整个入口。域名与 IP 需要分别导出时，可建立不同入口。

主面板用紫色标题、蓝色菜单序号、青色域名/数量、绿色正常、黄色待处理、红色异常或删除操作、灰色说明。颜色同时配有文字；重定向输出或使用 `vpskit --no-color` 时不输出颜色控制符。

## 8. Cloudflare 橙云与源站地址

推荐组合：**方案 B → Cloudflare 代理 → DNS-01 → VLESS + XHTTP + TLS H2**。

1. 在 Cloudflare 管理域名 DNS，把用于网站/XHTTP/WS 的记录设为橙云，并正确配置到源站。公开查询可返回 Cloudflare 边缘 IP；脚本不会强制 A/AAAA 等于 VPS IP。
2. 选择 Cloudflare DNS-01，用限定区域的 DNS 编辑 Token 和 Account ID 完成 TXT 验证。DNS API 凭据仅用于证书；脚本不自动改橙云、源站或 SSL 控制台配置。
3. 等源站有效证书就绪，在 Cloudflare 选择 **Full (strict)**，启用 **WebSockets**。云安全组和系统防火墙必须允许所需 HTTPS 回源。
4. 客户端默认连接这个域名的 443，代理路径、Host 和 TLS SNI 使用导出值。

也可在连接地址处填写可用的 Cloudflare 边缘 IPv4 / IPv6，保留自己的 Host/SNI；边缘地址的可用性需自行验证。填写 **VPS 源站 IP** 则是直连，会将该 IP 写入分享链接。

普通 Cloudflare 橙云适用于 HTTP(S)/WebSocket，不能直接代理本脚本的 REALITY、独立 TCP+TLS 或 Shadowsocks。若目标是尽量隐藏源站，应避免同时分发源站直连节点，并检查其他 DNS 记录；橙云不清除历史 DNS，也不保证源站永远无法被发现。可在菜单 12 显式启用 Nginx 层的 Cloudflare 网段限制；本版不自动改变云防火墙或 SSH。

## 9. 低内存 VPS 一键 Swap

主菜单选择 **11：Swap虚拟内存**。512MB RAM / 10GB 磁盘建议先添加 **1024MiB**，再安装组件；实际磁盘剩余空间必须足够。

```bash
sudo vpskit swap                    # 打开菜单
sudo vpskit swap enable             # 一键创建1GiB；已配置时恢复/修复
sudo vpskit swap custom             # 256～4096MiB，256的倍数
sudo vpskit swap status             # 实际使用量、路径、开机状态
sudo vpskit swap remove             # 确认后安全移除
```

- 使用独立文件和 systemd `.swap` 服务持久化，重启自动启用；不改 `/etc/fstab`，不覆盖、关闭或删除已有系统 Swap。
- 创建后至少保留 **1GiB** 空闲磁盘；文件权限为 `600`，不进入配置回滚快照。
- 自动创建支持 ext2/ext3/ext4/XFS；Btrfs、ZFS 等需专门配置，本功能会停止。容器环境需要宿主机支持，不保证可用。
- 创建/启用失败会留下归属和阶段记录，可重试 `swap enable` 或安全移除。已有 Swap 不会重复分配；变更容量请先移除再创建。
- 移除前要求可用 RAM ≥ 当前已用本工具 Swap + 128MiB。内存不足或 `swapoff` 失败时保留文件及开机配置，完整卸载也会停止，请先关闭占内存的应用再重试。
- Swap 用于缓冲内存压力，磁盘速度比 RAM 慢，不能替代物理内存，也不会增加代理带宽。

## 10. 方案 B 增强：防护、爬虫与带宽

升级脚本后打开 **主菜单 12：方案B防护与流量**。旧站点保留原有爬虫、限额和回源设置，增强预设需要主动应用；所有策略按网站域名保存。一个 Xray、一个 Nginx worker，不额外安装防爬守护进程或磁盘代理缓存。

推荐顺序：

1. 确认网站和 XHTTP/WS+TLS 节点已经能通过橙云连接。
2. 应用 **均衡预设**：仅拦截声明身份的 AI 爬虫；网站每 IP 5 请求/秒、允许突发 30、并发请求 20；静态资源缓存 1 小时，开启低等级 gzip。
3. 阅读 **Cloudflare边缘配置指引**，在控制台配置爬虫拦截和缓存，并排除 XHTTP前缀及 WS/ACME 等特定路径。
4. 确认网站与客户端正常后，开启 **限制Cloudflare回源**。
5. 可选 AOP：先 `observe`，在 Cloudflare 开启 Global Authenticated Origin Pulls，再执行回源验证；最后切换 `enforce`。

```bash
sudo vpskit edge                    # 防护与流量菜单
sudo vpskit edge status             # 每个网站的策略和更新时间
sudo vpskit edge profile            # 选择网站，应用均衡预设
sudo vpskit edge bots               # off / ai / common / all
sudo vpskit edge limits             # 请求、突发、并发、每响应下载限额
sudo vpskit edge cache              # 静态缓存时间与站点gzip
sudo vpskit edge origin             # 开关Cloudflare网段限制
sudo vpskit edge aop                # off / observe / enforce
sudo vpskit edge probe              # 验证本次公网回源是否为SUCCESS
sudo vpskit edge refresh            # 刷新官方IPv4/IPv6网段及公共AOP CA
sudo vpskit edge guide              # 输出控制台配置指引与网站规则范围
sudo vpskit edge traffic            # 网卡累计流量和约1秒速率采样
sudo vpskit edge reset              # 关闭所选网站的新增增强设置
```

### 各项功能的作用和边界

| 功能 | 行为 |
| --- | --- |
| 正常网站外观 | 网站照常展示；未配置的 Host、普通 HTTP 请求探测 WS 节点路径返回 404。WS 仍需正确握手和节点凭据；不保证流量无法被识别 |
| AI 爬虫 `ai` | 拒绝匹配 GPTBot、ClaudeBot、Bytespider 等已知 User-Agent；普通搜索引擎爬虫通常保留 |
| 常见采集器 `common` | 在 AI 名单上增加 Ahrefs、Semrush 等；适合不需要这些采集服务的网站 |
| 广泛策略 `all` | 增加 bot/spider/crawler、curl/wget 等匹配，会影响 SEO、网站 API 和监控工具；需要确认 |
| 网站限流 | 按访客 IP 控制请求速率、突发和并发，超限返回 429；同一 NAT 出口共享额度 |
| 网站下载限额 | 以 KiB/s 限制每一个网站响应；不是整台 VPS 或每个代理用户的总带宽配额 |
| 静态缓存 | CSS/JS/图片/字体设置缓存头；由浏览器/CDN减少重复请求。HTML和动态应用不强制缓存；WS/XHTTP禁用代理缓存 |
| 压缩 | 仅静态文本轻量 gzip；不重复压缩加密代理流量；全局 gzip 开关仍独立生效 |
| 回源限制 | Nginx 只接受来自已验证 Cloudflare 网段的网站/WS/XHTTP访问；保留 ACME HTTP-01 路径，不修改 SSH |
| AOP | 使用 Cloudflare 公共回源 CA 检查客户端证书；先观察，公网验证通过后才允许强制，并在应用后再次验证 |
| 更新与恢复 | 小型官方资料每 7 天通过现有维护任务刷新；失败保留旧资料。修改前验证配置，失败恢复；成功只重载 Nginx，不重启 Xray |

**爬虫并不会因为被列入名单就诚实报名字。** User-Agent 可以伪造，`robots.txt` 也只是一项约定。静态网站缺少 `robots.txt` 时提供对应默认声明；已有文件原样保留，动态应用的 robots 路由保留。部分 AI 产品使用 robots 产品标识而非同名 User-Agent，不能只靠字符串匹配覆盖所有抓取。

想真正减少 VPS 回源流量，优先让 **Cloudflare 在边缘拦截或命中缓存**。本机规则只能减少后续响应和应用开销，请求及 TLS 握手已经到达 VPS；无法防御超出线路容量的攻击。WS/XHTTP 代理传输仍计入实际 VPS 带宽，CDN 不会缓存你的代理数据，也不会提高服务商的硬性速率上限。

### Cloudflare 配置与防误伤

- 脚本只信任从官方 Cloudflare 网段传来的 `CF-Connecting-IP`，用于按真实访客限流；直接访问时伪造该头不能变成受信任请求。回源限制检查原始连接对端，避免把正常访客 IP 当作 Cloudflare IP 来误封。
- 跳转网站的 301/302 在 Nginx 请求限流阶段前返回，跳转请求速率应在 Cloudflare 边缘控制；爬虫和回源检查仍生效。
- **WS 精确路径和 XHTTP 路径前缀不套用网站爬虫过滤、请求/并发限额、下载限额、gzip 或缓存；回源限制和 AOP 仍然适用。** ACME 路径不套用网站策略。WS 路径之外伪造 `Upgrade` 头不能绕过网站规则。
- `edge guide` 输出的网站范围表达式只是规则的作用范围，必须再加拦截条件；不能把它直接设为 Block，否则会封禁正常网站流量。
- 不要对共用代理域名盲目开启 **免费 Bot Fight Mode**：普通 Skip 规则无法豁免它，可能影响自动客户端。支持例外的产品/套餐才按具体 WS 精确路径和 XHTTP 前缀做豁免；不要因携带任意 Upgrade 头就全站放行。
- Cloudflare 控制台的 AI 拦截策略、WAF、缓存和套餐能力以当前账户为准，脚本不自动发布这些规则，也不会把证书 DNS Token 用作 WAF 管理凭据。新增、改动或停用 WS/XHTTP 节点后，应同步更新边缘路径规则。
- 开启回源限制/AOP后，源站 IP 直连网站和 WS/XHTTP 会被拒绝。REALITY、独立 TCP+TLS、Shadowsocks 等其他端口不受该网站规则控制，仍可能暴露源站。
- 公共 AOP 证书由 Cloudflare 账户共享，仅证明来自 Cloudflare 网络，不绑定你的账户。需要更严格的账户/域名隔离时，应另外配置 zone-level/per-hostname 自有回源证书；本版不自动部署这一高级配置。
- `observe` 允许不提供客户端证书的请求，但会验证已经提供的证书。`enforce` 拒绝缺少有效证书的 HTTPS 请求；HTTP-01 的 80 端口验证路径仍可用。
- 修改完成后需从客户端检查网站、WS/XHTTP 节点和续期。Nginx 层限制不等于内核防火墙丢包；如需只允许 Cloudflare 网段进入源站的 80/443，应在云防火墙另行配置并安排网段更新。

旧 Ubuntu 如安装过缺少限流模块的 `nginx-light`，先运行 `sudo vpskit update nginx`。新版优先提取包含所需模块的发行版构建；缺少模块时会给出明确错误，不会默默按错误 IP 限流。不开启新防护时，不强制升级旧配置。

静态资源更新建议更换文件名或版本参数，并按需清理 CDN 缓存。关闭本机增强设置不会替你删除 Cloudflare 控制台规则；关闭站点 gzip 后，全局 gzip 如仍启用，还需在优化菜单关闭。

参考：[Nginx WebSocket](https://nginx.org/en/docs/http/websocket.html)、[Nginx Real IP](https://nginx.org/en/docs/http/ngx_http_realip_module.html)、[Cloudflare 缓存](https://developers.cloudflare.com/cache/concepts/default-cache-behavior/)、[Bot Fight Mode](https://developers.cloudflare.com/bots/get-started/bot-fight-mode/)、[公共 AOP](https://developers.cloudflare.com/ssl/origin-configuration/authenticated-origin-pull/set-up/global/)。


## 11. 1.6.0：XHTTP H2 / H3 与旧节点迁移

方案 B 的新节点默认 **VLESS + XHTTP + TLS，H2、packet-up 模式**。普通“添加节点”也默认选择 VLESS；方案 A 保持 VLESS REALITY Vision。明确选择 VMess/Trojan 时才创建旧协议节点，旧节点不会自动转换或删除。分享链接含 `type=xhttp`、`mode=packet-up`、`alpn=h2/h3`，客户端必须正确支持这些字段；无法完整导入时用客户端 JSON。

| 选择 | 实际连接链路 | 条件 |
| --- | --- | --- |
| H2（默认） | 客户端 → TLS/H2 → Nginx → 本机 Xray；也可经过 Cloudflare | Nginx 编译包含 http_v2 模块；客户端支持 XHTTP |
| H3（Cloudflare） | 客户端 → QUIC/H3 → Cloudflare → HTTPS 回源 Nginx → 本机 Xray | 网站设为 Cloudflare、节点地址使用该网站域名、橙云、有效边缘证书、Cloudflare 开启 HTTP/3、客户端出站 UDP443 可用 |

本版 **不安装 VPS 原生 H3/QUIC 监听，不支持用源站 IP 直连 H3**，无需为此开放 VPS UDP443。H3 仅作用于客户端到 Cloudflare，回源使用 TCP；没有自动 H3→H2 回退，失败时用节点菜单切回 H2并重新导入。网站选择“Cloudflare”不代表控制台已设置成功，脚本不会冒用 DNS Token 修改 HTTP/3、WAF 或缓存开关。

Cloudflare 控制台：进入域名 → **Speed → Settings → Protocol Optimization → HTTP/3** 开启。为 XHTTP 的 `路径/` **前缀及全部子路径**设置缓存 Bypass，避免 JS 挑战、验证码和网站限流；不要只豁免一个精确 URL。`sudo vpskit edge guide` 会输出包含 XHTTP 前缀的规则范围。不要单独拦截该范围表达式，应叠加实际拦截条件。

**操作步骤：**

1. 把本版 `vpskit.sh` 上传到仓库 `main` 根目录，再执行 README 开头的一键命令更新本机管理脚本；不会直接改掉现有节点。
2. 新建：主菜单 **2 → 1**，默认 VLESS → XHTTP，选择已签发证书的网站；H2 默认，H3需确认条件。
3. 迁移：主菜单 **2 → 11**，按序号选旧节点，创建独立名称、UUID、内部端口和路径的新节点。原节点及共享用户保留；这是逐个新增迁移，不是批量覆盖。
4. 将新链接/JSON导入支持 XHTTP 的客户端，测试上下行、DNS和网站访问。确认正常后，使用 **2 → 8** 按序号停用旧节点。
5. **2 → 12** 切换 H2/H3（同入口导出参数一起更新）；**2 → 13** 导出 Xray 客户端 JSON。

```bash
sudo vpskit node migrate-xhttp       # 交互选择旧节点并新建XHTTP节点
sudo vpskit node xhttp-version       # 切换H2/H3，随后重新导入客户端
sudo vpskit node xhttp-json          # 终端输出完整客户端JSON，含UUID
```

JSON 使用本地 SOCKS `127.0.0.1:10808`，仅供客户端使用，不要覆盖 VPS 的服务端配置。客户端保留 TLS 证书校验。H2 支持自定义 IPv4/IPv6 连接地址，SNI/Host仍使用证书域名；若已开启仅 Cloudflare 回源或强制 AOP，源站直连会被拒绝。

Nginx 对 XHTTP 使用独立前缀 location，关闭请求/响应缓冲和缓存；网站爬虫、请求、并发与下载限额不套用到该代理路径，原有回源网段限制及 AOP仍生效。为减少旧系统依赖，H2/H3导出均固定 `packet-up`，不自动启用 stream-up、额外 mux 或试验性 VLESS Encryption/Seed。外层 HTTPS仍启用；不保证更快、完全无法识别或无限并发。

Nginx 1.25.1+ 使用 `http2 on`，旧版本使用 `listen ... http2`。缺少 http_v2 模块时会停止新配置操作并提示先更新Nginx；Xray仍沿用本脚本已测试的 v26.3.27，不为消除警告盲目升级 latest。每次配置应用先验证Xray和Nginx；迁移失败回滚，成功应用仍可能短暂重启Xray。

**Cloudflare 签发诊断：** 输入 Token 时提示 `Zone/DNS/Edit` 与 `Zone/Zone/Read`，Account ID必须为32位十六进制。签发前只读查询所属区域，区分API连不上、查询被拒、查不到区域；失败可重新输入。查到Zone ID后明确传给acme.sh，避免旧区域ID干扰。该预检不写DNS，也不能证明DNS编辑权限正常；实际写TXT仍由ACME验证。DNS-01错误不再误提示开放80或关闭橙云。

**验证范围：** 使用真实 Xray v26.3.27、Nginx 1.24 和 Ubuntu 18.04 对应的 Nginx 1.14，在本机验证 XHTTP H2 的 IPv4/IPv6 下载及超过1MB上传；检查网站爬虫与限额不会误伤代理。检查H3客户端配置可被Xray接受；真实Cloudflare H3链路、权威DNS签发与公网吞吐需在目标VPS及客户端验收。本地测试不能替代这些外部条件。

参考：[XHTTP 官方说明](https://github.com/XTLS/Xray-core/discussions/4113)、[Cloudflare HTTP/3](https://developers.cloudflare.com/speed/optimization/protocol/http3/)、[Nginx HTTP/2模块](https://nginx.org/en/docs/http/ngx_http_v2_module.html)。
