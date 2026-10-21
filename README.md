# V2ray_deploy · VPSKit

用于 Debian / Ubuntu 小型 VPS 的单文件终端管理工具。当前版本：**1.3.0**。

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
4. 默认使用 Let's Encrypt / ECC P-256 / HTTP-01；HTTP 验证需要域名正确解析、外网能访问 80 端口。也可选择 Cloudflare 或 DNSPod 的自动 DNS 验证。
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

**签发证书前就要放通 80。** 如果部署卡在 HTTP 验证，返回防火墙菜单开放 80/443，检查域名及云安全组，然后继续部署。若 UFW/firewalld 未启用，先由管理员配置 SSH 放行和整机策略，再启用其中一个；不要在远程终端盲目重置防火墙。

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
sudo vpskit node list               # 节点列表
sudo vpskit node export             # 选择节点并导出链接
sudo vpskit node edit               # 更换UUID或密码
sudo vpskit node port               # 修改入口端口
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

完整卸载会删除本工具的网站、节点、证书、日志、备份、服务和入口，并撤销其网络调优及记录的防火墙规则；先另行备份需要保留的内容。外部防火墙、外部规则、系统共享日志、原有依赖以及自行下载的源码文件不属于本工具清理范围。

本版本做过语法、静态检查及隔离的防火墙命令/状态测试；真实 VPS 的防火墙内核规则、systemd、域名签发和公网访问需要现场验收。
