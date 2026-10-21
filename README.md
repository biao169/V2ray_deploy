# V2ray_deploy · VPSKit

用于 Debian / Ubuntu 小型 VPS 的单文件终端管理工具。当前版本：**1.4.0**。

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
| B | VLESS / VMess / Trojan + WS + TLS | 需要自有域名、Nginx 和有效证书；网站与客户端共用 443，Xray 监听本机内部端口 |

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
- `sync` 放行网站的 80/443、启用节点的公网 TCP 端口，以及 Shadowsocks 的 UDP 端口；不会放行 WS 的本机内部端口或本机网站应用端口。
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

本版本做过 Bash/ShellCheck、旧版 Bash 4.4 / jq 1.5、节点交互、配置与本机代理连接，以及隔离的防火墙、Swap 命令/状态测试。真实 VPS 的防火墙内核规则、systemd 启动、ACME 签发、Cloudflare 回源、Swap 激活及重启恢复仍需现场验收。

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
- WS+TLS / TCP+TLS 可以把连接地址设成 IP，但仍保留有有效证书的域名作为 **TLS SNI**，WS 同时保留该域名作为 **Host**，不会关闭证书校验。
- IPv6 输入示例：`2001:db8::10`，不输入方括号；导出的 URI 会按格式自动加括号。示例地址仅供说明，必须换成实际地址。独立入口的 IPv6 连接要求系统已启用 IPv6，并选择 `::` 监听。
- 同入口的多个用户共享连接地址、监听地址和端口；修改这些参数会同步影响整个入口。域名与 IP 需要分别导出时，可建立不同入口。

主面板用紫色标题、蓝色菜单序号、青色域名/数量、绿色正常、黄色待处理、红色异常或删除操作、灰色说明。颜色同时配有文字；重定向输出或使用 `vpskit --no-color` 时不输出颜色控制符。

## 8. Cloudflare 橙云与源站地址

推荐组合：**方案 B → Cloudflare 代理 → DNS-01 → WS+TLS**。

1. 在 Cloudflare 管理域名 DNS，把用于网站/WS 的记录设为橙云，并正确配置到源站。公开查询可返回 Cloudflare 边缘 IP；脚本不会强制 A/AAAA 等于 VPS IP。
2. 选择 Cloudflare DNS-01，用限定区域的 DNS 编辑 Token 和 Account ID 完成 TXT 验证。DNS API 凭据仅用于证书；脚本不自动改橙云、源站或 SSL 控制台配置。
3. 等源站有效证书就绪，在 Cloudflare 选择 **Full (strict)**，启用 **WebSockets**。云安全组和系统防火墙必须允许所需 HTTPS 回源。
4. 客户端默认连接这个域名的 443，WS 路径、Host 和 TLS SNI 使用导出值。

也可在连接地址处填写可用的 Cloudflare 边缘 IPv4 / IPv6，保留自己的 Host/SNI；边缘地址的可用性需自行验证。填写 **VPS 源站 IP** 则是直连，会将该 IP 写入分享链接。

普通 Cloudflare 橙云适用于 HTTP(S)/WebSocket，不能直接代理本脚本的 REALITY、独立 TCP+TLS 或 Shadowsocks。若目标是尽量隐藏源站，应避免同时分发源站直连节点，并检查其他 DNS 记录；橙云不清除历史 DNS，也不保证源站永远无法被发现。本版不会自动把源站访问限制为 Cloudflare IP 段。

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
