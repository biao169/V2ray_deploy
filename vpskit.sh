#!/usr/bin/env bash
# VPSKIT_SINGLE_FILE - MIT License - Copyright (c) 2026 VPSKit contributors
# VPSKit 1.4.0 | Debian 12+, Ubuntu 18.04+, systemd, amd64/arm64, Bash 4.4+.
# 单文件交付；运行配置/上游程序/证书在 /opt/vpskit；不创建系统账户。
# 使用: sudo bash vpskit.sh ; 安装后: sudo vpskit
# 上传为 biao169/V2ray_deploy/main/vpskit.sh 后:
# bash <(curl -fsSL https://raw.githubusercontent.com/biao169/V2ray_deploy/main/vpskit.sh)
# Root安装及服务运行。现有外部程序不接管、不卸载；防火墙仅按用户菜单选择修改。
# 支持: VLESS REALITY/Vision、VMess/VLESS/Trojan WS+TLS或TCP+TLS、Shadowsocks AEAD/2022。
# 不声称支持Xray所有实验协议、传输或客户端。配置修改可能重启Xray并中断连接。
# 完整卸载删除本工具资料；系统共享依赖仅在检查无其他依赖后可选移除。
# 真实域名ACME、防火墙实际规则、云安全组及网络吞吐必须在目标VPS验收。

# jq filters and Nginx variables below deliberately use literal single quotes.
# shellcheck disable=SC2016
set -Eeuo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
VERSION='1.4.0'
XRAY_TESTED_VERSION='v26.3.27'
ROOT='/opt/vpskit'
ENTRY='/usr/local/bin/vpskit'
STATE="$ROOT/data/state.json"
SELF_URL='https://raw.githubusercontent.com/biao169/V2ray_deploy/main/vpskit.sh'
SYSTEMD='/etc/systemd/system'
SYSCTL_LINK='/etc/sysctl.d/90-vpskit.conf'
XRAY="$ROOT/bin/xray"
NGINX="$ROOT/nginx/usr/sbin/nginx"
ACME="$ROOT/acme/acme.sh"
NO_COLOR_FLAG=0
TX=0
WIZARD_ACTIVE=0
WIZARD_STEP=''
PANEL_IDLE=0
UNINSTALLING=0
WORK=''
LOCK_FD=''
HAVE_LOCK=0
TTY_FD=''
LOGFILE=''
RED='' GREEN='' YELLOW='' BLUE='' CYAN='' MAGENTA='' BOLD='' DIM='' RESET=''

author_note() { printf '%s\n' 'VPSKit: 本地管理工具，不修改SSH、不创建用户、不清空防火墙；可显式管理端口。'; }
colors() {
    if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR:-} && $NO_COLOR_FLAG == 0 ]]; then
        RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[94m'; CYAN=$'\033[96m'; MAGENTA=$'\033[95m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
    fi
}
log() {
    local level=$1 color=$2; shift 2
    printf '%s[%s] [%s] %s%s\n' "$color" "$(date '+%F %T')" "$level" "$*" "$RESET" >&2
    if [[ -n $LOGFILE && -d ${LOGFILE%/*} ]]; then
        printf '[%s] [%s] %s\n' "$(date '+%F %T')" "$level" "$*" >> "$LOGFILE"
    fi
}
info() { log INFO "$BLUE" "$@"; }
ok() { log OK "$GREEN" "$@"; }
warn() { log WARN "$YELLOW" "$@"; }
die() { log ERROR "$RED" "$@"; exit 1; }
run() {
    # Do not pass credentials to this logger; credential commands use their own output policy.
    info "执行: $1"
    if [[ -n $LOGFILE ]]; then "$@" 2>&1 | tee -a "$LOGFILE"; else "$@"; fi
}
ask() {
    local var=$1 label=$2 default=${3:-} _reply
    [[ -n $TTY_FD ]] || die '此操作需要终端。使用交互菜单，或先运行 vpskit help。'
    printf '%s%s%s' "$BLUE" "$label" "$RESET" >&2
    [[ -z $default ]] || printf ' [%s]' "$default" >&2
    printf ': ' >&2
    IFS= read -r -u "$TTY_FD" _reply || die '输入已关闭。'
    if [[ $_reply == :q ]]; then warn '已取消本次操作；已保存的偏好保留。'; exit 130; fi
    _reply=${_reply:-$default}
    printf -v "$var" '%s' "$_reply"
}
secret() {
    local var=$1 label=$2 hint=${3:-留空自动生成} answer
    [[ -n $TTY_FD ]] || die '需要终端输入凭据。'
    printf '%s（%s；:q取消）: ' "$label" "$hint" >&2
    IFS= read -r -s -u "$TTY_FD" answer || die '输入已关闭。'
    printf '\n' >&2
    if [[ $answer == :q ]]; then warn '已取消本次操作。'; exit 130; fi
    printf -v "$var" '%s' "$answer"
}
confirm() {
    local answer
    ask_valid answer "$1；输入 yes 确认" no valid_choice '请输入yes或no。' 'yes no'
    [[ $answer == yes ]]
}

validate_cli() {
    local cmd=${1:-menu} sub=${2:-}
    case "$cmd" in
        help|--help|-h|version|--version|explain|selftest|menu|status|paths|doctor|repair|rollback|maintenance)
            (($#<=1)) || die '此命令不接受额外参数。';;
        install|update|uninstall|logs|site|cert|optimize|wizard|firewall|swap) (($#<=2)) || die '额外参数不支持；参数由交互向导收集。';;
        service) (($#==3)) || die '用法: vpskit service start|stop|restart xray|nginx';;
        node)
            (($#<=3)) || die '节点参数由交互向导收集，不支持额外选项。'
            if [[ $sub == add || $sub == list ]]; then (($#<=2)) || die '用法: vpskit node add 或 node list'; fi;;
    esac
}
valid_domain() {
    local d=$1 part
    [[ ${#d} -le 253 && $d == *.* && $d != *..* && $d != .* && $d != *. ]] || return 1
    [[ $d =~ ^[a-z0-9.-]+$ && ! $d =~ ^[0-9.]+$ ]] || return 1
    local -a labels; IFS=. read -r -a labels <<< "$d"
    for part in "${labels[@]}"; do
        [[ ${#part} -le 63 && $part =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
    done
}
valid_host() {
    valid_domain "$1" && return 0
    local part octets
    if [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        IFS=. read -r -a octets <<< "$1"
        for part in "${octets[@]}"; do ((10#$part<=255)) || return 1; done
        return 0
    fi
    [[ $1 =~ ^[0-9a-fA-F:]+$ && $1 == *:* && $1 != *:::* ]] || return 1
    [[ $1 != :* || $1 == ::* ]] || return 1
    [[ $1 != *: || $1 == *:: ]] || return 1
    # getent with AI_NUMERICHOST is unavailable in shell; use a bounded IPv6 syntax check.
    local rest=$1 doubles=0 count=0
    if [[ $rest == *::* ]]; then
        rest=${rest/::/X}; [[ $rest != *::* ]] || return 1; doubles=1
        rest=${rest/X/:}
    fi
    IFS=: read -r -a octets <<< "$rest"
    for part in "${octets[@]}"; do
        [[ -z $part ]] && continue
        [[ $part =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
        count=$((count+1))
    done
    if ((doubles)); then ((count<8)); else [[ $1 != :* && $1 != *: ]] && ((count==8)); fi
}
valid_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 > 0 && 10#$1 < 65536)); }
valid_uuid() { [[ $1 =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
valid_name() { [[ $1 =~ ^[a-zA-Z0-9_-]{1,48}$ ]]; }
valid_ws_path() { [[ $1 =~ ^/[a-zA-Z0-9_-]{8,80}$ && $1 != /\.well-known* ]]; }
valid_upstream() { [[ -z $1 || $1 =~ ^http://127\.0\.0\.1:([0-9]{1,5})$ ]] && { [[ -z $1 ]] || valid_port "${1##*:}"; }; }
# Input errors are recoverable; :q cancels the current action, keeping saved defaults.
ask_valid() {
    local av_dest=$1 av_label=$2 av_default=$3 av_validator=$4 av_hint=$5 av_value
    shift 5
    while :; do
        ask av_value "$av_label" "$av_default"
        av_value=${av_value#"${av_value%%[![:space:]]*}"}
        av_value=${av_value%"${av_value##*[![:space:]]}"}
        case "$av_validator" in valid_domain|valid_host|valid_scheme) av_value=${av_value,,};; esac
        if "$av_validator" "$av_value" "$@"; then printf -v "$av_dest" '%s' "$av_value"; return 0; fi
        warn "$av_hint 请重新输入，或输入 :q 取消本次操作。"
    done
}
valid_choice() { [[ -n $1 && $1 != *[[:space:]]* && " $2 " == *" $1 "* ]]; }
valid_scheme() { [[ $1 == a || $1 == b ]]; }
valid_email() {
    local email_domain=${1#*@}
    [[ ${#1} -le 254 && $1 =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] && valid_domain "${email_domain,,}"
}
valid_version() { [[ $1 == latest || $1 =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
valid_proxy_upstream() {
    [[ -n $1 ]] && valid_upstream "$1" || return 1
    local upstream_port=${1##*:}
    ((10#$upstream_port != 80 && 10#$upstream_port != 443))
}
valid_redirect() {
    local url=$1 host_part
    [[ $url =~ ^https://[a-z0-9.-]+(/[a-zA-Z0-9._~/%?\&=+#-]*)?$ ]] || return 1
    host_part=${url#https://}; host_part=${host_part%%/*}
    valid_domain "$host_part" && [[ $host_part != "${2:-}" ]]
}
valid_new_node_name() {
    valid_name "$1" || return 1
    ! jq -e --arg n "$1" --arg old "${2:-}" '.nodes[]|select(.id==$n and .id!=$old)' "$STATE" >/dev/null
}
valid_existing_node() { valid_name "$1" && jq -e --arg n "$1" '.nodes[]|select(.id==$n)' "$STATE" >/dev/null; }
valid_share_node() {
    [[ -n $1 ]] || return 0
    valid_name "$1" && jq -e --arg n "$1" '.nodes[]|select(.id==$n and .protocol!="shadowsocks")' "$STATE" >/dev/null
}
valid_node_port() {
    valid_port "$1" || return 1
    local p=$((10#$1)) except=${2:-}
    [[ $p != 22 && $p != 80 && $p != 443 ]] || return 1
    ! jq -e --argjson p "$p" --arg e "$except" '.nodes[]|select(.port==$p and .entry!=$e)' "$STATE" >/dev/null
}
ask_node_port() {
    local np_dest=$1 np_label=$2 np_default=$3 np_except=${4:-} np_value np_choice
    while :; do
        ask_valid np_value "$np_label" "$np_default" valid_node_port '端口应为1～65535，避开22/80/443及已保留节点端口。' "$np_except"
        np_value=$((10#$np_value))
        # A retained entry can keep its own current listener. Final checks still
        # run inside the transaction, where stopped external services can recover.
        if [[ -n $np_except ]] && jq -e --arg e "$np_except" --argjson p "$np_value" '.nodes[]|select(.entry==$e and .port==$p)' "$STATE" >/dev/null; then
            printf -v "$np_dest" '%s' "$np_value"; return 0
        fi
        if port_free "$np_value"; then printf -v "$np_dest" '%s' "$np_value"; return 0; fi
        warn "端口 $np_value 当前有程序监听。"
        port_lines "$np_value" >&2
        ask_valid np_choice '1=重新输入端口，2=保留此端口并在应用时确认清理占用' 1 valid_choice '请选择1或2。' '1 2'
        if [[ $np_choice == 2 ]]; then printf -v "$np_dest" '%s' "$np_value"; return 0; fi
    done
}
valid_new_ws_path() {
    valid_ws_path "$1" || return 1
    ! jq -e --arg p "$1" --arg d "${2:-}" '.nodes[]|select(.path==$p and .domain==$d)' "$STATE" >/dev/null
}

# UI preferences are saved before configuration transactions. A failed install
# can roll back its runtime files while retaining already accepted answers.
init_preferences() {
    if jq -e '.ui_version==2' "$STATE" >/dev/null; then return 0; fi
    local inferred_host; inferred_host=$(get '.host // ""')
    valid_domain "$inferred_host" || inferred_host=''
    json_update --arg h "$inferred_host" '
      (.sites[0] // {}) as $s |
      .preferences = ({domain:($s.domain // $h),email:($s.email // ""),challenge:($s.challenge // "http"),wildcard:($s.wildcard // false),
        site_kind:(if ($s|length)==0 then "template" elif ($s.upstream // "")!="" then "proxy" else "custom" end),
        site_access:($s.access // (if ($s|length)>0 then "direct" elif .scheme=="B" then "cloudflare" else "direct" end)),template:"welcome",upstream:($s.upstream // ""),redirect:"https://www.microsoft.com/",reality_target:"www.microsoft.com",protocol:"vless"} + (.preferences // {})) |
      .wizard = ({selected:((.scheme=="B") or (.sites|length)>0 or (.nodes|length)>0 or (.components.xray // false)),
        website:((.scheme=="B") or (.sites|length)>0 or ((.nodes|length)==0)),domain:($s.domain // $h),defaults_ready:true,last_step:"",last_result:""} + (.wizard // {})) |
      .ui_version=2'
}
remember_domain() { json_update --arg d "$1" '.preferences.domain=$d'; }
default_domain() {
    local d
    d=$(get '[.preferences.domain,.wizard.domain,.sites[0].domain,.host]|map(select(type=="string" and length>0))|.[0] // ""')
    if valid_domain "$d"; then printf '%s' "$d"; fi
}
component_ready() {
    local file
    case "$1" in xray) file=$XRAY;; nginx) file=$NGINX;; acme) file=$ACME;; *) return 1;; esac
    [[ $(get ".components.$1 // false") == true && -x $file ]]
}
plan_needs_site() { [[ $(get .scheme) == B || $(get '.wizard.website != false') == true ]]; }
plan_nodes() {
    jq -r --arg enabled "${1:-all}" '. as $s | .nodes[] | select(($enabled!="enabled" or .enabled) and
      (if $s.scheme=="A" then (.protocol=="vless" and .mode=="reality" and .host==$s.host)
       else (.mode=="ws" and .domain==($s.wizard.domain // $s.preferences.domain // "")) end)) | .id' "$STATE"
}
certificate_good() {
    local d=$1
    valid_domain "$d" || return 1
    jq -e --arg d "$d" '.sites[]|select(.domain==$d and .issued)' "$STATE" >/dev/null || return 1
    [[ -s $ROOT/certs/$d/current/fullchain.pem && -s $ROOT/certs/$d/current/key.pem ]] || return 1
    openssl x509 -in "$ROOT/certs/$d/current/fullchain.pem" -noout -checkend 0 >/dev/null 2>&1 &&
      openssl x509 -in "$ROOT/certs/$d/current/fullchain.pem" -noout -checkhost "$d" >/dev/null 2>&1
}
certificate_ready() {
    certificate_good "$1" && ! jq -e --arg d "$1" '.sites[]|select(.domain==$d and .cert_settings_pending==true)' "$STATE" >/dev/null
}
remember_step() {
    WIZARD_STEP=$1
    json_update --arg s "$1" --arg r "${2:-进行中}" '.wizard.last_step=$s | .wizard.last_result=$r'
    info "部署步骤：$1；已完成的步骤会自动跳过。"
}

new_uuid() { cat /proc/sys/kernel/random/uuid; }
randhex() { openssl rand -hex "${1:-16}"; }
get() { jq -r "$1" "$STATE"; }
json_update() {
    jq "$@" "$STATE" > "$ROOT/data/state.new"
    chmod 600 "$ROOT/data/state.new"
    mv -f "$ROOT/data/state.new" "$STATE"
}
fetch() {
    local url=$1 dest=$2
    [[ $url == https://* ]] || die '下载地址必须是HTTPS。'
    info "下载: $url"
    curl --proto '=https' --proto-redir '=https' -fSL --connect-timeout 15 --max-time 300 --retry 2 --retry-delay 2 -o "$dest" "$url"
    [[ -s $dest ]] || die '下载结果为空。'
}
check_root() { ((EUID == 0)) || die '需要root权限。请先 sudo -i，再执行一键命令；或 sudo bash ./vpskit.sh。'; }
detect_system() {
    [[ -r /etc/os-release ]] || die '无法识别系统。'
    # os-release also assigns VERSION (e.g. "13 (trixie)"). Keep it local:
    # the manager VERSION must survive system detection for self-persistence.
    local ID='' VERSION_ID='' VERSION=''
    # OS-owned metadata, never source our JSON state or user input.
    . /etc/os-release
    case "$ID" in debian) (( ${VERSION_ID%%.*} >= 12 )) || die '需要Debian 12或更新版本。';; ubuntu) (( ${VERSION_ID%%.*} >= 18 )) || die '需要Ubuntu 18.04或更新版本。';; *) die "已检测到 $ID；本版本仅支持Debian/Ubuntu，未修改系统。";; esac
    (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) || die '需要Bash 4.4或更新版本。'
    [[ -d /run/systemd/system ]] || die '需要以systemd为PID 1的VPS；不支持普通Docker/无systemd容器。'
    command -v apt-get >/dev/null || die '缺少apt-get。'
    command -v flock >/dev/null || die '需要系统自带util-linux/flock。'
    case "$(uname -m)" in x86_64) ARCH='64';; aarch64|arm64) ARCH='arm64-v8a';; *) die '仅支持amd64/arm64。';; esac
    export ARCH
    info "系统: $ID $VERSION_ID / $(uname -m)；有效账户: $(id -un)"
    [[ $(id -un) == root ]] || die '此版本只支持root安装与运行，不创建其他账户。'
}
safe_root() {
    [[ ! -L /opt && ! -L $ROOT ]] || die '安装路径为符号链接，拒绝写入。'
    if [[ -e $ROOT ]]; then
        [[ ! -L $ROOT/.vpskit-owned && -f $ROOT/.vpskit-owned && $(cat "$ROOT/.vpskit-owned") == VPSKIT_V1 ]] || die "$ROOT 已存在但不属于本工具，保留并停止。"
        [[ $(stat -c %u "$ROOT") == 0 && $(stat -c %a "$ROOT") == 700 ]] || die '安装根目录必须归root所有且权限700。'
        local p
        for p in bin config data certs acme www logs backup tmp run nginx; do
            [[ ! -L $ROOT/$p ]] || die "异常符号链接: $ROOT/$p"
        done
    else
        mkdir -m 700 "$ROOT"
        printf 'VPSKIT_V1\n' > "$ROOT/.vpskit-owned"
    fi
    mkdir -p "$ROOT"/{bin,config,data,certs,acme,www,logs,backup,tmp,run,nginx}
    exec {LOCK_FD}> "$ROOT/run/manage.lock"
    flock -w 5 "$LOCK_FD" || die '另一个管理或续期任务正在运行，请稍后再试。'
    HAVE_LOCK=1
    # Only this private transient tree is disposable, never certificates/site files.
    find "$ROOT/tmp" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    WORK=$(mktemp -d "$ROOT/tmp/job.XXXXXXXX")
    LOGFILE="$ROOT/logs/manage.log"
    rotate_logs
    if [[ ! -e $ROOT/data/packages.before ]]; then
        dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' | awk '$2=="installed"{print $1}' | sort -u > "$ROOT/data/packages.before"
    fi
}
rotate_logs() {
    local f
    for f in "$ROOT"/logs/*.log; do
        [[ -f $f && ! -L $f ]] || continue
        if (( $(stat -c %s "$f") > 2097152 )); then
            cp -- "$f" "$f.1"
            : > "$f"
        fi
    done
}
record_packages() {
    dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' | awk '$2=="installed"{print $1}' | sort -u > "$ROOT/data/packages.now"
    comm -13 "$WORK/packages.pre" "$ROOT/data/packages.now" > "$WORK/packages.delta"
    touch "$ROOT/data/packages.added"
    cat "$ROOT/data/packages.added" "$WORK/packages.delta" | sort -u > "$WORK/packages.union"
    mv "$WORK/packages.union" "$ROOT/data/packages.added"
}
install_deps() {
    local -a need=("$@") proposed=(); local cmd pkg d
    for cmd in curl jq openssl unzip ss free sysctl; do
        if ! command -v "$cmd" >/dev/null; then
            case "$cmd" in ss) pkg=iproute2;; free|sysctl) pkg=procps;; *) pkg=$cmd;; esac
            need+=("$pkg")
        fi
    done
    [[ -s /etc/ssl/certs/ca-certificates.crt ]] || need+=(ca-certificates)
    ((${#need[@]})) || return 0
    dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' | awk '$2=="installed"{print $1}' | sort -u > "$WORK/packages.pre"
    info '预检查依赖包，拒绝包含新增系统账户操作的维护脚本。'
    run apt-get update
    local cache="$WORK/apt-cache"
    mkdir -p "$cache/partial"
    run apt-get -o "Dir::Cache::archives=$cache" --download-only --no-install-recommends -y install "${need[@]}"
    for d in "$cache"/*.deb; do
        [[ -f $d ]] || continue
        mkdir -p "$WORK/control"; dpkg-deb -e "$d" "$WORK/control"
        if grep -ERq '(^|[^[:alnum:]_])(adduser|useradd|addgroup|groupadd|systemd-sysusers)([^[:alnum:]_]|$)' "$WORK/control"; then
            die "依赖包可能创建账户，已在安装前停止: ${d##*/}。请先准备必要系统依赖。"
        fi
        rm -rf "$WORK/control"
    done
    # Install exactly downloaded versions; no second network resolution race.
    for d in "$cache"/*.deb; do [[ ! -f $d ]] || proposed+=("$d"); done
    ((${#proposed[@]})) && run apt-get --no-download --no-install-recommends -y install "${proposed[@]}"
    record_packages
    for cmd in curl jq openssl unzip ss free sysctl; do command -v "$cmd" >/dev/null || die "依赖缺失: $cmd"; done
}
init_state() {
    [[ ! -L $STATE ]] || die '状态文件不能是符号链接。'
    [[ -f $STATE ]] && { jq -e '.schema == 1 and (.nodes|type=="array") and (.sites|type=="array")' "$STATE" >/dev/null || die '状态损坏，保留资料，请恢复备份。'; return; }
    jq -n --arg version "$VERSION" '{schema:1,manager:$version,scheme:"A",host:"",performance:{gzip:false},components:{xray:false,nginx:false,acme:false},versions:{},nodes:[],sites:[]}' > "$STATE"
}

# Ubuntu 18/20 Nginx predates -e (1.19.5). Old bootstrap diagnostics go to
# stderr; configured runtime logs remain inside ROOT. Do not create /var/log/nginx.
nginx_cmd() {
    local help
    help=$("$NGINX" -h 2>&1 || true)
    local -a args=()
    [[ $help != *'-e filename'* ]] || args=(-e "$ROOT/logs/nginx.log")
    "$NGINX" "${args[@]}" "$@"
}
nginx_tls_protocols() {
    local build
    build=$("$NGINX" -V 2>&1 || true)
    # Prefer the runtime OpenSSL version when Nginx reports both versions.
    if [[ $build == *'running with OpenSSL '* ]]; then build=${build##*running with OpenSSL }; else build=${build#*built with OpenSSL }; fi
    if [[ $build =~ ^(1\.1\.1|[3-9]\.) ]]; then printf 'TLSv1.2 TLSv1.3'; else printf 'TLSv1.2'; fi
}
service_runner() {
    check_root
    [[ -f $ROOT/.vpskit-owned && $(cat "$ROOT/.vpskit-owned") == VPSKIT_V1 && ! -L $ROOT ]] || die '服务根目录验证失败。'
    # Bash redirection works on systemd 237; append: needs systemd 240+.
    # These internal entry points intentionally do not acquire the manager lock.
    case "$1" in
        xray) exec "$XRAY" run -config "$ROOT/config/xray.json" >> "$ROOT/logs/xray.log" 2>&1;;
        nginx-test) nginx_cmd -t -p "$ROOT/" -c "$ROOT/config/nginx.conf" >> "$ROOT/logs/nginx-service.log" 2>&1;;
        nginx-reload) nginx_cmd -p "$ROOT/" -c "$ROOT/config/nginx.conf" -s reload >> "$ROOT/logs/nginx-service.log" 2>&1;;
        nginx)
            local help; help=$("$NGINX" -h 2>&1 || true)
            local -a args=(); [[ $help != *'-e filename'* ]] || args=(-e "$ROOT/logs/nginx.log")
            exec "$NGINX" "${args[@]}" -p "$ROOT/" -c "$ROOT/config/nginx.conf" -g 'daemon off;' >> "$ROOT/logs/nginx-service.log" 2>&1;;
        *) die '无效的内部服务命令。';;
    esac
}
persist_self() {
    local src=${BASH_SOURCE[0]} stage="$WORK/vpskit.sh" existing
    if [[ -f $src && $src != /dev/fd/* && $src != /proc/* ]]; then
        cp -- "$src" "$stage"
    else
        fetch "$SELF_URL" "$stage"
        grep -Fxq "VERSION='$VERSION'" "$stage" || die '远程落地版本与当前版本不同；请下载到本地后重新运行。'
    fi
    bash -n "$stage"
    grep -Fq 'VPSKIT_SINGLE_FILE' "$stage" || die '不是有效的VPSKit脚本。'
    if [[ -e $ENTRY || -L $ENTRY ]]; then
        existing=$(readlink "$ENTRY" || true)
        [[ $existing == "$ROOT/vpskit.sh" ]] || die "$ENTRY 已被其他程序使用。"
    fi
    install -m 700 "$stage" "$ROOT/vpskit.sh.new"
    mv -f "$ROOT/vpskit.sh.new" "$ROOT/vpskit.sh"
    ln -sfn "$ROOT/vpskit.sh" "$ENTRY"
}
unit_write() {
    local name=$1 path="$SYSTEMD/$1"
    [[ ! -L $path ]] || die "服务文件为符号链接: $path"
    if [[ -e $path ]]; then grep -Fq '# VPSKIT_OWNED' "$path" || die "同名外部服务存在: $path"; fi
    cat > "$path"
    chmod 644 "$path"
}
write_units() {
    unit_write vpskit-xray.service <<EOF
# VPSKIT_OWNED
[Unit]
Description=VPSKit Xray
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
WorkingDirectory=$ROOT
ExecStart=/bin/bash $ROOT/vpskit.sh _service xray
Restart=on-failure
RestartSec=5
TimeoutStopSec=20
LimitNOFILE=8192
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$ROOT
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
StandardOutput=null
StandardError=null
[Install]
WantedBy=multi-user.target
EOF
    unit_write vpskit-nginx.service <<EOF
# VPSKIT_OWNED
[Unit]
Description=VPSKit isolated Nginx
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
ExecStartPre=/bin/bash $ROOT/vpskit.sh _service nginx-test
ExecStart=/bin/bash $ROOT/vpskit.sh _service nginx
ExecReload=/bin/bash $ROOT/vpskit.sh _service nginx-reload
KillSignal=SIGQUIT
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$ROOT
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_SETUID CAP_SETGID
StandardOutput=null
StandardError=null
[Install]
WantedBy=multi-user.target
EOF
    unit_write vpskit-maintain.service <<EOF
# VPSKIT_OWNED
[Unit]
Description=VPSKit certificate renewal and log maintenance
After=network-online.target
[Service]
Type=oneshot
User=root
ExecStart=$ENTRY maintenance
TimeoutStartSec=30min
Nice=10
UMask=0077
EOF
    unit_write vpskit-maintain.timer <<'EOF'
# VPSKIT_OWNED
[Unit]
Description=VPSKit scheduled certificate and log check
[Timer]
OnCalendar=hourly
RandomizedDelaySec=600
Persistent=true
[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now vpskit-maintain.timer
}

# Transactions contain only files owned by VPSKit. Existing websites are never snapshotted/deleted.
begin_tx() {
    ((TX == 0)) || die '禁止嵌套事务。'
    local tx="$ROOT/backup/transaction" part u
    [[ ! -e $tx ]] || die '检测到待恢复事务，请先执行 vpskit repair。'
    mkdir -p "$tx/tree" "$tx/units"
    for part in bin nginx config certs acme; do cp -a "$ROOT/$part" "$tx/tree/"; done
    cp "$STATE" "$tx/state.json"
    for u in vpskit-xray.service vpskit-nginx.service vpskit-maintain.service vpskit-maintain.timer; do
        if [[ -e $SYSTEMD/$u ]]; then cp -a "$SYSTEMD/$u" "$tx/units/"; fi
        if systemctl is-active --quiet "$u"; then printf '%s\n' "$u" >> "$tx/active"; fi
        if systemctl is-enabled --quiet "$u" 2>/dev/null; then printf '%s\n' "$u" >> "$tx/enabled"; fi
    done
    : > "$tx/stopped-external"
    printf 'ready\n' > "$tx/ready"
    TX=1
}
restore_tx() {
    local tx=$1 part u failed=0
    [[ -f $tx/ready && -f $tx/state.json ]] || { warn '事务快照未完成；未替换正式配置，可清理该暂存目录。'; return 1; }
    warn '恢复操作前的程序、配置、证书和服务状态。'
    systemctl stop vpskit-xray.service vpskit-nginx.service 2>/dev/null || true
    for part in bin nginx config certs acme; do
        [[ -d $tx/tree/$part ]] || return 1
        rm -rf -- "${ROOT:?}/$part"
        cp -a "$tx/tree/$part" "$ROOT/" || failed=1
    done
    cp "$tx/state.json" "$STATE" || failed=1
    for u in vpskit-xray.service vpskit-nginx.service vpskit-maintain.service vpskit-maintain.timer; do
        if [[ -e $tx/units/$u ]]; then
            cp -a "$tx/units/$u" "$SYSTEMD/$u" || failed=1
        elif [[ -e $SYSTEMD/$u ]] && grep -Fq '# VPSKIT_OWNED' "$SYSTEMD/$u"; then
            systemctl disable --now "$u" 2>/dev/null || true
            rm -f "$SYSTEMD/$u"
        fi
    done
    systemctl daemon-reload || failed=1
    for u in vpskit-xray.service vpskit-nginx.service vpskit-maintain.service vpskit-maintain.timer; do
        if [[ -e $SYSTEMD/$u ]] && { [[ ! -f $tx/enabled ]] || ! grep -Fxq "$u" "$tx/enabled"; }; then
            systemctl disable "$u" >/dev/null 2>&1 || true
        fi
    done
    if [[ -f $tx/enabled ]]; then while read -r u; do systemctl enable "$u" >/dev/null 2>&1 || failed=1; done < "$tx/enabled"; fi
    if [[ -f $tx/active ]]; then while read -r u; do systemctl start "$u" || failed=1; done < "$tx/active"; fi
    while read -r u; do [[ -z $u ]] || systemctl start "$u" || failed=1; done < "$tx/stopped-external"
    ((failed == 0))
}
commit_tx() {
    ((TX == 1)) || die '没有待提交事务。'
    rm -rf "$ROOT/backup/last"
    mv "$ROOT/backup/transaction" "$ROOT/backup/last"
    TX=0
    ok '配置已验证并提交；保留一个回滚快照。'
}
on_exit() {
    local rc=$?
    trap - EXIT ERR INT TERM
    set +e
    if [[ $HAVE_LOCK == 1 && $PANEL_IDLE == 0 && -d $ROOT/backup/tuning-transaction ]]; then
        tuning_recover || { warn "网络调优恢复失败；保留快照，请执行 vpskit repair。"; rc=1; }
    fi
    if ((TX == 1 && UNINSTALLING == 0)); then
        if restore_tx "$ROOT/backup/transaction"; then
            rm -rf "$ROOT/backup/transaction"
        else
            warn "恢复不完整，保留 $ROOT/backup/transaction，执行 vpskit repair。"
        fi
    fi
    if ((WIZARD_ACTIVE == 1 && HAVE_LOCK == 1 && rc != 0)) && [[ -f $STATE ]]; then
        json_update --arg s "$WIZARD_STEP" --arg r "中断/失败（退出码 $rc），可继续" '.wizard.last_step=$s | .wizard.last_result=$r' || true
    fi
    [[ -z $WORK || ! -d $WORK ]] || rm -rf -- "$WORK"
    if ((rc != 0)); then warn "操作未完成，退出码 $rc。现有外部网站和SSH没有被自动删除。"; fi
    exit "$rc"
}
on_error() { local rc=$1 line=$2; log ERROR "$RED" "步骤失败，行 $line，退出码 $rc（不打印可能含凭据的命令）。"; exit "$rc"; }
recover() {
    tuning_recover || die '网络调优恢复未完成，保留快照。'
    local tx="$ROOT/backup/transaction"
    if [[ -d $tx ]]; then
        if [[ ! -f $tx/ready ]]; then
            rm -rf "$tx"
            warn '清理未完成的快照；该阶段尚未变更正式配置。'
        elif restore_tx "$tx"; then
            rm -rf "$tx"; ok '已自动恢复上次中断操作。'
        else die '自动恢复失败，请检查 service 日志和事务目录。'; fi
    fi
}

# Port handling is explicit and scoped. A force kill is never a hidden side effect.
port_lines() { ss -H -lntup "sport = :$1" 2>/dev/null; }
port_free() { [[ -z $(port_lines "$1") ]]; }
protected_pid() {
    local p=$1 cur=$$ exe
    ((p > 1)) || return 0
    while ((cur > 1)); do
        [[ $p == "$cur" ]] && return 0
        cur=$(awk '/^PPid:/{print $2}' "/proc/$cur/status" 2>/dev/null || printf 1)
        [[ $cur =~ ^[0-9]+$ ]] || break
    done
    exe=$(readlink "/proc/$p/exe" 2>/dev/null || true)
    case "${exe##*/}" in sshd|systemd|init|docker*|containerd*|apt*|dpkg*|dbus-daemon|systemd-resolved) return 0;; esac
    return 1
}
pid_identity() {
    local st
    st=$(cat "/proc/$1/stat") || return 1
    printf '%s %s\n' "$(printf '%s\n' "${st##*) }" | awk '{print $20}')" "$(readlink "/proc/$1/exe")"
}
release_port() {
    local port=$1 lines p unit identity answer
    local -a pids
    lines=$(port_lines "$port")
    printf '%s\n' "$lines" >&2
    mapfile -t pids < <(printf '%s\n' "$lines" | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)
    ((${#pids[@]})) || die '无法识别占用者；请手工处理或更换端口。'
    for p in "${pids[@]}"; do
        protected_pid "$p" && die "PID $p 为管理链路或关键服务，禁止强制清理。"
        [[ -r /proc/$p/stat ]] || continue
        identity=$(pid_identity "$p")
        unit=$(grep -oE '[^/]+\.service' "/proc/$p/cgroup" | tail -1 || true)
        if [[ -n $unit ]]; then
            case "$unit" in ssh*|systemd-*|docker*|containerd*|dbus*|vpskit-*) die "拒绝抢占关键/本工具服务 $unit；请使用相应管理功能。";; esac
            info "端口 $port 属于 $unit (PID $p)"
            confirm "停止 $unit，可能影响其现有业务" || die '已取消端口清理。'
            [[ -r /proc/$p/stat && $(pid_identity "$p") == "$identity" ]] || die '进程状态发生变化，请重试检测。'
            printf '%s\n' "$unit" >> "$ROOT/backup/transaction/stopped-external"
            systemctl stop "$unit"
        else
            warn "PID $p 不属于可恢复的systemd服务；终止后不能自动重建它。"
            confirm "向明确的PID $p 发送TERM" || die '已取消。'
            [[ -r /proc/$p/stat ]] || continue
            protected_pid "$p" && die '进程归属变化，取消清理。'
            [[ $(pid_identity "$p") == "$identity" ]] || die 'PID已重用，取消操作。'
            kill -TERM "$p"
            local tries
            for ((tries=0; tries<20; tries++)); do [[ -e /proc/$p ]] || break; sleep 0.25; done
            if [[ -e /proc/$p ]]; then
                ask answer "进程仍在运行；输入 KILL-$p 才强制终止" ''
                [[ $answer == "KILL-$p" ]] || die '未强制终止；请更换端口。'
                protected_pid "$p" && die '拒绝终止受保护进程。'
                [[ $(pid_identity "$p") == "$identity" ]] || die 'PID已重用，取消操作。'
                kill -KILL "$p"
            fi
        fi
    done
    sleep 0.3
    port_free "$port" || die "端口 $port 仍被占用；本次操作取消。"
}
check_port() {
    local port=$1 own=${2:-false} choice
    valid_port "$port" || die '端口必须为1～65535。'
    [[ $port != 22 ]] || die '不允许使用22作为代理端口。'
    if [[ $own == true ]]; then
        local pl pid all_owned=true
        pl=$(port_lines "$port")
        if [[ -z $pl ]]; then return 0; fi
        local -a owner_pids
        mapfile -t owner_pids < <(printf '%s\n' "$pl" | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)
        ((${#owner_pids[@]})) || all_owned=false
        for pid in "${owner_pids[@]}"; do
            if ! grep -Fq '/vpskit-nginx.service' "/proc/$pid/cgroup"; then all_owned=false; fi
        done
        [[ $all_owned != true ]] || return 0
    fi
    port_free "$port" && return 0
    warn "端口 $port 被占用（TCP/UDP、IPv4/IPv6均检查）。"
    port_lines "$port" >&2
    ask_valid choice '1=取消并改端口，2=查看并释放明确占用者' '1' valid_choice '请选择1或2。' '1 2'
    [[ $choice == 2 ]] || die '端口冲突，未修改服务。'
    ((TX == 1)) || die '端口释放必须处于可恢复事务中。'
    release_port "$port"
}
next_port() {
    local p=${1:-20000}
    while ((p < 65000)); do
        if port_free "$p" && ! jq -e --argjson p "$p" '.nodes[]|select(.port==$p)' "$STATE" >/dev/null; then printf '%s\n' "$p"; return; fi
        p=$((p+1))
    done
    die '没有找到可用端口。'
}

latest_release() {
    local repo=$1 out=$2
    fetch "https://api.github.com/repos/$repo/releases/latest" "$out"
    jq -er '.tag_name | select(test("^[A-Za-z0-9._-]+$"))' "$out"
}
install_xray() {
    local ver=${1:-$XRAY_TESTED_VERSION} asset url sha expected archive="$WORK/xray.zip" meta="$WORK/xray-release.json"
    case "$(uname -m)" in x86_64) asset=Xray-linux-64.zip;; aarch64|arm64) asset=Xray-linux-arm64-v8a.zip;; *) die '架构不支持。';; esac
    if [[ $ver == latest ]]; then ver=$(latest_release XTLS/Xray-core "$meta"); else
        [[ $ver =~ ^v[0-9.]+$ ]] || die 'Xray版本格式应为v数字.数字.数字。'
        fetch "https://api.github.com/repos/XTLS/Xray-core/releases/tags/$ver" "$meta"
    fi
    url=$(jq -er --arg n "$asset" '.assets[]|select(.name==$n)|.browser_download_url' "$meta")
    fetch "$url" "$archive"
    expected=$(jq -r --arg n "$asset" '.assets[]|select(.name==$n)|.digest // empty' "$meta")
    if [[ $expected == sha256:* ]]; then
        sha=${expected#sha256:}
    else
        fetch "$url.dgst" "$WORK/xray.dgst"
        sha=$(grep -Ei 'sha(2[-_])?256' "$WORK/xray.dgst" | grep -oE '[a-fA-F0-9]{64}' | head -1 || true)
    fi
    [[ $sha =~ ^[a-fA-F0-9]{64}$ ]] || die '没有找到有效SHA256摘要，拒绝安装。'
    printf '%s  %s\n' "$sha" "$archive" | sha256sum -c -
    unzip -p "$archive" xray > "$ROOT/bin/xray.new"
    chmod 700 "$ROOT/bin/xray.new"
    "$ROOT/bin/xray.new" version
    mv -f "$ROOT/bin/xray.new" "$XRAY"
    json_update --arg v "$ver" '.components.xray=true | .versions.xray=$v'
    ok "Xray $ver 已安装（同源摘要校验，不等同独立签名验证）。"
}
install_nginx() {
    local pkg file found=0 dir="$WORK/nginx-download" ver
    mkdir -p "$dir"
    run apt-get update
    # Extract distro's signed-repository packages, never execute nginx postinst/user creation.
    for pkg in nginx nginx-light nginx-core; do
        if ! apt-cache show "$pkg" >/dev/null 2>&1; then continue; fi
        info "下载发行版 $pkg 包，不执行维护脚本。"
        if ! (cd "$dir" && apt-get download "$pkg"); then continue; fi
        for file in "$dir"/*.deb; do
            [[ -f $file ]] || continue
            mkdir -p "$WORK/nginx-extract"
            dpkg-deb -x "$file" "$WORK/nginx-extract"
            if [[ -x $WORK/nginx-extract/usr/sbin/nginx ]]; then
                ver=$(dpkg-deb -f "$file" Version)
                found=1; break
            fi
        done
        ((found == 0)) || break
        rm -f "$dir"/*.deb
    done
    ((found == 1)) || die '发行版包中未找到Nginx二进制。'
    local soname; local -a libs=()
    while read -r soname; do
        case "$soname" in
            libpcre.so.3) libs+=(libpcre3);; libpcre2-8.so.0) libs+=(libpcre2-8-0);;
            libssl.so.1.1|libcrypto.so.1.1) libs+=(libssl1.1);;
            libssl.so.1.0.0|libcrypto.so.1.0.0) libs+=(libssl1.0.0);;
            libz.so.1) libs+=(zlib1g);; libcrypt.so.1) libs+=(libcrypt1);;
            libGeoIP.so.1) libs+=(libgeoip1);;
            *) die "未识别的Nginx共享库依赖 $soname，请用系统包管理器准备该库。";;
        esac
    done < <(ldd "$WORK/nginx-extract/usr/sbin/nginx" | awk '/not found/{print $1}')
    if ((${#libs[@]})); then install_deps "${libs[@]}"; fi
    if ldd "$WORK/nginx-extract/usr/sbin/nginx" | grep -q 'not found'; then die 'Nginx共享库仍缺失。'; fi
    mkdir -p "$ROOT/nginx/usr/sbin"
    install -m 700 "$WORK/nginx-extract/usr/sbin/nginx" "$ROOT/nginx/usr/sbin/nginx.new"
    "$ROOT/nginx/usr/sbin/nginx.new" -V
    mv -f "$ROOT/nginx/usr/sbin/nginx.new" "$NGINX"
    json_update --arg v "$ver" '.components.nginx=true | .versions.nginx=$v'
    ok "Nginx $ver 已提取到集中目录；未创建账户或系统nginx服务。"
}
install_acme() {
    local ver meta="$WORK/acme-release.json" url
    ver=$(latest_release acmesh-official/acme.sh "$meta")
    url="https://github.com/acmesh-official/acme.sh/archive/refs/tags/$ver.tar.gz"
    fetch "$url" "$WORK/acme.tar.gz"
    mkdir -p "$WORK/acme-source" "$ROOT/acme/config" "$ROOT/acme/certstore"
    tar -tzf "$WORK/acme.tar.gz" | awk '/(^\/|(^|\/)\.\.(\/|$))/{bad=1} END{exit bad}' || die '归档路径异常。'
    tar --no-same-owner -xzf "$WORK/acme.tar.gz" --strip-components=1 -C "$WORK/acme-source"
    sh -n "$WORK/acme-source/acme.sh"
    # Run directly: no installer, profile changes, crontab, or auto-upgrade.
    install -m 700 "$WORK/acme-source/acme.sh" "$ROOT/acme/acme.sh"
    rm -rf "$ROOT/acme/dnsapi"
    cp -a "$WORK/acme-source/dnsapi" "$ROOT/acme/dnsapi"
    chmod -R go-rwx "$ROOT/acme"
    json_update --arg v "$ver" '.components.acme=true | .versions.acme=$v'
    ok "acme.sh $ver 已安装，统一由本工具timer检查续期。"
}

validate_state() {
    local n d p id mode proto credential site kind template upstream redirect
    jq -e '.schema==1 and (.nodes|type=="array") and (.sites|type=="array") and
      ([.nodes[].id]|length== (unique|length)) and ([.sites[].domain]|length==(unique|length))' "$STATE" >/dev/null || die '状态结构或唯一性检查失败。'
    while IFS= read -r d; do valid_domain "$d" || die '状态中的域名非法。'; done < <(jq -r '.sites[].domain' "$STATE")
    while IFS= read -r site; do
        valid_choice "$(jq -r '.access // "direct"' <<< "$site")" 'direct cloudflare' || die '网站连接方式不合法。'
        kind=$(jq -r '.kind // (if (.upstream // "")!="" then "proxy" else "custom" end)' <<< "$site")
        template=$(jq -r '.template // "welcome"' <<< "$site"); upstream=$(jq -r '.upstream // ""' <<< "$site"); redirect=$(jq -r '.redirect // ""' <<< "$site")
        case "$kind" in template) valid_choice "$template" 'welcome notes blog' || die '网站模板不合法。';;
            custom) ;; proxy) valid_proxy_upstream "$upstream" || die '网站上游不合法。';;
            redirect) valid_redirect "$redirect" "$(jq -r .domain <<< "$site")" || die '网站跳转地址不合法。';; *) die '网站类型不合法。';; esac
        [[ $kind == proxy || -z $upstream ]] || die '网站类型与上游配置不一致。'
    done < <(jq -c '.sites[]' "$STATE")
    while IFS= read -r n; do
        id=$(jq -r .id <<< "$n"); p=$(jq -r .port <<< "$n")
        mode=$(jq -r .mode <<< "$n"); proto=$(jq -r .protocol <<< "$n")
        credential=$(jq -r .credential <<< "$n")
        valid_host "$(jq -r .host <<< "$n")" || die '节点连接地址不合法。'
        if ! valid_name "$id" || ! valid_port "$p"; then die '节点名称或端口无效。'; fi
        case "$proto:$mode" in vless:reality|vless:ws|vless:tls|vmess:ws|vmess:ws-plain|vmess:tls|trojan:ws|trojan:tls|shadowsocks:ss) ;; *) die "不支持的协议组合: $proto/$mode";; esac
        if [[ $proto == vless || $proto == vmess ]]; then valid_uuid "$credential" || die 'UUID不合法。'; fi
        if [[ $mode == ws || $mode == tls ]]; then
            d=$(jq -r .domain <<< "$n"); valid_domain "$d" || die '节点域名不合法。'
            jq -e --arg d "$d" '.sites[]|select(.domain==$d and .issued)' "$STATE" >/dev/null || die "节点引用了无有效证书的网站: $d"
        fi
        if [[ $mode == ws || $mode == ws-plain ]]; then valid_ws_path "$(jq -r .path <<< "$n")" || die 'WebSocket路径非法。'; fi
    done < <(jq -c '.nodes[]' "$STATE")
    jq -e '[.nodes|group_by(.entry)[] | (map(del(.id,.credential,.enabled))|unique|length)==1] | all' "$STATE" >/dev/null || die '共享入口参数不一致。'
    jq -e '[.nodes|group_by(.entry)[]|.[0].port] | length==(unique|length)' "$STATE" >/dev/null || die '不同入口的端口重复。'
}
render_xray() {
    local dest=$1
    jq --arg root "$ROOT" '
      {log:{access:"none",error:($root+"/logs/xray.log"),loglevel:"warning"},
       inbounds: ([.nodes[]|select(.enabled)] | group_by(.entry) | map(
         . as $g | .[0] as $n |
         {tag:$n.entry,listen:(if $n.mode=="ws" then "127.0.0.1" else $n.listen end),port:$n.port,protocol:$n.protocol,
          settings:(if $n.protocol=="vless" then {decryption:"none",clients:($g|map({id:.credential,email:.id,flow:(if .mode=="reality" then "xtls-rprx-vision" else "" end)}))}
            elif $n.protocol=="vmess" then {clients:($g|map({id:.credential,email:.id})),disableInsecureEncryption:true}
            elif $n.protocol=="trojan" then {clients:($g|map({password:.credential,email:.id}))}
            else {method:$n.method,password:$n.credential,network:"tcp,udp"} end)} +
          (if $n.mode=="ss" then {} else
            {streamSettings:({network:(if ($n.mode=="ws" or $n.mode=="ws-plain") then "ws" else "tcp" end),
             security:(if ($n.mode=="ws" or $n.mode=="ws-plain") then "none" elif $n.mode=="reality" then "reality" else "tls" end)} +
             (if $n.mode=="reality" then {realitySettings:{show:false,target:$n.target,xver:0,serverNames:[$n.sni],privateKey:$n.privateKey,shortIds:[$n.shortId]}}
              elif $n.mode=="tls" then {tlsSettings:{minVersion:"1.2",certificates:[{certificateFile:($root+"/certs/"+$n.domain+"/current/fullchain.pem"),keyFile:($root+"/certs/"+$n.domain+"/current/key.pem")}]}}
              else {wsSettings:{path:$n.path}} end))} end))),
       outbounds:[{tag:"direct",protocol:"freedom"},{tag:"blocked",protocol:"blackhole"}],
       routing:{domainStrategy:"IPIfNonMatch",rules:[
        {type:"field",ip:["0.0.0.0/8","10.0.0.0/8","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.168.0.0/16","224.0.0.0/4","::/128","::1/128","fc00::/7","fe80::/10","ff00::/8"],outboundTag:"blocked"}]}}
    ' "$STATE" > "$dest"
}
render_nginx() {
    local dest=$1 site domain issued upstream kind template redirect n path port ipv6='' protocols gzip
    protocols=$(nginx_tls_protocols)
    gzip=$(get '.performance.gzip // false')
    [[ -f /proc/sys/net/ipv6/conf/all/disable_ipv6 && $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) == 0 ]] && ipv6='yes'
    mkdir -p "$ROOT/run/nginx"/{client,proxy,fastcgi,uwsgi,scgi}
    {
        cat <<EOF
# VPSKIT_OWNED -- generated; edit sites with vpskit site, not this file.
user root;
worker_processes 1;
pid $ROOT/run/nginx.pid;
error_log $ROOT/logs/nginx.log warn;
events { worker_connections 512; }
http {
    types { text/html html htm; text/css css; application/javascript js; application/json json; image/png png; image/jpeg jpg jpeg; image/svg+xml svg; image/x-icon ico; text/plain txt; font/woff2 woff2; }
    default_type application/octet-stream;
    server_tokens off;
    sendfile on;
    tcp_nodelay on;
    tcp_nopush on;
    keepalive_timeout 30;
    client_max_body_size 10m;
    access_log off;
    client_body_temp_path $ROOT/run/nginx/client;
    proxy_temp_path $ROOT/run/nginx/proxy;
    fastcgi_temp_path $ROOT/run/nginx/fastcgi;
    uwsgi_temp_path $ROOT/run/nginx/uwsgi;
    scgi_temp_path $ROOT/run/nginx/scgi;
    ssl_session_cache shared:VPSKIT:1m;
    ssl_session_timeout 10m;
    ssl_protocols $protocols;
    server {
        listen 80 default_server;
EOF
        [[ -z $ipv6 ]] || printf '        listen [::]:80 default_server;\n'
        cat <<EOF
        server_name _;
        location ^~ /.well-known/acme-challenge/ { root $ROOT/www/acme; default_type text/plain; }
        location / { return 404; }
    }
EOF
        while IFS= read -r site; do
            domain=$(jq -r .domain <<< "$site"); issued=$(jq -r .issued <<< "$site"); upstream=$(jq -r '.upstream // ""' <<< "$site")
            kind=$(jq -r '.kind // (if (.upstream // "")!="" then "proxy" else "custom" end)' <<< "$site")
            template=$(jq -r '.template // "welcome"' <<< "$site"); redirect=$(jq -r '.redirect // ""' <<< "$site")
            if ! valid_domain "$domain" || ! valid_upstream "$upstream"; then die '网站参数不合法。'; fi
            printf '    server {\n        listen 80;\n'
            [[ -z $ipv6 ]] || printf '        listen [::]:80;\n'
            printf '        server_name %s;\n' "$domain"
            printf '        location ^~ /.well-known/acme-challenge/ { root %s/www/acme; default_type text/plain; }\n' "$ROOT"
            if [[ $issued == true ]]; then
                printf '        location / { return 301 https://%s$request_uri; }\n    }\n' "$domain"
                printf '    server {\n        listen 443 ssl;\n'
                [[ -z $ipv6 ]] || printf '        listen [::]:443 ssl;\n'
                printf '        server_name %s;\n' "$domain"
                printf '        ssl_certificate %s/certs/%s/current/fullchain.pem;\n' "$ROOT" "$domain"
                printf '        ssl_certificate_key %s/certs/%s/current/key.pem;\n' "$ROOT" "$domain"
            fi
            printf '        root %s/www/%s;\n' "$ROOT" "$domain"
            if [[ $kind == template ]]; then printf '        index vpskit-%s.html index.html;\n' "$template"; else printf '        index index.html;\n'; fi
            printf '        location ~ /\\. { deny all; }\n'
            if [[ $issued == true ]]; then
                while IFS= read -r n; do
                    path=$(jq -r .path <<< "$n"); port=$(jq -r .port <<< "$n")
                    cat <<EOF
        location = $path {
            proxy_pass http://127.0.0.1:$port;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host \$host;
            proxy_buffering off;
            proxy_request_buffering off;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
        }
EOF
                done < <(jq -c --arg d "$domain" '[.nodes[]|select(.enabled and .mode=="ws" and .domain==$d)]|unique_by(.entry)[]' "$STATE")
            fi
            if [[ $kind == redirect ]]; then
                valid_redirect "$redirect" "$domain" || die '跳转网址不合法。'
                printf '        location / { return 302 "%s"; }\n' "$redirect"
            elif [[ -n $upstream ]]; then
                cat <<EOF
        location / {
            proxy_pass $upstream;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$remote_addr;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
EOF
            else
                printf '        location / {\n            try_files $uri $uri/ =404;\n'
                if [[ $gzip == true ]]; then
                    cat <<'EOF'
            # Only static content; do not compress proxy payloads or dynamic secrets.
            gzip on;
            gzip_vary on;
            gzip_comp_level 2;
            gzip_min_length 1024;
            gzip_types text/plain text/css application/javascript application/json image/svg+xml;
EOF
                fi
                printf '        }\n'
            fi
            printf '    }\n'
        done < <(jq -c '.sites[]' "$STATE")
        printf '}\n'
    } > "$dest"
}
apply_config() {
    validate_state
    local xc="$ROOT/config/xray.next.json" nc="$ROOT/config/nginx.next.conf" count
    if [[ $(get .components.xray) == true ]]; then
        render_xray "$xc"
        info '验证Xray配置（验证错误可能包含本机配置路径）。'
        "$XRAY" run -test -config "$xc"
    fi
    if [[ $(get .components.nginx) == true ]]; then
        render_nginx "$nc"
        nginx_cmd -t -p "$ROOT/" -c "$nc"
    fi
    [[ ! -f $xc ]] || mv -f "$xc" "$ROOT/config/xray.json"
    [[ ! -f $nc ]] || mv -f "$nc" "$ROOT/config/nginx.conf"
    write_units
    if [[ $(get .components.nginx) == true ]]; then
        systemctl enable vpskit-nginx.service
        if systemctl is-active --quiet vpskit-nginx.service; then systemctl reload vpskit-nginx.service; else systemctl start vpskit-nginx.service; fi
        systemctl is-active --quiet vpskit-nginx.service || die 'Nginx未正常运行。'
    fi
    count=$(jq '[.nodes[]|select(.enabled)]|length' "$STATE")
    if [[ $(get .components.xray) == true && $count -gt 0 ]]; then
        warn '应用配置将重启Xray；现有代理连接可能短暂中断。'
        systemctl enable vpskit-xray.service
        systemctl restart vpskit-xray.service
        sleep 0.5
        systemctl is-active --quiet vpskit-xray.service || die 'Xray启动失败。'
        local p
        while read -r p; do
            ss -Hlnt "sport = :$p" | grep -q . || die "Xray端口$p未监听。"
        done < <(jq -r '[.nodes[]|select(.enabled)]|unique_by(.entry)[].port' "$STATE")
    else systemctl disable --now vpskit-xray.service 2>/dev/null || true; fi
}
ensure_component() {
    local c=$1
    component_ready "$c" || die "组件未安装或程序缺失，请运行: vpskit install $c"
}

# ACME: stage certs, validate matching key, switch current symlink, then reload.
acme_run() {
    "$ACME" --home "$ROOT/acme" --config-home "$ROOT/acme/config" --cert-home "$ROOT/acme/certstore" --no-color "$@"
}
site_select() {
    local dest=$1 _domain _default n=0 d
    [[ $(get '.sites|length') -gt 0 ]] || die '尚无网站，请先在部署向导添加网站。'
    _default=$(default_domain)
    jq -e --arg d "$_default" '.sites[]|select(.domain==$d)' "$STATE" >/dev/null || _default=$(get '.sites[0].domain')
    while read -r d; do n=$((n+1)); printf '  %s) %s\n' "$n" "$d" >&2; done < <(jq -r '.sites[].domain' "$STATE")
    while :; do
        ask _domain '选择网站（域名或编号；回车使用默认）' "$_default"
        if [[ $_domain =~ ^[0-9]{1,4}$ ]] && ((10#$_domain>0)); then _domain=$(jq -r --argjson n "$((10#$_domain-1))" '.sites[$n].domain // ""' "$STATE"); fi
        _domain=${_domain,,}
        if valid_domain "$_domain" && jq -e --arg d "$_domain" '.sites[]|select(.domain==$d)' "$STATE" >/dev/null; then break; fi
        warn '未找到该网站，请重新输入列表中的域名或编号。'
    done
    remember_domain "$_domain"
    printf -v "$dest" '%s' "$_domain"
}
dns_credentials() {
    local provider=$1 token='' account='' sid='' skey=''
    # Credential values are exported only for the ACME process; acme stores them in its private account config.
    case "$provider" in
        dns_cf)
            required_secret token 'Cloudflare限定区域DNS编辑Token'
            required_secret account 'Cloudflare Account ID'
            export CF_Token="$token" CF_Account_ID="$account";;
        dns_dp)
            required_secret sid 'DNSPod API ID'; required_secret skey 'DNSPod API Key'
            export DP_Id="$sid" DP_Key="$skey";;
        *) die '只支持Cloudflare dns_cf及DNSPod dns_dp的自动DNS验证。';;
    esac
}
required_secret() {
    local rs_dest=$1 rs_label=$2 rs_value
    while :; do
        secret rs_value "$rs_label" '必填，输入不回显'
        if [[ -n $rs_value && $rs_value != *[[:space:]]* ]]; then printf -v "$rs_dest" '%s' "$rs_value"; return 0; fi
        warn '凭据不能为空或包含空白，请重新输入。'
    done
}
cert_issue() {
    local domain=${1:-} site challenge email provider
    ensure_component acme
    [[ -n $domain ]] || site_select domain
    site=$(jq -c --arg d "$domain" '.sites[]|select(.domain==$d)' "$STATE")
    [[ -n $site ]] || die '先添加网站。'
    challenge=$(jq -r .challenge <<< "$site"); email=$(jq -r .email <<< "$site")
    local -a args=(--issue --server letsencrypt --keylength ec-256 -d "$domain" --accountemail "$email")
    if [[ $(jq -r '.cert_settings_pending // false' <<< "$site") == true ]]; then
        info '证书参数已变更，本次重新签发以使验证方式/泛域名设置生效。'
        args+=(--force)
    fi
    if [[ $(jq -r '.wildcard // false' <<< "$site") == true ]]; then
        [[ $challenge != http ]] || die '泛域名证书必须使用DNS验证。'
        args+=(-d "*.$domain")
    fi
    if [[ $challenge == http ]]; then
        args+=(--webroot "$ROOT/www/acme")
        info "HTTP-01要求 $domain 的公开HTTP验证路径能够到达本机80；可以经CDN转发，不比对A/AAAA是否为VPS地址。"
    else
        provider=$challenge
        dns_credentials "$provider"
        args+=(--dns "$provider")
    fi
    # Do not tee ACME's output to management logs (provider errors might contain sensitive context).
    local issue_rc=0
    acme_run "${args[@]}" || issue_rc=$?
    if ((issue_rc != 0 && issue_rc != 2)); then
        unset CF_Token CF_Account_ID DP_Id DP_Key
        die '签发失败，现有证书保留；核对DNS、80端口或DNS API权限。'
    fi
    if ((issue_rc == 2)) && [[ $(jq -r '.cert_settings_pending // false' <<< "$site") == true ]]; then
        unset CF_Token CF_Account_ID DP_Id DP_Key
        die 'ACME跳过签发，新验证参数尚未生效；原证书保留，请稍后重试。'
    fi
    unset CF_Token CF_Account_ID DP_Id DP_Key
    mkdir -p "$ROOT/certs/$domain/pending"
    acme_run --install-cert -d "$domain" --ecc --key-file "$ROOT/certs/$domain/pending/key.pem" \
        --fullchain-file "$ROOT/certs/$domain/pending/fullchain.pem" --reloadcmd /bin/true
    begin_tx
    deploy_cert "$domain"
    json_update --arg d "$domain" '(.sites[]|select(.domain==$d)|.cert_settings_pending)=false'
    apply_config
    commit_tx
    ok "$domain 证书已部署，日常续期自动运行。"
}
deploy_cert() {
    local d=$1 base="$ROOT/certs/$1" cert key v prev
    cert="$base/pending/fullchain.pem"; key="$base/pending/key.pem"
    [[ -s $cert && -s $key ]] || die "$d 缺少待部署证书。"
    openssl x509 -in "$cert" -noout -checkend 86400 >/dev/null || die '新证书有效期异常。'
    openssl x509 -in "$cert" -noout -checkhost "$d" >/dev/null || die '证书域名不匹配。'
    [[ $(openssl x509 -in "$cert" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | cut -d' ' -f1) == \
       $(openssl pkey -in "$key" -pubout -outform DER | sha256sum | cut -d' ' -f1) ]] || die '证书和私钥不匹配。'
    v="rev-$(date +%s)-$(randhex 4)"
    mkdir -p "$base/$v"
    install -m 600 "$cert" "$base/$v/fullchain.pem"
    install -m 600 "$key" "$base/$v/key.pem"
    prev=$(readlink "$base/current" || true)
    ln -s "$v" "$base/current.new"
    mv -Tf "$base/current.new" "$base/current"
    json_update --arg d "$d" '(.sites[]|select(.domain==$d)|.issued)=true'
    [[ -z $prev ]] || info "$d 已切换证书；上次证书保存在回滚快照。"
    find "$base" -mindepth 1 -maxdepth 1 -type d -name 'rev-*' ! -name "$v" -exec rm -rf -- {} +
}
cert_renew() {
    [[ $(get .components.acme) == true ]] || return 0
    [[ $(jq '[.sites[]|select(.issued)]|length' "$STATE") -gt 0 ]] || return 0
    local rc=0 d changed=0
    if acme_run --cron; then :; else rc=$?; warn "ACME检查返回 $rc，继续核对现有证书。"; fi
    while read -r d; do
        if [[ -s $ROOT/certs/$d/pending/fullchain.pem ]] && ! cmp -s "$ROOT/certs/$d/pending/fullchain.pem" "$ROOT/certs/$d/current/fullchain.pem"; then
            if ((changed == 0)); then begin_tx; fi
            changed=1; deploy_cert "$d"
        fi
    done < <(jq -r '.sites[].domain' "$STATE")
    if ((changed)); then apply_config; commit_tx; fi
    cert_status
    return "$rc"
}
cert_status() {
    local d file bad=0
    while read -r d; do
        if jq -e --arg d "$d" '.sites[]|select(.domain==$d and .cert_settings_pending==true)' "$STATE" >/dev/null; then warn "$d 新证书参数待签发，现有证书仍按原方式续期。"; fi
        file="$ROOT/certs/$d/current/fullchain.pem"
        if [[ -s $file ]]; then
            printf '%s: ' "$d"; openssl x509 -in "$file" -noout -enddate
            if ! openssl x509 -in "$file" -noout -checkend 1209600 >/dev/null; then warn "$d 证书不足14天，请检查续期日志。"; bad=1; fi
        else warn "$d 尚未部署证书。"; fi
    done < <(jq -r '.sites[].domain' "$STATE")
    ((bad == 0))
}
site_access_prompt() {
    local d=$1 current answer old
    current=$(jq -r --arg d "$d" '[.sites[]|select(.domain==$d)][0].access // empty' "$STATE")
    [[ -n $current ]] || current=$(get '.preferences.site_access // (if .scheme=="B" then "cloudflare" else "direct" end)')
    old=$current
    panel_title '网站 / WS连接方式'
    menu_item 1 'Cloudflare代理（橙云）' '适用于网站和WS+TLS；公开DNS可以返回Cloudflare IP'
    menu_item 2 '直连 / 其他反向代理' '不强制DNS解析结果等于VPS；由你保证连接及回源正确'
    ask_valid answer '连接方式：编号或 cloudflare / direct' "$current" valid_choice '请选择1、2、cloudflare或direct。' '1 2 cloudflare direct'
    case "$answer" in 1|cloudflare) SITE_ACCESS=cloudflare;; 2|direct) SITE_ACCESS=direct;; esac
    json_update --arg a "$SITE_ACCESS" '.preferences.site_access=$a | .preferences.access_chosen=true'
    if [[ $SITE_ACCESS == cloudflare ]]; then
        if [[ $old != cloudflare ]]; then
            json_update '.preferences.challenge="dns_cf"'
        fi
        info '建议Cloudflare DNS-01：通过TXT验证域名所有权，不要求公开A/AAAA等于当前VPS。'
        info 'Cloudflare控制台：记录开启橙云；正确设置源站/回源；SSL选择Full (strict)，WebSockets开启。'
        info 'DNS-01签发不要求开放80，但网站回源443仍须可达。脚本不会自动修改Cloudflare控制台设置。'
        warn '橙云不保证源站IP绝对隐藏；直连节点、其他DNS记录和历史记录仍可能暴露源站。'
    else info '仅校验域名格式；不进行“DNS必须解析到本机IPv4/IPv6”的强制检查。'; fi
}
certificate_prompt() {
    local d=$1 existing current answer
    existing=$(jq -c --arg d "$d" '[.sites[]|select(.domain==$d)][0] // {}' "$STATE")
    panel_title "证书默认值 · $d"
    info "签发机构：Let's Encrypt；证书：ECC P-256；自动续期：每小时检查，按到期策略续期。"
    if [[ $(get .scheme) == A ]]; then info '方案A的REALITY代理不使用此证书；此证书用于你的网站。'
    else info '方案B的网站与WS代理共用此域名的HTTPS证书。'; fi
    current=$(jq -r '.email // empty' <<< "$existing"); [[ -n $current ]] || current=$(get '.preferences.email // ""')
    ask_valid CERT_EMAIL 'ACME联系邮箱' "$current" valid_email '邮箱格式示例：admin@example.com。'
    json_update --arg v "$CERT_EMAIL" '.preferences.email=$v'
    current=$(jq -r '.challenge // empty' <<< "$existing"); [[ -n $current ]] || current=$(get '.preferences.challenge // "http"')
    # Switching an existing site to orange-cloud offers DNS-01 once. Subsequent
    # visits retain the user's explicit HTTP/DNS choice.
    if [[ $(get '.preferences.site_access // "direct"') == cloudflare && $(jq -r '.access // "direct"' <<< "$existing") != cloudflare && $(jq -r 'has("domain")' <<< "$existing") == true ]]; then current=dns_cf; fi
    menu_item 1 'HTTP-01' '公开域名的HTTP验证请求须能到达本机80；可经代理，不比对A/AAAA地址' 
    menu_item 2 'Cloudflare DNS-01' '适用于使用Cloudflare DNS、泛域名或80端口不可达的情况'
    menu_item 3 'DNSPod DNS-01' '适用于DNSPod DNS；需要API凭据，可申请泛域名'
    ask_valid answer '验证方式：编号或 http / dns_cf / dns_dp' "$current" valid_choice '请选择1/2/3或列出的验证方式。' '1 2 3 http dns_cf dns_dp'
    case "$answer" in 1|http) CERT_CHALLENGE=http;; 2|dns_cf) CERT_CHALLENGE=dns_cf;; 3|dns_dp) CERT_CHALLENGE=dns_dp;; esac
    json_update --arg v "$CERT_CHALLENGE" '.preferences.challenge=$v'
    CERT_WILDCARD=false
    if [[ $CERT_CHALLENGE != http ]]; then
        current=$(jq -r 'if has("wildcard") then .wildcard else empty end' <<< "$existing")
        [[ -n $current ]] || current=$(get '.preferences.wildcard // false')
        if [[ $current == true ]]; then current=yes; else current=no; fi
        ask_valid answer '同时签发*.当前域名的泛域名证书？yes/no' "$current" valid_choice '请输入yes或no。' 'yes no'
        [[ $answer != yes ]] || CERT_WILDCARD=true
    fi
    json_update --argjson w "$CERT_WILDCARD" '.preferences.wildcard=$w'
}
site_content_prompt() {
    local d=$1 existing current choice target
    existing=$(jq -c --arg d "$d" '[.sites[]|select(.domain==$d)][0] // {}' "$STATE")
    current=$(jq -r 'if .kind then .kind elif (.upstream // "")!="" then "proxy" elif .domain then "custom" else "" end' <<< "$existing")
    [[ -n $current ]] || current=$(get '.preferences.site_kind // "template"')
    panel_title "网站内容 · https://$d"
    menu_item 1 '本地轻量网站模板' '欢迎页 / 技术笔记 / 个人博客；无需数据库，适合512MB VPS'
    menu_item 2 '自己的静态网站' "使用 $ROOT/www/$d 中的index.html；保留已有内容"
    menu_item 3 '自己的动态网站' '反向代理到本机应用，例如http://127.0.0.1:8000'
    menu_item 4 '跳转到常用或自定义网站' '浏览器访问时跳转；WS路径仍由本机代理处理，不复制目标网站'
    ask_valid choice '网站类型：编号或 template / custom / proxy / redirect' "$current" valid_choice '请选择1～4或列出的类型。' '1 2 3 4 template custom proxy redirect'
    case "$choice" in 1|template) SITE_KIND=template;; 2|custom) SITE_KIND=custom;; 3|proxy) SITE_KIND=proxy;; 4|redirect) SITE_KIND=redirect;; esac
    SITE_TEMPLATE=welcome; SITE_UPSTREAM=''; SITE_REDIRECT=''
    json_update --arg k "$SITE_KIND" '.preferences.site_kind=$k'
    case "$SITE_KIND" in
        template)
            current=$(jq -r '.template // empty' <<< "$existing"); [[ -n $current ]] || current=$(get '.preferences.template // "welcome"')
            menu_item 1 '简洁欢迎页' '显示当前域名与基本介绍'
            menu_item 2 '技术笔记页' '用于整理文档与学习记录'
            menu_item 3 '个人博客页' '用于个人介绍和内容入口'
            ask_valid choice '模板编号或 welcome / notes / blog' "$current" valid_choice '请选择1/2/3或模板名称。' '1 2 3 welcome notes blog'
            case "$choice" in 1|welcome) SITE_TEMPLATE=welcome;; 2|notes) SITE_TEMPLATE=notes;; 3|blog) SITE_TEMPLATE=blog;; esac
            json_update --arg v "$SITE_TEMPLATE" '.preferences.template=$v';;
        proxy)
            current=$(jq -r '.upstream // empty' <<< "$existing"); [[ -n $current ]] || current=$(get '.preferences.upstream // ""')
            [[ -n $current ]] || current=http://127.0.0.1:8000
            ask_valid SITE_UPSTREAM '本机应用地址' "$current" valid_proxy_upstream '请输入http://127.0.0.1:端口，且不能回指80/443。'
            json_update --arg v "$SITE_UPSTREAM" '.preferences.upstream=$v';;
        redirect)
            current=$(jq -r '.redirect // empty' <<< "$existing"); [[ -n $current ]] || current=$(get '.preferences.redirect // "https://www.microsoft.com/"')
            menu_item 1 'Microsoft' '跳转到https://www.microsoft.com/'
            menu_item 2 'Wikipedia' '跳转到https://www.wikipedia.org/'
            menu_item 3 'Bing' '跳转到https://www.bing.com/'
            menu_item 4 '自定义网址' '使用你指定的HTTPS网站地址'
            while :; do
                ask choice '选择编号，或直接输入HTTPS网址（回车使用上次网址）' "$current"
                case "$choice" in 1) target=https://www.microsoft.com/;; 2) target=https://www.wikipedia.org/;; 3) target=https://www.bing.com/;;
                    4) ask_valid target '目标HTTPS网址' "$current" valid_redirect '仅允许普通HTTPS域名及URL路径，且不能跳回当前域名。' "$d";; *) target=$choice;; esac
                if valid_redirect "$target" "$d"; then SITE_REDIRECT=$target; break; fi
                warn '目标网址无效或会跳回本站，请重新选择。'
            done
            json_update --arg v "$SITE_REDIRECT" '.preferences.redirect=$v'
            info '普通访问会发生HTTP跳转；这不提供REALITY握手伪装，也不保证隐藏代理特征。';;
    esac
}
site_template_file() {
    local d=$1 kind=$2 template=$3 file title lead
    mkdir -p "$ROOT/www/$d" "$ROOT/www/acme/.well-known/acme-challenge"
    case "$kind" in
        template)
            case "$template" in welcome) title='欢迎来到这里'; lead='一个分享想法、记录生活与探索新知的地方。';;
                notes) title='技术与日常笔记'; lead='把值得记录的知识整理下来，让每一次探索都有迹可循。';;
                blog) title='记录与分享'; lead='关于生活、学习，以及那些值得留下的片刻。';; *) die '模板名称不合法。';; esac
            file="$ROOT/www/$d/vpskit-$template.html";;
        custom) file="$ROOT/www/$d/index.html"; title='欢迎访问'; lead='本站内容正在整理，欢迎稍后再来。';;
        *) return 0;;
    esac
    # Never overwrite an existing page, including a template the user customized.
    [[ ! -e $file && ! -L $file ]] || return 0
    cat > "$file" <<EOF_PAGE
<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>$d · $title</title>
<style>html{color-scheme:light}body{margin:0;background:#f5f7fa;color:#1b2a41;font:16px/1.8 system-ui,sans-serif}main{max-width:760px;margin:9vh auto;padding:32px}header{border-bottom:1px solid #dbe2ea;padding-bottom:20px}small{color:#536b86;letter-spacing:.08em}h1{font-size:clamp(32px,6vw,48px);line-height:1.3}section{background:white;border:1px solid #e2e7ee;border-radius:16px;padding:24px;margin-top:28px}footer{margin-top:40px;color:#65768b;font-size:14px}a{color:#285f9a}</style></head>
<body><main><header><small>$d</small><h1>$title</h1><p>$lead</p></header><section><h2>关于本站</h2><p>这里将持续更新文章、笔记与个人作品。感谢你的访问。</p></section><footer>$d · 保持好奇，继续探索。</footer></main></body></html>
EOF_PAGE
}
site_apply_preferences() {
    local domain=$1 exists=false own=false access
    valid_domain "$domain" || die '网站域名不合法。'
    access=$(get '.preferences.site_access // "direct"')
    SITE_KIND=$(get '.preferences.site_kind // "template"'); SITE_TEMPLATE=$(get '.preferences.template // "welcome"')
    SITE_UPSTREAM=''; SITE_REDIRECT=''
    [[ $SITE_KIND != proxy ]] || SITE_UPSTREAM=$(get '.preferences.upstream // ""')
    [[ $SITE_KIND != redirect ]] || SITE_REDIRECT=$(get '.preferences.redirect // ""')
    CERT_EMAIL=$(get '.preferences.email // ""'); CERT_CHALLENGE=$(get '.preferences.challenge // "http"'); CERT_WILDCARD=$(get '.preferences.wildcard // false')
    valid_email "$CERT_EMAIL" || die '请先设置证书联系邮箱。'
    if jq -e --arg d "$domain" '.sites[]|select(.domain==$d)' "$STATE" >/dev/null; then exists=true; fi
    begin_tx
    if [[ $exists == false ]]; then
        if systemctl is-active --quiet vpskit-nginx.service; then own=true; fi
        check_port 80 "$own"; check_port 443 "$own"
        json_update --arg d "$domain" '.sites += [{domain:$d,issued:false}]'
    fi
    site_template_file "$domain" "$SITE_KIND" "$SITE_TEMPLATE"
    json_update --arg d "$domain" --arg e "$CERT_EMAIL" --arg c "$CERT_CHALLENGE" --arg u "$SITE_UPSTREAM" --arg r "$SITE_REDIRECT" --arg k "$SITE_KIND" --arg t "$SITE_TEMPLATE" --arg a "$access" --argjson w "$CERT_WILDCARD" '
        (.sites[]|select(.domain==$d)) |= (. + {cert_settings_pending:((.cert_settings_pending // false) or (.issued==true and (.email!=$e or .challenge!=$c or (.wildcard // false)!=$w))),email:$e,challenge:$c,upstream:$u,redirect:$r,kind:$k,template:$t,access:$a,wildcard:$w}) |
        if .wizard.domain==$d then .wizard.site_pending=false else . end'
    apply_config; commit_tx
}
site_add() {
    local domain choice
    ensure_component nginx; ensure_component acme
    ask_valid domain '网站域名（小写ASCII/Punycode，不含https://）' "$(default_domain)" valid_domain '域名示例：www.example.com；不能填IP或网址路径。'
    remember_domain "$domain"
    if jq -e --arg d "$domain" '.sites[]|select(.domain==$d)' "$STATE" >/dev/null; then
        info "$domain 已存在，可继续配置或签发证书，不会重复添加。"
        ask_valid choice '1=使用现有网站并检查证书，2=修改网站配置' 1 valid_choice '请选择1或2。' '1 2'
        if [[ $choice == 1 ]]; then
            if certificate_ready "$domain"; then ok '现有网站和证书可用。'; else cert_issue "$domain"; fi
            return 0
        fi
    fi
    site_access_prompt "$domain"; certificate_prompt "$domain"; site_content_prompt "$domain"
    site_apply_preferences "$domain"
    info "网站域名已记住：$domain；内容目录：$ROOT/www/$domain。"
    if ! certificate_ready "$domain"; then cert_issue "$domain"; fi
}
site_edit() {
    local domain
    site_select domain
    info "当前域名：$domain；已有静态文件保留，可在 $ROOT/www/$domain 修改。"
    # Preserve the site's certificate options while changing only content.
    local cert_data; cert_data=$(jq -c --arg d "$domain" '.sites[]|select(.domain==$d)|{email,challenge,wildcard:(.wildcard // false)}' "$STATE")
    json_update --argjson c "$cert_data" '.preferences += $c'
    site_access_prompt "$domain"
    # Editing website routing does not silently change active certificate settings.
    json_update --argjson c "$cert_data" '.preferences += $c'
    site_content_prompt "$domain"
    site_apply_preferences "$domain"
}
site_certificate_edit() {
    local domain
    site_select domain
    json_update --arg d "$domain" '.preferences.site_access=([.sites[]|select(.domain==$d)][0].access // "direct")'
    certificate_prompt "$domain"
    begin_tx
    json_update --arg d "$domain" --arg e "$CERT_EMAIL" --arg c "$CERT_CHALLENGE" --argjson w "$CERT_WILDCARD" '(.sites[]|select(.domain==$d)) |= (. + {cert_settings_pending:((.cert_settings_pending // false) or (.issued==true and (.email!=$e or .challenge!=$c or (.wildcard // false)!=$w))),email:$e,challenge:$c,wildcard:$w})'
    commit_tx
    info '签发偏好已保存。成功重新签发后切换续期验证方式；暂不签发时，现有证书仍按原方式续期。'
    if confirm '现在按新设置签发证书'; then cert_issue "$domain"; fi
}
reality_target_prompt() {
    local rt_dest=$1 rt_choice rt_value rt_default
    rt_default=$(get '.preferences.reality_target // "www.microsoft.com"')
    panel_title 'REALITY握手目标（与自有网站域名分别保存）'
    menu_item 1 'Microsoft候选' 'www.microsoft.com；将从本VPS测试TLS连接'
    menu_item 2 'Apple候选' 'www.apple.com；可用性以现场检测为准'
    menu_item 3 'Cloudflare候选' 'www.cloudflare.com；可用性以现场检测为准'
    menu_item 4 '自己的HTTPS网站 / 自定义目标' '目标应支持TLS1.3；不会向该域名申请证书'
    while :; do
        ask rt_choice '编号或目标域名（回车使用上次目标）' "$rt_default"
        case "$rt_choice" in 1) rt_value=www.microsoft.com;; 2) rt_value=www.apple.com;; 3) rt_value=www.cloudflare.com;;
            4) ask_valid rt_value '目标域名/SNI' "$rt_default" valid_domain '请填写域名，不含https://、端口或路径。';; *) rt_value=${rt_choice,,};; esac
        if valid_domain "$rt_value"; then
            json_update --arg d "$rt_value" '.preferences.reality_target=$d'
            printf -v "$rt_dest" '%s' "$rt_value"; return 0
        fi
        warn '域名格式错误，请重新选择或输入域名。'
    done
}

site_remove() {
    local domain answer
    site_select domain
    jq -e --arg d "$domain" '.nodes[]|select(.domain==$d)' "$STATE" >/dev/null && die '还有节点引用此域名，请先删除这些节点。'
    confirm "移除 $domain 的站点绑定及续期（网站文件和证书另行选择删除）" || return 0
    begin_tx
    if [[ $(get .components.acme) == true ]]; then acme_run --remove -d "$domain" --ecc || die '移除续期记录失败。'; fi
    json_update --arg d "$domain" '.sites |= map(select(.domain!=$d))'
    apply_config; commit_tx
    if confirm "同时永久删除 $domain 的网站内容和证书"; then
        rm -rf -- "$ROOT/www/$domain" "$ROOT/certs/$domain"
    else ok '网站内容和证书保留在集中目录。'; fi
}

node_list() {
    local index name proto mode host port internal enabled domain state color
    if [[ $(get '.nodes|length') == 0 ]]; then printf '  暂无节点；选择“添加节点”开始。\n'; return 0; fi
    while IFS=$'\t' read -r index name proto mode host port internal enabled domain; do
        color=$DIM; state='停用'; [[ $enabled != true ]] || { color=$GREEN; state='配置启用'; }
        [[ $host != *:* ]] || host="[$host]"
        printf '  %s[%s]%s %s%s%s  %s[%s]%s\n' "$BLUE" "$index" "$RESET" "$BOLD" "$name" "$RESET" "$color" "$state" "$RESET"
        printf '       %s / %s | 连接 %s%s:%s%s | 本机端口 %s | TLS/SNI %s\n' "$proto" "$mode" "$CYAN" "$host" "$port" "$RESET" "$internal" "$domain"
    done < <(jq -r '.nodes|to_entries[]|.key as $i|.value|[($i+1|tostring),.id,.protocol,(if .mode=="ws" then "WS+TLS" elif .mode=="ws-plain" then "WS(无TLS)" elif .mode=="tls" then "TCP+TLS" elif .mode=="reality" then "REALITY" else "TCP/UDP" end),.host,(if .mode=="ws" then "443" else (.port|tostring) end),(.port|tostring),(.enabled|tostring),(if .mode=="reality" then .sni elif (.domain // "")!="" then .domain else "-" end)]|@tsv' "$STATE")
    printf '  %s序号按当前列表排列；删除节点后会重新编号。启用状态不等于公网连通。%s\n' "$DIM" "$RESET"
}
valid_node_index() {
    [[ $1 =~ ^[0-9]{1,6}$ ]] || return 1
    ((10#$1>=1 && 10#$1<=$(get '.nodes|length')))
}
node_select() {
    local ns_dest=$1 ns_name=${2:-} ns_index
    [[ $(get '.nodes|length') -gt 0 ]] || die '尚无节点，请先添加节点。'
    if [[ -z $ns_name ]]; then
        node_list >&2
        ask_valid ns_index '选择节点序号（输入:q取消）' '' valid_node_index '请输入当前列表内的有效序号。'
        ns_name=$(jq -r --argjson i "$((10#$ns_index-1))" '.nodes[$i].id' "$STATE")
    elif ! valid_existing_node "$ns_name"; then
        # CLI keeps old names working. Numeric existing names have precedence.
        valid_node_index "$ns_name" || die '指定节点名称或序号不存在。'
        ns_name=$(jq -r --argjson i "$((10#$ns_name-1))" '.nodes[$i].id' "$STATE")
    fi
    info "已选择节点：$ns_name"
    printf -v "$ns_dest" '%s' "$ns_name"
}
node_share_select() {
    local sh_dest=$1 sh_index sh_name
    node_list >&2
    while :; do
        ask sh_index '复用入口：输入节点序号；0=新建独立入口' 0
        if [[ $sh_index == 0 ]]; then printf -v "$sh_dest" '%s' ''; return 0; fi
        if valid_node_index "$sh_index"; then
            sh_name=$(jq -r --argjson i "$((10#$sh_index-1))" '.nodes[$i].id' "$STATE")
            if valid_share_node "$sh_name"; then printf -v "$sh_dest" '%s' "$sh_name"; return 0; fi
        fi
        warn '序号无效或该节点为Shadowsocks（需独立入口），请重新选择。'
    done
}
node_endpoint_prompt() {
    local ep_dest=$1 ep_mode=$2 ep_domain=$3 ep_default=$4 ep_value access
    if [[ $ep_mode == ws || $ep_mode == tls ]]; then
        info "连接地址与证书域名分开设置：TLS SNI/WS Host仍使用 $ep_domain。"
        ask_valid ep_value '客户端连接地址：域名、IPv4或IPv6（IPv6不加方括号）' "$ep_default" valid_host '请输入有效域名或IP，不含https://、端口或路径。'
        access=$(jq -r --arg d "$ep_domain" '[.sites[]|select(.domain==$d)][0].access // "direct"' "$STATE")
        if [[ $access == cloudflare ]]; then
            if ! valid_domain "$ep_value"; then warn '自定义IP会写入客户端链接；若填写源站IP，将绕过Cloudflare并暴露该IP。'; fi
            [[ $ep_mode != tls ]] || warn '独立TCP+TLS不能通过Cloudflare普通橙云代理，请使用源站IP/直连域名，或改为WS+TLS。'
        fi
    else
        ask_valid ep_value '客户端连接地址：VPS IPv4、IPv6或直连域名' "$ep_default" valid_host '请输入有效IP或域名，不含端口、路径或IPv6方括号。'
        info '当前传输需要直连；Cloudflare普通橙云不能代理此独立TCP/UDP入口。'
    fi
    printf -v "$ep_dest" '%s' "$ep_value"
}
choose_credential() {
    local cc_dest=$1 cc_protocol=$2 cc_method=${3:-} cc_except=${4:-} cc_value='' cc_length cc_wanted
    while :; do
        case "$cc_protocol" in
            vless|vmess)
                ask_valid cc_value 'UUID（回车使用随机默认值）' "$(new_uuid)" valid_uuid 'UUID应为8-4-4-4-12格式的十六进制字符。'
                cc_value=${cc_value,,};;
            shadowsocks)
                secret cc_value "Shadowsocks密码；$cc_method"
                if [[ -z $cc_value ]]; then
                    case "$cc_method" in 2022-blake3-aes-128-gcm) cc_value=$(openssl rand -base64 16);; 2022-*) cc_value=$(openssl rand -base64 32);; *) cc_value=$(randhex 24);; esac
                fi
                if [[ $cc_method == 2022-* ]]; then
                    cc_wanted=32; [[ $cc_method != 2022-blake3-aes-128-gcm ]] || cc_wanted=16
                    if ! cc_length=$(printf '%s' "$cc_value" | base64 -d 2>/dev/null | wc -c); then
                        warn 'SS2022需要有效的Base64密钥，请重新输入，或回车自动生成。'; continue
                    fi
                    if [[ $cc_length != "$cc_wanted" ]]; then
                        warn "此方法需要Base64编码的${cc_wanted}字节密钥，请重新输入，或回车自动生成。"; continue
                    fi
                fi;;
            trojan) secret cc_value 'Trojan密码'; [[ -n $cc_value ]] || cc_value=$(randhex 24);;
            *) die '不支持的协议。';;
        esac
        if [[ ${#cc_value} -lt 8 || ${#cc_value} -gt 256 || $cc_value == *$'\n'* || $cc_value == *$'\r'* ]]; then
            warn '凭据必须为8～256个字符且不能换行，请重新输入。'; continue
        fi
        if jq -e --arg c "$cc_value" --arg n "$cc_except" '.nodes[]|select(.id!=$n and .credential==$c)' "$STATE" >/dev/null; then
            warn '凭据已被其他节点使用，请重新输入。'; continue
        fi
        printf -v "$cc_dest" '%s' "$cc_value"; return 0
    done
}
ipv6_available() { [[ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 && $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) == 0 ]]; }
node_listen_prompt() {
    local nl_dest=$1 nl_host=$2 nl_default=${3:-0.0.0.0} nl_value
    while :; do
        ask_valid nl_value '监听地址：0.0.0.0（IPv4）或 ::（IPv4/IPv6，需系统支持）' "$nl_default" valid_choice '请输入0.0.0.0或::。' '0.0.0.0 ::'
        if [[ $nl_value == :: ]] && ! ipv6_available; then warn '系统IPv6已禁用；请先启用IPv6，或输入:q取消并改用IPv4地址。'; continue; fi
        if [[ $nl_host == *:* && $nl_value != :: ]]; then warn 'IPv6直连地址需要::监听；请重新选择或:q取消。'; continue; fi
        printf -v "$nl_dest" '%s' "$nl_value"; return 0
    done
}
node_add() {
    ensure_component xray
    local guided=${1:-no} name proto mode share='' entry port domain='' path='' method='' credential='' host listen target='' sni='' pk='' pub='' sid='' keys template
    ask_valid name '节点名称（英文/数字/下划线/横线）' "node-$(randhex 3)" valid_new_node_name '名称须为1～48个英文、数字、下划线或横线，且不能重名。'
    if [[ $guided != guided ]]; then
        node_share_select share
    fi
    if [[ -n $share ]]; then
        node_select share "$share"
        template=$(jq -c --arg n "$share" '.nodes[]|select(.id==$n)' "$STATE")
        proto=$(jq -r .protocol <<< "$template"); method=$(jq -r .method <<< "$template")
        [[ $proto != shadowsocks ]] || die 'Shadowsocks在本版本中每入口一个凭据；请新增独立端口。'
        choose_credential credential "$proto" "$method"
        begin_tx
        json_update --argjson t "$template" --arg n "$name" --arg c "$credential" '.nodes += [$t|.id=$n|.credential=$c|.enabled=true]'
    else
        if [[ $guided == guided && $(get .scheme) == A ]]; then
            proto=vless; mode=reality
            info '沿用方案A：VLESS + REALITY + Vision。'
        else
            panel_title '选择代理协议'
            menu_item 1 'VLESS' '轻量；可选REALITY、WS+TLS、TCP+TLS'
            menu_item 2 'VMess' 'AEAD加密；可选WS、WS+TLS、TCP+TLS'
            menu_item 3 'Trojan' '密码认证；可选WS+TLS、TCP+TLS'
            local choices='1 2 3 vless vmess trojan' default_proto
            default_proto=$(get '.preferences.protocol // "vless"')
            if [[ $guided != guided ]]; then
                menu_item 4 'Shadowsocks' '独立TCP/UDP端口；AEAD或2022方法'
                choices+=' 4 ss shadowsocks'
            elif [[ $default_proto == shadowsocks ]]; then default_proto=vless; fi
            ask_valid proto '协议编号或名称' "$default_proto" valid_choice '请选择列出的协议编号或名称。' "$choices"
            case "$proto" in 1) proto=vless;; 2) proto=vmess;; 3) proto=trojan;; 4|ss) proto=shadowsocks;; esac
            json_update --arg p "$proto" '.preferences.protocol=$p'
            if [[ $guided == guided ]]; then mode=ws; info '沿用方案B：WS + TLS，网站与代理共用443。'
            elif [[ $proto == shadowsocks ]]; then mode=ss
            else
                local default=1 mode_choices='1 2 ws wss ws-tls tls'
                [[ $(get .scheme) != A || $proto != vless ]] || default=3
                panel_title '选择传输方式（WS是传输层，不是独立代理协议）'
                menu_item 1 'WS + TLS' '推荐网站共用443；需要域名、Nginx和证书'
                menu_item 2 'TCP + TLS' '独立公网端口；需要域名和证书'
                if [[ $proto == vless ]]; then menu_item 3 'TCP + REALITY' '独立端口，不需要自己的代理证书'; mode_choices+=' 3 reality'; fi
                if [[ $proto == vmess ]]; then menu_item 4 'WS（无外层TLS）' 'VMess AEAD；独立端口，无HTTPS外观'; mode_choices+=' 4 ws-plain'; fi
                ask_valid mode '传输编号或名称' "$default" valid_choice '此协议不支持该传输，请从当前列表重新选择。' "$mode_choices"
                case "$mode" in 1|wss|ws-tls) mode=ws;; 2) mode=tls;; 3) mode=reality;; 4) mode=ws-plain;; esac
            fi
        fi
        if [[ $mode == ws-plain ]]; then
            warn '独立WS没有外层TLS和HTTPS伪装；VMess必须使用AEAD客户端，导出链接启用auto加密。VLESS/Trojan不提供明文WS。'
            confirm '选择VMess独立WS；通常建议改用选项1 WS+TLS' || return 0
        fi
        if [[ $mode == ws || $mode == tls ]]; then
            ensure_component nginx
            if [[ $guided == guided ]]; then
                domain=$(get '.wizard.domain // ""')
                certificate_good "$domain" || die '当前方案域名的证书未就绪，请先继续部署向导完成证书签发。'
                info "沿用网站与证书域名：$domain"
            else
                [[ $(get '[.sites[]|select(.issued)]|length') -gt 0 ]] || die '尚无已签发证书的网站，请先添加网站并签发证书。'
                while :; do
                    site_select domain
                    if certificate_good "$domain"; then break; fi
                    warn '此网站证书未就绪，请重新选择其他网站，或输入 :q 返回证书管理。'
                done
            fi
            node_endpoint_prompt host "$mode" "$domain" "$domain"
        elif [[ $guided == guided ]]; then
            host=$(get .host); info "沿用连接地址：$host"
        else
            node_endpoint_prompt host "$mode" "$domain" "$(get .host)"
            json_update --arg h "$host" '.host=$h'
            if valid_domain "$host"; then remember_domain "$host"; fi
        fi
        if [[ $mode == ws ]]; then
            ask_node_port port 'Xray本机端口，客户端仍连接网站443' "$(next_port 20000)"
            ask_valid path 'WebSocket路径（至少8个字母/数字/横线/下划线）' "/$(randhex 12)" valid_new_ws_path '路径须以/开头，后接8～80个允许字符，且当前网站尚未使用。' "$domain"
            listen=127.0.0.1
        else
            local start=8443
            [[ $proto != shadowsocks ]] || start=8388
            ask_node_port port '公网代理端口（避开网站80/443和SSH）' "$(next_port "$start")"
            listen=0.0.0.0
            if ipv6_available; then listen='::'; fi
            node_listen_prompt listen "$host" "$listen"
        fi
        if [[ $mode == ws-plain ]]; then
            ask_valid path '独立WebSocket路径（至少8个字母/数字/横线/下划线）' "/$(randhex 12)" valid_ws_path '路径须以/开头，后接8～80个字母、数字、横线或下划线。'
        fi
        if [[ $mode == reality ]]; then
            local -a tls_flags=()
            local tls_help; tls_help=$(openssl s_client -help 2>&1 || true)
            if [[ $tls_help == *'-tls1_3'* ]]; then tls_flags=(-tls1_3)
            else warn '此OpenSSL不支持TLS1.3预检，仅检查证书和连通性；目标TLS1.3能力需另行确认。'; fi
            while :; do
                reality_target_prompt sni; target="$sni:443"
                info '检查目标TLS连接及证书；失败后可重选目标。'
                if timeout 15 openssl s_client -connect "$target" -servername "$sni" "${tls_flags[@]}" -alpn h2 -verify_return_error -verify_hostname "$sni" </dev/null > "$WORK/target-check.log" 2>&1; then break; fi
                warn '目标TLS检查失败；请更换目标，或输入 :q 取消。已填节点参数保留到本次输入结束。'
            done
            keys=$("$XRAY" x25519)
            pk=$(printf '%s\n' "$keys" | awk -F': *' '/PrivateKey|Private key/{print $2;exit}')
            pub=$(printf '%s\n' "$keys" | awk -F': *' '/PublicKey|Public key|Password/{print $2;exit}')
            [[ $pk =~ ^[A-Za-z0-9_-]{43}$ && $pub =~ ^[A-Za-z0-9_-]{43}$ ]] || die '无法解析当前Xray密钥输出。'
            sid=$(randhex 8)
        fi
        if [[ $proto == shadowsocks ]]; then
            ask_valid method 'Shadowsocks加密方法' 2022-blake3-aes-128-gcm valid_choice '支持aes-128-gcm、aes-256-gcm、chacha20-ietf-poly1305、2022-blake3-aes-128-gcm、2022-blake3-aes-256-gcm。' 'aes-128-gcm aes-256-gcm chacha20-ietf-poly1305 2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm'
            warn 'Shadowsocks已加密，但没有REALITY/HTTPS外观；端口须放行TCP和UDP。'
        fi
        choose_credential credential "$proto" "$method"
        entry="in-$(randhex 6)"
        begin_tx
        check_port "$port"
        json_update --arg id "$name" --arg entry "$entry" --arg protocol "$proto" --arg mode "$mode" \
          --argjson port "$port" --arg domain "$domain" --arg path "$path" --arg method "$method" --arg credential "$credential" \
          --arg host "$host" --arg listen "$listen" --arg target "$target" --arg sni "$sni" --arg pk "$pk" --arg pub "$pub" --arg sid "$sid" \
          '.nodes += [{id:$id,entry:$entry,protocol:$protocol,mode:$mode,port:$port,domain:$domain,path:$path,method:$method,credential:$credential,host:$host,listen:$listen,target:$target,sni:$sni,privateKey:$pk,publicKey:$pub,shortId:$sid,enabled:true}]'
    fi
    apply_config; commit_tx
    ok "节点 $name 已添加。请用 vpskit firewall sync 放行系统防火墙端口；云安全组需另行设置。"
    node_export "$name"
}
node_export() {
    local name=${1:-} n host displayhost port mode proto encoded label path sni key sid credential method
    node_select name "$name"
    n=$(jq -c --arg n "$name" '.nodes[]|select(.id==$n)' "$STATE")
    host=$(jq -r .host <<< "$n"); port=$(jq -r .port <<< "$n"); mode=$(jq -r .mode <<< "$n"); proto=$(jq -r .protocol <<< "$n")
    credential=$(jq -r .credential <<< "$n"); label=$(jq -rn --arg v "$name" '$v|@uri')
    displayhost=$host; [[ $host != *:* ]] || displayhost="[$host]"
    [[ $mode != ws ]] || port=443
    path=$(jq -r .path <<< "$n"); sni=$(jq -r '.domain' <<< "$n")
    warn '以下链接含访问凭据，请勿公开或粘贴到公共日志。'
    case "$proto" in
        vmess)
            encoded=$(jq -cn --arg ps "$name" --arg add "$host" --arg port "$port" --arg id "$credential" --arg mode "$mode" --arg path "$path" --arg sni "$sni" \
              '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:(if ($mode=="ws" or $mode=="ws-plain") then "ws" else "tcp" end),type:"none",host:$sni,path:$path,tls:(if $mode=="ws-plain" then "" else "tls" end),sni:$sni}' | base64 -w0)
            printf 'vmess://%s\n' "$encoded";;
        vless|trojan)
            local query
            if [[ $mode == reality ]]; then
                sni=$(jq -r .sni <<< "$n"); key=$(jq -r .publicKey <<< "$n"); sid=$(jq -r .shortId <<< "$n")
                query="security=reality&type=tcp&flow=xtls-rprx-vision&sni=$sni&fp=chrome&pbk=$key&sid=$sid"
            elif [[ $mode == ws ]]; then
                path=$(jq -rn --arg v "$path" '$v|@uri')
                query="security=tls&type=ws&sni=$sni&host=$sni&path=$path"
            else query="security=tls&type=tcp&sni=$sni"; fi
            [[ $proto != vless ]] || query="encryption=none&$query"
            credential=$(jq -rn --arg v "$credential" '$v|@uri')
            printf '%s://%s@%s:%s?%s#%s\n' "$proto" "$credential" "$displayhost" "$port" "$query" "$label";;
        shadowsocks)
            method=$(jq -r .method <<< "$n")
            encoded=$(printf '%s:%s' "$method" "$credential" | base64 -w0 | tr '+/' '-_' | tr -d '=')
            printf 'ss://%s@%s:%s#%s\n' "$encoded" "$displayhost" "$port" "$label";;
    esac
}
node_action() {
    local action=$1 name=${2:-} entry credential proto method port old newname mode domain host listen
    node_select name "$name"
    entry=$(jq -r --arg n "$name" '.nodes[]|select(.id==$n)|.entry' "$STATE")
    case "$action" in
        address)
            mode=$(jq -r --arg n "$name" '.nodes[]|select(.id==$n)|.mode' "$STATE")
            domain=$(jq -r --arg n "$name" '.nodes[]|select(.id==$n)|.domain' "$STATE")
            old=$(jq -r --arg n "$name" '.nodes[]|select(.id==$n)|.host' "$STATE")
            node_endpoint_prompt host "$mode" "$domain" "$old"
            [[ $host != "$old" ]] || { ok '连接地址未变更。'; return 0; }
            listen=$(jq -r --arg n "$name" '.nodes[]|select(.id==$n)|.listen' "$STATE")
            if [[ $mode != ws && $host == *:* && $listen != :: ]]; then
                info '改为IPv6直连，需要同步调整共享入口的监听地址。'
                node_listen_prompt listen "$host" ::
            fi
            info '同入口所有用户一起更新连接地址；证书域名/SNI、UUID和端口保留。'
            begin_tx
            json_update --arg e "$entry" --arg h "$host" --arg l "$listen" '(.nodes[]|select(.entry==$e)) |= (. + {host:$h,listen:$l})';;
        rename)
            ask_valid newname '新的节点名称' "$name" valid_new_node_name '名称格式不合法或与其他节点重名，请输入1～48个英文、数字、下划线或横线。' "$name"
            [[ $newname != "$name" ]] || return 0
            begin_tx
            json_update --arg old "$name" --arg new "$newname" '(.nodes[]|select(.id==$old)|.id)=$new'
            name=$newname;;
        delete)
            confirm "删除节点 $name 的凭据（其他共享用户保留）" || return 0
            begin_tx; json_update --arg n "$name" '.nodes |= map(select(.id!=$n))';;
        enable|disable)
            begin_tx
            if [[ $action == enable ]]; then
                port=$(jq -r --arg n "$name" '.nodes[]|select(.id==$n)|.port' "$STATE")
                if ! jq -e --arg e "$entry" '.nodes[]|select(.entry==$e and .enabled)' "$STATE" >/dev/null; then check_port "$port"; fi
            fi
            json_update --arg n "$name" --argjson enabled "$([[ $action == enable ]] && echo true || echo false)" '(.nodes[]|select(.id==$n)|.enabled)=$enabled';;
        edit)
            proto=$(jq -r --arg n "$name" '.nodes[]|select(.id==$n)|.protocol' "$STATE")
            method=$(jq -r --arg n "$name" '.nodes[]|select(.id==$n)|.method' "$STATE")
            choose_credential credential "$proto" "$method" "$name"
            begin_tx; json_update --arg n "$name" --arg c "$credential" '(.nodes[]|select(.id==$n)|.credential)=$c';;
        port)
            old=$(jq -r --arg n "$name" '.nodes[]|select(.id==$n)|.port' "$STATE")
            ask_node_port port '新的入口端口（同入口所有用户一起修改；WS仅修改内部端口）' "$old" "$entry"
            [[ $port != "$old" ]] || { ok '端口未变更。'; return 0; }
            begin_tx; check_port "$port"
            json_update --arg e "$entry" --argjson p "$port" '(.nodes[]|select(.entry==$e)|.port)=$p';;
        *) die '未知节点操作。';;
    esac
    apply_config; commit_tx
    ok "节点操作完成: $action $name"
    if [[ $action == edit || $action == port || $action == address ]]; then node_export "$name"; fi
}

explain() {
    cat <<'EOF'
A：VLESS+REALITY+Vision直连（默认8443），网站单独使用80/443。
   代理不需要自有域名；网站仍需要域名和证书。
B：VLESS/VMess/Trojan + WebSocket，经Nginx TLS共用网站443。
   需要有效证书和可达的域名/指定IP；支持Cloudflare橙云，不要求公开DNS等于VPS IP。
额外：上述三个协议可选独立TCP+TLS；Shadowsocks使用独立TCP+UDP端口。
VMess还可选独立WS（无外层TLS），仍使用VMess AEAD加密，但不伪装成HTTPS。
WS+TLS适合网站共用443；WS封装本身不会加速，直连REALITY通常开销更低。
只启动一个Xray进程。A/B是新建节点的默认模式，允许明确选择其他支持的组合。
TLS/REALITY降低内容暴露，但不保证匿名、无法识别或永久可用。
本工具提供UFW/firewalld端口菜单；只按明确选择修改。云安全组需单独管理，不创建账户、不修改SSH配置。
服务按当前提升权限后的root账户运行，网站默认仅静态文件。
EOF
}
install_component() {
    local c=$1
    case "$c" in xray|nginx|acme);; *) die '组件名必须为xray/nginx/acme。';; esac
    if component_ready "$c"; then ok "$c 已安装，更新请用 update。"; return 0; fi
    begin_tx
    if [[ $c == nginx ]]; then
        local own=false
        if systemctl is-active --quiet vpskit-nginx.service; then own=true; fi
        check_port 80 "$own"; check_port 443 "$own"
    fi
    "install_$c"
    apply_config
    commit_tx
}
inspect_existing() {
    local service location
    for service in xray.service v2ray.service nginx.service x-ui.service; do
        location=$(systemctl show -p FragmentPath --value "$service" 2>/dev/null || true)
        if [[ -n $location ]]; then
            warn "发现非本工具服务: $service ($location)，保留；若端口冲突将单独处理。"
        fi
    done
    info "本工具残留检查完成；仅自动清理 $ROOT/tmp 中的暂存文件并恢复未完成事务。"
}
configure_wizard() {
    local scheme website host domain current
    explain
    ask_valid scheme '部署方案 A / B（回车保留上次选择）' "$(get '.scheme // "A"')" valid_scheme '方案只能为A或B。'
    scheme=${scheme^^}
    json_update --arg s "$scheme" '.scheme=$s | .wizard.selected=true | .wizard.defaults_ready=false'
    if [[ $(get '.preferences.access_chosen // false') != true && $(get '.sites|length') == 0 ]]; then
        json_update --arg s "$scheme" '.preferences.site_access=(if $s=="B" then "cloudflare" else "direct" end) | .preferences.challenge=(if $s=="B" then "dns_cf" else "http" end)'
    fi
    if [[ $scheme == B ]]; then
        website=yes
        info '方案B：网站与WS+TLS共用443；自动选择Nginx、acme.sh和域名证书。'
    else
        current=$(get '.wizard.website != false'); if [[ $current == true ]]; then current=yes; else current=no; fi
        ask_valid website '方案A同时部署HTTPS网站？yes/no（代理本身无需证书）' "$current" valid_choice '请输入yes或no。' 'yes no'
        ask_valid host 'VPS公网IP或直连域名（REALITY客户端连接地址）' "$(get '.host // ""')" valid_host '请输入IP或小写域名，不含https://、端口、路径或IPv6方括号。'
        json_update --arg h "$host" '.host=$h'
        if [[ -z $(default_domain) ]] && valid_domain "$host"; then remember_domain "$host"; fi
    fi
    json_update --argjson w "$([[ $website == yes ]] && printf true || printf false)" '.wizard.website=$w'
    if [[ $website == yes ]]; then
        current=$(get '.wizard.domain // ""'); [[ -n $current ]] || current=$(default_domain)
        ask_valid domain '自有网站域名（后续节点、网站和证书默认使用此域名）' "$current" valid_domain '请填写你能管理DNS的域名，不含https://或路径。'
        remember_domain "$domain"
        json_update --arg d "$domain" '.wizard.domain=$d'
        site_access_prompt "$domain"
        certificate_prompt "$domain"
        site_content_prompt "$domain"
        json_update '.wizard.site_pending=true'
    else json_update '.wizard.site_pending=false'; fi
    json_update '.wizard.defaults_ready=true'
    remember_step '方案与默认值' '已保存'
    wizard_preview
}
wizard_preview() {
    local domain website
    domain=$(get '.wizard.domain // ""'); website=$(get '.wizard.website != false')
    panel_title "已记住方案 $(get .scheme)"
    if [[ $(get .scheme) == A ]]; then
        printf '  代理：VLESS + REALITY + Vision；连接地址：%s；默认起始端口8443\n' "$(get '.host // "待输入"')"
    else printf '  代理：默认VLESS + WS + TLS；客户端连接 %s:443；内部端口从20000选择\n' "${domain:-待输入}"; fi
    if [[ $(get .scheme) == B || $website == true ]]; then
        printf '  网站：%s；内容类型：%s\n' "${domain:-待输入}" "$(get '.preferences.site_kind // "template"')"
        printf '  访问：%s；不强制公开DNS解析到本机IP\n' "$(get '.preferences.site_access // "direct"')"
        printf '  证书：Let\047s Encrypt / ECC P-256；验证：%s；泛域名：%s\n' "$(get '.preferences.challenge // "http"')" "$(get '.preferences.wildcard // false')"
        printf '  后续：检查组件 → 配置当前域名网站 → 签发/检查证书 → 添加本方案节点 → 检查本机运行\n'
    else printf '  后续：检查Xray → 添加REALITY节点 → 检查本机运行（无需网站证书）\n'; fi
    printf '  默认值已保存在本机；输入 :q 可中断当前操作，下次继续。\n'
}
install_all() {
    local choice domain free_kb existing_node
    init_preferences
    if [[ $(get '.wizard.selected // false') != true ]]; then configure_wizard
    else
        wizard_preview
        ask_valid choice '1=按上次方案继续未完成步骤，2=修改方案和默认值，0=返回' 1 valid_choice '请选择0、1或2。' '0 1 2'
        case "$choice" in 0) return 0;; 2) configure_wizard;; esac
    fi
    # Incomplete answers (e.g. :q during email input) resume with saved defaults.
    domain=$(get '.wizard.domain // ""')
    if [[ $(get '.wizard.defaults_ready != false') != true ]] || { [[ $(get .scheme) == A ]] && ! valid_host "$(get '.host // ""')"; }; then
        info '上次默认值尚未填写完整，保留已填内容并继续配置。'
        configure_wizard; domain=$(get '.wizard.domain // ""')
    fi
    if plan_needs_site; then
        if ! valid_domain "$domain" || ! valid_email "$(get '.preferences.email // ""')"; then
            info '域名或证书联系信息尚未填写完整，继续配置默认值。'
            configure_wizard; domain=$(get '.wizard.domain // ""')
        fi
    elif ! valid_host "$(get '.host // ""')"; then configure_wizard; fi
    WIZARD_ACTIVE=1
    inspect_existing
    free_kb=$(df -Pk "$ROOT" | awk 'NR==2{print $4}')
    ((free_kb >= 512000)) || die '可用磁盘不足500MB，请释放空间后继续；已输入的默认值保留。'
    remember_step '安装Xray'
    if component_ready xray; then ok 'Xray已安装，跳过下载。'; else install_component xray; fi
    if plan_needs_site; then
        remember_step '安装网站与证书工具'
        if component_ready nginx; then ok 'Nginx已安装，跳过下载。'; else install_component nginx; fi
        if component_ready acme; then ok 'acme.sh已安装，跳过下载。'; else install_component acme; fi
        remember_step "配置网站 $domain"
        if ! jq -e --arg d "$domain" '.sites[]|select(.domain==$d)' "$STATE" >/dev/null || [[ $(get '.wizard.site_pending // false') == true ]]; then
            site_apply_preferences "$domain"
        else ok "$domain 已配置，跳过重复建站。"; fi
        remember_step "检查/签发证书 $domain"
        if certificate_ready "$domain"; then ok '当前域名证书有效，跳过重复签发。'; else cert_issue "$domain"; fi
    fi
    remember_step '配置本方案节点'
    if [[ -n $(plan_nodes enabled) ]]; then
        ok '已存在本方案的启用节点，跳过重复创建。'
    elif [[ -n $(plan_nodes all) ]]; then
        existing_node=$(plan_nodes all | head -1)
        ask_valid choice "已有停用节点 $existing_node：1=启用，2=新建，0=稍后" 1 valid_choice '请选择0、1或2。' '0 1 2'
        case "$choice" in 1) node_action enable "$existing_node";; 2) node_add guided;; 0) remember_step '配置本方案节点' '待继续'; WIZARD_ACTIVE=0; return 0;; esac
    else
        ask_valid choice '现在添加本方案节点？yes/no' yes valid_choice '请输入yes或no。' 'yes no'
        if [[ $choice == yes ]]; then node_add guided
        else remember_step '配置本方案节点' '待继续'; WIZARD_ACTIVE=0; return 0; fi
    fi
    remember_step '检查本机运行'
    refresh_deployment
    if [[ $D_RUNTIME_OK != true ]]; then
        info '检查到服务、监听端口或续期timer尚未就绪，重新验证并应用配置。'
        begin_tx; apply_config; commit_tx
    fi
    refresh_deployment
    if [[ $D_COMPLETE == true ]]; then remember_step '部署向导' '本机检查通过'
    else remember_step '部署向导' '待继续'; warn "$D_NEXT"; fi
    WIZARD_ACTIVE=0
    deployment_details
    info '公网访问还需检查DNS、云安全组和客户端连通性；本机就绪不代表公网已验收。'
}
service_caption() {
    local v; v=$(systemctl is-active "vpskit-$1.service" 2>/dev/null || true)
    case "$v" in active) printf '运行中';; failed) printf '启动失败';; activating) printf '启动中';; *) printf '已停止';; esac
}
component_caption() {
    if component_ready "$1"; then
        if [[ $1 == acme ]]; then printf '已安装'; else printf '已安装 / %s' "$(service_caption "$1")"; fi
    elif [[ $(get ".components.$1 // false") == true ]]; then printf '异常：程序文件缺失'
    else printf '未安装'; fi
}
progress_step() {
    local label=$1 complete=$2 next=$3
    D_TOTAL=$((D_TOTAL+1))
    if [[ $complete == true ]]; then D_DONE=$((D_DONE+1)); D_ROWS+=("完成|$label")
    else
        D_ROWS+=("待办|$label")
        [[ -n $D_NEXT ]] || D_NEXT=$next
    fi
}
refresh_deployment() {
    local flag components=true d certfile p selected timer_active timer_enabled runtime=true
    D_TOTAL=0; D_DONE=0; D_NEXT=''; D_ROWS=(); D_COMPLETE=false
    D_SCHEME=$(get '.scheme // "A"'); D_DOMAIN=$(get '.wizard.domain // ""')
    D_NODE_TOTAL=$(get '.nodes|length'); D_NODE_ENABLED=$(get '[.nodes[]|select(.enabled)]|length')
    D_SITE_TOTAL=$(get '.sites|length'); D_PLAN_ENABLED=$(plan_nodes enabled | awk 'NF{n++} END{print n+0}')
    D_XRAY=$(component_caption xray); D_NGINX=$(component_caption nginx); D_ACME=$(component_caption acme)
    D_CERT_OK=0; D_CERT_DUE=0; D_CURRENT_CERT=false
    while read -r d; do
        if certificate_good "$d"; then
            D_CERT_OK=$((D_CERT_OK+1))
            if [[ $d == "$D_DOMAIN" ]] && certificate_ready "$d"; then D_CURRENT_CERT=true; fi
            certfile="$ROOT/certs/$d/current/fullchain.pem"
            if ! openssl x509 -in "$certfile" -noout -checkend 1209600 >/dev/null 2>&1; then D_CERT_DUE=$((D_CERT_DUE+1)); fi
        fi
    done < <(jq -r '.sites[].domain' "$STATE")
    timer_active=false; timer_enabled=false
    if systemctl is-active --quiet vpskit-maintain.timer; then timer_active=true; fi
    if systemctl is-enabled --quiet vpskit-maintain.timer 2>/dev/null; then timer_enabled=true; fi
    D_TIMER='未就绪'; [[ $timer_active != true || $timer_enabled != true ]] || D_TIMER='已开启'
    selected=$(get '.wizard.selected // false')
    [[ $(get '.wizard.defaults_ready != false') == true ]] || selected=false
    progress_step '选择并保存部署方案与默认值' "$selected" '打开部署与安装 → 继续部署向导，选择A或B方案。'
    flag=false
    if [[ $D_SCHEME == A ]]; then
        if valid_host "$(get '.host // ""')"; then flag=true; fi
    elif valid_domain "$D_DOMAIN"; then flag=true; fi
    progress_step '填写本方案连接地址 / 域名' "$flag" '继续部署向导，补全VPS连接地址或自有域名。'
    component_ready xray || components=false
    if plan_needs_site; then component_ready nginx || components=false; component_ready acme || components=false; fi
    progress_step '安装本方案所需组件' "$components" '继续部署向导，安装缺少的组件或修复缺失程序。'
    if plan_needs_site; then
        flag=false
        if jq -e --arg d "$D_DOMAIN" '.sites[]|select(.domain==$d)' "$STATE" >/dev/null && [[ $(get '.wizard.site_pending // false') != true ]]; then flag=true; fi
        progress_step "配置网站 ${D_DOMAIN:-（待填写）}" "$flag" '继续部署向导，配置已保存的域名和网站类型。'
        flag=false; [[ $D_CURRENT_CERT != true || $D_TIMER != '已开启' ]] || flag=true
        progress_step '域名证书有效 + 自动续期已开启' "$flag" '检查网站与证书，或继续部署向导重试签发/恢复续期timer。'
        systemctl is-active --quiet vpskit-nginx.service || runtime=false
        [[ $D_TIMER == '已开启' ]] || runtime=false
        for p in 80 443; do [[ -n $(ss -H -lnt "sport = :$p" 2>/dev/null) ]] || runtime=false; done
    fi
    flag=false; ((D_PLAN_ENABLED == 0)) || flag=true
    progress_step "本方案启用节点（$D_PLAN_ENABLED 个）" "$flag" '继续部署向导添加本方案节点，或在节点管理中启用已有节点。'
    D_CONFIG_OK=false; ((D_DONE != D_TOTAL)) || D_CONFIG_OK=true
    systemctl is-active --quiet vpskit-xray.service || runtime=false
    ((D_PLAN_ENABLED > 0)) || runtime=false
    [[ -s $ROOT/config/xray.json ]] || runtime=false
    if plan_needs_site; then [[ -s $ROOT/config/nginx.conf ]] || runtime=false; fi
    while read -r p; do [[ -n $(ss -H -lnt "sport = :$p" 2>/dev/null) ]] || runtime=false; done < <(jq -r '[.nodes[]|select(.enabled)]|unique_by(.entry)[].port' "$STATE")
    D_RUNTIME_OK=$runtime
    progress_step '本机服务与所需TCP端口就绪' "$runtime" '打开状态、日志与维护检查服务，或继续部署向导修复运行配置。'
    if ((D_DONE == D_TOTAL)); then D_COMPLETE=true; D_DEPLOYMENT='已完成 / 本机运行正常'; D_NEXT='本机检查通过；可导出节点，并从客户端验证公网连接。'
    elif [[ $D_CONFIG_OK == true ]]; then D_DEPLOYMENT='配置完成 / 运行异常'
    elif [[ $(get '.wizard.selected // false') != true ]]; then D_DEPLOYMENT='待选择方案'
    elif [[ $selected != true ]]; then D_DEPLOYMENT='待完善方案默认值'
    else D_DEPLOYMENT="进行中 $D_DONE/$D_TOTAL"; fi
}
deployment_details() {
    refresh_deployment
    panel_title "部署进度 · $D_DEPLOYMENT"
    local row kind label color
    for row in "${D_ROWS[@]}"; do
        kind=${row%%|*}; label=${row#*|}; color=$YELLOW; [[ $kind != 完成 ]] || color=$GREEN
        printf '  %s[%s]%s %s\n' "$color" "$kind" "$RESET" "$label"
    done
    printf '  %s下一步：%s%s\n' "$BLUE" "$D_NEXT" "$RESET"
    printf '  节点：总计%s / 配置启用%s / 当前方案启用%s；网站：%s；有效证书：%s；14天内到期：%s\n' "$D_NODE_TOTAL" "$D_NODE_ENABLED" "$D_PLAN_ENABLED" "$D_SITE_TOTAL" "$D_CERT_OK" "$D_CERT_DUE"
}

update_component() {
    local c=$1
    if [[ $c == manager ]]; then update_manager; return; fi
    case "$c" in xray|nginx|acme);; *) die '更新目标：xray/nginx/acme/manager/all。';; esac
    ensure_component "$c"
    begin_tx
    if [[ $c == xray ]]; then
        local requested
        ask_valid requested 'Xray版本：latest或v版本（默认经本脚本配置测试的版本）' "$XRAY_TESTED_VERSION" valid_version '格式示例：v26.3.27 或 latest。'
        install_xray "$requested"
    else "install_$c"; fi
    apply_config
    if [[ $c == nginx ]]; then
        systemctl restart vpskit-nginx.service
        sleep 0.3
        systemctl is-active --quiet vpskit-nginx.service || die 'Nginx新程序启动失败。'
    fi
    commit_tx
}
update_all() {
    local c
    for c in xray nginx acme; do
        if [[ $(get ".components.$c") == true ]]; then update_component "$c"; fi
    done
    update_manager
    ok '全部已安装组件依次更新完成；未执行整机系统升级。'
}
update_manager() {
    local stage="$WORK/manager.new" v
    info "管理脚本更新来源: $SELF_URL"
    confirm '从你的GitHub仓库下载并替换管理脚本' || return 0
    fetch "$SELF_URL" "$stage"
    grep -Fq 'VPSKIT_SINGLE_FILE' "$stage" || die '文件标识不匹配。'
    bash -n "$stage"
    v=$(sed -n "s/^VERSION='\([0-9.]*\)'$/\1/p" "$stage" | head -1)
    [[ -n $v ]] || die '没有有效版本号。'
    cp "$ROOT/vpskit.sh" "$ROOT/backup/manager.previous"
    install -m 700 "$stage" "$ROOT/vpskit.sh.new"
    mv -f "$ROOT/vpskit.sh.new" "$ROOT/vpskit.sh"
    json_update --arg v "$v" '.manager=$v'
    ok "管理脚本已更新至$v；当前会话仍执行旧代码，下次唤醒使用新版本。"
}
rollback_last() {
    [[ -f $ROOT/backup/last/ready ]] || die '没有可回滚快照。'
    confirm '恢复最近一次操作前的节点、配置及程序；之后增加的节点将被撤销' || return 0
    restore_tx "$ROOT/backup/last" || die '回滚不完整，保留快照供排查。'
    rm -rf "$ROOT/backup/last"
    ok '回滚完成。'
}
remove_unit() {
    local u=$1
    if [[ -f $SYSTEMD/$u ]] && grep -Fq '# VPSKIT_OWNED' "$SYSTEMD/$u"; then
        systemctl disable --now "$u" 2>/dev/null || true
        rm -f -- "$SYSTEMD/$u"
        systemctl reset-failed "$u" 2>/dev/null || true
    fi
}
uninstall_component() {
    local c=$1
    case "$c" in xray|nginx|acme);; *) die '卸载目标：xray/nginx/acme/all。';; esac
    if [[ $c == nginx ]]; then
        jq -e '.nodes[]|select(.mode=="ws" or .mode=="tls")' "$STATE" >/dev/null && die '仍有域名/TLS节点，请先移除它们。'
        [[ $(jq '.sites|length' "$STATE") == 0 ]] || die '仍有网站绑定，请先执行 site remove。'
    fi
    if [[ $c == acme ]]; then
        [[ $(jq '.sites|length' "$STATE") == 0 ]] || die '仍有网站依赖自动证书，请先移除网站。'
    fi
    confirm "卸载$c及其私有资料；不会卸载系统原有同名程序" || return 0
    begin_tx
    case "$c" in
        xray) json_update '.nodes=[] | .components.xray=false | del(.versions.xray)'; systemctl disable --now vpskit-xray.service 2>/dev/null || true; rm -f "$XRAY" "$ROOT/config/xray.json";;
        nginx) json_update '.components.nginx=false | del(.versions.nginx)'; systemctl disable --now vpskit-nginx.service 2>/dev/null || true; rm -rf "$ROOT/nginx"; mkdir -p "$ROOT/nginx"; rm -f "$ROOT/config/nginx.conf";;
        acme) json_update '.components.acme=false | del(.versions.acme)'; rm -rf "$ROOT/acme" "$ROOT/certs"; mkdir -p "$ROOT/acme" "$ROOT/certs";;
    esac
    apply_config
    commit_tx
    # Component removal should not retain its binaries/secrets in a generic rollback copy.
    rm -rf "$ROOT/backup/last" "$ROOT/backup/manager.previous"
    case "$c" in xray) remove_unit vpskit-xray.service;; nginx) remove_unit vpskit-nginx.service;; esac
    systemctl daemon-reload
    ok "$c 已卸载；管理工具及其他组件保留。"
}
purge_owned_packages() {
    local -a pkgs=(); local p simulated removed
    [[ -s $ROOT/data/packages.added ]] || return 0
    while read -r p; do
        [[ $p =~ ^[a-z0-9][a-z0-9+.:_-]+$ ]] || die '依赖包清单异常。'
        if dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null | grep -qx installed; then pkgs+=("$p"); fi
    done < "$ROOT/data/packages.added"
    ((${#pkgs[@]})) || return 0
    printf '本工具新增过的依赖包：\n%s\n' "${pkgs[*]}"
    confirm '尝试移除这些共享依赖（若涉及其他包则拒绝）' || return 0
    simulated=$(apt-get -s purge "${pkgs[@]}") || die '卸载模拟失败，保留依赖。'
    while read -r removed; do
        [[ -z $removed ]] && continue
        printf '%s\n' "${pkgs[@]}" | grep -Fxq "$removed" || die "移除将影响其他软件包 $removed；已保留依赖。"
    done < <(printf '%s\n' "$simulated" | awk '$1=="Remv"||$1=="Purg"{print $2}')
    run apt-get -y purge "${pkgs[@]}"
}
uninstall_all() {
    printf '将删除：\n  %s\n  %s\n  VPSKit服务、续期timer、全部节点/私钥/网站/日志/备份、本工具防火墙规则及Swap\n' "$ROOT" "$ENTRY"
    printf '已配置网站：\n'; jq -r '.sites[].domain' "$STATE"
    warn '完整卸载不可恢复。请先把需要保留的网站文件复制到其他位置。不会删除其他工具的目录或系统共享日志。'
    confirm '完整卸载VPSKit' || return 0
    swap_remove no
    firewall_cleanup no
    tuning_restore no
    UNINSTALLING=1
    local u
    for u in vpskit-maintain.timer vpskit-maintain.service vpskit-xray.service vpskit-nginx.service; do remove_unit "$u"; done
    systemctl daemon-reload
    # Optional dependency purge uses only a whitelist recorded at the actual dependency installation.
    purge_owned_packages
    [[ ! -L $ROOT && $(cat "$ROOT/.vpskit-owned") == VPSKIT_V1 && $(stat -c %u "$ROOT") == 0 ]] || die '目录归属检查失败，停止删除。'
    if [[ -L $ENTRY && $(readlink "$ENTRY") == "$ROOT/vpskit.sh" ]]; then rm -f "$ENTRY"; fi
    cd /
    LOGFILE=''; WORK=''
    rm -rf --one-file-system -- "$ROOT"
    [[ ! -e $ROOT ]] || die '仍有挂载点或不可删除内容，请人工检查 /opt/vpskit。'
    ok '完整卸载完成。本工具文件、入口、服务和任务已移除。'
}
status() {
    deployment_details
    printf '\nVPSKit %s | 默认方案 %s | 目录 %s\n' "$VERSION" "$(get .scheme)" "$ROOT"
    free -m; df -h "$ROOT"
    jq -r '.versions|to_entries[]|"\(.key): \(.value)"' "$STATE"
    local u
    for u in xray nginx; do printf '%s: ' "$u"; systemctl is-active "vpskit-$u.service" || true; done
    printf '续期任务: '; systemctl is-active vpskit-maintain.timer || true
    printf '节点数: '; jq '.nodes|length' "$STATE"
    cert_status || true
}
doctor() {
    status
    validate_state
    [[ $(get .components.xray) != true ]] || "$XRAY" run -test -config "$ROOT/config/xray.json"
    [[ $(get .components.nginx) != true ]] || nginx_cmd -t -p "$ROOT/" -c "$ROOT/config/nginx.conf"
    printf '\n监听端口：\n'; ss -lntup
    printf '\n续期timer：\n'; systemctl list-timers vpskit-maintain.timer --no-pager
    local d
    while read -r d; do
        info "DNS解析 $d"; getent ahosts "$d" || warn '解析失败。'
        if [[ -s $ROOT/certs/$d/current/fullchain.pem ]]; then
            info "通过公网域名检查HTTPS $d（若使用CDN，检查的是CDN证书）"
            curl -fsSI --connect-timeout 10 --max-time 20 "https://$d/" || warn '公网HTTPS检查失败。'
            timeout 15 openssl s_client -connect "$d:443" -servername "$d" </dev/null 2>/dev/null | openssl x509 -noout -dates -issuer || warn '未读取到线上证书。'
        fi
    done < <(jq -r '.sites[].domain' "$STATE")
    warn '云安全组、实际客户端连通性、性能和REALITY目标适用性还需从客户端验收。'
}
logs() {
    local c=${1:-manager} file
    case "$c" in xray) file="$ROOT/logs/xray.log";; nginx) file="$ROOT/logs/nginx.log";; manager) file="$ROOT/logs/manage.log";; cert) journalctl -u vpskit-maintain.service -n 100 --no-pager; return;; *) die '日志目标：xray/nginx/manager/cert。';; esac
    [[ -f $file ]] || { warn '尚无日志。'; return 0; }
    tail -n 100 "$file"
}
service_action() {
    local action=$1 c=$2
    case "$action" in start|stop|restart);; *) die '服务操作必须是start/stop/restart。';; esac
    case "$c" in xray|nginx);; *) die '服务目标必须是xray/nginx。';; esac
    ensure_component "$c"
    systemctl "$action" "vpskit-$c.service"
    systemctl is-active "vpskit-$c.service" || [[ $action == stop ]]
}
maintenance() {
    rotate_logs
    if [[ $(get .components.acme) == true ]]; then cert_renew; fi
}
# Reversible system-wide tuning. Kept outside generic configuration snapshots so
# ordinary node/certificate rollback cannot silently change kernel tuning files.
tuning_paths_ok() {
    [[ -d ${SYSCTL_LINK%/*} && ! -L ${SYSCTL_LINK%/*} ]] || die 'sysctl.d目录异常。'
    if [[ -e $SYSCTL_LINK || -L $SYSCTL_LINK ]]; then
        [[ -L $SYSCTL_LINK && $(readlink "$SYSCTL_LINK") == "$ROOT/data/sysctl.conf" ]] || die "$SYSCTL_LINK 已被其他工具使用，保留并停止。"
    fi
}
tuning_write_persistent() {
    tuning_paths_ok
    if [[ -f $ROOT/data/tuning.json ]] && jq -e '.keys|length>0' "$ROOT/data/tuning.json" >/dev/null; then
        { printf '# VPSKIT_OWNED -- manage with vpskit optimize\n'; jq -r '.keys|to_entries[]|"\(.key) = \(.value.applied)"' "$ROOT/data/tuning.json"; } > "$ROOT/data/sysctl.conf.new"
        chmod 600 "$ROOT/data/sysctl.conf.new"
        mv -f "$ROOT/data/sysctl.conf.new" "$ROOT/data/sysctl.conf"
        ln -sfn "$ROOT/data/sysctl.conf" "$SYSCTL_LINK"
    else
        if [[ -L $SYSCTL_LINK ]]; then rm -f "$SYSCTL_LINK"; fi
        rm -f "$ROOT/data/sysctl.conf" "$ROOT/data/tuning.json"
    fi
}
tuning_begin() {
    local intent=$1 tx="$ROOT/backup/tuning-transaction" f
    tuning_paths_ok
    [[ ! -e $tx ]] || die '有待恢复的网络调优事务，请执行 repair。'
    mkdir -p "$tx"
    for f in tuning.json sysctl.conf; do [[ ! -f $ROOT/data/$f ]] || cp -a "$ROOT/data/$f" "$tx/$f"; done
    [[ ! -L $SYSCTL_LINK ]] || touch "$tx/had-link"
    cp "$intent" "$tx/changes.json"
    touch "$tx/ready"
}
tuning_recover() {
    local tx="$ROOT/backup/tuning-transaction" row key before after current f
    [[ -d $tx ]] || return 0
    if [[ ! -f $tx/ready ]]; then rm -rf "$tx"; return 0; fi
    tuning_paths_ok
    warn '恢复上次未完成的网络调优。'
    while read -r row; do
        key=$(jq -r .key <<< "$row"); before=$(jq -r .value.before <<< "$row"); after=$(jq -r .value.after <<< "$row")
        case "$key" in net.ipv4.tcp_congestion_control|net.core.default_qdisc|net.ipv4.tcp_mtu_probing);; *) warn '调优快照中有未知参数。'; return 1;; esac
        current=$(sysctl -n "$key") || return 1
        if [[ $current == "$before" ]]; then continue; fi
        if [[ $current != "$after" ]]; then warn "$key 已被外部改为 $current；保留快照，需核对后再恢复。"; return 1; fi
        sysctl -q -w "$key=$before" || return 1
    done < <(jq -c 'to_entries[]' "$tx/changes.json")
    for f in tuning.json sysctl.conf; do
        if [[ -f $tx/$f ]]; then cp -a "$tx/$f" "$ROOT/data/$f" || return 1; else rm -f "$ROOT/data/$f"; fi
    done
    if [[ -f $tx/had-link ]]; then ln -sfn "$ROOT/data/sysctl.conf" "$SYSCTL_LINK"; else rm -f "$SYSCTL_LINK"; fi
    rm -rf "$tx"
    ok '网络调优已恢复到该次操作之前。'
}
tuning_apply() {
    local kind=$1 key value current previous tracked intent="$WORK/tuning-intent.json" record="$WORK/tuning-record.json" i
    local -a keys=() values=()
    case "$kind" in
        bbr)
            confirm '启用BBR与默认fq队列；这会影响整台VPS的新TCP连接' || return 0
            if ! sysctl -n net.ipv4.tcp_available_congestion_control | tr ' ' '\n' | grep -Fxq bbr; then
                if command -v modprobe >/dev/null; then modprobe tcp_bbr || true; fi
            fi
            sysctl -n net.ipv4.tcp_available_congestion_control | tr ' ' '\n' | grep -Fxq bbr || die '当前内核不提供BBR；保留原值，不安装内核、不重启。'
            if command -v modprobe >/dev/null; then modprobe sch_fq 2>/dev/null || true; fi
            keys=(net.core.default_qdisc net.ipv4.tcp_congestion_control); values=(fq bbr);;
        mtu)
            confirm '启用按需TCP MTU黑洞探测（值1）；适用于部分卡顿链路，影响整台VPS' || return 0
            keys=(net.ipv4.tcp_mtu_probing); values=(1);;
        *) die '未知调优方式。';;
    esac
    tuning_paths_ok
    printf '{}\n' > "$intent"
    if [[ -f $ROOT/data/tuning.json ]]; then cp "$ROOT/data/tuning.json" "$record"; else printf '{"keys":{}}\n' > "$record"; fi
    for i in "${!keys[@]}"; do
        key=${keys[$i]}; value=${values[$i]}
        current=$(sysctl -n "$key") || die "内核未提供 $key，未应用调优。"
        tracked=$(jq -r --arg k "$key" '.keys[$k].applied // empty' "$record")
        [[ -z $tracked || $current == "$tracked" ]] || die "$key 已被其他工具修改；先运行 optimize restore，再重新选择。"
        previous=$(jq -r --arg k "$key" --arg v "$current" '.keys[$k].before // $v' "$record")
        jq --arg k "$key" --arg v "$previous" --arg a "$value" '.keys[$k]={before:$v,applied:$a}' "$record" > "$record.new"; mv "$record.new" "$record"
        jq --arg k "$key" --arg b "$current" --arg a "$value" '.[$k]={before:$b,after:$a}' "$intent" > "$intent.new"; mv "$intent.new" "$intent"
    done
    tuning_begin "$intent"
    for i in "${!keys[@]}"; do
        key=${keys[$i]}; value=${values[$i]}
        info "设置 $key=$value"
        sysctl -q -w "$key=$value"
        [[ $(sysctl -n "$key") == "$value" ]] || die "$key 未生效。"
    done
    mv "$record" "$ROOT/data/tuning.json"
    tuning_write_persistent
    rm -rf "$ROOT/backup/tuning-transaction"
    ok '调优已应用并持久化，可用 optimize restore 恢复。'
    warn '现有监听器/连接可能仍使用原算法；维护时重启本工具服务后再对比。fq默认值不会替换现有网卡队列。'
    tuning_status
}
tuning_restore() {
    local interactive=${1:-yes} row key before applied current intent="$WORK/tuning-intent.json"
    if [[ ! -f $ROOT/data/tuning.json ]]; then
        [[ ! -L $SYSCTL_LINK || $(readlink "$SYSCTL_LINK") != "$ROOT/data/sysctl.conf" ]] || die '调优记录缺失但仍有持久化链接，请先人工核对，防止丢失原值。'
        ok '没有本工具管理的内核调优。'; return 0
    fi
    [[ $interactive != yes ]] || { confirm '恢复本工具修改前的内核参数，并移除调优持久化配置' || return 0; }
    printf '{}\n' > "$intent"
    while read -r row; do
        key=$(jq -r .key <<< "$row"); before=$(jq -r .value.before <<< "$row"); applied=$(jq -r .value.applied <<< "$row")
        case "$key" in net.ipv4.tcp_congestion_control|net.core.default_qdisc|net.ipv4.tcp_mtu_probing);; *) die '调优记录参数异常。';; esac
        current=$(sysctl -n "$key") || die "无法读取 $key；保留恢复资料。"
        if [[ $current != "$applied" ]]; then warn "$key 已被外部改为 $current，保留外部值。"; continue; fi
        jq --arg k "$key" --arg b "$current" --arg a "$before" '.[$k]={before:$b,after:$a}' "$intent" > "$intent.new"; mv "$intent.new" "$intent"
    done < <(jq -c '.keys|to_entries[]' "$ROOT/data/tuning.json")
    tuning_begin "$intent"
    while read -r row; do
        key=$(jq -r .key <<< "$row"); before=$(jq -r .value.after <<< "$row")
        sysctl -q -w "$key=$before"
        [[ $(sysctl -n "$key") == "$before" ]] || die "恢复 $key 未生效，保留资料。"
    done < <(jq -c 'to_entries[]' "$intent")
    printf '{"keys":{}}\n' > "$ROOT/data/tuning.json"
    tuning_write_persistent
    rm -rf "$ROOT/backup/tuning-transaction"
    ok '内核调优已恢复；现有连接/网卡队列的状态由内核继续管理。'
}
tuning_status() {
    local key
    printf '\n%s网络调优状态%s\n' "$BLUE" "$RESET"
    for key in net.ipv4.tcp_available_congestion_control net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.tcp_mtu_probing; do
        printf '  %s = %s\n' "$key" "$(sysctl -n "$key" 2>/dev/null || printf '内核未提供')"
    done
    printf '  静态网站gzip: %s\n' "$(get '.performance.gzip // false')"
    if [[ -f $ROOT/data/tuning.json ]]; then jq -r '.keys|to_entries[]|"  已记录：\(.key)，原值=\(.value.before)，设定值=\(.value.applied)"' "$ROOT/data/tuning.json"; fi
    if command -v tc >/dev/null; then printf '\n当前网卡队列（只读）：\n'; tc qdisc show || true; fi
    printf '\nBBR取决于内核与链路；WS本身不加速。gzip只减少静态文本传输量。\n不扩大TCP缓冲、不更换内核、不自动修改网卡队列或防火墙。\n'
}
gzip_action() {
    local enabled=$1
    ensure_component nginx
    begin_tx
    json_update --argjson e "$enabled" '.performance.gzip=$e'
    apply_config; commit_tx
    ok "静态网站轻量gzip=$enabled；级别2，只压缩大于1KB的文本，不压缩代理节点或动态网站响应。"
}
optimize_action() {
    case "${1:-status}" in
        status) tuning_status;; bbr|mtu) tuning_apply "$1";; restore) tuning_restore;;
        gzip-on) gzip_action true;; gzip-off) gzip_action false;;
        *) die '用法: vpskit optimize status|bbr|mtu|restore|gzip-on|gzip-off';;
    esac
}

# Firewall changes are explicit and use a separate durable ownership journal.
# They are not rolled back by a proxy configuration transaction.
firewall_init() {
    local f="$ROOT/data/firewall.json"
    [[ ! -L $f ]] || die '防火墙记录不能是符号链接。'
    if [[ ! -f $f ]]; then printf '[]\n' > "$f"; fi
    jq -e 'type=="array"' "$f" >/dev/null || die '防火墙记录损坏，停止更改规则。'
}
firewall_detect() {
    FW_BACKEND=none
    local ua=false fa=false ufw_state
    if command -v ufw >/dev/null; then
        if ! ufw_state=$(ufw status 2>/dev/null); then FW_BACKEND=error; return 0; fi
        if grep -q '^Status: active' <<< "$ufw_state"; then ua=true; fi
    fi
    if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then fa=true; fi
    if [[ $ua == true && $fa == true ]]; then FW_BACKEND=conflict
    elif [[ $ua == true ]]; then FW_BACKEND=ufw
    elif [[ $fa == true ]]; then FW_BACKEND=firewalld; fi
}
firewall_status() {
    firewall_detect
    panel_title "防火墙状态 · $FW_BACKEND"
    if command -v ufw >/dev/null; then ufw status numbered || true; else printf 'UFW：未安装\n'; fi
    if command -v firewall-cmd >/dev/null; then
        if firewall-cmd --state; then firewall-cmd --get-active-zones; firewall-cmd --list-all; fi
    else printf 'firewalld：未安装\n'; fi
    if [[ -f $ROOT/data/firewall.json ]]; then
        printf '\n本工具规则记录（也包含待完成操作）：\n'
        jq -r '.[]|[.backend,.zone,(.port|tostring),.proto,.action,.scope]|@tsv' "$ROOT/data/firewall.json"
    fi
    printf '\n仅管理已启用的UFW/firewalld；不自动启用、禁用或重置整机防火墙。\n原生nftables/iptables、Docker链及云安全组可能另有限制，请从外网验证新连接。\n'
}
firewall_prepare() {
    firewall_detect
    case "$FW_BACKEND" in
        error) die '无法读取UFW状态，请先排查其权限或内核错误；为避免冲突，未修改任何规则。';;
        none) die '未发现已启用的UFW/firewalld；请先通过系统配置启用一个防火墙。脚本不自动改变整机默认策略。';;
        conflict) die 'UFW和firewalld同时启用，请先明确使用其中一个，避免两套规则互相影响。';;
    esac
    firewall_init
    FW_ZONE=''
    if [[ $FW_BACKEND == firewalld ]]; then
        local zones
        info 'firewalld按zone管理；请选择公网网卡/来源实际所属的zone。'
        firewall-cmd --get-active-zones
        zones=$(firewall-cmd --get-zones)
        ask_valid FW_ZONE '需要修改的zone' "$(firewall-cmd --get-default-zone)" valid_choice '请选择现有zone（上方显示接口绑定，firewall-cmd --get-zones可列出全部）。' "$zones"
    fi
}
firewall_record() {
    local verb=$1 backend=$2 zone=$3 port=$4 proto=$5 action=$6 scope=$7 f="$ROOT/data/firewall.json"
    jq --arg v "$verb" --arg b "$backend" --arg z "$zone" --argjson p "$port" --arg t "$proto" --arg a "$action" --arg s "$scope" '
      map(select((.backend==$b and .zone==$z and .port==$p and .proto==$t and .action==$a and .scope==$s)|not)) |
      if $v=="add" then .+[{backend:$b,zone:$z,port:$p,proto:$t,action:$a,scope:$s}] else . end' "$f" > "$f.new"
    chmod 600 "$f.new"; mv -f "$f.new" "$f"
}
firewall_ufw_rule() {
    # show added supplies canonical commands, independent of translated table columns.
    local action=$1 port=$2 proto=$3 line rules
    rules=$(ufw show added) || die '无法读取UFW规则。'
    while IFS= read -r line; do
        line=${line#ufw }
        if [[ $line == "$action $port/$proto" || $line == "$action $port/$proto comment "* ]]; then printf '%s' "$line"; return 0; fi
    done <<< "$rules"
}
firewall_rich_rule() { printf 'rule priority="-17321" port port="%s" protocol="%s" %s' "$1" "$2" "$3"; }
firewall_remove_record() {
    local backend=$1 zone=$2 port=$3 proto=$4 action=$5 scope=$6 rule line tag rc
    if ! valid_port "$port" || ! valid_choice "$proto" 'tcp udp'; then die '防火墙记录中的端口/协议无效。'; fi
    case "$backend" in
        ufw)
            valid_choice "$action" 'allow deny' || die 'UFW记录动作无效。'
            command -v ufw >/dev/null || die 'UFW程序缺失，无法清理已记录规则。'
            line=$(firewall_ufw_rule "$action" "$port" "$proto")
            tag="vpskit-managed-$port-$proto-$action"
            if [[ $line == *" comment '$tag'" || $line == *" comment $tag" ]]; then
                run ufw --force delete "$action" "$port/$proto"
            elif [[ -n $line ]]; then warn "保留已由外部修改的UFW规则：$port/$proto。"; fi;;
        firewalld)
            if ! valid_choice "$action" 'accept drop' || ! valid_choice "$scope" 'runtime permanent' || [[ ! $zone =~ ^[a-zA-Z0-9_-]+$ ]]; then die 'firewalld记录格式无效。'; fi
            if ! command -v firewall-cmd >/dev/null || ! firewall-cmd --state >/dev/null 2>&1; then die '请先启动firewalld以清理规则；记录仍保留。'; fi
            local -a args=(--zone="$zone"); [[ $scope != permanent ]] || args+=(--permanent)
            rule=$(firewall_rich_rule "$port" "$proto" "$action")
            if firewall-cmd "${args[@]}" --query-rich-rule="$rule" >/dev/null; then
                run firewall-cmd "${args[@]}" --remove-rich-rule="$rule"
            else rc=$?; ((rc==1)) || die '查询firewalld规则失败，保留记录。'; fi;;
        *) die '未知防火墙记录类型。';;
    esac
    firewall_record del "$backend" "$zone" "$port" "$proto" "$action" "$scope"
}
firewall_ssh_ports() {
    local _client_ip _client_port _server_ip p sshbin
    printf '22\n'
    if [[ -n ${SSH_CONNECTION:-} ]]; then
        read -r _client_ip _client_port _server_ip p <<< "$SSH_CONNECTION"
        if valid_port "${p:-}"; then printf '%s\n' "$((10#$p))"; fi
    fi
    sshbin=$(command -v sshd || true)
    if [[ -n $sshbin ]]; then "$sshbin" -T 2>/dev/null | awk '$1=="port"{print $2}' || true; fi
    # Include listening and established SSH sockets (also covers socket activation
    # once an SSH connection exists), including dropbear when used instead of sshd.
    { ss -H -lntp 2>/dev/null; ss -H -ntp 2>/dev/null; } |
        awk '/sshd|dropbear/{n=split($4,a,":"); if(a[n]~/^[0-9]+$/)print a[n]}' || true
}
valid_firewall_port() {
    valid_port "$1" || return 1
    local p=$((10#$1))
    if [[ ${FW_PROTOCOL:-tcp} != udp ]] && grep -Fxq "$p" <<< "${FW_SSH_PORTS:-22}"; then return 1; fi
    return 0
}
firewall_change() {
    local operation=$1 port=$2 proto=$3 backend=$FW_BACKEND zone=$FW_ZONE action opposite scope rule line tag rc
    if ! valid_port "$port" || ! valid_choice "$proto" 'tcp udp' || ! valid_choice "$operation" 'open close'; then die '防火墙操作、端口或协议无效。'; fi
    # Recheck SSH immediately before applying any TCP close, including cleanup callers.
    if [[ $proto == tcp ]] && grep -Fxq "$port" <<< "$(firewall_ssh_ports)"; then
        if [[ $operation == close ]]; then die '拒绝关闭SSH端口。'; fi
        warn "端口$port属于SSH，跳过本工具规则管理，请保留系统SSH放行规则。"; return 0
    fi
    if [[ $backend == ufw ]]; then
        action=allow; opposite=deny; [[ $operation != close ]] || { action=deny; opposite=allow; }
    else action=accept; opposite=drop; [[ $operation != close ]] || { action=drop; opposite=accept; }; fi
    # Remove only this tool's opposite rule; external rules stay untouched.
    while IFS=$'\t' read -r scope; do
        [[ -n $scope ]] || continue
        firewall_remove_record "$backend" "$zone" "$port" "$proto" "$opposite" "$scope"
    done < <(jq -r --arg b "$backend" --arg z "$zone" --argjson p "$port" --arg t "$proto" --arg a "$opposite" '.[]|select(.backend==$b and .zone==$z and .port==$p and .proto==$t and .action==$a)|.scope' "$ROOT/data/firewall.json")
    if [[ $backend == ufw ]]; then
        tag="vpskit-managed-$port-$proto-$action"
        line=$(firewall_ufw_rule "$action" "$port" "$proto")
        if [[ -n $line ]]; then
            if [[ $line == *" comment '$tag'" || $line == *" comment $tag" ]]; then firewall_record add "$backend" "$zone" "$port" "$proto" "$action" all
            else warn "已有外部同类规则 $port/$proto，未接管；请检查其优先级和最终效果。"; fi
            return 0
        fi
        firewall_record add "$backend" "$zone" "$port" "$proto" "$action" all
        run ufw insert 1 "$action" "$port/$proto" comment "$tag"
    else
        rule=$(firewall_rich_rule "$port" "$proto" "$action")
        for scope in permanent runtime; do
            local -a args=(--zone="$zone"); [[ $scope != permanent ]] || args+=(--permanent)
            if firewall-cmd "${args[@]}" --query-rich-rule="$rule" >/dev/null; then
                info "规则已存在：$scope $zone $port/$proto $action；不重复添加。"
            else
                rc=$?; ((rc==1)) || die '读取firewalld规则失败。'
                firewall_record add "$backend" "$zone" "$port" "$proto" "$action" "$scope"
                run firewall-cmd "${args[@]}" --add-rich-rule="$rule"
            fi
        done
    fi
}
firewall_port_action() {
    local operation=$1 port proto
    firewall_prepare
    ask_valid FW_PROTOCOL '协议 tcp / udp / both（两者）' tcp valid_choice '请选择tcp、udp或both。' 'tcp udp both'
    FW_SSH_PORTS=$(firewall_ssh_ports | sort -nu)
    ask_valid port '需要操作的端口（单个1～65535）' '' valid_firewall_port '端口格式错误，或选择了受保护的SSH端口（SSH规则由系统单独管理）。'
    port=$((10#$port))
    warn "将对新入站连接执行 $operation：$FW_BACKEND ${FW_ZONE:-} $port/$FW_PROTOCOL。已有连接可能继续；关闭80/443会影响网站、WS或HTTP证书验证。"
    confirm '应用以上端口规则' || return 0
    for proto in tcp udp; do
        [[ $FW_PROTOCOL == both || $FW_PROTOCOL == "$proto" ]] || continue
        firewall_change "$operation" "$port" "$proto"
    done
    ok '端口规则操作完成；请查看防火墙状态，并从外网验证新连接。'
}
firewall_required_ports() {
    if [[ $(get '.sites|length') -gt 0 ]] || { [[ $(get '.wizard.selected // false') == true ]] && plan_needs_site; }; then printf '80 tcp\n443 tcp\n'; fi
    jq -r '.nodes[]|select(.enabled and .mode!="ws" and .listen!="127.0.0.1" and .listen!="::1")|"\(.port) tcp",(if .protocol=="shadowsocks" then "\(.port) udp" else empty end)' "$STATE"
}
firewall_sync() {
    local ports port proto
    firewall_prepare
    ports=$(firewall_required_ports | sort -u)
    [[ -n $ports ]] || { info '还没有需要放行的网站/公网代理端口。'; return 0; }
    printf '将放行以下入站端口（WS本机内部端口不对公网开放）：\n%s\n' "$ports"
    info '只添加当前需要的放行规则；停用/删除节点后的旧端口，请通过关闭端口功能处理。'
    confirm '放行这些网站与节点端口' || return 0
    while read -r port proto; do firewall_change open "$port" "$proto"; done <<< "$ports"
    ok '所需端口规则已处理；云安全组需另行放行。'
}
firewall_cleanup() {
    [[ -f $ROOT/data/firewall.json ]] || return 0
    firewall_init
    [[ $(jq length "$ROOT/data/firewall.json") -gt 0 ]] || return 0
    if [[ ${1:-ask} != no ]]; then
        warn '撤销本工具添加的允许/阻止规则，恢复由原有防火墙规则决定访问；网站和代理可能不可达。'
        confirm '清理本工具的防火墙规则' || return 0
    fi
    local backend zone port proto action scope row present line tag
    while IFS= read -r row; do
        backend=$(jq -r .backend <<< "$row"); zone=$(jq -r .zone <<< "$row"); port=$(jq -r .port <<< "$row")
        proto=$(jq -r .proto <<< "$row"); action=$(jq -r .action <<< "$row"); scope=$(jq -r .scope <<< "$row")
        # Never remove an allow rule if that port has subsequently become SSH.
        if [[ $proto == tcp && ( $action == allow || $action == accept ) ]] && grep -Fxq "$port" <<< "$(firewall_ssh_ports)"; then
            present=true
            if [[ $backend == ufw ]]; then
                line=$(firewall_ufw_rule "$action" "$port" "$proto"); tag="vpskit-managed-$port-$proto-$action"
                if [[ $line != *" comment '$tag'" && $line != *" comment $tag" ]]; then present=false; fi
            elif [[ $backend == firewalld ]]; then
                local -a check_args=(--zone="$zone"); [[ $scope != permanent ]] || check_args+=(--permanent)
                if firewall-cmd --state >/dev/null 2>&1 && ! firewall-cmd "${check_args[@]}" --query-rich-rule="$(firewall_rich_rule "$port" "$proto" "$action")" >/dev/null 2>&1; then present=false; fi
            fi
            if [[ $present == true ]]; then die "端口$port现用于SSH，不能自动撤销其放行规则。请先建立独立SSH放行规则，并手动移除本工具对应规则后重试。"; fi
        fi
        firewall_remove_record "$backend" "$zone" "$port" "$proto" "$action" "$scope"
    done < <(jq -c '.[]' "$ROOT/data/firewall.json")
    ok '本工具记录的防火墙规则已清理；外部规则及防火墙软件保留。'
}
firewall_menu() {
    local choice
    while [[ -f $STATE ]]; do
        panel_title '防火墙端口管理 · 已启用的UFW / firewalld'
        menu_item 1 '查看状态与规则' '显示防火墙、zone和本工具操作记录'
        menu_item 2 '开放端口' '输入端口及TCP/UDP，确认后放行新入站连接'
        menu_item 3 '关闭端口' '增加阻止规则，保护SSH；已有连接可能继续'
        menu_item 4 '放行网站与节点所需端口' '根据配置生成清单；WS本机内部端口不对公网开放'
        menu_item 5 '撤销本工具的防火墙规则' '保留外部规则；不重置或卸载整机防火墙'
        menu_item 0 '返回' '云安全组仍需在服务商控制台管理'
        ask choice '选择编号' 0
        case "$choice" in 1) menu_run firewall_status;; 2) menu_run firewall_port_action open;; 3) menu_run firewall_port_action close;;
            4) menu_run firewall_sync;; 5) menu_run firewall_cleanup;; 0) return;; *) warn '无效选择，请重新输入。';; esac
    done
}
firewall_action() {
    case "$1" in status) firewall_status;; open|close) firewall_port_action "$1";; sync) firewall_sync;; cleanup) firewall_cleanup;; *) die '用法：vpskit firewall status|open|close|sync|cleanup';; esac
}

# Swap has its own ownership journal; never include a GiB-sized swapfile in
# configuration snapshots, or touch any pre-existing system swap/fstab entries.
swap_unit_name() { systemd-escape --path --suffix=swap "$ROOT/swap/swapfile"; }
swap_active() { awk -v p="$ROOT/swap/swapfile" 'NR>1 && $1==p{found=1} END{exit !found}' /proc/swaps; }
swap_used_kib() { awk -v p="$ROOT/swap/swapfile" 'NR>1 && $1==p{used=$4} END{print used+0}' /proc/swaps; }
swap_available_kib() { awk '/^MemAvailable:/{print $2; found=1} END{if(!found)print 0}' /proc/meminfo; }
swap_free_mib() { df -Pk "$ROOT" | awk 'NR==2{print int($4/1024)}'; }
swap_filesystem() { findmnt -n -o FSTYPE --target "$ROOT"; }
swap_container() { systemd-detect-virt --container --quiet; }
valid_swap_size() { [[ $1 =~ ^[0-9]{3,4}$ ]] && ((10#$1>=256 && 10#$1<=4096 && 10#$1%256==0)); }
swap_check_ownership() {
    local file="$ROOT/swap/swapfile" record="$ROOT/data/swap.json" unit
    unit=$(swap_unit_name)
    [[ ! -L $ROOT/swap && ! -L $file && ! -L $record && ! -L $SYSTEMD/$unit ]] || die 'Swap路径为符号链接；拒绝接管。'
    if [[ -e $SYSTEMD/$unit ]]; then
        grep -Fxq '# VPSKIT_OWNED_SWAP' "$SYSTEMD/$unit" || die '存在同名外部Swap服务，拒绝修改。'
    fi
    if [[ -e $record ]]; then
        [[ -f $record ]] || die 'Swap记录不是普通文件。'
        jq -e --arg f "$file" --arg u "$unit" '.owner=="VPSKIT_SWAP_V1" and .path==$f and .unit==$u and (.phase=="creating" or .phase=="prepared" or .phase=="ready") and (.size_mib|type=="number")' "$record" >/dev/null || die 'Swap归属记录异常，保留现场。'
        valid_swap_size "$(jq -r .size_mib "$record")" || die 'Swap容量记录异常。'
        [[ ! -e $file || -f $file ]] || die 'Swap路径不是普通文件。'
    elif [[ -e $file ]] || swap_active || [[ -e $SYSTEMD/$unit ]]; then
        die '发现没有本工具归属记录的Swap文件/服务；拒绝覆盖或删除，请人工核实。'
    fi
}
swap_record() {
    local size=$1 phase=$2 tmp
    tmp=$(mktemp "$ROOT/data/.swap.XXXXXXXX")
    jq -n --arg p "$ROOT/swap/swapfile" --arg u "$(swap_unit_name)" --arg s "$phase" --argjson m "$size" \
        '{owner:"VPSKIT_SWAP_V1",path:$p,unit:$u,size_mib:$m,phase:$s}' > "$tmp"
    chmod 600 "$tmp"; mv -f "$tmp" "$ROOT/data/swap.json"
}
swap_caption() {
    if [[ ! -f $ROOT/data/swap.json ]]; then printf '本工具未配置'; return; fi
    if swap_active; then
        if systemctl is-enabled --quiet "$(swap_unit_name)" 2>/dev/null; then printf '运行中 / 重启保留'; else printf '运行中 / 持久化待修复'; fi
    else printf '已记录 / 未启用（可重试）'; fi
}
swap_status() {
    panel_title 'Swap虚拟内存'
    free -m
    printf '\n系统所有Swap（只读）：\n'; cat /proc/swaps
    printf '\n本工具：%s\n' "$(swap_caption)"
    if [[ -f $ROOT/data/swap.json ]]; then
        jq -r '"容量：\(.size_mib) MiB；阶段：\(.phase)\n文件：\(.path)\n持久化服务：\(.unit)"' "$ROOT/data/swap.json"
    fi
    printf 'Swap是磁盘缓冲，速度慢于RAM；不能替代物理内存或提高网络带宽。\n'
}
swap_enable() {
    local mode=${1:-recommended} size=1024 free_mib phase=creating file="$ROOT/swap/swapfile" record="$ROOT/data/swap.json" unit tool
    for tool in swapon swapoff mkswap dd findmnt systemd-escape systemd-detect-virt; do command -v "$tool" >/dev/null || die "缺少工具 $tool，请先安装util-linux、coreutils和systemd。"; done
    swap_check_ownership
    swap_container && die '容器通常不能自行配置Swap，请在宿主机或服务商控制台处理。'
    case "$(swap_filesystem)" in ext2|ext3|ext4|xfs) ;; *) die '自动Swap仅支持ext2/ext3/ext4/XFS；其他文件系统需专门配置，未创建文件。';; esac
    if [[ -f $record ]]; then
        size=$(jq -r .size_mib "$record"); phase=$(jq -r .phase "$record")
        info "继续使用已记录的 $size MiB Swap；变更容量请先安全移除再创建。"
    elif [[ $mode == custom ]]; then
        ask_valid size 'Swap容量MiB（256～4096，256的倍数）' 1024 valid_swap_size '请输入256～4096且为256倍数的整数。'
        size=$((10#$size))
    fi
    unit=$(swap_unit_name)
    if ! swap_active; then
        if [[ ! -f $file || $phase == creating ]]; then
            # A partial dd file is retained after interruption; retry can recreate
            # it only while inactive. Reserve 1 GiB for OS, updates and the site.
            free_mib=$(swap_free_mib)
            if [[ -f $file ]]; then free_mib=$((free_mib + $(du -k "$file" | awk '{print int($1/1024)}'))); fi
            ((free_mib-size>=1024)) || die "磁盘空间不足：创建${size}MiB后须至少剩余1024MiB。可选较小容量或清理磁盘。"
            mkdir -p "$ROOT/swap"; chmod 700 "$ROOT/swap"
            swap_record "$size" creating
            info "分配 $size MiB Swap文件（512MiB RAM推荐1024MiB；现有系统Swap保留）。"
            run dd if=/dev/zero of="$file" bs=1M count="$size" status=progress conv=fsync
            chmod 600 "$file"
            run mkswap "$file"
            swap_record "$size" prepared
        fi
        info '启用Swap；若平台不允许，保留归属记录，稍后可重试或移除。'
        run swapon --priority 10 "$file"
        swap_active || die 'swapon返回成功但未发现活动Swap，保留文件供检查。'
    fi
    unit_write "$unit" <<UNIT
# VPSKIT_OWNED
# VPSKIT_OWNED_SWAP
[Unit]
Description=VPSKit persistent swap
[Swap]
What=$file
Priority=10
TimeoutSec=120
[Install]
WantedBy=swap.target
UNIT
    run systemctl daemon-reload
    run systemctl enable "$unit"
    systemctl is-enabled --quiet "$unit" || die 'Swap已启用但开机持久化失败；请再次运行swap enable修复。'
    swap_record "$size" ready
    ok "Swap已启用：$size MiB；开机通过 $unit 自动启用。"
}
swap_remove() {
    local prompt=${1:-yes} file="$ROOT/swap/swapfile" record="$ROOT/data/swap.json" unit used available
    swap_check_ownership
    [[ -f $record ]] || { info '没有本工具管理的Swap。'; return 0; }
    unit=$(swap_unit_name)
    if [[ $prompt == yes ]]; then confirm '关闭并删除本工具Swap及开机服务（其他系统Swap保留）' || return 0; fi
    if swap_active; then
        used=$(swap_used_kib); available=$(swap_available_kib)
        ((available>=used+131072)) || die '当前可用RAM不足以安全移除Swap（需已用Swap+128MiB余量）；请先停止占内存的程序再重试。'
        info '仅停用本工具Swap；失败时保留文件和持久化服务。'
        if ! swapoff "$file"; then die 'swapoff失败，未删除Swap；请释放内存后重试。'; fi
        swap_active && die 'Swap仍然处于活动状态，拒绝删除。'
    fi
    if [[ -e $SYSTEMD/$unit ]]; then
        run systemctl disable "$unit"
        rm -f -- "$SYSTEMD/$unit"
        run systemctl daemon-reload
    fi
    rm -f -- "$file" "$record"
    if [[ -d $ROOT/swap ]]; then rmdir "$ROOT/swap" 2>/dev/null || warn 'Swap目录有其他文件，已保留。'; fi
    ok '本工具Swap和开机服务已移除。'
}
swap_menu() {
    local choice
    while [[ -f $STATE ]]; do
        panel_title "Swap虚拟内存 · $(swap_caption)"
        menu_item 1 '一键添加 / 恢复Swap' '推荐1024MiB；文件集中存放，开机自动启用；已有配置则修复'
        menu_item 2 '自定义容量' '256～4096MiB，256的倍数；至少保留1GiB磁盘空间'
        menu_item 3 '内存与Swap状态' '查看实际使用量、其他系统Swap及开机持久化状态'
        menu_item 4 '移除本工具Swap' '先检查可用RAM，成功停用后再删除；保留其他Swap'
        menu_item 0 '返回' '回到主菜单'
        ask choice '选择编号' 0
        case "$choice" in 1) menu_run swap_enable;; 2) menu_run swap_enable custom;; 3) menu_run swap_status;; 4) menu_run swap_remove;; 0) return;; *) warn '无效选择。';; esac
    done
}
swap_action() {
    case "$1" in enable) swap_enable;; custom) swap_enable custom;; status) swap_status;; remove) swap_remove;; *) die '用法：vpskit swap status|enable|custom|remove';; esac
}

path_row() {
    local label=$1 path=$2 state='未创建 / 无权查看' color=$YELLOW
    if [[ -L $path && ! -e $path ]]; then state='链接目标缺失'; color=$RED
    elif [[ -e $path ]]; then state='存在'; color=$GREEN; fi
    printf '  %s[%s]%s %s\n      %s\n' "$color" "$state" "$RESET" "$label" "$path"
}
show_paths() {
    panel_title '配置文件与安装目录（只显示路径，不显示凭据）'
    path_row '集中安装目录' "$ROOT"
    path_row '管理脚本' "$ROOT/vpskit.sh"
    path_row '终端唤醒入口' "$ENTRY"
    path_row 'Xray配置：所有代理协议共用' "$ROOT/config/xray.json"
    path_row 'Xray可执行文件' "$XRAY"
    path_row 'Nginx配置：网站、TLS、WS反向代理' "$ROOT/config/nginx.conf"
    path_row 'Nginx可执行文件' "$NGINX"
    path_row '管理状态：节点、域名、偏好（含敏感信息）' "$STATE"
    path_row 'acme.sh程序' "$ACME"
    path_row 'ACME账户及DNS验证配置（含敏感信息）' "$ROOT/acme/config"
    path_row 'ACME证书存储' "$ROOT/acme/certstore"
    path_row '网站内容总目录' "$ROOT/www"
    path_row 'HTTP证书验证目录' "$ROOT/www/acme/.well-known/acme-challenge"
    local d
    if [[ -r $STATE ]] && command -v jq >/dev/null; then
        while IFS= read -r d; do
            valid_domain "$d" || continue
            path_row "网站：$d" "$ROOT/www/$d"
            path_row "证书链：$d" "$ROOT/certs/$d/current/fullchain.pem"
            path_row "证书私钥：$d" "$ROOT/certs/$d/current/key.pem"
        done < <(jq -r '.sites[]?.domain // empty' "$STATE" 2>/dev/null)
    fi
    path_row 'Xray日志' "$ROOT/logs/xray.log"
    path_row 'Nginx日志' "$ROOT/logs/nginx.log"
    path_row '管理日志' "$ROOT/logs/manage.log"
    path_row '配置回滚快照' "$ROOT/backup/last"
    path_row 'Swap文件' "$ROOT/swap/swapfile"
    path_row 'Swap归属与阶段记录' "$ROOT/data/swap.json"
    if command -v systemd-escape >/dev/null; then path_row 'Swap开机服务' "$SYSTEMD/$(swap_unit_name)"; fi
    path_row '防火墙操作记录' "$ROOT/data/firewall.json"
    path_row '内核调优配置' "$ROOT/data/sysctl.conf"
    path_row '内核调优系统入口' "$SYSCTL_LINK"
    for d in xray.service nginx.service maintain.service maintain.timer; do
        path_row "systemd：vpskit-$d" "$SYSTEMD/vpskit-$d"
    done
    path_row '系统UFW配置（如已安装）' /etc/ufw
    path_row '系统firewalld配置（如已安装）' /etc/firewalld
    printf '\n生成的Xray/Nginx配置会被菜单操作重新生成；请优先通过面板修改。\n网站文件可以自行编辑；配置、状态和私钥不要上传到公开仓库。\n续期任务日志：journalctl -u vpskit-maintain.service -n 100 --no-pager\n'
}

help_text() {
    cat <<'EOF'
VPSKit 单文件管理器
  sudo bash vpskit.sh                  首次启动/菜单
  sudo vpskit                         管理菜单
  sudo vpskit install [xray|nginx|acme] 完整向导/单组件安装
  sudo vpskit node add                 添加节点/共享入口用户
  sudo vpskit node list
  sudo vpskit node export [名称或序号]       输出含凭据的客户端链接
  sudo vpskit node edit [名称或序号]         更换UUID/密码
  sudo vpskit node rename [名称或序号]       修改节点名称
  sudo vpskit node address [名称或序号] 修改连接域名/IPv4/IPv6，保留SNI
  sudo vpskit node port [名称或序号]         修改整个入口端口
  sudo vpskit node enable|disable|delete [名称或序号]
  sudo vpskit site add|edit|list|remove|default
  sudo vpskit wizard configure|status  保存默认值/查看逐步进度
  sudo vpskit cert issue|renew|status|settings
  sudo vpskit update xray|nginx|acme|manager|all
  sudo vpskit optimize                 网络与网站优化菜单
  sudo vpskit optimize status|bbr|mtu|restore|gzip-on|gzip-off
  sudo vpskit rollback                 回滚最近一次配置事务（内核调优单独恢复）
  sudo vpskit service start|stop|restart xray|nginx
  sudo vpskit paths                    查看配置、证书、日志、服务等路径
  sudo vpskit firewall                 防火墙管理菜单
  sudo vpskit firewall status|open|close|sync|cleanup
  sudo vpskit swap                     Swap虚拟内存菜单
  sudo vpskit swap status|enable|custom|remove
  sudo vpskit status|doctor|repair
  sudo vpskit logs xray|nginx|manager|cert
  sudo vpskit uninstall xray|nginx|acme|all
  bash vpskit.sh help|version|explain   不需要root，不修改系统
  bash vpskit.sh selftest              本地静态功能测试，不联网、不部署
选项: --no-color（放在命令之前）
格式错误可原地重输，输入:q取消当前操作；已保存的方案和偏好保留。
修改命令需要交互输入；定时续期为无人值守。无危险的全局--force。
默认仓库文件: biao169/V2ray_deploy/main/vpskit.sh
仅支持Debian 12+ / Ubuntu 18.04+、systemd、amd64/arm64。不创建用户、不修改SSH。
Ubuntu旧版本需要仍可用的软件源及更新后的基础库；脚本不改软件源。
仅一个Xray进程，Nginx单worker；面板无常驻Web进程，适合小型静态网站与少量连接。
网站内容: /opt/vpskit/www/域名。证书续期依赖DNS和网络可用性。
默认拒绝代理访问回环/私网/云元数据地址，不下载GeoIP/GeoSite大规则。
默认内核锁定到本地验证版本；更新时可输入latest或指定版本。
配置变更会重启Xray；大量持续连接时请安排维护窗口。
完整卸载后系统软件包日志/已存在依赖不属于本工具文件，不擦除。
EOF
}
panel_title() { printf '\n%s%s━━ %s ━━%s\n' "$BOLD" "$MAGENTA" "$1" "$RESET"; }
menu_item() {
    local tone=$BLUE
    case "$2" in *卸载*|*删除*|*移除*|*关闭端口*) tone=$RED;; esac
    [[ $1 != 0 ]] || tone=$DIM
    printf '  %s%2s%s  %s%s%s\n      %s%s%s\n' "$tone" "$1" "$RESET" "$BOLD" "$2" "$RESET" "$DIM" "$3" "$RESET"
}
status_badge() {
    local value=$1 tone=$YELLOW
    case "$value" in *异常*|*失败*|*缺失*) tone=$RED;; *未*|*待*|*停*|*进行中*) tone=$YELLOW;; *正常*|*运行*|*就绪*|*已*|*完成*) tone=$GREEN;; esac
    printf '%s%s%s' "$tone" "$value" "$RESET"
}
panel_header() {
    local memory disk last domain
    refresh_deployment
    memory=$(free -m | awk '/^Mem:/{printf "%s/%s MiB（可用%s）",$3,$2,$7}')
    disk=$(df -h "$ROOT" | awk 'NR==2{printf "%s可用",$4}')
    domain=$(default_domain); domain=${domain:-待配置}
    panel_title "VPSKit $VERSION · 轻量终端面板"
    printf '  %s方案 %s%s  |  默认网站 %s%s%s\n' "$BOLD" "$D_SCHEME" "$RESET" "$CYAN" "$domain" "$RESET"
    printf '  部署：'; status_badge "$D_DEPLOYMENT"; printf '（%s/%s步骤）\n' "$D_DONE" "$D_TOTAL"
    printf '  Xray：'; status_badge "$D_XRAY"; printf '  |  Nginx：'; status_badge "$D_NGINX"; printf '  |  acme.sh：'; status_badge "$D_ACME"; printf '\n'
    printf '  节点 %s%s%s（配置启用%s） | 网站 %s | 有效证书 %s | 续期 ' "$CYAN" "$D_NODE_TOTAL" "$RESET" "$D_NODE_ENABLED" "$D_SITE_TOTAL" "$D_CERT_OK"
    status_badge "$D_TIMER"; printf '\n'
    printf '  %s内存 %s | 磁盘 %s%s\n' "$DIM" "$memory" "$disk" "$RESET"
    printf '  Swap：'; status_badge "$(swap_caption)"; printf '\n'
    if ((D_CERT_DUE>0)); then printf '  %s提醒：%s张证书不足14天，请检查续期。%s\n' "$YELLOW" "$D_CERT_DUE" "$RESET"; fi
    last=$(get '.wizard.last_step // ""')
    if [[ -n $last ]]; then printf '  上次步骤：%s / ' "$last"; status_badge "$(get '.wizard.last_result // ""')"; printf '\n'; fi
    printf '  %s下一步：%s%s\n' "$CYAN" "$D_NEXT" "$RESET"
    printf '  %s数据: %s | 唤醒: sudo vpskit | 输入错误可重试，:q取消%s\n' "$DIM" "$ROOT" "$RESET"
    printf '  %s正常%s / %s待处理%s / %s异常或删除操作%s · 状态以文字同时标示\n' "$GREEN" "$RESET" "$YELLOW" "$RESET" "$RED" "$RESET"
}
menu_run() {
    # A subshell retains errexit and its rollback trap. Calling it in if/|| would
    # disable errexit in Bash functions, allowing failed commands to be committed.
    local rc
    set +e
    trap - ERR
    (
        set -Ee
        trap 'on_error $? $LINENO' ERR
        trap on_exit EXIT
        [[ -f $STATE ]] || die '部署已被另一会话移除，请退出面板。'
        flock -w 5 "$LOCK_FD" || die '另一个管理任务正在执行，请稍后再试。'
        [[ $(stat -Lc '%d:%i' "/proc/self/fd/$LOCK_FD") == "$(stat -Lc '%d:%i' "$ROOT/run/manage.lock")" ]] || die '部署锁已被另一会话替换，请退出并重新运行vpskit。'
        HAVE_LOCK=1
        PANEL_IDLE=0
        WORK=$(mktemp -d "$ROOT/tmp/menu.XXXXXXXX")
        TX=0
        recover
        init_preferences
        "$@"
    )
    rc=$?
    set -e
    trap 'on_error $? $LINENO' ERR
    flock -u "$LOCK_FD"
    if ((rc != 0)); then warn "本次操作未完成（$rc），已返回面板。"; fi
    if [[ -f $STATE ]]; then local answer; ask answer '按回车返回菜单' ''; fi
}
component_menu() {
    local action=$1 choice
    while [[ -f $STATE ]]; do
        refresh_deployment
        panel_title "$action · 独立组件管理"
        printf '  部署：%s | Xray：%s | Nginx：%s | acme.sh：%s\n' "$D_DEPLOYMENT" "$D_XRAY" "$D_NGINX" "$D_ACME"
        case "$action" in
            install) menu_item 1 "继续部署向导 · $D_DEPLOYMENT" "已完成步骤自动跳过；$D_NEXT";;
            update) menu_item 1 '更新所有已装组件' '依次更新Xray、Nginx、证书工具、管理脚本';;
            uninstall) menu_item 1 '完整卸载' '删除本工具全部资料，并恢复本工具内核调优';;
        esac
        menu_item 2 'Xray代理核心' '只处理代理程序；卸载会删除所有代理节点'
        menu_item 3 'Nginx网站与WS入口' '只处理独立Nginx；有依赖的网站/节点时禁止卸载'
        menu_item 4 'acme.sh自动证书' '只处理证书工具；有证书依赖时禁止卸载'
        [[ $action != update ]] || menu_item 5 '管理脚本' '从你配置的GitHub地址更新；下次唤醒生效'
        if [[ $action == install ]]; then
            menu_item 5 '修改方案与默认值' '保存方案、域名、证书验证方式和网站类型；继续部署时应用'
            menu_item 6 '查看逐步进度' '根据程序文件、配置、证书、服务和端口判断完成情况'
        fi
        menu_item 0 '返回' '回到主菜单'
        ask choice '选择编号' 0
        case "$choice" in
            0) return;;
            1) menu_run "${action}_all";;
            2) menu_run "${action}_component" xray;;
            3) menu_run "${action}_component" nginx;;
            4) menu_run "${action}_component" acme;;
            5) if [[ $action == update ]]; then menu_run update_manager; elif [[ $action == install ]]; then menu_run configure_wizard; else warn '无效选择。'; fi;;
            6) if [[ $action == install ]]; then menu_run deployment_details; else warn '无效选择。'; fi;;
            *) warn '无效选择。';;
        esac
    done
}
node_menu() {
    local choice
    while [[ -f $STATE ]]; do
        refresh_deployment
        panel_title "节点与用户管理 · 共$D_NODE_TOTAL个 / 配置启用$D_NODE_ENABLED个"
        printf '  当前方案%s匹配节点：%s | Xray：%s\n' "$D_SCHEME" "$D_PLAN_ENABLED" "$D_XRAY"
        menu_item 1 '添加节点 / 共享入口用户' '选择协议和传输；UUID、密码、端口可默认或自定义'
        menu_item 2 '节点列表' '查看协议、传输、入口端口和启用状态'
        menu_item 3 '导出客户端链接' '链接含凭据；请仅交给可信客户端'
        menu_item 4 '更换UUID / 密码' '旧凭据立即失效，同入口其他用户保留'
        menu_item 5 '修改入口端口' '检查占用；共享该入口的所有用户一起修改'
        menu_item 6 '修改节点名称' '修改管理名称与导出链接备注'
        menu_item 7 '启用节点' '检查入口端口，再恢复代理服务'
        menu_item 8 '停用节点' '保留参数，可随时再次启用'
        menu_item 9 '删除节点' '按列表序号选择；删除该用户凭据前确认'
        menu_item 10 '修改连接域名 / IPv4 / IPv6' '按序号选择；保留证书域名/SNI，更新整个共享入口的连接地址'
        menu_item 0 '返回' '回到主菜单'
        ask choice '选择编号' 0
        case "$choice" in
            1) menu_run node_add;; 2) menu_run node_list;; 3) menu_run node_export;;
            4) menu_run node_action edit;; 5) menu_run node_action port;; 6) menu_run node_action rename;;
            7) menu_run node_action enable;; 8) menu_run node_action disable;; 9) menu_run node_action delete;; 10) menu_run node_action address;;
            0) return;; *) warn '无效选择。';;
        esac
    done
}
site_list() { jq '.sites|map(del(.email))' "$STATE"; }
site_default() { local domain; site_select domain; ok "默认网站已记住：$domain"; }
site_menu() {
    local choice
    while [[ -f $STATE ]]; do
        refresh_deployment
        panel_title "网站与证书 · 网站$D_SITE_TOTAL个 / 有效证书$D_CERT_OK张"
        printf '  默认域名：%s | 续期：%s | 14天内到期：%s\n' "$(default_domain)" "$D_TIMER" "$D_CERT_DUE"
        menu_item 1 '添加 / 继续配置网站' '默认使用已记住域名；轻量模板、自建网站、反代或跳转'
        menu_item 2 '修改网站' '修改站点内容入口等参数'
        menu_item 3 '网站列表' '查看域名和部署状态'
        menu_item 4 '删除网站' '先检查节点依赖，再确认删除'
        menu_item 5 '签发 / 重新签发证书' 'HTTP验证或支持的DNS API验证'
        menu_item 6 '检查续期' '调用ACME按到期策略续期，不强制重复签发'
        menu_item 7 '证书状态' '查看当前证书与到期时间'
        menu_item 8 '修改证书默认值' '设置邮箱、HTTP/DNS验证及泛域名选项'
        menu_item 9 '选择默认网站' '记住已有域名，供后续网站和节点操作使用'
        menu_item 0 '返回' '回到主菜单'
        ask choice '选择编号' 0
        case "$choice" in
            1) menu_run site_add;; 2) menu_run site_edit;; 3) menu_run site_list;; 4) menu_run site_remove;;
            5) menu_run cert_issue;; 6) menu_run cert_renew;; 7) menu_run cert_status;;
            8) menu_run site_certificate_edit;; 9) menu_run site_default;;
            0) return;; *) warn '无效选择。';;
        esac
    done
}
optimize_menu() {
    local choice
    while [[ -f $STATE ]]; do
        panel_title '网络与网站优化（512MB保守设置）'
        menu_item 1 '查看能力与当前状态' '检查内核算法、MTU探测、网卡队列和gzip'
        menu_item 2 '启用BBR + 默认fq' '可能改善部分高延迟/丢包链路；需要内核支持'
        menu_item 3 '启用按需MTU探测' '检测到MTU黑洞时尝试较小报文；不保证提速'
        menu_item 4 '恢复内核原值' '撤销本工具的BBR/fq/MTU设置和持久化文件'
        menu_item 5 '开启静态网站轻量gzip' '压缩HTML/CSS/JS等；级别2，减少文本传输量'
        menu_item 6 '关闭静态网站gzip' '节省压缩CPU；适合CPU受限或已预压缩的站点'
        menu_item 0 '返回' 'WS已关闭代理缓冲；TLS会话缓存、TCP_NODELAY默认启用'
        ask choice '选择编号' 0
        case "$choice" in
            1) menu_run tuning_status;; 2) menu_run tuning_apply bbr;; 3) menu_run tuning_apply mtu;;
            4) menu_run tuning_restore;; 5) menu_run gzip_action true;; 6) menu_run gzip_action false;;
            0) return;; *) warn '无效选择。';;
        esac
    done
}
service_menu() {
    local choice action component
    panel_title '服务控制'
    menu_item 1 '启动' '启动已经安装的组件'
    menu_item 2 '停止' '停止组件；网站或代理会暂时不可用'
    menu_item 3 '重启' '重新建立监听器；现有连接可能中断'
    menu_item 0 '返回' '不修改服务'
    ask_valid choice '操作编号' 0 valid_choice '请选择0～3。' '0 1 2 3'
    case "$choice" in 0) return;; 1) action=start;; 2) action=stop;; 3) action=restart;; *) warn '无效选择。'; return;; esac
    menu_item 1 'Xray' '代理节点服务'
    menu_item 2 'Nginx' '网站和WS+TLS入口'
    ask_valid choice '组件编号' 1 valid_choice '请选择1或2。' '1 2'
    case "$choice" in 1) component=xray;; 2) component=nginx;; *) warn '无效选择。'; return;; esac
    menu_run service_action "$action" "$component"
}
operations_menu() {
    local choice
    while [[ -f $STATE ]]; do
        panel_title '状态、日志与维护'
        menu_item 1 '运行状态' '查看资源、组件版本、节点和证书状态'
        menu_item 2 '诊断检查' '验证配置，查看端口、DNS、HTTPS和续期timer'
        menu_item 3 'Xray日志' '最近100行代理错误日志'
        menu_item 4 'Nginx日志' '最近100行网站/WS入口错误日志'
        menu_item 5 '管理日志' '最近100行安装与管理过程日志'
        menu_item 6 '证书任务日志' '查看systemd续期任务结果'
        menu_item 7 '恢复中断事务' '重试恢复上次未完成的配置或调优操作'
        menu_item 8 '回滚最近一次配置' '恢复节点、证书和程序快照；内核调优在优化菜单恢复'
        menu_item 9 '服务启动 / 停止 / 重启' '按组件控制，操作可能中断现有连接'
        menu_item 10 '配置文件与安装目录' '显示Xray、Nginx、网站、证书和日志的实际路径'
        menu_item 0 '返回' '回到主菜单'
        ask choice '选择编号' 0
        case "$choice" in
            1) menu_run status;; 2) menu_run doctor;; 3) menu_run logs xray;; 4) menu_run logs nginx;;
            5) menu_run logs manager;; 6) menu_run logs cert;; 7) menu_run recover;; 8) menu_run rollback_last;;
            9) service_menu;; 10) menu_run show_paths;; 0) return;; *) warn '无效选择。';;
        esac
    done
}
main_menu() {
    local choice
    # An idle panel must not block hourly certificate renewal or another terminal.
    PANEL_IDLE=1
    HAVE_LOCK=0
    flock -u "$LOCK_FD"
    while [[ -f $STATE ]]; do
        panel_header
        menu_item 1 "部署与安装 · $D_DEPLOYMENT" '记住A/B方案和默认值；继续未完成步骤'
        menu_item 2 "节点与用户 · $D_NODE_TOTAL个 / 启用$D_NODE_ENABLED个" '添加、导出、修改、停用或删除多个代理节点'
        menu_item 3 "网站与证书 · $D_SITE_TOTAL个网站 / $D_CERT_OK张有效证书" "默认域名：$(default_domain)；自动续期：$D_TIMER"
        menu_item 4 '网络与网站优化' "当前拥塞算法：$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf 未知)；静态gzip：$(get '.performance.gzip // false')"
        menu_item 5 '组件更新' "Xray：$(get '.versions.xray // "未安装"')；Nginx：$(get '.versions.nginx // "未安装"')；支持独立或全部更新"
        menu_item 6 '状态、日志与维护' '资源用量、诊断、服务控制与事务回滚'
        menu_item 7 '卸载' '按组件卸载，或删除本工具全部资料'
        menu_item 8 '方案说明与命令帮助' '查看要求、传输区别和命令行入口'
        menu_item 9 '配置文件与目录' '查看Xray、Nginx、证书、日志与网站路径'
        menu_item 10 '防火墙端口管理' 'UFW / firewalld状态、端口开闭和所需端口放行'
        menu_item 11 'Swap虚拟内存' '一键添加1024MiB磁盘Swap，重启保留；支持状态、自定义容量和安全移除'
        menu_item 0 '退出' '后台代理、网站和自动续期继续运行'
        ask choice '请选择数字' 0
        case "$choice" in
            1) component_menu install;; 2) node_menu;; 3) site_menu;; 4) optimize_menu;;
            5) component_menu update;; 6) operations_menu;; 7) component_menu uninstall;;
            8) menu_run show_help;; 9) menu_run show_paths;; 10) firewall_menu;; 11) swap_menu;; 0) return;; *) warn '无效选择，请输入菜单编号。';;
        esac
    done
}
show_help() { explain; help_text; }

selftest() {
    command -v jq >/dev/null || die 'selftest需要jq。'
    local t test_fail=0
    for t in example.com xn--fiqs8s.example a-b.example; do valid_domain "$t" || test_fail=1; done
    for t in 'a;reboot.com' '../x.com' '-a.example' 'a..example' 'a.com/new' '*.example.com'; do if valid_domain "$t"; then test_fail=1; fi; done
    for t in 1 443 65535 08443; do valid_port "$t" || test_fail=1; done
    for t in 0 65536 abc '80;id' -1; do if valid_port "$t"; then test_fail=1; fi; done
    for t in 192.0.2.10 2001:db8::10 2001:db8:0:0:0:0:0:10 ::1; do valid_host "$t" || test_fail=1; done
    for t in 256.0.0.1 '2001::1:' ':2001::1' '2001::db8::1' '[2001:db8::1]'; do if valid_host "$t"; then test_fail=1; fi; done
    valid_uuid '12345678-1234-1234-1234-123456789abc' || test_fail=1
    if valid_uuid '$(id)'; then test_fail=1; fi
    valid_ws_path /abcdefgh || test_fail=1
    if valid_ws_path '/x; }'; then test_fail=1; fi
    valid_upstream 'http://127.0.0.1:8000' || test_fail=1
    if valid_upstream 'http://example.com:80'; then test_fail=1; fi
    ((test_fail == 0)) || die '输入验证自测失败。'
    bash -n "${BASH_SOURCE[0]}"
    ok '输入验证、注入字符拒绝和Bash语法自测通过（不代替实际VPS部署验收）。'
}
main() {
    if [[ ${1:-} == _service ]]; then
        (($# == 2)) || die '内部服务参数错误。'
        service_runner "$2"; return
    fi
    if [[ ${1:-} == --no-color ]]; then NO_COLOR_FLAG=1; shift; fi
    colors
    validate_cli "$@"
    case "${1:-}" in help|--help|-h) help_text; return;; version|--version) echo "$VERSION"; return;; explain) explain; return;; selftest) selftest; return;; paths) show_paths; return;; esac
    check_root; detect_system
    if { exec {TTY_FD}<> /dev/tty; } 2>/dev/null; then :; else TTY_FD=''; fi
    trap 'on_error $? $LINENO' ERR
    trap on_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    safe_root
    # Read-only commands on an empty system must not pretend that a deployment exists.
    if [[ ! -e $STATE && ${1:-install} != install && $# -gt 0 ]]; then die '尚未安装，请运行 bash vpskit.sh install。'; fi
    install_deps
    init_state
    recover
    init_preferences
    if [[ ! -f $ROOT/vpskit.sh ]]; then persist_self
    elif [[ ${BASH_SOURCE[0]} != "$ROOT/vpskit.sh" && ${BASH_SOURCE[0]} != "$ENTRY" ]] && ! grep -Fxq "VERSION='$VERSION'" "$ROOT/vpskit.sh"; then
        # A locally downloaded/new process-substitution invocation upgrades the
        # installed service runner too. The caller explicitly executed this file.
        cp "$ROOT/vpskit.sh" "$ROOT/backup/manager.previous"
        persist_self
        json_update --arg v "$VERSION" '.manager=$v'
    fi
    case "${1:-menu}" in
        menu) main_menu;;
        install) if [[ -n ${2:-} ]]; then install_component "$2"; else install_all; fi;;
        node)
            case "${2:-list}" in
                add) node_add;; list) node_list;; export) node_export "${3:-}";;
                edit|rename|port|address|enable|disable|delete) node_action "$2" "${3:-}";;
                *) die '未知节点子命令。';;
            esac;;
        wizard) case "${2:-status}" in configure) configure_wizard;; status) deployment_details;; *) die '用法：vpskit wizard configure|status';; esac;;
        site) case "${2:-list}" in add) site_add;; edit) site_edit;; list) site_list;; default) site_default;; remove) site_remove;; *) die '未知网站子命令。';; esac;;
        cert) case "${2:-status}" in issue) cert_issue;; renew) cert_renew;; status) cert_status;; settings) site_certificate_edit;; *) die '未知证书子命令。';; esac;;
        update) if [[ ${2:-} == all ]]; then update_all; else update_component "${2:-xray}"; fi;;
        uninstall) if [[ ${2:-} == all ]]; then uninstall_all; else uninstall_component "${2:-xray}"; fi;;
        service) service_action "${2:-}" "${3:-}";;
        status) status;; logs) logs "${2:-manager}";; doctor) doctor;; repair) recover; doctor;; rollback) rollback_last;;
        firewall) if [[ -z ${2:-} ]]; then PANEL_IDLE=1; HAVE_LOCK=0; flock -u "$LOCK_FD"; firewall_menu; else firewall_action "$2"; fi;;
        optimize) if [[ -z ${2:-} ]]; then PANEL_IDLE=1; HAVE_LOCK=0; flock -u "$LOCK_FD"; optimize_menu; else optimize_action "$2"; fi;;
        swap) if [[ -z ${2:-} ]]; then PANEL_IDLE=1; HAVE_LOCK=0; flock -u "$LOCK_FD"; swap_menu; else swap_action "$2"; fi;;
        maintenance) maintenance;;
        *) help_text; die '未知命令。';;
    esac
}
# All function definitions are parsed before main. Source-only use is reserved for local tests.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
