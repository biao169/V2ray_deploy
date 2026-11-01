#!/usr/bin/env bash
# VPSKIT_SINGLE_FILE
# VPSKIT_FEATURE_LEVEL=13
# VPSKIT_STATE_SCHEMA=1
# VPSKit 2.0.4-smart — indexed defaults, port inventory and explicit emergency cleanup; independent release.
# Based on the public VPSKit 1.6.0 data model and deployment layout.
# MIT License — Copyright (c) 2026 VPSKit contributors.
# Run: sudo bash ./vpskit.sh ; help: bash ./vpskit.sh help
# Debian 12+ / Ubuntu 18.04+, Bash 4.4+, systemd, amd64/arm64.
# No useradd/adduser, no automatic firewall reset, no automatic SSH changes.
# JSON is data, never sourced. The manager/master require root; Nginx workers do not.
# shellcheck disable=SC2016
set -Eeuo pipefail
shopt -s inherit_errexit
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
VERSION='2.0.4-smart'
FEATURE_LEVEL=13
ROOT='/opt/vpskit'
STATE="$ROOT/data/state.json"
ENTRY='/usr/local/bin/vpskit'
SYSTEMD='/etc/systemd/system'
XRAY="$ROOT/bin/xray"
NGINX="$ROOT/nginx/usr/sbin/nginx"
ACME="$ROOT/acme/acme.sh"
SELF_URL='https://raw.githubusercontent.com/biao169/V2ray_deploy/main/vpskit.sh'
XRAY_DEFAULT_VERSION='latest'
SELF="${BASH_SOURCE[0]}"
WORK='' LOCK_FD='' TTY_FD='' TX=0 LOGFILE='' BOOTSTRAP_DIR=''
HISTORY_KEEP=20
PREFLIGHT_BASE='/run'
RUNTIME_UNIT_DIR='/run/systemd/system'
RUNTIME_PROC='/proc' # Internal test seam; never imported from environment.
UNITS=(vpskit-xray.service vpskit-nginx.service vpskit-maintain.service vpskit-maintain.timer)

info() { log INFO "$@"; }
warn() { log WARN "$@"; }
ok() { log OK "$@"; }
die() { log ERROR "$@"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "缺少命令 $1。"; }
root_check() { (( EUID == 0 )) || die '请使用 sudo bash ./vpskit.sh 或 sudo vpskit。'; }
confirm() { local cp_answer; ask cp_answer "$1；输入 yes 确认" no; [[ $cp_answer == yes ]]; }
s5_legacy_ask_valid() {
    local av_dest=$1 av_label=$2 av_default=$3 av_validator=$4 av_value
    shift 4
    while :; do
        ask av_value "$av_label" "$av_default"
        if "$av_validator" "$av_value" "$@"; then printf -v "$av_dest" '%s' "$av_value"; return 0; fi
        warn '输入不合法，请重新输入；:q取消。'
    done
}
choice() { [[ -n $1 && $1 != *[[:space:]]* && " $2 " == *" $1 "* ]]; }
number() { [[ $1 =~ ^(0|[1-9][0-9]{0,7})$ ]] && (( $1 >= $2 && $1 <= $3 )); }
valid_port() { number "$1" 1 65535; }
valid_name() { [[ $1 =~ ^[a-zA-Z0-9_-]{1,48}$ ]]; }
valid_user_name() { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
valid_uuid() { [[ $1 =~ ^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$ ]]; }
valid_domain() {
    local label; local -a labels=()
    [[ ${#1} -le 253 && $1 == *.* && $1 != *..* && $1 != .* && $1 != *. && $1 =~ ^[a-z0-9.-]+$ && ! $1 =~ ^[0-9.]+$ ]] || return 1
    IFS=. read -r -a labels <<< "$1"
    for label in "${labels[@]}"; do
        [[ ${#label} -le 63 && $label =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
    done
}
valid_host() {
    valid_domain "$1" && return 0
    local x rest count=0 compressed=0; local -a parts=()
    if [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        IFS=. read -r -a parts <<< "$1"
        for x in "${parts[@]}"; do ((10#$x <= 255)) || return 1; done
        return 0
    fi
    [[ $1 == *:* && $1 =~ ^[a-fA-F0-9:]+$ && $1 != *:::* ]] || return 1
    [[ $1 != :* || $1 == ::* ]] && [[ $1 != *: || $1 == *:: ]] || return 1
    rest=$1
    if [[ $rest == *::* ]]; then compressed=1; rest=${rest/::/X}; [[ $rest != *::* ]] || return 1; rest=${rest/X/:}; fi
    IFS=: read -r -a parts <<< "$rest"
    for x in "${parts[@]}"; do
        [[ -n $x ]] || continue
        [[ $x =~ ^[a-fA-F0-9]{1,4}$ ]] || return 1
        count=$((count+1))
    done
    if ((compressed)); then ((count<8)); else ((count==8)); fi
}
valid_email() { [[ $1 =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ && ${#1} -le 254 ]] && valid_domain "${1#*@}"; }
valid_path() { [[ $1 =~ ^/[a-zA-Z0-9_-]{8,80}$ ]]; }
valid_upstream() { [[ $1 =~ ^http://127\.0\.0\.1:([0-9]{1,5})$ ]] && valid_port "${1##*:}" && [[ ${1##*:} != 80 && ${1##*:} != 443 ]]; }
valid_redirect() {
    local host=${1#https://}; host=${host%%/*}
    [[ $1 =~ ^https://[a-z0-9.-]+(/[a-zA-Z0-9._~/%?\&=+#-]*)?$ && $host != "${2:-}" ]] && valid_domain "$host"
}
valid_version() { [[ $1 == latest || $1 =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
valid_bool() { [[ $1 == true || $1 == false ]]; }
valid_worker_count() { [[ $1 == auto ]] || number "$1" 1 64; }
randhex() { openssl rand -hex "${1:-12}"; }
new_uuid() { cat /proc/sys/kernel/random/uuid; }
get() { jq -r "$1" "$STATE"; }
json_update() {
    local tmp; tmp=$(mktemp "$ROOT/data/.state.XXXXXXXX")
    if ! jq "$@" "$STATE" > "$tmp"; then rm -f -- "$tmp"; die 'JSON变更失败，原配置保留。'; fi
    chmod 600 "$tmp"; chown 0:0 "$tmp"
    mv -f -- "$tmp" "$STATE"
}
state_basic() {
    [[ -s $1 && ! -L $1 && $(stat -c %s "$1") -le 16777216 ]] || return 1
    jq -e 'type=="object" and .schema==1 and (.nodes|type=="array") and (.sites|type=="array") and (.components|type=="object")' "$1" >/dev/null
}
nginx_defaults() {
    cat <<'JSON'
{"worker_user":"auto","workers":1,"connections":1024,"nofile":8192,"keepalive":20,"keepalive_requests":1000,"ssl_cache":4,"ssl_timeout":10,"http2":true,"client_header_timeout":15,"client_body_timeout":60,"send_timeout":60,"proxy_connect_timeout":10,"proxy_read_timeout":3600,"proxy_send_timeout":3600,"site_proxy_timeout":60,"client_max_body_mb":16,"access_log":false,"worker_shutdown_timeout":0,"upstream_keepalive":4,"startup_timeout":30,"sandbox_mode":"compatible","xhttp_keepalive":4,"upstream_idle":15,"error_log_level":"warn","access_log_mode":"errors","access_log_sample":1,"access_log_buffer_kb":16,"access_log_flush":30,"proxy_access_log":false,"gzip_level":2,"proxy_gzip":false}
JSON
}
nginx_settings() {
    jq -c --argjson d "$(nginx_defaults)" '(.advanced.nginx // {}) as $n | ($d * $n) |
      if ($n.access_log==true and ($n|has("access_log_mode")|not)) then .access_log_mode="full" else . end' "${1:-$STATE}"
}
ng_value() { nginx_settings | jq -r --arg k "$1" '.[$k]'; }
xray_nofile() { jq -r '.advanced.xray.nofile // 8192' "$STATE"; }

xray_defaults() {
    # auto is this manager's bounded per-connection pipe policy, not a TCP window.
    printf '%s\n' '{"nofile":8192,"conn_idle":600,"handshake":60,"buffer_kb":"auto","loglevel":"warning"}'
}
xray_settings() { jq -c --argjson d "$(xray_defaults)" '$d * (.advanced.xray // {})' "${1:-$STATE}"; }
logging_defaults() { printf '%s\n' '{"max_mb":4,"tail_kb":256,"keep":2}'; }
logging_settings() { jq -c --argjson d "$(logging_defaults)" '$d * (.advanced.logging // {})' "${1:-$STATE}"; }
stable_node_ids() {
    # Preserve historical email/identity on first migration; never derive it from a renamed label.
    json_update '.nodes |= map(if has("runtime_id") then . else .runtime_id=.id end)'
}
json_equal() {
    [[ -s $1 && -s $2 ]] || return 1
    local left right
    left=$(jq -cS . "$1") && right=$(jq -cS . "$2") && [[ $left == "$right" ]]
}

init_state() {
    if [[ -e $STATE ]]; then state_basic "$STATE" || die "配置损坏，未覆盖。请使用 history list / history restore 恢复：$STATE"; return; fi
    if [[ -e $ROOT/config/nginx.conf || -e $ROOT/config/xray.json || -d $ROOT/backup/history ]] && [[ ${ALLOW_NEW_STATE:-0} != 1 ]]; then
        die '发现部署资料但state.json缺失；拒绝创建空配置，请从历史恢复。'
    fi
    jq -n --arg v "$VERSION" '{schema:1,manager:$v,scheme:"A",host:"",performance:{gzip:true},components:{xray:false,nginx:false,acme:false},versions:{},nodes:[],sites:[],preferences:{},wizard:{selected:false}}' > "$STATE"
    chmod 600 "$STATE"
}

migrate_state() {
    # Never overwrite explicit false/zero or an operator's saved tuning. Preserve legacy full access logs.
    json_update --argjson d "$(nginx_defaults)" --argjson x "$(xray_defaults)" --argjson l "$(logging_defaults)" --arg v "$VERSION" '
      .advanced=((.advanced // {}) + {version:2}) |
      (if (.advanced.nginx.access_log==true and (.advanced.nginx|has("access_log_mode")|not))
       then .advanced.nginx.access_log_mode="full" else . end) |
      .advanced.nginx=($d * (.advanced.nginx // {})) |
      .advanced.xray=($x * (.advanced.xray // {})) |
      .advanced.logging=($l * (.advanced.logging // {})) |
      .nodes |= map(if has("runtime_id") then . else .runtime_id=.id end) |
      .preferences=(.preferences // {}) | .wizard=(.wizard // {}) | .manager=$v'
}
validate_advanced() {
    local cfg="$1" n nr
    n=$(nginx_settings "$cfg")
    jq -e 'def i($lo;$hi): type=="number" and .==floor and .>=$lo and .<=$hi;
      ((.workers=="auto") or (.workers|i(1;64))) and (.connections|i(128;65535)) and
      (.nofile|i(2048;1048576)) and (.nofile >= (.connections+1024)) and
      (.keepalive|i(5;300)) and (.keepalive_requests|i(100;100000)) and
      (.ssl_cache|i(1;128)) and (.ssl_timeout|i(1;1440)) and (.http2|type=="boolean") and
      (.client_header_timeout|i(5;300)) and (.client_body_timeout|i(5;3600)) and
      (.send_timeout|i(5;3600)) and (.proxy_connect_timeout|i(1;60)) and
      (.proxy_read_timeout|i(30;86400)) and (.proxy_send_timeout|i(30;86400)) and
      (.site_proxy_timeout|i(5;3600)) and (.client_max_body_mb|i(1;4096)) and
      (.access_log|type=="boolean") and (.worker_shutdown_timeout|i(0;3600)) and
      (.upstream_keepalive|i(0;128)) and (.startup_timeout|i(5;180)) and
      (.sandbox_mode=="strict" or .sandbox_mode=="compatible") and (.worker_user|type=="string") and
      ((.resolved_user // "")|type=="string")' <<< "$n" >/dev/null || die '高级配置类型/范围错误，或nofile小于connections+1024。'
    local user; user=$(jq -r .worker_user <<< "$n")
    [[ $user == auto ]] || valid_user_name "$user" || die 'Worker账户名称不合法。'
    [[ $user != root ]] || die '禁止设置root Worker。'
    jq -e '(.advanced.xray.nofile // 8192) as $n | ($n|type=="number") and $n==($n|floor) and $n>=2048 and $n<=1048576' "$cfg" >/dev/null || die 'Xray文件描述符上限无效。'
    validate_efficiency "$cfg"
    nr=$(cat /proc/sys/fs/nr_open 2>/dev/null || printf 1048576)
    (( $(jq -r .nofile <<< "$n") <= nr && $(jq -r '.advanced.xray.nofile // 8192' "$cfg") <= nr )) || die "nofile超过当前内核nr_open=$nr；未自动改变内核。"
}

validate_efficiency() {
    local cfg=$1
    # Validate explicit enums and bounds without evaluating any input as shell code.
    nginx_settings "$cfg" | jq -e '
      def i($l;$h): type=="number" and .==floor and .>=$l and .<=$h;
      (.xhttp_keepalive|i(0;64)) and (.upstream_idle|i(1;60)) and
      (.error_log_level as $v|["warn","error","crit"]|index($v)!=null) and
      (.access_log_mode as $v|["errors","sample","full"]|index($v)!=null) and
      (.access_log_sample|i(1;100)) and (.access_log_buffer_kb|i(4;64)) and
      (.access_log_flush|i(1;300)) and (.proxy_access_log|type=="boolean") and
      (.gzip_level|i(1;5)) and (.proxy_gzip|type=="boolean")' >/dev/null || die 'Nginx日志/复用/压缩设置无效。'
    xray_settings "$cfg" | jq -e '
      def i($l;$h): type=="number" and .==floor and .>=$l and .<=$h;
      (.conn_idle|i(60;7200)) and (.handshake|i(10;120)) and
      (.buffer_kb=="auto" or .buffer_kb=="core" or (.buffer_kb|i(4;512))) and
      (.loglevel as $v|["warning","error","none"]|index($v)!=null)' >/dev/null || die 'Xray策略无效：空闲60～7200秒、握手10～120秒、缓冲auto/core或4～512KiB、日志warning/error/none。'
    logging_settings "$cfg" | jq -e '
      def i($l;$h): type=="number" and .==floor and .>=$l and .<=$h;
      (.max_mb|i(1;64)) and (.tail_kb|i(16;1024)) and (.keep|i(1;5))' >/dev/null || die '日志保留设置无效。'
}

service_user_valid() {
    local row name password uid gid gecos home shell group
    valid_user_name "$1" || return 1
    row=$(getent passwd "$1") || return 1
    IFS=: read -r name password uid gid gecos home shell <<< "$row"
    [[ $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ && $uid != 0 && $gid != 0 ]] || return 1
    case "$shell" in */nologin|*/false) ;; *) return 1;; esac
    for group in $(id -Gn "$name"); do
        case "$group" in root|sudo|wheel|docker|lxd|disk|shadow|admin) return 1;; esac
    done
    valid_user_name "$(id -gn "$name")"
}
s1_base_resolve_worker() {
    local cfg=${1:-$STATE} requested saved candidate saved_uid
    requested=$(nginx_settings "$cfg" | jq -r .worker_user)
    saved=$(nginx_settings "$cfg" | jq -r '.resolved_user // ""')
    saved_uid=$(nginx_settings "$cfg" | jq -r '.resolved_uid // ""')
    if [[ $requested != auto ]]; then
        service_user_valid "$requested" || die "账户 $requested 不符合非特权、非登录服务账户要求。"
        printf '%s' "$requested"; return
    fi
    if [[ -n $saved ]]; then
        service_user_valid "$saved" || die "已记录Worker账户 $saved 不可用；请在高级配置中重新选择auto或已有服务账户。"
        [[ -z $saved_uid || $(id -u "$saved") == "$saved_uid" ]] || die '记录的Worker UID已变化；请显式重新选择账户。'
        printf '%s' "$saved"; return
    fi
    for candidate in vpskit-www www-data nginx http nobody; do
        if service_user_valid "$candidate"; then printf '%s' "$candidate"; return; fi
    done
    die '没有可复用的安全服务账户；不会新建用户或退回root。请先由管理员准备非登录服务账户。'
}
remember_worker() {
    local user; user=$(resolve_worker)
    [[ $user != nobody ]] || warn '复用nobody；该UID可能与其他服务共享，隔离弱于专用服务账户。'
    json_update --arg u "$user" --argjson id "$(id -u "$user")" '.advanced.nginx.resolved_user=$u | .advanced.nginx.resolved_uid=$id'
}
worker_permissions() {
    local user=$1 group path
    service_user_valid "$user" || die 'Worker身份不安全。'
    group=$(id -gn "$user")
    if ((TX==1)) && [[ -f $ROOT/backup/transaction/ready ]]; then
        printf 'runtime\n' > "$ROOT/backup/transaction/phase"
    fi
    # Shared directories allow read/traverse; all secrets stay root:root 0700.
    # This deliberately avoids an ACL dependency and never creates OS accounts.
    chown "0:$group" "$ROOT"; chmod 0750 "$ROOT"
    for path in data config certs acme backup tmp bin nginx; do
        [[ -d $ROOT/$path && ! -L $ROOT/$path ]] || die "异常私有目录 $path"
        chown 0:0 "$ROOT/$path"; chmod 0700 "$ROOT/$path"
    done
    [[ ! -L $ROOT/www && ! -L $ROOT/run && ! -L $ROOT/logs ]] || die '网站/运行目录不能为符号链接。'
    # Do not follow symlinks, hard links or mounted subtrees during permission repair.
    if [[ -n $(find -P "$ROOT/www" -xdev \( -type l -o \( -type f -links +1 \) \) -print -quit) ]]; then
        die '网站目录含符号链接或硬链接；请改为实际文件，避免权限修复影响目录外资料。'
    fi
    if findmnt -rn -o TARGET 2>/dev/null | grep -Fq "$ROOT/www/"; then die '网站目录内有子挂载，拒绝递归调整权限。'; fi
    find -P "$ROOT/www" -xdev -type d -exec chown "0:$group" {} + -exec chmod 2750 {} +
    find -P "$ROOT/www" -xdev -type f -exec chown "0:$group" {} + -exec chmod 0640 {} +
    chown "0:$group" "$ROOT/run" "$ROOT/logs"; chmod 0750 "$ROOT/run" "$ROOT/logs"
    mkdir -p "$ROOT/run/nginx"
    chown "0:$group" "$ROOT/run/nginx"; chmod 0750 "$ROOT/run/nginx"
    for path in client proxy fastcgi uwsgi scgi; do
        [[ ! -L $ROOT/run/nginx/$path ]] || die 'Nginx临时目录不能为链接。'
        mkdir -p "$ROOT/run/nginx/$path"
        chown "$user:$group" "$ROOT/run/nginx/$path"; chmod 0700 "$ROOT/run/nginx/$path"
    done
    if command -v runuser >/dev/null; then
        runuser -u "$user" -- test -x "$ROOT/www" || die 'Worker无法访问网站目录。'
        for path in client proxy fastcgi uwsgi scgi; do
            runuser -u "$user" -- test -w "$ROOT/run/nginx/$path" || die "Worker无法写入临时目录：$path"
        done
        if runuser -u "$user" -- test -r "$STATE"; then die 'Worker不应能读取state.json。'; fi
        if runuser -u "$user" -- test -x "$ROOT/certs"; then die 'Worker不应能遍历证书私钥目录。'; fi
    fi
}

system_check() {
    root_check
    (( BASH_VERSINFO[0]>4 || (BASH_VERSINFO[0]==4 && BASH_VERSINFO[1]>=4) )) || die '需要Bash 4.4+。'
    local ID='' VERSION_ID='' VERSION=''
    [[ -r /etc/os-release ]] || die '无法识别系统。'
    . /etc/os-release
    case "$ID" in debian) (( ${VERSION_ID%%.*}>=12 )) || die '需要Debian 12+。';; ubuntu) (( ${VERSION_ID%%.*}>=18 )) || die '需要Ubuntu 18.04+。';; *) die '只支持Debian/Ubuntu。';; esac
    [[ -d /run/systemd/system ]] || die '需要以systemd为PID 1的VPS；普通容器不能进行部署。'
    case $(uname -m) in x86_64|aarch64|arm64) ;; *) die '只支持amd64/arm64。';; esac
    need flock; need apt-get
}
safe_layout() {
    local p mode
    [[ ! -L /opt && ! -L $ROOT ]] || die '安装根目录不能为符号链接。'
    if [[ -e $ROOT ]]; then
        [[ -f $ROOT/.vpskit-owned && ! -L $ROOT/.vpskit-owned && $(cat "$ROOT/.vpskit-owned") == VPSKIT_V1 ]] || die "$ROOT 已存在且不属于VPSKit，未接管。"
        [[ $(stat -c %u "$ROOT") == 0 ]] || die '安装目录必须归root所有。'
        mode=$(stat -c %a "$ROOT")
        (( (8#$mode & 0027)==0 )) || die '安装目录不得允许组写入或其他用户访问。'
    else
        mkdir -m 700 "$ROOT"; printf 'VPSKIT_V1\n' > "$ROOT/.vpskit-owned"
    fi
    for p in bin config data certs acme www logs backup tmp run nginx; do
        [[ ! -L $ROOT/$p ]] || die "拒绝符号链接目录 $p"
        mkdir -p "$ROOT/$p"
    done
    for p in data config certs acme backup tmp bin nginx; do chown 0:0 "$ROOT/$p"; chmod 700 "$ROOT/$p"; done
    [[ ! -L $STATE && ! -L $ROOT/run/manage.lock ]] || die '状态文件/锁文件不能为链接。'
    exec {LOCK_FD}> "$ROOT/run/manage.lock"
    flock -w 10 "$LOCK_FD" || die '另一个VPSKit操作正在运行。'
    WORK=$(mktemp -d "$ROOT/tmp/job.XXXXXXXX")
    LOGFILE="$ROOT/logs/manage.log"
    touch "$LOGFILE"; chmod 600 "$LOGFILE"; chown 0:0 "$LOGFILE"
}
cleanup() {
    local rc=$?
    trap - EXIT ERR INT TERM
    set +e
    if ((TX)); then
        warn '操作失败或中断，开始恢复事务前状态。'
        failure_diagnostics 'before-automatic-rollback' >/dev/null 2>&1 || true
        if restore_transaction "$ROOT/backup/transaction" automatic; then rm -rf -- "$ROOT/backup/transaction"; else warn '自动恢复失败，事务保留。运行 vpskit repair；仍失败可运行 vpskit repair --force。'; rc=1; fi
    fi
    [[ -z $WORK || ! -d $WORK ]] || rm -rf -- "$WORK"
    [[ -z $BOOTSTRAP_DIR || ! -d $BOOTSTRAP_DIR ]] || rm -rf -- "$BOOTSTRAP_DIR"
    exit "$rc"
}
error_trap() { local rc=$1 line=$2; warn "第 $line 行执行失败（退出码 $rc）；不打印可能含凭据的命令。"; exit "$rc"; }
fetch() {
    local url=$1 dest=$2
    [[ $url == https://* && $url != *[[:space:]]* ]] || die '下载地址必须是无空白的HTTPS URL。'
    curl --proto '=https' --proto-redir '=https' --fail --show-error --location --connect-timeout 15 --max-time 300 --retry 2 --output "$dest" "$url"
    [[ -s $dest ]] || die '下载结果为空。'
}
install_dependencies() {
    local cmd pkg; local -a packages=()
    for cmd in curl jq openssl unzip ss free sysctl; do
        if ! command -v "$cmd" >/dev/null; then
            case "$cmd" in ss) pkg=iproute2;; free|sysctl) pkg=procps;; *) pkg=$cmd;; esac
            packages+=("$pkg")
        fi
    done
    [[ -s /etc/ssl/certs/ca-certificates.crt ]] || packages+=(ca-certificates)
    ((${#packages[@]})) || return 0
    info "安装基础依赖：${packages[*]}（不安装系统Nginx服务，不创建VPSKit账户）。"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"
}
# History snapshots contain configuration, certificates, units and permission metadata.
# Firewall records are reference only; no global firewall/SWAP/BBR state is restored.
s1_base_snapshot_copy() {
    local dest=$1 reason=$2 p
    mkdir -p "$dest" || return 1
    [[ ! -f $STATE ]] || cp -a "$STATE" "$dest/state.json" || return 1
    for p in config certs; do cp -a "$ROOT/$p" "$dest/$p" || return 1; done
    mkdir -p "$dest/acme" || return 1
    for p in config certstore; do [[ ! -d $ROOT/acme/$p ]] || cp -a "$ROOT/acme/$p" "$dest/acme/$p" || return 1; done
    permissions_save "$dest/permissions.nul" || return 1
    mkdir -p "$dest/units" || return 1
    for p in "${UNITS[@]}"; do
        if [[ -f $SYSTEMD/$p && ! -L $SYSTEMD/$p ]] && grep -Fq '# VPSKIT_OWNED' "$SYSTEMD/$p"; then cp -a "$SYSTEMD/$p" "$dest/units/$p" || return 1; fi
        if systemctl is-active --quiet "$p" 2>/dev/null; then printf '%s\n' "$p" >> "$dest/active" || return 1; fi
        if systemctl is-enabled --quiet "$p" 2>/dev/null; then printf '%s\n' "$p" >> "$dest/enabled" || return 1; fi
    done
    firewall_required_state "$STATE" > "$dest/required-ports.txt" || return 1
    if [[ -f $ROOT/data/firewall-v2.json && ! -L $ROOT/data/firewall-v2.json ]]; then
        cp -a "$ROOT/data/firewall-v2.json" "$dest/firewall-records.json" || return 1
    fi
    jq -n --arg v "$VERSION" --arg r "$reason" --arg t "$(date -u '+%FT%TZ')" '{snapshot_schema:1,manager:$v,created:$t,reason:$r,includes:["state","config","certs","acme/config","acme/certstore","units","permissions","required ports","firewall records (reference only)"],excludes:["website files","binaries","manager code","firewall","swap"]}' > "$dest/meta.json" || return 1
    (cd "$dest" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 -r sha256sum > SHA256SUMS) || return 1
    chmod 700 "$dest"
}
history_prune() {
    local f count=0
    while IFS= read -r f; do
        count=$((count+1)); ((count<=HISTORY_KEEP)) && continue
        [[ $f =~ ^[0-9]{8}T[0-9]{6}Z-[a-f0-9]{8}$ ]] || continue
        rm -rf -- "$ROOT/backup/history/$f"
    done < <(history_dirs | while IFS= read -r path; do printf '%s\n' "${path##*/}"; done)
}
history_save() {
    local reason=${1:-manual} source=${2:-} id dest
    state_basic "$STATE" || die '当前状态无效，不能创建正常历史快照。'
    mkdir -p "$ROOT/backup/history"
    id="$(date -u '+%Y%m%dT%H%M%SZ')-$(randhex 4)"
    dest="$ROOT/backup/history/.pending-$id"
    if [[ -n $source ]]; then
        mkdir -p "$dest"; cp -a --reflink=auto "$source/." "$dest/"
    else snapshot_copy "$dest" "$reason"; fi
    mv -- "$dest" "$ROOT/backup/history/$id"
    history_prune
    info "历史快照：$id（含凭据/私钥，仅root可读；保留最近$HISTORY_KEEP份）"
}
history_list() {
    local dir index=0 description
    printf '序号  快照ID                         时间 / 原因 / 版本\n'
    while IFS= read -r dir; do
        [[ -f $dir/meta.json && -f $dir/state.json ]] || continue
        index=$((index+1))
        description=$(jq -r '[.created,.reason,.manager]|@tsv' "$dir/meta.json" 2>/dev/null || printf '元信息损坏')
        printf '%3d.  %s  %s\n' "$index" "${dir##*/}" "$(panel_clean "$description")"
    done < <(history_dirs)
    ((index>0)) || printf '暂无可恢复的历史快照。\n'
    return 0
}
snapshot_verify() {
    local dir=$1 f target line path
    [[ -d $dir && ! -L $dir && -s $dir/SHA256SUMS ]] || die '快照不存在或不完整。'
    state_basic "$dir/state.json" || die '快照state.json结构无效。'
    jq -e '.snapshot_schema==1' "$dir/meta.json" >/dev/null || die '快照版本不支持。'
    while IFS= read -r line; do
        [[ $line =~ ^[a-f0-9]{64}\ \ \./ ]] || die '校验清单格式无效。'
        path=${line:66}
        [[ $path != *'/../'* && $path != *'/..' && $path != *$'\n'* ]] || die '快照清单路径越界。'
    done < "$dir/SHA256SUMS"
    while IFS= read -r -d '' f; do
        target=$(realpath -m -- "$f")
        [[ $target == "$dir/"* ]] || die '快照内存在越界符号链接。'
    done < <(find -P "$dir" -type l -print0)
    (cd "$dir"; sha256sum --status -c SHA256SUMS) || die '快照校验失败，未恢复。'
}
begin_tx() {
    local reason=${1:-configuration} scope=${2:-state} dir="$ROOT/backup/transaction" u p
    ((TX==0)) || die '禁止嵌套事务。'
    [[ ! -e $dir ]] || die '发现未完成事务，请先执行 vpskit repair。'
    # Ready marker is written only after the complete pre-change backup exists.
    mkdir -p "$dir/units"
    snapshot_copy "$dir/snapshot" "$reason"
    stat -c '%a %g' "$ROOT" > "$dir/root-permissions"
    printf '%s\n' "$scope" > "$dir/scope"
    if [[ $scope == components ]]; then
        mkdir -p "$dir/programs"
        for p in bin nginx acme; do cp -a "$ROOT/$p" "$dir/programs/$p"; done
    fi
    for u in "${UNITS[@]}"; do
        if [[ -e $SYSTEMD/$u ]]; then
            [[ ! -L $SYSTEMD/$u ]] && grep -Fq '# VPSKIT_OWNED' "$SYSTEMD/$u" || die "同名外部服务 $u，拒绝接管。"
            cp -a "$SYSTEMD/$u" "$dir/units/$u"
        fi
        if systemctl is-active --quiet "$u"; then printf '%s\n' "$u" >> "$dir/active"; fi
        if systemctl is-enabled --quiet "$u" 2>/dev/null; then printf '%s\n' "$u" >> "$dir/enabled"; fi
    done
    (snapshot_verify "$dir/snapshot") || die '事务备份校验失败；未进入修改阶段。'
    printf 'ready\n' > "$dir/ready"
    printf 'prepared\n' > "$dir/phase"
    TX=1
    if state_basic "$STATE"; then history_save "before:$reason" "$dir/snapshot"; fi
}
s1_base_restore_transaction() {
    local dir=$1 mode=${2:-normal} p u perms worker failed=0 prepared=no
    if [[ -f $dir/state.json && -d $dir/tree ]]; then
        legacy_restore_transaction "$dir" || return 1
        recovery_firewall check || true
        return 0
    fi
    [[ -f $dir/ready && -d $dir/snapshot && ! -L $dir ]] || return 1
    ( snapshot_verify "$dir/snapshot" ) || { warn '恢复资料校验失败，未停止服务。'; return 1; }
    if [[ $mode == automatic && -f $dir/phase && $(cat "$dir/phase") == prepared ]]; then prepared=yes; fi
    for u in "${UNITS[@]}"; do
        [[ ${RESTORE_PRESERVE_XRAY:-no} != yes || $u != vpskit-xray.service ]] || continue
        if [[ -e $SYSTEMD/$u ]] && { [[ -L $SYSTEMD/$u ]] || ! grep -Fq '# VPSKIT_OWNED' "$SYSTEMD/$u"; }; then
            warn "同名外部服务 $u，拒绝覆盖。"; return 1
        fi
        if [[ -e $dir/units/$u ]] && { [[ -L $dir/units/$u ]] || ! grep -Fq '# VPSKIT_OWNED' "$dir/units/$u"; }; then return 1; fi
    done
    if [[ $prepared != yes ]]; then
        # Stop only owned services, never external nginx/apache or arbitrary port owners.
        for u in vpskit-nginx.service vpskit-xray.service; do
            [[ ${RESTORE_PRESERVE_XRAY:-no} != yes || $u != vpskit-xray.service ]] || continue
            if [[ -f $SYSTEMD/$u ]]; then
                systemctl stop "$u" || { warn "$u 未能停止，拒绝替换其运行资料。"; return 1; }
            fi
        done
    fi
    for p in config certs; do
        [[ -d $dir/snapshot/$p && ! -L $dir/snapshot/$p ]] || return 1
        rm -rf -- "$ROOT/$p"; cp -a "$dir/snapshot/$p" "$ROOT/$p" || return 1
    done
    for p in config certstore; do
        rm -rf -- "$ROOT/acme/$p"
        [[ ! -d $dir/snapshot/acme/$p ]] || cp -a "$dir/snapshot/acme/$p" "$ROOT/acme/$p" || return 1
    done
    if [[ -d $dir/programs ]]; then
        for p in bin nginx acme; do
            [[ ${RESTORE_PRESERVE_XRAY:-no} != yes || $p != bin ]] || continue
            [[ -d $dir/programs/$p && ! -L $dir/programs/$p ]] || return 1
            rm -rf -- "$ROOT/$p"; cp -a "$dir/programs/$p" "$ROOT/$p" || return 1
        done
    fi
    cp -a "$dir/snapshot/state.json" "$STATE" || return 1
    # A failed preflight changes only staged/state files, so leave healthy live services alone.
    if [[ $prepared == yes ]]; then
        ok '预检阶段失败：仅恢复原资料，未重启原来运行中的组件。'
        return 0
    fi
    for u in "${UNITS[@]}"; do
        [[ ${RESTORE_PRESERVE_XRAY:-no} != yes || $u != vpskit-xray.service ]] || continue
        if [[ -f $dir/units/$u ]]; then cp -a "$dir/units/$u" "$SYSTEMD/$u" || return 1
        elif [[ -f $SYSTEMD/$u ]] && grep -Fq '# VPSKIT_OWNED' "$SYSTEMD/$u"; then
            systemctl disable --now "$u" >/dev/null 2>&1 || true; rm -f "$SYSTEMD/$u"
        fi
    done
    worker=$(nginx_conf_value user "$ROOT/config/nginx.conf" || true)
    if [[ -f $dir/snapshot/permissions.nul ]]; then
        permissions_restore "$dir/snapshot/permissions.nul" || { warn '权限元数据恢复失败。'; return 1; }
    elif [[ -n $worker && $worker != root ]]; then
        # Compatibility with 1.7.0–1.7.2: no full permission metadata was saved.
        ( worker_permissions "$worker" ) || return 1
    elif [[ -r $dir/root-permissions ]]; then
        local saved_mode saved_gid
        read -r saved_mode saved_gid < "$dir/root-permissions" || return 1
        [[ $saved_mode =~ ^[0-7]{3,4}$ && $saved_gid =~ ^[0-9]+$ ]] || return 1
        chown "0:$saved_gid" "$ROOT" && chmod "$saved_mode" "$ROOT" || return 1
    fi
    # Never regenerate Nginx/Xray config here: original settings are the rollback target.
    if [[ -f $SYSTEMD/vpskit-nginx.service && -f $ROOT/config/nginx.conf ]]; then
        [[ -x $NGINX ]] || { warn '恢复缺少Nginx程序；历史快照不包含二进制。'; return 1; }
        nginx_cmd -t -p "$ROOT/" -c "$ROOT/config/nginx.conf" || { failure_diagnostics rollback-syntax || true; return 1; }
        [[ $worker != root ]] || warn '正在原样恢复历史root Worker配置；恢复可用性后请再迁移非root。'
    fi
    if [[ ${RESTORE_PRESERVE_XRAY:-no} != yes && -f $dir/active ]] && grep -Fxq vpskit-xray.service "$dir/active"; then
        [[ -x $XRAY && -f $ROOT/config/xray.json ]] || return 1
        "$XRAY" run -test -config "$ROOT/config/xray.json" || return 1
    fi
    systemctl daemon-reload || return 1
    for u in "${UNITS[@]}"; do
        [[ ${RESTORE_PRESERVE_XRAY:-no} != yes || $u != vpskit-xray.service ]] || continue
        systemctl reset-failed "$u" >/dev/null 2>&1 || true
        if [[ -f $dir/enabled ]] && grep -Fxq "$u" "$dir/enabled"; then systemctl enable "$u" >/dev/null 2>&1 || failed=1
        else systemctl disable "$u" >/dev/null 2>&1 || true; fi
    done
    # Start upstream first. Do not start a renewal oneshot while holding the manager lock.
    for u in vpskit-xray.service vpskit-nginx.service vpskit-maintain.timer; do
        [[ ${RESTORE_PRESERVE_XRAY:-no} != yes || $u != vpskit-xray.service ]] || continue
        [[ -f $dir/active ]] && grep -Fxq "$u" "$dir/active" || continue
        if ! systemctl start "$u"; then failed=1; continue; fi
        if [[ $u == vpskit-nginx.service ]]; then
            verify_nginx_runtime '' '' "$ROOT/config/nginx.conf" yes || failed=1
        elif ! service_wait_active "$u"; then failed=1; fi
    done
    if ((failed)); then failure_diagnostics rollback-start || true; return 1; fi
    recovery_firewall check || true
    return 0
}
s2_base_commit_tx() {
    ((TX==1)) || die '没有待提交事务。'
    rm -rf -- "$ROOT/backup/last"
    mv -- "$ROOT/backup/transaction" "$ROOT/backup/last"
    TX=0
    ok '配置已验证并提交；操作前历史和最近事务均可恢复。'
}
repair_transaction() {
    local option=${1:-}
    [[ -z $option || $option == --force ]] || die '用法：repair [--force]。'
    if [[ $option == --force ]]; then force_recover transaction; return; fi
    if [[ -d $ROOT/backup/transaction ]]; then
        if [[ ! -f $ROOT/backup/transaction/ready ]]; then
            # A transaction never mutates official state before its ready marker exists.
            mkdir -p "$ROOT/backup/rescue"
            mv "$ROOT/backup/transaction" "$ROOT/backup/rescue/incomplete-$(date +%s)-$(randhex 4)"
            ok '未完成的备份已隔离保存；该事务尚未进入修改阶段。'
        else
            restore_transaction "$ROOT/backup/transaction" || die '恢复失败，事务保留；可运行 vpskit repair --force 进入强制恢复。'
            mkdir -p "$ROOT/backup/rescue"
            mv "$ROOT/backup/transaction" "$ROOT/backup/rescue/repaired-$(date +%s)-$(randhex 4)"
            ok '已恢复未完成事务；原始备份保存在backup/rescue。'
        fi
    else ok '没有未完成事务。'; fi
}

s1_base_component_ready() {
    local f
    case "$1" in xray) f=$XRAY;; nginx) f=$NGINX;; acme) f=$ACME;; *) return 1;; esac
    [[ $(get ".components.$1 // false") == true && -x $f && ! -L $f ]]
}
ensure_component() { component_ready "$1" || die "组件 $1 未安装或缺失，请运行 vpskit install $1。"; }
s1_base_latest_release() {
    fetch "https://api.github.com/repos/$1/releases/latest" "$2"
    jq -er '.tag_name|select(test("^[A-Za-z0-9._-]+$"))' "$2"
}
s1_base_install_xray_binary() {
    local ver=${1:-$XRAY_DEFAULT_VERSION} asset meta="$WORK/xray-release.json" url digest
    valid_version "$ver" || die 'Xray版本应为v数字.数字.数字，或latest。'
    case $(uname -m) in x86_64) asset=Xray-linux-64.zip;; aarch64|arm64) asset=Xray-linux-arm64-v8a.zip;; esac
    if [[ $ver == latest ]]; then ver=$(latest_release XTLS/Xray-core "$meta")
    else fetch "https://api.github.com/repos/XTLS/Xray-core/releases/tags/$ver" "$meta"; fi
    url=$(jq -er --arg n "$asset" '.assets[]|select(.name==$n)|.browser_download_url' "$meta")
    [[ $url == https://github.com/XTLS/Xray-core/releases/download/* ]] || die 'Xray下载来源异常。'
    fetch "$url" "$WORK/xray.zip"
    digest=$(jq -r --arg n "$asset" '.assets[]|select(.name==$n)|.digest // ""' "$meta")
    if [[ $digest == sha256:* ]]; then digest=${digest#sha256:}
    else
        fetch "$url.dgst" "$WORK/xray.dgst"
        digest=$(grep -Ei 'sha(2[-_])?256' "$WORK/xray.dgst" | grep -oE '[a-fA-F0-9]{64}' | head -1 || true)
    fi
    [[ $digest =~ ^[a-fA-F0-9]{64}$ ]] || die '没有有效的Xray SHA256摘要。'
    printf '%s  %s\n' "$digest" "$WORK/xray.zip" | sha256sum -c -
    unzip -p "$WORK/xray.zip" xray > "$ROOT/bin/xray.new"
    chmod 700 "$ROOT/bin/xray.new"; "$ROOT/bin/xray.new" version
    mv -f "$ROOT/bin/xray.new" "$XRAY"
    json_update --arg v "$ver" '.components.xray=true | .versions.xray=$v'
    ok "Xray $ver 已安装；官方同源摘要用于完整性检查，不是独立签名。"
}
s1_base_install_nginx_binary() {
    local pkg deb version='' soname; local -a libs=()
    local dl="$WORK/nginx-download" tree="$WORK/nginx-extract"
    mkdir -p "$dl" "$tree"
    apt-get update
    for pkg in nginx nginx-core nginx-light; do
        apt-cache show "$pkg" >/dev/null 2>&1 || continue
        rm -f -- "$dl"/*.deb
        if ! (cd "$dl"; apt-get download "$pkg"); then continue; fi
        for deb in "$dl"/*.deb; do
            [[ -f $deb ]] || continue
            dpkg-deb -x "$deb" "$tree"
            if [[ -x $tree/usr/sbin/nginx ]]; then version=$(dpkg-deb -f "$deb" Version); break; fi
        done
        [[ -z $version ]] || break
    done
    [[ -n $version ]] || die '发行版软件源中未找到可提取的Nginx。'
    while read -r soname; do
        case "$soname" in
            libpcre.so.3) libs+=(libpcre3);; libpcre2-8.so.0) libs+=(libpcre2-8-0);;
            libssl.so.1.1|libcrypto.so.1.1) libs+=(libssl1.1);;
            libssl.so.3|libcrypto.so.3)
                if apt-cache show libssl3t64 >/dev/null 2>&1; then libs+=(libssl3t64); else libs+=(libssl3); fi;;
            libssl.so.1.0.0|libcrypto.so.1.0.0) libs+=(libssl1.0.0);;
            libz.so.1) libs+=(zlib1g);; libcrypt.so.1) libs+=(libcrypt1);; libGeoIP.so.1) libs+=(libgeoip1);;
            *) die "未识别的动态库 $soname，请由系统包管理器补齐。";;
        esac
    done < <(ldd "$tree/usr/sbin/nginx" | awk '/not found/{print $1}')
    if ((${#libs[@]})); then DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${libs[@]}"; fi
    if ldd "$tree/usr/sbin/nginx" | grep -q 'not found'; then die 'Nginx动态库依赖仍不完整。'; fi
    mkdir -p "$ROOT/nginx/usr/sbin"
    install -m 700 "$tree/usr/sbin/nginx" "$NGINX.new"
    "$NGINX.new" -V
    mv -f "$NGINX.new" "$NGINX"
    json_update --arg v "$version" '.components.nginx=true | .versions.nginx=$v'
    ok "Nginx $version 已独立提取；未运行Nginx包维护脚本或创建账户。"
}
s1_base_install_acme_binary() {
    local version meta="$WORK/acme-release.json"
    version=$(latest_release acmesh-official/acme.sh "$meta")
    fetch "https://github.com/acmesh-official/acme.sh/archive/refs/tags/$version.tar.gz" "$WORK/acme.tar.gz"
    tar -tzf "$WORK/acme.tar.gz" | awk '/(^\/|(^|\/)\.\.(\/|$))/{bad=1} END{exit bad}' || die 'ACME归档路径异常。'
    if tar -tvzf "$WORK/acme.tar.gz" | awk 'substr($1,1,1)=="l" || substr($1,1,1)=="h"{bad=1} END{exit !bad}'; then die 'ACME归档含链接，拒绝自动解压。'; fi
    mkdir -p "$WORK/acme-source" "$ROOT/acme/config" "$ROOT/acme/certstore"
    tar --no-same-owner --no-same-permissions -xzf "$WORK/acme.tar.gz" --strip-components=1 -C "$WORK/acme-source"
    sh -n "$WORK/acme-source/acme.sh"
    install -m 700 "$WORK/acme-source/acme.sh" "$ACME"
    rm -rf -- "$ROOT/acme/dnsapi"
    cp -a "$WORK/acme-source/dnsapi" "$ROOT/acme/dnsapi"
    chmod -R go-rwx "$ROOT/acme"
    json_update --arg v "$version" '.components.acme=true | .versions.acme=$v'
    ok "acme.sh $version 已安装；保留原有账户与续期数据，不启用其自动代码升级。"
}
nginx_cmd() {
    local help; help=$("$NGINX" -h 2>&1 || true)
    local -a args=()
    [[ $help != *'-e filename'* ]] || args=(-e "$ROOT/logs/nginx.log")
    "$NGINX" "${args[@]}" "$@"
}
nginx_tls_protocols() {
    local build; build=$("$NGINX" -V 2>&1)
    if [[ $build == *'running with OpenSSL '* ]]; then build=${build##*running with OpenSSL }; else build=${build#*built with OpenSSL }; fi
    if [[ $build =~ ^(1\.1\.1|[3-9]\.) ]]; then printf 'TLSv1.2 TLSv1.3'; else printf 'TLSv1.2'; fi
}
edge_settings() { jq -c '{bots:"off",rate:0,burst:30,connections:0,kbps:0,static_ttl:0,gzip:false,origin:false,aop:"off"} * (.protection // {})' <<< "$1"; }
edge_zone() { printf '%s' "$1" | sha256sum | cut -c1-12; }
edge_validate() {
    local cfg=${2:-$STATE} s; s=$(edge_settings "$1")
    jq -e 'def i($a;$b): type=="number" and .==floor and .>=$a and .<=$b;
      (.bots=="off" or .bots=="ai" or .bots=="common" or .bots=="all") and
      (.rate|i(0;100)) and (.burst|i(1;200)) and (.connections|i(0;200)) and
      (.kbps|i(0;10240)) and (.static_ttl|i(0;604800)) and
      (.gzip|type=="boolean") and (.origin|type=="boolean") and
      (.aop=="off" or .aop=="observe" or .aop=="enforce")' <<< "$s" >/dev/null || die '网站防护设置无效。'
    if [[ $(jq -r .origin <<< "$s") == true || $(jq -r .aop <<< "$s") != off ]]; then
        [[ $(jq -r '.access // "direct"' <<< "$1") == cloudflare ]] || die '来源限制/AOP只能用于Cloudflare站点。'
    fi
    if [[ $(jq -r .aop <<< "$s") != off ]]; then
        [[ $(jq -r .issued <<< "$1") == true && -s $ROOT/config/edge/aop-ca.pem ]] || die 'AOP缺少网站TLS证书或回源CA。'
        local token; token=$(jq -r '.edge.probe // ""' "$cfg"); [[ $token =~ ^[a-f0-9]{32}$ ]] || die 'AOP探测标识不合法。'
    fi
}
cert_files_valid() {
    local d=$1 file="$ROOT/certs/$1/current/fullchain.pem" key="$ROOT/certs/$1/current/key.pem" base
    [[ -s $file && -s $key ]] || return 1
    base=$(realpath -m -- "$ROOT/certs/$d/current")
    [[ $base == "$ROOT/certs/$d/"* ]] || return 1
    openssl x509 -in "$file" -noout -checkend 0 >/dev/null 2>&1 &&
      openssl x509 -in "$file" -noout -checkhost "$d" >/dev/null 2>&1 &&
      [[ $(openssl x509 -in "$file" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum) == $(openssl pkey -in "$key" -pubout -outform DER | sha256sum) ]]
}
s1_base_validate_state() {
    local cfg=${1:-$STATE} resources=${2:-yes} site node domain kind upstream protocol mode name port entry cred listen target
    state_basic "$cfg" || die '配置结构无效，原文件未被重置。'
    validate_advanced "$cfg"
    jq -e '([.nodes[].id]|length==(unique|length)) and ([.sites[].domain]|length==(unique|length)) and
      ([.components.xray,.components.nginx,.components.acme]|all(type=="boolean")) and
      (.nodes|all(type=="object" and (.enabled|type=="boolean") and (.port|type=="number") and .port==(.port|floor))) and
      (.sites|all(type=="object" and (.issued|type=="boolean")))' "$cfg" >/dev/null || die '节点/网站字段类型或唯一性错误。'
    while IFS= read -r site; do
        domain=$(jq -r .domain <<< "$site"); valid_domain "$domain" || die '网站域名无效。'
        kind=$(jq -r '.kind // (if (.upstream // "")!="" then "proxy" else "custom" end)' <<< "$site")
        upstream=$(jq -r '.upstream // ""' <<< "$site")
        choice "$(jq -r '.access // "direct"' <<< "$site")" 'direct cloudflare' || die '网站访问方式无效。'
        choice "$(jq -r '.challenge // "http"' <<< "$site")" 'http dns_cf dns_dp' || die '证书验证方式无效。'
        case "$kind" in
            template) choice "$(jq -r '.template // "welcome"' <<< "$site")" 'welcome notes blog' || die '模板无效。';;
            custom) ;;
            proxy) valid_upstream "$upstream" || die '上游必须是本机HTTP端口，且不能为80/443。';;
            redirect) valid_redirect "$(jq -r .redirect <<< "$site")" "$domain" || die '跳转地址无效。';;
            *) die '网站类型无效。';;
        esac
        [[ $kind == proxy || -z $upstream ]] || die '网站类型与反代地址不一致。'
        edge_validate "$site" "$cfg"
        if [[ $resources == yes && $(jq -r .issued <<< "$site") == true ]]; then cert_files_valid "$domain" || die "域名 $domain 的证书缺失、过期或密钥不匹配。请先恢复/续期证书。"; fi
    done < <(jq -c '.sites[]' "$cfg")
    while IFS= read -r node; do
        name=$(jq -r .id <<< "$node"); entry=$(jq -r .entry <<< "$node"); port=$(jq -r .port <<< "$node")
        protocol=$(jq -r .protocol <<< "$node"); mode=$(jq -r .mode <<< "$node"); cred=$(jq -r .credential <<< "$node")
        valid_name "$(jq -r '.runtime_id // .id' <<< "$node")" || die '节点内部稳定ID无效。'
        valid_name "$name" && valid_name "$entry" && valid_port "$port" && [[ $port != 22 && $port != 80 && $port != 443 ]] || die '节点名称、入口或端口无效。'
        valid_host "$(jq -r .host <<< "$node")" || die '节点连接地址无效。'
        listen=$(jq -r '.listen // "0.0.0.0"' <<< "$node")
        choice "$listen" '0.0.0.0 127.0.0.1 :: ::1' || die '节点监听地址不在允许列表。'
        case "$protocol:$mode" in vless:reality|vless:xhttp|vless:ws|vless:tls|vmess:ws|vmess:ws-plain|vmess:tls|trojan:ws|trojan:tls|shadowsocks:ss) ;; *) die '不支持的协议/传输组合。';; esac
        if [[ $protocol == vless || $protocol == vmess ]]; then valid_uuid "$cred" || die 'UUID无效。'
        else [[ ${#cred} -ge 8 && ${#cred} -le 256 && $cred != *[[:space:]]* ]] || die '密码长度/格式无效。'; fi
        if [[ $protocol == shadowsocks ]]; then
            choice "$(jq -r .method <<< "$node")" 'aes-128-gcm aes-256-gcm chacha20-ietf-poly1305 2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305' || die 'Shadowsocks算法无效。'
            if [[ $(jq -r .method <<< "$node") == 2022-* ]]; then
                local wanted=32 actual
                [[ $(jq -r .method <<< "$node") != 2022-blake3-aes-128-gcm ]] || wanted=16
                actual=$(printf '%s' "$cred" | base64 -d | wc -c) || die 'SS2022密钥不是有效Base64。'
                ((actual==wanted)) || die 'SS2022密钥长度与算法不匹配。'
            fi
        fi
        if [[ $mode == ws || $mode == xhttp || $mode == ws-plain ]]; then valid_path "$(jq -r .path <<< "$node")" || die '节点路径无效。'; fi
        if [[ $mode == ws || $mode == xhttp || $mode == tls ]]; then
            domain=$(jq -r .domain <<< "$node"); valid_domain "$domain" || die '节点TLS域名无效。'
            jq -e --arg d "$domain" '.sites[]|select(.domain==$d and .issued)' "$cfg" >/dev/null || die 'TLS节点引用了未签发证书的站点。'
        fi
        if [[ $mode == xhttp ]]; then
            choice "$(jq -r '.http_version // "h2"' <<< "$node")" 'h2 h3' || die 'XHTTP协议版本无效。'
            if [[ $(jq -r '.http_version // "h2"' <<< "$node") == h3 ]]; then
                jq -e --arg d "$domain" '.sites[]|select(.domain==$d and .access=="cloudflare")' "$cfg" >/dev/null || die 'H3出口要求Cloudflare站点。'
                [[ $(jq -r .host <<< "$node") == "$domain" ]] || die 'H3出口必须连接Cloudflare域名。'
            fi
        fi
        if [[ $mode == reality ]]; then
            valid_domain "$(jq -r .sni <<< "$node")" || die 'REALITY SNI无效。'
            target=$(jq -r .target <<< "$node"); valid_domain "${target%:*}" && valid_port "${target##*:}" || die 'REALITY目标无效。'
            [[ $(jq -r .privateKey <<< "$node") =~ ^[A-Za-z0-9_-]{43}$ && $(jq -r .publicKey <<< "$node") =~ ^[A-Za-z0-9_-]{43}$ && $(jq -r .shortId <<< "$node") =~ ^([a-fA-F0-9]{2}){1,8}$ ]] || die 'REALITY密钥或ShortID无效。'
        fi
    done < <(jq -c '.nodes[]' "$cfg")
    jq -e '[.nodes|group_by(.entry)[]|select(.[0].protocol=="shadowsocks")|length==1]|all' "$cfg" >/dev/null || die 'Shadowsocks入口不支持共享多个用户，请拆分入口。'
    jq -e '[.nodes|group_by(.entry)[]|(map(del(.id,.runtime_id,.credential,.enabled))|unique|length)==1]|all' "$cfg" >/dev/null || die '同入口用户的传输参数不一致。'
    jq -e '[.nodes|group_by(.entry)[]|.[0].port]|length==(unique|length)' "$cfg" >/dev/null || die '不同入口使用了重复端口。'
    jq -e '[.nodes[]|select(.mode=="ws" or .mode=="xhttp")]|group_by([.domain,.path])|map(map(.entry)|unique|length==1)|all' "$cfg" >/dev/null || die '不同入口使用了同一网站代理路径。'
    jq -e '[.nodes[]|(.runtime_id // .id)]|length==(unique|length)' "$cfg" >/dev/null || die '节点内部ID重复，拒绝覆盖用户身份。'
    # A WS exact path must not fall under another XHTTP prefix.
    jq -e '.nodes as $a | [ $a[]|select(.mode=="xhttp") as $x | $a[]|select(.entry!=$x.entry and .domain==$x.domain and (.mode=="xhttp" or .mode=="ws")) | (.path|startswith($x.path+"/")) ] | any | not' "$cfg" >/dev/null || die 'XHTTP路径前缀冲突。'
}
s1_base_render_xray() {
    local opts buffer
    opts=$(xray_settings); buffer=$(jq -r .buffer_kb <<< "$opts")
    if [[ $buffer == auto ]]; then
        case $(uname -m) in aarch64|arm64) buffer=4;; *) buffer=64;; esac
    fi
    jq --arg root "$ROOT" --argjson x "$opts" --arg buffer "$buffer" '
      {log:{access:"none",error:($root+"/logs/xray.log"),loglevel:$x.loglevel,dnsLog:false},
       policy:{levels:{"0":({handshake:$x.handshake,connIdle:$x.conn_idle,uplinkOnly:1,downlinkOnly:1,
         statsUserUplink:false,statsUserDownlink:false} +
         (if $buffer=="core" then {} else {bufferSize:($buffer|tonumber)} end))},
         system:{statsInboundUplink:false,statsInboundDownlink:false,statsOutboundUplink:false,statsOutboundDownlink:false}},
       inbounds:([.nodes[]|select(.enabled)]|group_by(.entry)|map(. as $g|.[0] as $n|
        {tag:$n.entry,listen:(if ($n.mode=="ws" or $n.mode=="xhttp") then "127.0.0.1" else $n.listen end),port:$n.port,protocol:$n.protocol,
         settings:(if $n.protocol=="vless" then {decryption:"none",clients:($g|map({id:.credential,email:(.runtime_id // .id),flow:(if .mode=="reality" then "xtls-rprx-vision" else "" end)}))}
          elif $n.protocol=="vmess" then {clients:($g|map({id:.credential,email:(.runtime_id // .id)})),disableInsecureEncryption:true}
          elif $n.protocol=="trojan" then {clients:($g|map({password:.credential,email:(.runtime_id // .id)}))}
          else {method:$n.method,password:$n.credential,network:"tcp,udp"} end)} +
        (if $n.mode=="ss" then {} else {streamSettings:({network:(if ($n.mode=="ws" or $n.mode=="ws-plain") then "ws" elif $n.mode=="xhttp" then "xhttp" else "tcp" end),
          security:(if ($n.mode=="ws" or $n.mode=="xhttp" or $n.mode=="ws-plain") then "none" elif $n.mode=="reality" then "reality" else "tls" end)} +
          (if $n.mode=="reality" then {realitySettings:{show:false,target:$n.target,xver:0,serverNames:[$n.sni],privateKey:$n.privateKey,shortIds:[$n.shortId]}}
           elif $n.mode=="tls" then {tlsSettings:{minVersion:"1.2",certificates:[{certificateFile:($root+"/certs/"+$n.domain+"/current/fullchain.pem"),keyFile:($root+"/certs/"+$n.domain+"/current/key.pem")}]}}
           elif $n.mode=="xhttp" then {xhttpSettings:{path:($n.path+"/"),mode:"packet-up"}}
           else {wsSettings:{path:$n.path}} end))} end))),
       outbounds:[{tag:"direct",protocol:"freedom"},{tag:"blocked",protocol:"blackhole"}],
       routing:{domainStrategy:"IPIfNonMatch",rules:[{type:"field",ip:["0.0.0.0/8","10.0.0.0/8","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.168.0.0/16","224.0.0.0/4","::/128","::1/128","fc00::/7","fe80::/10","ff00::/8"],outboundTag:"blocked"}]}}
    ' "$STATE" > "$1"
}
cf_cidrs_valid() {
    local file=$1 family=$2 line address prefix count=0
    [[ -s $file && $(stat -c %s "$file") -le 65536 ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == */* && $line != *[[:space:]]* ]] || return 1
        address=${line%/*}; prefix=${line##*/}
        valid_host "$address" && number "$prefix" 1 128 || return 1
        if [[ $family == 4 ]]; then [[ $address =~ ^[0-9.]+$ ]] && number "$prefix" 8 32 || return 1
        else [[ $address == *:* ]] && number "$prefix" 16 128 || return 1; fi
        count=$((count+1)); ((count<=512)) || return 1
    done < "$file"
    ((count>0))
}
cf_ready() { cf_cidrs_valid "$ROOT/config/edge/cf-v4.txt" 4 && cf_cidrs_valid "$ROOT/config/edge/cf-v6.txt" 6; }
cf_needed() { jq -e '.sites[]|select((.access // "direct")=="cloudflare")' "$STATE" >/dev/null; }
cf_fetch() {
    mkdir -p "$WORK/edge"
    fetch https://www.cloudflare.com/ips-v4 "$WORK/edge/cf-v4.txt"
    fetch https://www.cloudflare.com/ips-v6 "$WORK/edge/cf-v6.txt"
    fetch https://developers.cloudflare.com/ssl/static/authenticated_origin_pull_ca.pem "$WORK/edge/aop-ca.pem"
    cf_cidrs_valid "$WORK/edge/cf-v4.txt" 4 && cf_cidrs_valid "$WORK/edge/cf-v6.txt" 6 || die 'Cloudflare网段无效，旧配置保留。'
    openssl x509 -in "$WORK/edge/aop-ca.pem" -noout -checkend 2592000 >/dev/null || die 'AOP CA无效或即将到期。'
    openssl x509 -in "$WORK/edge/aop-ca.pem" -text -noout | grep -q 'CA:TRUE' || die '下载文件不是CA证书。'
}
cf_install_assets() { mkdir -p "$ROOT/config/edge"; install -m 600 "$WORK/edge/"* "$ROOT/config/edge/"; date +%s > "$ROOT/config/edge/updated.epoch"; }
bot_pattern() {
    local pattern='GPTBot|ChatGPT-User|OAI-SearchBot|ClaudeBot|Claude-User|Claude-SearchBot|anthropic-ai|CCBot|Bytespider|Amazonbot|Applebot-Extended|Google-Extended|cohere-ai|PerplexityBot|Perplexity-User|Diffbot|FacebookBot|meta-externalagent|meta-externalfetcher'
    case "$1" in common) pattern+='|AhrefsBot|SemrushBot|MJ12bot|DotBot|BLEXBot|DataForSeoBot|SeekportBot';;
        all) pattern+='|bot|spider|crawler|scrapy|python-requests|curl|wget|go-http-client|headlesschrome';; esac
    printf '%s' "$pattern"
}
edge_origin_guard() { if [[ $(jq -r .origin <<< "$1") == true ]]; then printf '            if ($vpskit_cf_peer = 0) { return 403; }\n'; fi; }
edge_web_guard() {
    local settings=$1 domain=$2 bots rate burst conn kbps zone
    bots=$(jq -r .bots <<< "$settings"); rate=$(jq -r .rate <<< "$settings"); burst=$(jq -r .burst <<< "$settings")
    conn=$(jq -r .connections <<< "$settings"); kbps=$(jq -r .kbps <<< "$settings"); zone=$(edge_zone "$domain")
    edge_origin_guard "$settings"
    [[ $bots == off ]] || printf '            if ($vpskit_bot_%s) { return 403; }\n' "$bots"
    ((rate==0)) || printf '            limit_req zone=vr_%s burst=%s nodelay;\n            limit_req_status 429;\n' "$zone" "$burst"
    ((conn==0)) || printf '            limit_conn vc_%s %s;\n            limit_conn_status 429;\n' "$zone" "$conn"
    ((kbps==0)) || printf '            limit_rate %sk;\n' "$kbps"
}

static_gzip() {
    [[ $1 == true ]] || return 0
    printf '            gzip on;\n            gzip_vary on;\n            gzip_comp_level %s;\n' "${2:-2}"
    cat <<'NGINX'
            gzip_min_length 1024;
            gzip_proxied any;
            gzip_types text/plain text/css application/javascript application/json image/svg+xml application/xml;
NGINX
}

render_access_logging() {
    local a=$1 mode sample buffer flush
    if [[ $(jq -r .access_log <<< "$a") != true ]]; then printf '    access_log off;\n'; return; fi
    mode=$(jq -r .access_log_mode <<< "$a"); sample=$(jq -r .access_log_sample <<< "$a")
    buffer=$(jq -r .access_log_buffer_kb <<< "$a"); flush=$(jq -r .access_log_flush <<< "$a")
    # No URI, query string, visitor IP, Referer, UA, UUID or credentials in performance logs.
    cat <<'NGINX'
    log_format vpskit_perf 'time=$time_iso8601 host=$server_name status=$status bytes=$bytes_sent rt=$request_time uct=$upstream_connect_time uht=$upstream_header_time urt=$upstream_response_time';
NGINX
    case "$mode" in
        errors) printf '    map $status $vpskit_loggable { default 0; 499 1; ~^5 1; }\n';;
        sample)
            if ((sample==100)); then printf '    map $request_id $vpskit_sample { default 1; }\n'
            else printf '    split_clients "$request_id" $vpskit_sample { %s%% 1; * 0; }\n' "$sample"; fi
            printf '    map "$status:$vpskit_sample" $vpskit_loggable { default 0; ~^499: 1; ~^5 1; ~:1$ 1; }\n';;
        full) printf '    map $status $vpskit_loggable { default 1; }\n';;
    esac
    printf '    access_log %s/logs/access.log vpskit_perf buffer=%sk flush=%ss if=$vpskit_loggable;\n' "$ROOT" "$buffer" "$flush"
}

s1_base_render_nginx() {
    local dest=$1 a user group version build h2 modern=false ipv6=false site domain kind upstream issued settings zone rate conn cidr policy ttl gzip node path port aop probe field value nodezone
    local -A nv=()
    a=$(nginx_settings); user=$(resolve_worker); group=$(id -gn "$user")
    build=$("$NGINX" -V 2>&1); version=$("$NGINX" -v 2>&1 | sed -n 's@.*nginx/\([0-9.]*\).*@\1@p')
    while IFS=$'\t' read -r field value; do nv["$field"]=$value; done < <(jq -r 'to_entries[]|[.key,(.value|tostring)]|@tsv' <<< "$a")
    h2=${nv[http2]}
    if jq -e '.nodes[]|select(.enabled and .mode=="xhttp")' "$STATE" >/dev/null; then h2=true; fi
    if [[ $h2 == true && $build != *--with-http_v2_module* ]]; then die 'HTTP/2或XHTTP需要带http_v2模块的Nginx；请升级组件或关闭网站HTTP/2。'; fi
    if dpkg --compare-versions "${version:-0}" ge 1.25.1; then modern=true; fi
    if [[ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 && $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) == 0 ]]; then ipv6=true; fi
    if cf_needed; then
        cf_ready || die 'Cloudflare网站缺少官方IP网段，请运行 vpskit edge refresh。'
        [[ $build == *--with-http_realip_module* ]] || die 'Cloudflare访客识别需要Nginx realip模块。'
    fi
    {
        cat <<EOF
# VPSKIT_OWNED — generated; edit state using vpskit advanced, not this file.
user $user $group;
worker_processes ${nv[workers]};
worker_rlimit_nofile ${nv[nofile]};
pid $ROOT/run/nginx.pid;
error_log $ROOT/logs/nginx.log ${nv[error_log_level]};
EOF
        if (( ${nv[worker_shutdown_timeout]} > 0 )); then printf 'worker_shutdown_timeout %ss;\n' "${nv[worker_shutdown_timeout]}"; fi
        cat <<EOF
 events { worker_connections ${nv[connections]}; }
http {
    types { text/html html htm; text/css css; application/javascript js mjs; application/json json; image/png png; image/jpeg jpg jpeg; image/gif gif; image/webp webp; image/avif avif; image/svg+xml svg; image/x-icon ico; text/plain txt; font/woff woff; font/woff2 woff2; font/ttf ttf; application/pdf pdf; video/mp4 mp4; application/xml xml; }
    default_type application/octet-stream;
    server_tokens off;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout ${nv[keepalive]}s;
    keepalive_requests ${nv[keepalive_requests]};
    client_header_timeout ${nv[client_header_timeout]}s;
    client_body_timeout ${nv[client_body_timeout]}s;
    send_timeout ${nv[send_timeout]}s;
    reset_timedout_connection on;
    client_max_body_size ${nv[client_max_body_mb]}m;
    client_body_temp_path $ROOT/run/nginx/client;
    proxy_temp_path $ROOT/run/nginx/proxy;
    fastcgi_temp_path $ROOT/run/nginx/fastcgi;
    uwsgi_temp_path $ROOT/run/nginx/uwsgi;
    scgi_temp_path $ROOT/run/nginx/scgi;
    ssl_session_cache shared:VPSKITSSL${nv[ssl_cache]}:${nv[ssl_cache]}m;
    ssl_session_timeout ${nv[ssl_timeout]}m;
    ssl_protocols $(nginx_tls_protocols);
EOF
        render_access_logging "$a"
        cat <<'NGINX'
    map $http_upgrade $vpskit_is_ws { default 0; ~*^websocket$ 1; }
    map $http_upgrade $vpskit_connection { default upgrade; '' ''; }
    map $http_upgrade $vpskit_connection_close { default upgrade; '' close; }
NGINX
        for policy in ai common all; do printf '    map $http_user_agent $vpskit_bot_%s { default 0; ~*(%s) 1; }\n' "$policy" "$(bot_pattern "$policy")"; done
        if cf_needed; then
            printf '    geo $realip_remote_addr $vpskit_cf_peer { default 0;\n'
            while IFS= read -r cidr; do printf '        %s 1;\n' "$cidr"; done < <(cat "$ROOT/config/edge/cf-v4.txt" "$ROOT/config/edge/cf-v6.txt")
            printf '    }\n'
        fi
        while IFS= read -r site; do
            domain=$(jq -r .domain <<< "$site"); settings=$(edge_settings "$site"); zone=$(edge_zone "$domain")
            rate=$(jq -r .rate <<< "$settings"); conn=$(jq -r .connections <<< "$settings")
            if ((rate>0)); then printf '    limit_req_zone $binary_remote_addr zone=vr_%s:1m rate=%sr/s;\n' "$zone" "$rate"; fi
            if ((conn>0)); then printf '    limit_conn_zone $binary_remote_addr zone=vc_%s:1m;\n' "$zone"; fi
            upstream=$(jq -r '.upstream // ""' <<< "$site")
            if [[ -n $upstream ]]; then
                printf '    upstream va_%s { server %s;' "$zone" "${upstream#http://}"
                if (( ${nv[upstream_keepalive]}>0 )); then
                    printf ' keepalive %s;' "${nv[upstream_keepalive]}"
                    if dpkg --compare-versions "${version:-0}" ge 1.15.3; then printf ' keepalive_timeout %ss; keepalive_requests 1000;' "${nv[upstream_idle]}"; fi
                fi
                printf ' }\n'
            fi
        done < <(jq -c '.sites[]' "$STATE")
        while IFS= read -r node; do
            port=$(jq -r .port <<< "$node"); nodezone="vx_$port"
            printf '    upstream %s { server 127.0.0.1:%s;' "$nodezone" "$port"
            if ((nv[xhttp_keepalive]>0)); then
                printf ' keepalive %s;' "${nv[xhttp_keepalive]}"
                if dpkg --compare-versions "${version:-0}" ge 1.15.3; then
                    printf ' keepalive_timeout %ss; keepalive_requests 1000;' "${nv[upstream_idle]}"
                fi
            fi
            printf ' }\n'
        done < <(jq -c '[.nodes[]|select(.enabled and .mode=="xhttp")]|unique_by(.entry)[]' "$STATE")
        printf '    server {\n        listen 80 default_server;\n'
        [[ $ipv6 != true ]] || printf '        listen [::]:80 default_server;\n'
        printf '        server_name _;\n        location ^~ /.well-known/acme-challenge/ { root %s/www/acme; default_type text/plain; }\n        location / { return 404; }\n    }\n' "$ROOT"
        while IFS= read -r site; do
            domain=$(jq -r .domain <<< "$site"); issued=$(jq -r .issued <<< "$site"); settings=$(edge_settings "$site"); zone=$(edge_zone "$domain")
            kind=$(jq -r '.kind // (if (.upstream // "")!="" then "proxy" else "custom" end)' <<< "$site")
            upstream=$(jq -r '.upstream // ""' <<< "$site"); ttl=$(jq -r .static_ttl <<< "$settings")
            gzip=$(jq -r --argjson global "$(get '.performance.gzip // false')" 'if ((.protection // {})|has("gzip")) then .protection.gzip else $global end' <<< "$site")
            printf '    server {\n        listen 80;\n'
            [[ $ipv6 != true ]] || printf '        listen [::]:80;\n'
            printf '        server_name %s;\n        if ($host != %s) { return 404; }\n' "$domain" "$domain"
            printf '        location ^~ /.well-known/acme-challenge/ { root %s/www/acme; default_type text/plain; }\n' "$ROOT"
            if [[ $issued == true ]]; then
                printf '        location / { return 301 https://%s$request_uri; }\n    }\n' "$domain"
                printf '    server {\n'
                if [[ $h2 == true && $modern == false ]]; then
                    printf '        listen 443 ssl http2;\n'; [[ $ipv6 != true ]] || printf '        listen [::]:443 ssl http2;\n'
                else
                    printf '        listen 443 ssl;\n'; [[ $ipv6 != true ]] || printf '        listen [::]:443 ssl;\n'
                    [[ $h2 != true ]] || printf '        http2 on;\n'
                fi
                printf '        server_name %s;\n        if ($host != %s) { return 404; }\n' "$domain" "$domain"
                printf '        ssl_certificate %s/certs/%s/current/fullchain.pem;\n        ssl_certificate_key %s/certs/%s/current/key.pem;\n' "$ROOT" "$domain" "$ROOT" "$domain"
            fi
            if [[ $(jq -r '.access // "direct"' <<< "$site") == cloudflare ]]; then
                while IFS= read -r cidr; do printf '        set_real_ip_from %s;\n' "$cidr"; done < <(cat "$ROOT/config/edge/cf-v4.txt" "$ROOT/config/edge/cf-v6.txt")
                printf '        real_ip_header CF-Connecting-IP;\n        real_ip_recursive on;\n'
            fi
            aop=$(jq -r .aop <<< "$settings")
            if [[ $issued == true && $aop != off ]]; then
                printf '        ssl_client_certificate %s/config/edge/aop-ca.pem;\n        ssl_verify_client %s;\n        ssl_verify_depth 2;\n' "$ROOT" "$([[ $aop == enforce ]] && printf on || printf optional)"
                probe=$(get .edge.probe)
                printf '        location = /.well-known/vpskit-aop-%s { default_type text/plain; add_header Cache-Control "no-store" always; return 200 "$ssl_client_verify"; }\n' "$probe"
            fi
            printf '        root %s/www/%s;\n' "$ROOT" "$domain"
            if [[ $kind == template ]]; then printf '        index vpskit-%s.html index.html;\n' "$(jq -r '.template // "welcome"' <<< "$site")"
            else printf '        index index.html;\n'; fi
            printf '        location ~ /\\. { deny all; }\n'
            if [[ $issued == true ]]; then
                while IFS= read -r node; do
                    path=$(jq -r .path <<< "$node"); port=$(jq -r .port <<< "$node")
                    if [[ $(jq -r .mode <<< "$node") == xhttp ]]; then
                        printf '        location ^~ %s/ {\n' "$path"
                        edge_origin_guard "$settings"
                        printf '            proxy_http_version 1.1;\n            proxy_set_header Host $host;\n            client_max_body_size 0;\n'
                    else
                        printf '        location = %s {\n' "$path"
                        edge_origin_guard "$settings"
                        printf '            if ($vpskit_is_ws = 0) { return 404; }\n            if ($request_method != GET) { return 404; }\n            proxy_http_version 1.1;\n            proxy_set_header Upgrade $http_upgrade;\n            proxy_set_header Connection "upgrade";\n            proxy_set_header Host $host;\n'
                    fi
                    if [[ ${nv[proxy_access_log]} != true ]]; then printf '            access_log off;\n'; fi
                    if [[ $(jq -r .mode <<< "$node") == xhttp ]]; then
                        printf '            proxy_pass http://vx_%s;\n' "$port"
                        if ((nv[xhttp_keepalive]==0)); then printf '            proxy_set_header Connection close;\n'; else printf '            proxy_set_header Connection "";\n'; fi
                    else printf '            proxy_pass http://127.0.0.1:%s;\n' "$port"; fi
                    cat <<EOF
            proxy_next_upstream off;
            proxy_buffering off;
            proxy_request_buffering off;
            proxy_cache off;
            gzip off;
            add_header Cache-Control "no-store" always;
            proxy_connect_timeout ${nv[proxy_connect_timeout]}s;
            proxy_read_timeout ${nv[proxy_read_timeout]}s;
            proxy_send_timeout ${nv[proxy_send_timeout]}s;
            client_body_timeout ${nv[proxy_send_timeout]}s;
            send_timeout ${nv[proxy_read_timeout]}s;
        }
EOF
                done < <(jq -c --arg d "$domain" '[.nodes[]|select(.enabled and (.mode=="ws" or .mode=="xhttp") and .domain==$d)]|unique_by(.entry)[]' "$STATE")
            fi
            if [[ $kind == template || $kind == custom ]]; then
                if ((ttl>0)); then
                    printf '        location ~* \\.(css|js|png|jpe?g|gif|svg|webp|avif|ico|woff2?|ttf)$ {\n'
                    edge_web_guard "$settings" "$domain"
                    printf '            try_files $uri =404;\n            expires %ss;\n' "$ttl"; static_gzip "$gzip" "${nv[gzip_level]}"; printf '        }\n'
                fi
            fi
            printf '        location / {\n'; edge_web_guard "$settings" "$domain"
            if [[ $kind == redirect ]]; then
                printf '            return 302 "%s";\n' "$(jq -r .redirect <<< "$site")"
            elif [[ $kind == proxy ]]; then
                cat <<EOF
            proxy_pass http://va_$zone;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection $([[ ${nv[upstream_keepalive]} == 0 ]] && printf '$vpskit_connection_close' || printf '$vpskit_connection');
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$remote_addr;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_hide_header X-Powered-By;
            proxy_connect_timeout ${nv[proxy_connect_timeout]}s;
            proxy_read_timeout ${nv[site_proxy_timeout]}s;
            proxy_send_timeout ${nv[site_proxy_timeout]}s;
EOF
                if [[ ${nv[proxy_gzip]} == true ]]; then static_gzip true "${nv[gzip_level]}"; fi
            else printf '            try_files $uri $uri/ =404;\n'; static_gzip "$gzip" "${nv[gzip_level]}"; fi
            printf '        }\n    }\n'
        done < <(jq -c '.sites[]' "$STATE")
        printf '}\n'
    } > "$dest"
}

s1_base_render_units() {
    local dir=$1 user='not-installed' nglimit xrlimit
    mkdir -p "$dir"
    nglimit=$(ng_value nofile); xrlimit=$(xray_nofile)
    if [[ $(get '.components.nginx // false') == true ]]; then user=$(resolve_worker); fi
    cat > "$dir/vpskit-nginx.service" <<EOF
# VPSKIT_OWNED
# worker-user: $user
[Unit]
Description=VPSKit Nginx (root master, unprivileged workers)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
ExecStartPre=/bin/bash $ROOT/vpskit.sh _service nginx-test
ExecStart=/bin/bash $ROOT/vpskit.sh _service nginx
ExecReload=/bin/bash $ROOT/vpskit.sh _service nginx-reload
KillSignal=SIGQUIT
KillMode=mixed
TimeoutStopSec=30
Restart=on-failure
RestartSec=5
$(nginx_unit_properties "$(ng_value sandbox_mode)" "$nglimit")
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF
    cat > "$dir/vpskit-xray.service" <<EOF
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
LimitNOFILE=$xrlimit
LimitCORE=0
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectControlGroups=true
ReadWritePaths=$ROOT/logs $ROOT/run
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF
    cat > "$dir/vpskit-maintain.service" <<EOF
# VPSKIT_OWNED
[Unit]
Description=VPSKit certificate renewal and bounded log maintenance
After=network-online.target
[Service]
Type=oneshot
User=root
ExecStart=/bin/bash $ROOT/vpskit.sh maintenance
TimeoutStartSec=30min
Nice=10
IOSchedulingClass=idle
UMask=0077
EOF
    cat > "$dir/vpskit-maintain.timer" <<'EOF'
# VPSKIT_OWNED
[Unit]
Description=VPSKit scheduled certificate and log maintenance
[Timer]
OnCalendar=hourly
RandomizedDelaySec=300
AccuracySec=1min
Persistent=true
[Install]
WantedBy=timers.target
EOF
}
service_runner() {
    root_check
    [[ ! -L $ROOT && -f $ROOT/.vpskit-owned && $(cat "$ROOT/.vpskit-owned") == VPSKIT_V1 ]] || die '服务根目录无效。'
    case "$1" in
        nginx-test) nginx_cmd -t -p "$ROOT/" -c "$ROOT/config/nginx.conf";;
        nginx-reload) nginx_cmd -t -p "$ROOT/" -c "$ROOT/config/nginx.conf"; nginx_cmd -p "$ROOT/" -c "$ROOT/config/nginx.conf" -s reload;;
        nginx) local help; help=$("$NGINX" -h 2>&1 || true); local -a args=()
            [[ $help != *'-e filename'* ]] || args=(-e "$ROOT/logs/nginx.log")
            exec "$NGINX" "${args[@]}" -p "$ROOT/" -c "$ROOT/config/nginx.conf" -g 'daemon off;' ;;
        xray) exec "$XRAY" run -config "$ROOT/config/xray.json";;
        *) die '未知内部服务入口。';;
    esac
}
proc_start_ticks() {
    # /proc/PID/stat field 2 is parenthesized and MAY contain whitespace or ')'.
    # Strip through the LAST ') ' before indexing fields 3.., never awk $22.
    local pid=$1 record rest; local -a fields=()
    [[ $pid =~ ^[1-9][0-9]*$ ]] || return 1
    IFS= read -r record < "$RUNTIME_PROC/$pid/stat" 2>/dev/null || return 1
    [[ $record == *') '* ]] || return 1
    rest=${record##*) }; IFS=' ' read -r -a fields <<< "$rest"
    [[ ${fields[19]:-} =~ ^[0-9]+$ ]] || return 1
    printf '%s' "${fields[19]}"
}
proc_worker_fields() {
    # A bounded, read-only sample using shell builtins instead of multiple awk forks.
    local pid=$1 key value line a b c d
    W_PPID='' W_UID='' W_RUID='' W_SUID='' W_FSUID='' W_CAPS='' W_FD='' W_START='' W_STATE=''
    [[ $pid =~ ^[1-9][0-9]*$ && -r $RUNTIME_PROC/$pid/status ]] || return 1
    while IFS=: read -r key value; do
        case "$key" in
            PPid) read -r W_PPID <<< "$value";;
            Uid) read -r W_RUID W_UID W_SUID W_FSUID <<< "$value";;
            CapEff) read -r W_CAPS <<< "$value";;
            State) read -r W_STATE _ <<< "$value";;
        esac
    done < "$RUNTIME_PROC/$pid/status"
    if [[ -r $RUNTIME_PROC/$pid/limits ]]; then
        while IFS= read -r line; do
            if [[ $line == 'Max open files'* ]]; then read -r a b c W_FD d _ <<< "$line"; break; fi
        done < "$RUNTIME_PROC/$pid/limits"
    fi
    W_START=$(proc_start_ticks "$pid") || return 1
    [[ $W_PPID =~ ^[0-9]+$ && $W_UID =~ ^[0-9]+$ && $W_STATE != Z && $W_STATE != X ]]
}
master_workers() {
    local master=$1 hint=${2:-} pid title uid parent key value children='' rows='' row_title
    local -a candidates=(); local -A seen=() titles=()
    [[ $master =~ ^[1-9][0-9]*$ ]] || return 0
    # ps and the task children file are complementary snapshots, not an either/or.
    # Some procfs implementations expose an empty/restricted children file.
    rows=$(ps -ww --ppid "$master" -o pid=,uid=,args= 2>/dev/null || true)
    while read -r pid uid row_title; do
        [[ $pid =~ ^[1-9][0-9]*$ ]] || continue
        titles[$pid]=$row_title
        if [[ -z ${seen[$pid]:-} ]]; then candidates+=("$pid"); seen[$pid]=1; fi
    done <<< "$rows"
    if [[ -r $RUNTIME_PROC/$master/task/$master/children ]]; then
        IFS= read -r children < "$RUNTIME_PROC/$master/task/$master/children" || true
        for pid in $children; do
            [[ $pid =~ ^[1-9][0-9]*$ ]] || continue
            if [[ -z ${seen[$pid]:-} ]]; then candidates+=("$pid"); seen[$pid]=1; fi
        done
    fi
    # Hint is only from the private probe HTTP response. It NEVER bypasses PPid,
    # process title, UID, capability, FD or stable-generation verification.
    if [[ $hint =~ ^[1-9][0-9]*$ && -z ${seen[$hint]:-} ]]; then candidates+=("$hint"); fi
    for pid in "${candidates[@]}"; do
        title=''; uid=''; parent=''
        if [[ -r $RUNTIME_PROC/$pid/cmdline ]]; then IFS= read -r -d '' title < "$RUNTIME_PROC/$pid/cmdline" 2>/dev/null || true; fi
        [[ -n $title ]] || title=${titles[$pid]:-}
        [[ $title == 'nginx: worker process'* && $title != *'shutting down'* && $title != *'exiting'* ]] || continue
        [[ -r $RUNTIME_PROC/$pid/status ]] || continue
        while IFS=: read -r key value; do
            case "$key" in PPid) read -r parent <<< "$value";; Uid) read -r _ uid _ <<< "$value";; esac
        done < "$RUNTIME_PROC/$pid/status"
        [[ $parent == "$master" && $uid =~ ^[0-9]+$ ]] || continue
        printf '%s %s\n' "$pid" "$uid"
    done
    return 0
}
preflight_failure_hint() {
    # Use only bounded local-probe error text. No config/credentials are printed.
    local probe=$1 text line
    [[ -r $probe/error.log ]] || return 1
    text=$(tail -c 16384 "$probe/error.log" 2>/dev/null) || return 1
    while IFS= read -r line; do
        case "$line" in
            *'setuid('*'failed'*|*'setgid('*'failed'*|*'fork() failed'*|*'worker process'*'exited with fatal code'*|*'worker process'*'exited on signal'*|*'bind('*'failed'*|*'[emerg]'*)
                printf '%s' "${line:0:800}"; return 0;;
        esac
    done <<< "$text"
    return 1
}
preflight_unit_failed() {
    local unit=$1 data key value active='' result='' status=''
    [[ -n $unit ]] || return 1
    data=$(timeout 2 systemctl show "$unit" -p ActiveState -p SubState -p Result -p ExecMainStatus 2>/dev/null) || return 1
    while IFS== read -r key value; do
        case "$key" in ActiveState) active=$value;; Result) result=$value;; ExecMainStatus) status=$value;; esac
    done <<< "$data"
    if [[ $active == failed || $active == inactive ]]; then
        warn "预检服务已停止：ActiveState=$active Result=${result:-unknown} ExecMainStatus=${status:-unknown}。"
        return 0
    fi
    return 1
}
verify_nginx_runtime() {
    local old=${1:-} explicit=${2:-} cfg=${3:-$ROOT/config/nginx.conf} allow_root=${4:-no}
    local unit=${5:-} probe=${6:-} hint=${7:-}
    local master='' user uid pid actual_uid birth count=0 seen=0 stable=0 last='' current reason='未发现Master'
    local expected limit connections wait_s deadline required last_diag=-1 msg check_birth
    user=$(nginx_conf_value user "$cfg" || true)
    if [[ -z $user ]]; then user=$(resolve_worker) || return 1; fi
    uid=$(id -u "$user" 2>/dev/null) || { warn "Worker账户不存在：$user"; return 1; }
    [[ $uid != 0 || $allow_root == yes ]] || { warn '拒绝新配置中的root Worker。'; return 1; }
    expected=$(nginx_conf_value worker_processes "$cfg" || true); expected=${expected:-$(ng_value workers)}
    limit=$(nginx_conf_value worker_rlimit_nofile "$cfg" || true)
    connections=$(nginx_conf_value worker_connections "$cfg" || true); connections=${connections:-512}
    [[ $expected != auto ]] || expected=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 1)
    [[ $expected =~ ^[1-9][0-9]*$ && $connections =~ ^[0-9]+$ ]] || return 1
    required=${limit:-$connections}; [[ $required =~ ^[0-9]+$ ]] || return 1
    wait_s=$(ng_value startup_timeout 2>/dev/null || printf 30); number "$wait_s" 5 180 || wait_s=30
    deadline=$((SECONDS+wait_s))
    while ((SECONDS<=deadline)); do
        if [[ -n $unit && $SECONDS != "$last_diag" ]]; then
            last_diag=$SECONDS
            preflight_unit_failed "$unit" && return 1
            if [[ -n $probe ]] && msg=$(preflight_failure_hint "$probe"); then warn "预检启动错误：$msg"; return 1; fi
        fi
        if [[ -n $explicit ]]; then master=$explicit; else master=$(nginx_master_pid || true); fi
        if [[ ! $master =~ ^[1-9][0-9]*$ || ! -r $RUNTIME_PROC/$master/status ]]; then
            if [[ -n $explicit ]]; then warn '预检Master在校验期间退出；请查看预检诊断。'; return 1; fi
            reason='未找到已启动的Nginx Master'; sleep .25; continue
        fi
        count=0; seen=0; current=''; reason="未识别到接入Worker（需要$expected个；同时核对ps与/proc）"
        while read -r pid actual_uid; do
            [[ -n $pid ]] || continue
            seen=$((seen+1))
            if ! proc_worker_fields "$pid"; then reason="Worker $pid 的/proc信息不可读、已退出或正在变化"; continue; fi
            birth=$W_START
            [[ " $old " != *" $pid:$birth "* && " $old " != *" $pid "* ]] || { reason='仅观察到旧一代Worker；等待新一代'; continue; }
            [[ $W_PPID == "$master" ]] || { reason="Worker $pid 的父进程已变化"; continue; }
            if [[ $actual_uid != "$uid" || $W_UID != "$uid" || $W_RUID != "$uid" || $W_SUID != "$uid" || $W_FSUID != "$uid" || ( $W_UID == 0 && $allow_root != yes ) ]]; then
                warn "Worker PID=$pid UID=$actual_uid（实际$W_UID），预期UID=$uid；拒绝提交。"; return 1
            fi
            [[ $W_CAPS =~ ^[a-fA-F0-9]+$ && -n $W_FD ]] || { reason="Worker $pid 的capabilities或文件数不可核验"; continue; }
            if [[ $W_UID != 0 && ! $W_CAPS =~ ^0+$ ]]; then warn "非root Worker $pid 保留有效capabilities=$W_CAPS，拒绝提交。"; return 1; fi
            if [[ $W_FD != unlimited ]] && { [[ ! $W_FD =~ ^[0-9]+$ ]] || ((W_FD<required)); }; then
                reason="Worker $pid 文件数上限=$W_FD，小于目标=$required；检查LimitNOFILE/CAP_SYS_RESOURCE"; continue
            fi
            check_birth=$(proc_start_ticks "$pid" || true)
            [[ $check_birth == "$birth" ]] || { reason="Worker $pid 在采样期间更换，等待稳定"; continue; }
            count=$((count+1)); current+="$pid:$birth "
        done < <(master_workers "$master" "$hint")
        if ((count>=expected)); then
            if [[ $current == "$last" ]]; then stable=$((stable+1)); else stable=1; fi
            last=$current; ((stable<2)) || return 0
        else stable=0; last=''; fi
        sleep .25
    done
    warn "Nginx运行校验超时（${wait_s}s）：$reason；识别$seen个、通过$count个、要求$expected个。"
    return 1
}
guard_port() {
    local port=$1 service=$2 output pid
    output=$(ss -H -lntup "sport = :$port")
    [[ -n $output ]] || return 0
    local -a pids=()
    mapfile -t pids < <(printf '%s\n' "$output" | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)
    ((${#pids[@]})) || die "端口 $port 被占用且无法识别归属；不会自动杀进程。"
    for pid in "${pids[@]}"; do
        grep -Fq "/$service" "/proc/$pid/cgroup" || die "端口 $port 被其他进程占用；请换端口或人工处理，不会抢占外部服务。"
    done
}
s1_base_check_listener_ports() {
    local port
    if [[ $(get '.components.nginx // false') == true ]]; then
        guard_port 80 vpskit-nginx.service
        if jq -e '.sites[]|select(.issued)' "$STATE" >/dev/null; then guard_port 443 vpskit-nginx.service; fi
    fi
    while IFS= read -r port; do guard_port "$port" vpskit-xray.service; done < <(jq -r '[.nodes[]|select(.enabled)]|unique_by(.entry)[].port' "$STATE")
}
code_candidate_check() {
    local file=$1 minimum=${2:-$FEATURE_LEVEL}
    [[ -s $file && ! -L $file && $(stat -c %s "$file") -le 4194304 ]] || die '脚本文件为空、为链接或大于4MiB。'
    grep -Fq 'VPSKIT_SINGLE_FILE' "$file" || die '没有VPSKit单文件标识。'
    grep -Fxq '# VPSKIT_STATE_SCHEMA=1' "$file" || die '候选脚本不兼容当前配置结构。'
    local level ver
    level=$(sed -n 's/^# VPSKIT_FEATURE_LEVEL=\([0-9][0-9]*\)$/\1/p' "$file")
    [[ $level =~ ^[0-9]{1,3}$ ]] && ((level>=minimum)) || die '拒绝用缺少高级配置/恢复能力的旧脚本覆盖增强版。请先上传新版源码到更新源。'
    ver=$(sed -n "s/^VERSION='\([A-Za-z0-9.+~-]*\)'$/\1/p" "$file")
    [[ -n $ver && $ver != *$'\n'* ]] || die '版本字段无效。'
    bash -n "$file" || die '候选脚本存在Bash语法错误，未安装。'
    printf '%s' "$ver"
}
install_manager_file() {
    local candidate=$1 dest="$ROOT/vpskit.sh" backup version
    version=$(code_candidate_check "$candidate")
    if [[ -e $ENTRY || -L $ENTRY ]]; then [[ $(readlink "$ENTRY" || true) == "$dest" ]] || die "$ENTRY 属于其他程序，拒绝覆盖。"; fi
    if [[ -e $dest ]]; then
        [[ ! -L $dest ]] && grep -Fq 'VPSKIT_SINGLE_FILE' "$dest" || die '已安装脚本不是本工具的普通文件。'
        if cmp -s "$candidate" "$dest"; then ln -sfn "$dest" "$ENTRY"; ok '管理脚本内容相同，无需替换。'; return; fi
        mkdir -p "$ROOT/backup/code"
        backup="$ROOT/backup/code/$(date -u '+%Y%m%dT%H%M%SZ')-$(randhex 4).sh"
        cp -a "$dest" "$backup"; chmod 600 "$backup"
    fi
    install -m 700 "$candidate" "$ROOT/vpskit.sh.new"
    mv -f "$ROOT/vpskit.sh.new" "$dest"
    ln -sfn "$dest" "$ENTRY"
    printf '%s  %s\n' "$(sha256sum "$dest" | cut -d' ' -f1)" "$version" > "$ROOT/data/manager-installed.sha256"
    ok "管理代码已安装：$version；未改写state.json或重启服务。"
}
ensure_manager_installed() {
    [[ -f $SELF && $SELF != /dev/fd/* && $SELF != /proc/* ]] || die '请将完整脚本下载为文件后执行。'
    if [[ ! -f $ROOT/vpskit.sh ]] || ! cmp -s "$SELF" "$ROOT/vpskit.sh"; then
        install_manager_file "$SELF"
    fi
}
update_manager() {
    local source=${1:-} expected=${2:-} candidate="$WORK/manager.candidate.sh" version current='' digest
    if [[ -z $source ]]; then
        if [[ $(realpath -m "$SELF") != "$ROOT/vpskit.sh" ]]; then source=$SELF
        else ask source '完整新版脚本本地路径或HTTPS地址' "$SELF_URL"; fi
    fi
    if [[ $source == https://* ]]; then fetch "$source" "$candidate"
    else [[ -f $source && ! -L $source ]] || die '本地源码文件不存在或为符号链接。'; cp -- "$source" "$candidate"; fi
    version=$(code_candidate_check "$candidate")
    if [[ -f $ROOT/vpskit.sh ]]; then
        current=$(sed -n "s/^VERSION='\([A-Za-z0-9.+~-]*\)'$/\1/p" "$ROOT/vpskit.sh")
        [[ -z $current ]] || dpkg --compare-versions "$version" ge "$current" || die "候选版本 $version 低于已安装版本 $current；拒绝静默降级。"
    fi
    digest=$(sha256sum "$candidate" | cut -d' ' -f1)
    if [[ -n $expected ]]; then
        [[ $expected =~ ^[a-fA-F0-9]{64}$ && ${expected,,} == "$digest" ]] || die 'SHA256不匹配。'
    fi
    printf '候选版本：%s\nSHA256：%s\n' "$version" "$digest"
    warn '语法/标识检查不证明来源可信；仅安装你审查过的源码或用可信渠道提供的SHA256校验。'
    confirm '仅替换管理代码，保留当前配置、证书、节点和运行中的服务' || return 0
    install_manager_file "$candidate"
    info '旧进程配置不会因此改变。要启用非root Worker等新生成配置，请执行 vpskit apply 或在高级配置中保存。'
}
# Runtime planning uses file content, not mtimes. It never treats a successful
# syntax check as proof that a service has loaded the candidate configuration.
declare -a RUNTIME_UNITS=()
RUNTIME_NG='skip' RUNTIME_X='skip' RUNTIME_NG_REASON='' RUNTIME_X_REASON=''
RUNTIME_NG_HASH='{}' RUNTIME_X_HASH='{}' RUNTIME_SCOPE='all'
runtime_hash_file() {
    if [[ -f $1 ]]; then sha256sum -- "$1" | cut -d' ' -f1; else printf 'missing\n'; fi
}
s1_base_runtime_fingerprint() {
    local component=$1 config=$2 confhash binhash assets domain binary
    if [[ $component == nginx ]]; then binary=$NGINX; confhash=$(runtime_hash_file "$config")
    else binary=$XRAY; confhash=$(jq -cS . "$config" | sha256sum | cut -d' ' -f1); fi
    binhash=$(runtime_hash_file "$binary")
    assets=$({
        while IFS= read -r domain; do
            [[ -n $domain ]] || continue
            printf 'domain=%s\n' "$domain"
            runtime_hash_file "$ROOT/certs/$domain/current/fullchain.pem"
            runtime_hash_file "$ROOT/certs/$domain/current/key.pem"
        done < <(jq -r --arg c "$component" '
          if $c=="nginx" then [.sites[]|select(.issued)|.domain]
          else [.nodes[]|select(.enabled and .mode=="tls")|.domain] + [(.native_nodes // [])[]|select(.enabled and (.domain // "")!="")|.domain] end | unique[]' "$STATE")
        if [[ $component == nginx ]] && jq -e '.sites[]|select(.issued and (.protection.aop // "off")!="off")' "$STATE" >/dev/null; then
            runtime_hash_file "$ROOT/config/edge/aop-ca.pem"
        fi
    } | sha256sum | cut -d' ' -f1)
    jq -nc --arg c "$confhash" --arg b "$binhash" --arg a "$assets" '{config:$c,binary:$b,assets:$a}'
}
runtime_prepare() {
    local scope=${1:-all} force=${2:-none} base="$ROOT/config" record oldng='{}' oldx='{}' u oldbin newbin
    RUNTIME_SCOPE=$scope; RUNTIME_UNITS=(); RUNTIME_NG=skip; RUNTIME_X=skip
    RUNTIME_NG_REASON='配置、证书和程序未变化'; RUNTIME_X_REASON='配置、证书和程序未变化'
    RUNTIME_NG_HASH='{}'; RUNTIME_X_HASH='{}'
    # A restore may already have replaced config/ on disk: compare to pre-transaction files.
    if ((TX==1)) && [[ -d $ROOT/backup/transaction/snapshot/config ]]; then base="$ROOT/backup/transaction/snapshot/config"; fi
    record="$base/.runtime-applied.json"
    if [[ -r $record && ! -L $record ]]; then
        oldng=$(jq -ce '.nginx // {}' "$record" 2>/dev/null || printf '{}')
        oldx=$(jq -ce '.xray // {}' "$record" 2>/dev/null || printf '{}')
    fi
    if [[ $(get '.components.nginx // false') == true ]]; then
        ensure_component nginx; render_nginx "$WORK/nginx.next.conf"
        RUNTIME_NG_HASH=$(runtime_fingerprint nginx "$WORK/nginx.next.conf")
        if ! cmp -s "$WORK/nginx.next.conf" "$base/nginx.conf" || [[ $(jq -cS . <<< "$oldng") != $(jq -cS . <<< "$RUNTIME_NG_HASH") ]]; then
            RUNTIME_NG=reload; RUNTIME_NG_REASON='生成配置/证书/加载指纹变化（首次应用也会建立指纹）'
        fi
        oldbin=$(jq -r '.binary // ""' <<< "$oldng"); newbin=$(jq -r .binary <<< "$RUNTIME_NG_HASH")
        if [[ -n $oldbin && $oldbin != "$newbin" ]]; then RUNTIME_NG=restart; RUNTIME_NG_REASON='Nginx程序内容变化'; fi
    elif systemctl is-active --quiet vpskit-nginx.service; then RUNTIME_NG=stop; RUNTIME_NG_REASON='配置禁用了组件'; fi
    if [[ $scope == all ]]; then
        if [[ $(get '.components.xray // false') == true ]]; then
            ensure_component xray; render_xray "$WORK/xray.next.json"
            RUNTIME_X_HASH=$(runtime_fingerprint xray "$WORK/xray.next.json")
            if ! json_equal "$WORK/xray.next.json" "$base/xray.json" || [[ $(jq -cS . <<< "$oldx") != $(jq -cS . <<< "$RUNTIME_X_HASH") ]]; then
                RUNTIME_X=restart; RUNTIME_X_REASON='运行配置/证书/程序或首次加载指纹变化'
            fi
        elif systemctl is-active --quiet vpskit-xray.service; then RUNTIME_X=stop; RUNTIME_X_REASON='配置禁用了组件'; fi
    else RUNTIME_X_REASON='本次仅处理网站；不更改Xray配置或服务单元'; fi
    render_units "$WORK/units"
    for u in "${UNITS[@]}"; do
        [[ $scope != web || $u != vpskit-xray.service ]] || continue
        if [[ -e $SYSTEMD/$u ]]; then [[ ! -L $SYSTEMD/$u ]] && grep -Fq '# VPSKIT_OWNED' "$SYSTEMD/$u" || die "外部同名服务：$u"; fi
        if ! cmp -s "$WORK/units/$u" "$SYSTEMD/$u"; then
            RUNTIME_UNITS+=("$u")
            if [[ $u == vpskit-nginx.service && $(get '.components.nginx // false') == true ]]; then RUNTIME_NG=restart; RUNTIME_NG_REASON='服务单元/Worker账户/文件数限制变化'; fi
            if [[ $u == vpskit-xray.service && $(get '.components.xray // false') == true ]]; then RUNTIME_X=restart; RUNTIME_X_REASON='Xray服务单元/文件数限制变化'; fi
        fi
    done
    if [[ $(get '.components.nginx // false') == true ]]; then
        if [[ $force == nginx ]]; then RUNTIME_NG=restart; RUNTIME_NG_REASON='显式更新Nginx组件'; fi
        if ! systemctl is-active --quiet vpskit-nginx.service; then RUNTIME_NG=start; RUNTIME_NG_REASON='已配置但当前未运行'; fi
    fi
    if [[ $scope == all && $(get '.components.xray // false') == true ]]; then
        if [[ $force == xray ]]; then RUNTIME_X=restart; RUNTIME_X_REASON='显式更新Xray组件'; fi
        if [[ $(jq '([.nodes[]|select(.enabled)]|length) + ([(.native_nodes // [])[]|select(.enabled)]|length)' "$STATE") == 0 ]]; then
            if systemctl is-active --quiet vpskit-xray.service; then RUNTIME_X=stop; RUNTIME_X_REASON='没有启用的节点'
            else RUNTIME_X=skip; RUNTIME_X_REASON='没有启用节点，保持停止'; fi
        elif ! systemctl is-active --quiet vpskit-xray.service; then RUNTIME_X=start; RUNTIME_X_REASON='已配置但当前未运行'; fi
    fi
}
runtime_print_plan() {
    local action label component reason
    for component in Xray Nginx; do
        if [[ $component == Xray ]]; then action=$RUNTIME_X; reason=$RUNTIME_X_REASON; else action=$RUNTIME_NG; reason=$RUNTIME_NG_REASON; fi
        case "$action" in skip) label='无需动作';; reload) label='优雅重载';; restart) label='重启（现有连接会中断）';; start) label='启动';; stop) label='停止';; esac
        printf '  %-6s：%s；%s\n' "$component" "$label" "$reason"
    done
    printf '  systemd 单元差异：%s 项\n' "${#RUNTIME_UNITS[@]}"
}
s1_base_runtime_plan_command() {
    validate_state
    runtime_prepare all none
    ui_title '按当前代码生成配置后的动作预览'
    runtime_print_plan
    ui_note '只在临时目录生成/比较；不保存状态、不修改服务、不执行预检实例。实际应用前会再次比较并验证。'
}
runtime_record() {
    local component=$1 action=$2 reason=$3 before=$4 after=$5 file="$ROOT/logs/runtime-events.jsonl" stamp tmp
    [[ ! -L $file ]] || return 1
    printf -v stamp '%(%Y-%m-%dT%H:%M:%S%z)T' -1
    # Only service changes are logged. Never record runtime config contents.
    jq -nc --arg t "$stamp" --arg c "$component" --arg a "$action" --arg r "$reason" --arg b "$before" --arg n "$after" \
      '{time:$t,component:$c,action:$a,reason:$r,before_pid:$b,after_pid:$n}' >> "$file" || return 1
    chmod 600 "$file"
    if (( $(stat -c %s "$file")>65536 )); then
        tmp=$(mktemp "$ROOT/logs/.events.XXXXXXXX") || return 1
        tail -n 100 "$file" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$file"
    fi
}
runtime_save_fingerprints() {
    local file="$ROOT/config/.runtime-applied.json" tmp="$WORK/applied.next.json"
    if [[ $RUNTIME_SCOPE == web && -f $file ]]; then
        jq --argjson n "$RUNTIME_NG_HASH" '.schema=1 | .nginx=$n' "$file" > "$tmp"
    else jq -n --argjson n "$RUNTIME_NG_HASH" --argjson x "$RUNTIME_X_HASH" '{schema:1,nginx:$n,xray:$x}' > "$tmp"; fi
    if ! json_equal "$file" "$tmp"; then install -m 600 "$tmp" "$file"; fi
}
s1_base_xray_wait_listeners() {
    local deadline=$((SECONDS+10)) port ready
    while ((SECONDS<deadline)); do
        ready=true
        if ! systemctl is-active --quiet vpskit-xray.service; then ready=false; fi
        while IFS= read -r port; do
            [[ -n $(ss -H -lnt "sport = :$port") ]] || ready=false
        done < <(jq -r '[.nodes[]|select(.enabled)]|unique_by(.entry)[].port' "$STATE")
        [[ $ready != true ]] || return 0
        sleep .2
    done
    return 1
}
s1_base_apply_config() {
    local scope=${1:-all} force=${2:-none} u old='' before after reason need_permissions=false need_preflight=false timer_changed=false
    ((TX==1)) || die '应用配置必须处于事务中。'
    s2_journal_begin
    migrate_state
    if [[ $(get '.components.nginx // false') == true ]]; then remember_worker; fi
    validate_state; check_listener_ports
    runtime_prepare "$scope" "$force"
    runtime_print_plan
    reason=$(jq -r '.reason // "apply"' "$ROOT/backup/transaction/snapshot/meta.json")
    case "$RUNTIME_NG" in start|restart) need_preflight=true; need_permissions=true;;
        reload)
            # A capacity change also validates candidate worker viability before touching live service.
            if [[ $(nginx_conf_value worker_processes "$ROOT/config/nginx.conf" || true) != $(ng_value workers) ]]; then need_preflight=true; fi;;
    esac
    case "$reason" in site:*|restore:*) [[ $(get '.components.nginx // false') != true ]] || need_permissions=true;; esac
    if [[ $RUNTIME_X == restart || $RUNTIME_X == start ]]; then "$XRAY" run -test -config "$WORK/xray.next.json"; fi
    if [[ $need_preflight == true ]]; then
        nginx_preflight "$WORK/nginx.next.conf" || die 'Nginx非root预检失败，正式服务尚未切换。'
    fi
    if [[ $RUNTIME_NG == reload || $RUNTIME_NG == start || $RUNTIME_NG == restart ]]; then
        if [[ $need_permissions == true ]]; then worker_permissions "$(resolve_worker)"; fi
        nginx_cmd -t -p "$ROOT/" -c "$WORK/nginx.next.conf"
    elif [[ $need_permissions == true ]]; then worker_permissions "$(resolve_worker)"; fi
    ensure_manager_installed
    # Do not mark a no-op as a runtime change: failed bookkeeping should not restart healthy services.
    if [[ $RUNTIME_NG != skip || $RUNTIME_X != skip || ${#RUNTIME_UNITS[@]} -gt 0 ]]; then
        printf 'runtime\n' > "$ROOT/backup/transaction/phase"
    fi
    if [[ $scope == all && -f $WORK/xray.next.json ]] && ! json_equal "$WORK/xray.next.json" "$ROOT/config/xray.json"; then
        s2_publish "$WORK/xray.next.json" "$ROOT/config/xray.json" 600 || die '发布Xray配置失败。'
    fi
    if [[ -f $WORK/nginx.next.conf ]] && ! cmp -s "$WORK/nginx.next.conf" "$ROOT/config/nginx.conf"; then
        s2_publish "$WORK/nginx.next.conf" "$ROOT/config/nginx.conf" 600 || die '发布Nginx配置失败。'
    fi
    for u in "${RUNTIME_UNITS[@]}"; do
        s2_publish "$WORK/units/$u" "$SYSTEMD/$u" 644 || die '发布服务定义失败。'
        [[ $u != vpskit-maintain.timer ]] || timer_changed=true
    done
    if ((${#RUNTIME_UNITS[@]})); then systemctl daemon-reload; fi
    # Upstream first: do not route new Nginx requests to a backend not yet listening.
    if [[ $RUNTIME_X != skip ]]; then
        s2_service_mark vpskit-xray.service "$RUNTIME_X"
        before=$(systemctl show -p MainPID --value vpskit-xray.service 2>/dev/null || true)
        if [[ $RUNTIME_X == stop ]]; then systemctl disable --now vpskit-xray.service
        else
            s3_auto_enable vpskit-xray.service >/dev/null
            [[ $RUNTIME_X != restart ]] || warn 'Xray运行配置变化；本实例所有现有代理会话会中断一次。'
            systemctl "$RUNTIME_X" vpskit-xray.service || die 'Xray服务动作失败。'
            xray_wait_listeners || die 'Xray未在10秒内进入运行状态并监听；触发事务恢复。'
        fi
        after=$(systemctl show -p MainPID --value vpskit-xray.service 2>/dev/null || true)
        runtime_record xray "$RUNTIME_X" "$RUNTIME_X_REASON" "$before" "$after" || warn '服务已处理，但动作记录写入失败。'
    fi
    if [[ $RUNTIME_NG != skip ]]; then
        s2_service_mark vpskit-nginx.service "$RUNTIME_NG"
        before=$(systemctl show -p MainPID --value vpskit-nginx.service 2>/dev/null || true)
        if [[ $RUNTIME_NG == stop ]]; then systemctl disable --now vpskit-nginx.service
        else
            s3_auto_enable vpskit-nginx.service >/dev/null
            if [[ $RUNTIME_NG == reload ]]; then old=$(worker_generation "$before"); fi
            if [[ $RUNTIME_NG == restart ]]; then
                warn 'Nginx服务参数/用户/二进制变化，需要重启；现有连接会中断。'
                systemctl reset-failed vpskit-nginx.service >/dev/null 2>&1 || true
            fi
            systemctl "$RUNTIME_NG" vpskit-nginx.service || die 'Nginx服务动作失败。'
            if ! verify_nginx_runtime "$old"; then
                failure_diagnostics nginx-activation || true
                die 'Nginx运行校验失败；诊断已保存，正在恢复。'
            fi
        fi
        after=$(systemctl show -p MainPID --value vpskit-nginx.service 2>/dev/null || true)
        runtime_record nginx "$RUNTIME_NG" "$RUNTIME_NG_REASON" "$before" "$after" || warn '服务已处理，但动作记录写入失败。'
    fi
    runtime_save_fingerprints
    s3_timer_reconcile "$timer_changed" || die '维护定时器处理失败。'
    if [[ $RUNTIME_NG == skip && $RUNTIME_X == skip ]]; then ok 'Nginx/Xray无需动作；未启动测试Worker，也未重载或重启。'; fi
}
s1_base_install_component() {
    local name=$1 version=${2:-$XRAY_DEFAULT_VERSION} force=${3:-no}
    choice "$name" 'nginx xray acme' || die '组件只能为nginx/xray/acme。'
    if [[ $force == no ]] && component_ready "$name"; then ok "$name 已安装，读取原配置，不重复安装。"; return; fi
    begin_tx "component:$name" components
    case "$name" in nginx) install_nginx_binary;; xray) install_xray_binary "$version";; acme) install_acme_binary;; esac
    apply_config all "$name"
    commit_tx
}
apply_existing() {
    confirm '按已保存配置重新生成并验证；初次降权/文件数变更可能重启服务' || return 0
    begin_tx apply
    if cf_needed && ! cf_ready; then cf_fetch; cf_install_assets; fi
    apply_config
    commit_tx
}
s1_base_history_restore() {
    local id=${1:-} scope=${2:-} dir p candidate="$WORK/restored-state.json"
    history_select id "$id"
    if [[ -z $scope ]]; then
        select_value scope '选择恢复范围' full \
          'full|完整配置：状态、证书、ACME资料；按本版重新验证生成配置' \
          'state|仅状态：使用当前证书和程序重新生成配置' \
          'advanced|仅高级参数：保留当前节点、网站和证书'
    fi
    choice "$scope" 'full state advanced' || die '恢复范围只能为full/state/advanced；原样恢复使用recover。'
    dir="$ROOT/backup/history/$id"; snapshot_verify "$dir"
    if [[ $scope == advanced ]]; then
        state_basic "$STATE" || die '高级参数恢复需要当前state.json有效；损坏时使用full或recover。'
        jq --slurpfile h "$dir/state.json" '.advanced=($h[0].advanced // {})' "$STATE" > "$candidate"
    else cp "$dir/state.json" "$candidate"; fi
    validate_advanced "$candidate"
    for p in xray nginx acme; do
        if [[ $(jq -r ".components.$p // false" "$candidate") == true ]]; then
            case "$p" in xray) [[ -x $XRAY ]];; nginx) [[ -x $NGINX ]];; acme) [[ -x $ACME ]];; esac || die "快照需要$p，但二进制不存在；历史不含程序，请先补装。"
        fi
    done
    warn "恢复范围=$scope；不覆盖网站内容、管理代码、二进制或防火墙。服务恢复后单独检查端口。"
    confirm "恢复快照 $id，预检通过后应用；可能重启相关服务" || return 0
    cp -a "$dir" "$WORK/history-selected"; dir="$WORK/history-selected"
    begin_tx "restore:$id:$scope"
    if [[ $scope == full ]]; then
        for p in config certs; do rm -rf -- "$ROOT/$p"; cp -a "$dir/$p" "$ROOT/$p"; done
        for p in config certstore; do
            rm -rf -- "$ROOT/acme/$p"
            [[ ! -d $dir/acme/$p ]] || cp -a "$dir/acme/$p" "$ROOT/acme/$p"
        done
    fi
    install -m 600 "$candidate" "$STATE"
    if state_basic "$ROOT/backup/transaction/snapshot/state.json"; then
        json_update --slurpfile old "$ROOT/backup/transaction/snapshot/state.json" '.versions=($old[0].versions // .versions)'
    fi
    apply_config; commit_tx
    recovery_firewall ask || true
}
rollback_last() {
    local dir="$ROOT/backup/last" preserved="$WORK/last-copy"
    [[ -f $dir/ready ]] || die '没有最近事务备份；可运行recover按编号选择历史。'
    [[ ! -d $ROOT/backup/transaction ]] || die '有未完成事务；先执行repair或repair --force，不覆盖它。'
    confirm '原样回滚最近事务（可能含二进制），恢复之前服务状态；不重新生成配置' || return 0
    cp -a "$dir" "$preserved"
    begin_tx rollback components
    printf 'runtime\n' > "$ROOT/backup/transaction/phase"
    restore_transaction "$preserved" || die '回滚失败；保存的事务将用于恢复操作前状态。'
    commit_tx
    recovery_firewall ask || true
}

advanced_show() {
    printf '\nNginx高级配置（默认值与已保存值合并显示）：\n'
    nginx_settings | jq .
    printf 'Xray高级策略：\n'; xray_settings | jq .
    printf '有界日志设置：\n'; logging_settings | jq .
    printf 'CPU逻辑核心=%s；内存=%s MiB\n' "$(getconf _NPROCESSORS_ONLN)" "$(awk '/MemTotal:/{printf "%d",$2/1024}' /proc/meminfo)"
    printf '连接数包含客户端和上游连接，不等于用户人数；auto按CPU数量启动Worker。\n'
    printf 'XHTTP启用时HTTP/2保持开启；纯网站可通过http2参数关闭。\n'
    if component_ready nginx; then
        printf '计划Worker用户：%s\n' "$(resolve_worker)"
        local master; master=$(systemctl show -p MainPID --value "$NGINX_SERVICE" 2>/dev/null || true)
        printf '当前Worker PID / UID：\n'; master_workers "$master"
    fi
}
advanced_assign() {
    local file=$1 key=$2 value=$3 section=${2%%.*} field=${2#*.} type=num
    case "$key" in
        nginx.workers) valid_worker_count "$value" || die 'Worker数量需为auto或1～64。'; [[ $value != auto ]] || type=string;;
        nginx.sandbox_mode) choice "$value" 'strict compatible' || die '沙箱模式为strict/compatible。'; type=string;;
        nginx.worker_user) [[ $value == auto ]] || service_user_valid "$value" || die '必须选择已有的非特权、非登录服务账户。'; type=string;;
        nginx.error_log_level) choice "$value" 'warn error crit' || die '日志级别为warn/error/crit。'; type=string;;
        nginx.access_log_mode) choice "$value" 'errors sample full' || die '访问日志模式为errors/sample/full。'; type=string;;
        xray.loglevel) choice "$value" 'warning error none' || die 'Xray日志级别为warning/error/none。'; type=string;;
        xray.buffer_kb) if [[ $value == auto || $value == core ]]; then type=string; else number "$value" 4 512 || die '缓冲为auto/core或4～512KiB。'; fi;;
        nginx.http2|nginx.access_log|nginx.proxy_access_log|nginx.proxy_gzip) valid_bool "$value" || die '布尔值只能为true/false。'; type=bool;;
        nginx.connections|nginx.nofile|nginx.keepalive|nginx.keepalive_requests|nginx.ssl_cache|nginx.ssl_timeout|nginx.client_header_timeout|nginx.client_body_timeout|nginx.send_timeout|nginx.proxy_connect_timeout|nginx.proxy_read_timeout|nginx.proxy_send_timeout|nginx.site_proxy_timeout|nginx.client_max_body_mb|nginx.worker_shutdown_timeout|nginx.upstream_keepalive|nginx.startup_timeout|nginx.xhttp_keepalive|nginx.upstream_idle|nginx.access_log_sample|nginx.access_log_buffer_kb|nginx.access_log_flush|nginx.gzip_level|xray.nofile|xray.conn_idle|xray.handshake|logging.max_mb|logging.tail_kb|logging.keep)
            number "$value" 0 1048576 || die '请输入不含前导零的整数。';;
        *) die "未知或不允许修改的高级字段：$key";;
    esac
    if [[ $type == string ]]; then
        jq --arg s "$section" --arg k "$field" --arg v "$value" '.advanced[$s][$k]=$v' "$file" > "$file.next"
    else
        jq --arg s "$section" --arg k "$field" --argjson v "$value" '.advanced[$s][$k]=$v' "$file" > "$file.next"
    fi
    mv "$file.next" "$file"
    if [[ $key == nginx.worker_user ]]; then
        jq 'del(.advanced.nginx.resolved_user,.advanced.nginx.resolved_uid)' "$file" > "$file.next"; mv "$file.next" "$file"
    fi
}
s1_base_advanced_set() {
    (( $#>=2 && $#%2==0 )) || die '用法：advanced set nginx.workers 2 nginx.connections 2048 nginx.nofile 16384'
    local candidate="$WORK/advanced.json" scope=web key value
    cp "$STATE" "$candidate"
    while (($#)); do
        key=$1; value=$2; shift 2
        advanced_assign "$candidate" "$key" "$value"
        [[ $key != xray.* ]] || scope=all
    done
    validate_advanced "$candidate"
    if [[ $(nginx_settings "$candidate" | jq -r .workers) == auto ]]; then warn 'auto并不按内存限制Worker数量；低内存VPS建议明确设置1或2。'; fi
    if component_ready nginx; then resolve_worker "$candidate" >/dev/null; fi
    if json_equal "$candidate" "$STATE"; then ok '设置未变化；未创建事务或重载服务。'; return; fi
    confirm '保存这些高级配置并按差异应用；Xray策略或服务参数变化可能重启' || return 0
    begin_tx advanced
    install -m 600 "$candidate" "$STATE"
    if component_ready nginx || component_ready xray; then apply_config "$scope"
    else migrate_state; fi
    commit_tx
}
s1_base_advanced_defaults() {
    confirm '只恢复Nginx/Xray高级默认参数，保留节点、网站和证书' || return 0
    begin_tx advanced-defaults
    json_update --argjson d "$(nginx_defaults)" --argjson x "$(xray_defaults)" --argjson l "$(logging_defaults)" '.advanced.nginx=$d | .advanced.xray=$x | .advanced.logging=$l'
    if component_ready nginx || component_ready xray; then apply_config; else migrate_state; fi
    commit_tx
}
site_list() { jq -r '.sites|to_entries[]|[(.key+1),.value.domain,(.value.kind // "custom"),(.value.access // "direct"),(.value.issued|tostring)]|@tsv' "$STATE"; }
site_select() {
    local ss_dest=$1 ss_value=${2:-} ss_domain ss_label ss_row
    local -a ss_options=()
    if [[ -z $ss_value ]]; then
        while IFS= read -r ss_row; do
            ss_domain=$(jq -r .domain <<< "$ss_row")
            ss_label=$(jq -r '"\(.domain) | \(.kind // "custom") | " + (if .issued then "证书已登记" else "尚无证书" end)' <<< "$ss_row")
            ss_options+=("$ss_domain|$ss_label")
        done < <(jq -c '.sites[]' "$STATE")
        ((${#ss_options[@]})) || die '尚无网站，请先添加网站。'
        select_value ss_value '选择网站（输入序号）' "$(get '.preferences.domain // ""')" "${ss_options[@]}"
    elif [[ $ss_value =~ ^[1-9][0-9]{0,7}$ ]]; then ss_value=$(jq -r --argjson i "$ss_value" '.sites[$i-1].domain // ""' "$STATE"); fi
    valid_domain "$ss_value" && jq -e --arg d "$ss_value" '.sites[]|select(.domain==$d)' "$STATE" >/dev/null || die '网站不存在。'
    printf -v "$ss_dest" '%s' "$ss_value"
}

site_template() {
    local domain=$1 kind=$2 template=$3 file title
    mkdir -p "$ROOT/www/$domain" "$ROOT/www/acme/.well-known/acme-challenge"
    [[ $kind == template ]] || return 0
    file="$ROOT/www/$domain/vpskit-$template.html"
    [[ ! -e $file ]] || { info '模板文件已存在，保留内容。'; return; }
    case "$template" in welcome) title='欢迎访问';; notes) title='技术与日常笔记';; blog) title='记录与分享';; *) die '模板非法。';; esac
    cat > "$file" <<EOF
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>$title · $domain</title><style>body{max-width:850px;margin:10vh auto;padding:24px;font:18px/1.8 system-ui,sans-serif;color:#253245;background:#f8fafc}article{background:#fff;border:1px solid #e2e8f0;border-radius:16px;padding:36px}h1{line-height:1.3}small{color:#64748b}</style></head><body><article><small>$domain</small><h1>$title</h1><p>这是一个轻量静态网站。你可以替换此页面，发布自己的介绍、文档和内容。</p></article></body></html>
EOF
}
site_configure() {
    local domain=${1:-} existing kind access email challenge wildcard template upstream redirect oldcert pending
    ensure_component nginx
    if [[ -z $domain ]]; then ask_valid domain '网站域名（小写，不含协议或路径）' "$(get '.preferences.domain // .sites[0].domain // ""')" valid_domain; fi
    valid_domain "$domain" || die '域名无效。'
    existing=$(jq -c --arg d "$domain" '[.sites[]|select(.domain==$d)][0] // {}' "$STATE")
    ask_valid kind '网站类型：template/custom/proxy/redirect' "$(jq -r '.kind // (if (.upstream // "")!="" then "proxy" else "template" end)' <<< "$existing")" choice 'template custom proxy redirect'
    ask_valid access '访问方式：direct直连 / cloudflare橙云' "$(jq -r '.access // "direct"' <<< "$existing")" choice 'direct cloudflare'
    ask_valid email '证书联系邮箱' "$(jq -r --arg fallback "$(get '.preferences.email // ""')" '.email // $fallback' <<< "$existing")" valid_email
    ask_valid challenge '证书验证：http / dns_cf / dns_dp' "$(jq -r '.challenge // "http"' <<< "$existing")" choice 'http dns_cf dns_dp'
    wildcard=false
    if [[ $challenge != http ]]; then ask_valid wildcard '同时签发泛域名证书（true/false）' "$(jq -r '.wildcard // false' <<< "$existing")" valid_bool; fi
    template=welcome; upstream=''; redirect=''
    case "$kind" in
        template) ask_valid template '模板：welcome/notes/blog' "$(jq -r '.template // "welcome"' <<< "$existing")" choice 'welcome notes blog';;
        custom) info "静态文件放在 $ROOT/www/$domain；不会覆盖已有文件。";;
        proxy) ask_valid upstream '本机应用HTTP地址' "$(jq -r 'if (.upstream // "")=="" then "http://127.0.0.1:8000" else .upstream end' <<< "$existing")" valid_upstream;;
        redirect) ask_valid redirect 'HTTPS跳转目标' "$(jq -r 'if (.redirect // "")=="" then "https://www.microsoft.com/" else .redirect end' <<< "$existing")" valid_redirect "$domain";;
    esac
    if [[ $access == cloudflare ]] && ! cf_ready; then cf_fetch; fi
    confirm "保存网站 $domain；保留已有节点、证书及网站文件" || return 0
    begin_tx "site:$domain"
    [[ ! -d $WORK/edge ]] || cf_install_assets
    json_update --arg d "$domain" --arg k "$kind" --arg a "$access" --arg e "$email" --arg c "$challenge" --argjson w "$wildcard" --arg t "$template" --arg u "$upstream" --arg r "$redirect" '
      ([.sites[]|select(.domain==$d)][0] // {domain:$d,issued:false}) as $old |
      ($old + {domain:$d,kind:$k,access:$a,email:$e,challenge:$c,wildcard:$w,template:$t,upstream:$u,redirect:$r,
       cert_settings_pending:($old.issued==true and (($old.challenge // "http")!=$c or ($old.wildcard // false)!=$w))}) as $new |
      .sites=([.sites[]|select(.domain!=$d)]+[$new]) |
      .preferences += {domain:$d,email:$e,challenge:$c,wildcard:$w,site_kind:$k,site_access:$a,template:$t,upstream:$u,redirect:$r}'
    site_template "$domain" "$kind" "$template"
    apply_config web; commit_tx
    info '网站配置已保存。尚无证书或证书参数改变时，请在证书菜单签发。'
}
s2_previous_site_remove() {
    local domain; site_select domain "${1:-}"
    if jq -e --arg d "$domain" '(.nodes + (.native_nodes // []))[]|select(.domain==$d)' "$STATE" >/dev/null; then die '仍有节点引用此网站，请先删除或迁移这些节点。'; fi
    confirm "移除 $domain 绑定和续期；保留网站内容和证书文件" || return 0
    begin_tx "site-remove:$domain"
    if component_ready acme && jq -e --arg d "$domain" '.sites[]|select(.domain==$d and .issued)' "$STATE" >/dev/null; then acme_run --remove -d "$domain" --ecc; fi
    json_update --arg d "$domain" '.sites |= map(select(.domain!=$d))'
    apply_config web; commit_tx
}
s1_base_acme_run() { (umask 077; "$ACME" --home "$ROOT/acme" --config-home "$ROOT/acme/config" --cert-home "$ROOT/acme/certstore" --no-color "$@"); }
s5_legacy_dns_credentials() {
    local provider=$1 token account sid key
    case "$provider" in
        dns_cf)
            secret token 'Cloudflare API Token；留空复用ACME已保存凭据'
            if [[ -n $token ]]; then
                [[ $token =~ ^[a-zA-Z0-9_-]{10,256}$ ]] || die 'Cloudflare Token格式异常。'
                ask account 'Cloudflare Account ID（32位十六进制）' ''
                [[ $account =~ ^[a-fA-F0-9]{32}$ ]] || die 'Account ID格式错误。'
                export CF_Token="$token" CF_Account_ID="$account"
            elif ! grep -Rq '^SAVED_CF_Token=' "$ROOT/acme/config"; then die '未找到已保存的Cloudflare Token。'; fi;;
        dns_dp)
            secret sid 'DNSPod API ID；留空复用ACME已保存凭据'
            if [[ -n $sid ]]; then
                [[ $sid =~ ^[0-9]+$ ]] || die 'DNSPod ID应为数字。'
                secret key 'DNSPod API Key'
                [[ -n $key && $key != *[[:space:]]* ]] || die 'DNSPod密钥为空或包含空白。'
                export DP_Id="$sid" DP_Key="$key"
            elif ! grep -Rq '^SAVED_DP_Id=' "$ROOT/acme/config"; then die '未找到已保存的DNSPod凭据。'; fi;;
        *) die '不支持的DNS验证方式。';;
    esac
}
s2_previous_deploy_certificate() {
    local domain=$1 base="$ROOT/certs/$1" cert key rev p
    cert="$base/pending/fullchain.pem"; key="$base/pending/key.pem"
    [[ -s $cert && -s $key ]] || die '没有待部署证书及私钥。'
    openssl x509 -in "$cert" -noout -checkend 86400 >/dev/null || die '新证书有效期不足一天。'
    openssl x509 -in "$cert" -noout -checkhost "$domain" >/dev/null || die '证书域名不匹配。'
    [[ $(openssl x509 -in "$cert" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum) == $(openssl pkey -in "$key" -pubout -outform DER | sha256sum) ]] || die '证书与私钥不匹配。'
    rev="rev-$(date +%s)-$(randhex 4)"; mkdir -m 700 "$base/$rev"
    install -m 600 "$cert" "$base/$rev/fullchain.pem"; install -m 600 "$key" "$base/$rev/key.pem"
    ln -s "$rev" "$base/current.new"; mv -Tf "$base/current.new" "$base/current"
    json_update --arg d "$domain" '(.sites[]|select(.domain==$d)) |= (. + {issued:true,cert_settings_pending:false})'
    find "$base" -mindepth 1 -maxdepth 1 -type d -name 'rev-*' ! -name "$rev" -exec rm -rf -- {} +
}
cert_issue() {
    local domain site challenge email rc=0
    ensure_component acme; ensure_component nginx; site_select domain "${1:-}"
    site=$(jq -c --arg d "$domain" '.sites[]|select(.domain==$d)' "$STATE")
    challenge=$(jq -r '.challenge // "http"' <<< "$site"); email=$(jq -r '.email // ""' <<< "$site")
    valid_email "$email" || die '请先在网站设置中填写有效邮箱。'
    local -a args=(--issue --server letsencrypt --keylength ec-256 -d "$domain" --accountemail "$email")
    if [[ $(jq -r '.cert_settings_pending // false' <<< "$site") == true ]]; then args+=(--force); fi
    if [[ $(jq -r '.wildcard // false' <<< "$site") == true ]]; then
        [[ $challenge != http ]] || die '泛域名证书需要DNS验证。'; args+=(-d "*.$domain")
    fi
    if [[ $challenge == http ]]; then
        systemctl is-active --quiet "$NGINX_SERVICE" || die "HTTP-01需要当前模式的$NGINX_SERVICE运行。"
        args+=(--webroot "$ROOT/www/acme")
        info '请确认公网80及/.well-known/acme-challenge/能到达本机；不自动修改防火墙。'
    else dns_credentials "$challenge"; args+=(--dns "$challenge"); fi
    begin_tx "cert-issue:$domain"
    mkdir -p "$ROOT/www/acme/.well-known/acme-challenge"
    migrate_state
    s2_journal_begin
    [[ $MODE == shared ]] || remember_worker
    acme_web_permissions
    acme_run "${args[@]}" || rc=$?
    unset CF_Token CF_Account_ID CF_Zone_ID DP_Id DP_Key
    ((rc==0 || rc==2)) || die '证书签发失败，原证书保留；检查DNS凭据或HTTP验证路径。'
    if ((rc==2)) && [[ $(jq -r '.cert_settings_pending // false' <<< "$site") == true ]]; then die 'ACME跳过签发，新参数尚未生效。'; fi
    mkdir -p "$ROOT/certs/$domain/pending"
    acme_run --install-cert -d "$domain" --ecc --key-file "$ROOT/certs/$domain/pending/key.pem" --fullchain-file "$ROOT/certs/$domain/pending/fullchain.pem" --reloadcmd /bin/true
    deploy_certificate "$domain"
    json_update --arg d "$domain" '(.sites[]|select(.domain==$d)).certificate_source="acme"'
    apply_config; commit_tx
}
s2_previous_cert_import() {
    local domain=$1 cert=$2 key=$3
    site_select domain "$domain"
    [[ -f $cert && -f $key && ! -L $cert && ! -L $key ]] || die '证书/私钥必须为现有普通文件。'
    confirm "为 $domain 导入手动证书，并暂停该域名原有ACME自动续期" || return 0
    begin_tx "cert-import:$domain"
    mkdir -p "$ROOT/certs/$domain/pending"
    install -m 600 "$cert" "$ROOT/certs/$domain/pending/fullchain.pem"; install -m 600 "$key" "$ROOT/certs/$domain/pending/key.pem"
    if component_ready acme && [[ -d $ROOT/acme/certstore/${domain}_ecc ]]; then
        acme_run --remove -d "$domain" --ecc
    fi
    deploy_certificate "$domain"
    json_update --arg d "$domain" '(.sites[]|select(.domain==$d)).certificate_source="manual"'
    apply_config; commit_tx
}
cert_status() {
    local domain f
    while IFS= read -r domain; do
        f="$ROOT/certs/$domain/current/fullchain.pem"
        if [[ -s $f ]]; then printf '%s: ' "$domain"; openssl x509 -in "$f" -noout -enddate
        else printf '%s: 尚无证书\n' "$domain"; fi
    done < <(jq -r '.sites[].domain' "$STATE")
}
s2_previous_cert_renew() {
    component_ready acme || return 0
    local domain changed=false rc=0
    mkdir -p "$ROOT/www/acme/.well-known/acme-challenge"
    if component_ready nginx; then acme_web_permissions; fi
    acme_run --cron || rc=$?
    if ((rc!=0 && rc!=2)); then warn "ACME续期检查返回$rc；继续检查已生成的新证书。"; fi
    while IFS= read -r domain; do
        if [[ -s $ROOT/certs/$domain/pending/fullchain.pem ]] && ! cmp -s "$ROOT/certs/$domain/pending/fullchain.pem" "$ROOT/certs/$domain/current/fullchain.pem"; then
            if [[ $changed == false ]]; then begin_tx certificate-renewal; changed=true; fi
            deploy_certificate "$domain"
        fi
    done < <(jq -r '.sites[]|select(.issued and (.certificate_source // "acme")!="manual")|.domain' "$STATE")
    if [[ $changed == true ]]; then apply_config; commit_tx; fi
    ((rc==0 || rc==2))
}
# Only this manager's logs are touched. Copying a bounded tail keeps CPU/I/O
# independent of an accidentally huge source log. This is not a full audit archive.
rotate_logs() {
    local cfg max tailbytes keep f size tmp i archive safe
    cfg=$(logging_settings)
    jq -e 'def i($l;$h): type=="number" and .==floor and .>=$l and .<=$h;
      (.max_mb|i(1;64)) and (.tail_kb|i(16;1024)) and (.keep|i(1;5))' <<< "$cfg" >/dev/null || die '日志保留参数损坏；未截断或删除日志。'
    read -r max tailbytes keep < <(jq -r '[.max_mb*1048576,.tail_kb*1024,.keep]|@tsv' <<< "$cfg")
    for f in "$ROOT/logs/nginx.log" "$ROOT/logs/xray.log" "$ROOT/logs/access.log" "$ROOT/logs/manage.log"; do
        # Only slots 1..5 belong to this manager. Do not follow/archive arbitrary paths.
        safe=true
        for ((i=1;i<=5;i++)); do
            archive="$f.$i"
            if [[ -e $archive || -L $archive ]]; then
                if [[ ! -f $archive || -L $archive || $(stat -c %h "$archive") != 1 ]]; then
                    warn "跳过含异常轮转目标的日志：${f##*/}"; safe=false; break
                fi
            fi
        done
        [[ $safe == true ]] || continue
        for ((i=1;i<=5;i++)); do
            archive="$f.$i"; [[ -f $archive ]] || continue
            if ((i>keep)); then rm -f -- "$archive"; continue; fi
            # Bound oversized legacy full-copy archives even when the active log is small.
            if (( $(stat -c %s "$archive")>tailbytes+128 )); then
                tmp=$(mktemp "$ROOT/logs/.rotate.XXXXXXXX")
                printf '[VPSKIT bounded tail; older bytes discarded; not a complete audit archive]\n' > "$tmp"
                tail -c "$tailbytes" "$archive" >> "$tmp"
                chmod 600 "$tmp"; chown 0:0 "$tmp"; mv -f -- "$tmp" "$archive"
            fi
        done
        [[ -f $f && ! -L $f ]] || continue
        [[ $(stat -c %h "$f") == 1 ]] || { warn "跳过多硬链接日志：${f##*/}"; continue; }
        size=$(stat -c %s "$f"); ((size>=max)) || continue
        tmp=$(mktemp "$ROOT/logs/.rotate.XXXXXXXX")
        printf '[VPSKIT bounded tail; older bytes discarded; not a complete audit archive]\n' > "$tmp"
        tail -c "$tailbytes" "$f" >> "$tmp"
        chmod 600 "$tmp"; chown 0:0 "$tmp"
        for ((i=keep;i>1;i--)); do [[ ! -f $f.$((i-1)) ]] || mv -f -- "$f.$((i-1))" "$f.$i"; done
        mv -f -- "$tmp" "$f.1"
        # Keep the writer's inode: no daemon reload/restart or expensive compression.
        # Like copytruncate, concurrent writes in this tiny window can be lost.
        : > "$f"
    done
    # Failure details are only generated on demand; retain the newest 10 local reports.
    if [[ -d $ROOT/logs/diagnostics && ! -L $ROOT/logs/diagnostics ]]; then
        i=0
        while IFS= read -r -d '' f; do
            i=$((i+1)); ((i<=10)) && continue
            f=${f#* }; [[ $f == "$ROOT/logs/diagnostics/"* && ! -L $f ]] || continue
            rm -f -- "$f"
        done < <(find -P "$ROOT/logs/diagnostics" -maxdepth 1 -type f -name '*.log' -printf '%T@ %p\0' | sort -zrn)
    fi
}
acme_web_permissions() {
    local user group p base="$ROOT/www/acme"
    user=$(resolve_worker); group=$(id -gn "$user")
    if findmnt -rn -o TARGET 2>/dev/null | grep -Fq "$base/"; then die 'ACME目录内有子挂载，未调整权限。'; fi
    if mountpoint -q "$base"; then die 'ACME目录自身为挂载点，未调整权限。'; fi
    for p in "$ROOT/www" "$base" "$base/.well-known" "$base/.well-known/acme-challenge"; do
        [[ ! -L $p ]] || die 'ACME目录为链接，未调整权限。'
        mkdir -p "$p"; chown "0:$group" "$p"; chmod 2750 "$p"
    done
    if [[ -n $(find -P "$base" -xdev \( -type l -o \( -type f -links +1 \) \) -print -quit) ]]; then die 'ACME目录存在不安全链接。'; fi
    find -P "$base" -xdev -type f -exec chown "0:$group" {} + -exec chmod 640 {} +
}
maintenance_epoch_set() {
    local key=$1 value=$2 file="$ROOT/data/maintenance-epochs.json" tmp="$WORK/epochs.next.json"
    [[ ! -L $file ]] || die '维护记录不能为链接。'
    if [[ -f $file ]]; then jq --arg k "$key" --argjson v "$value" '.[$k]=$v' "$file" > "$tmp"
    else jq -n --arg k "$key" --argjson v "$value" '{($k):$v}' > "$tmp"; fi
    install -m 600 "$tmp" "$file"
}
maintenance_tick() {
    local now last=0 attempt=0 file="$ROOT/data/maintenance-epochs.json"
    printf -v now '%(%s)T' -1
    rotate_logs
    if [[ -r $file && ! -L $file ]]; then
        last=$(jq -r '.cert_success // 0' "$file"); attempt=$(jq -r '.cert_attempt // 0' "$file")
        [[ $last =~ ^[0-9]{1,12}$ && $attempt =~ ^[0-9]{1,12}$ ]] || die '维护时间记录无效。'
    fi
    # No repeated ACME subprocesses each hour; retry failures at most once per four hours.
    if component_ready acme && ((now-last>=72000 && now-attempt>=14400)); then
        maintenance_epoch_set cert_attempt "$now"
        cert_renew
        maintenance_epoch_set cert_success "$now"
    fi
    # Existing edge_maintenance has a 7-day success window; add a 4-hour retry gate.
    attempt=0
    if [[ -r $file ]]; then attempt=$(jq -r '.edge_attempt // 0' "$file"); fi
    [[ $attempt =~ ^[0-9]{1,12}$ ]] || die '维护时间记录无效。'
    if cf_needed && ((now-attempt>=14400)); then
        maintenance_epoch_set edge_attempt "$now"
        edge_maintenance
    fi
}
performance_show() {
    ui_title '资源 / 稳定性 / 日志（保存配置，不冒充当前进程加载值）'
    printf 'Nginx：\n'; nginx_settings | jq '{workers,connections,nofile,keepalive,upstream_keepalive,xhttp_keepalive,upstream_idle,gzip_level,proxy_gzip,access_log,access_log_mode,access_log_sample,access_log_buffer_kb,access_log_flush,proxy_access_log,error_log_level}'
    printf 'Xray：\n'; xray_settings | jq .
    printf '日志保留：\n'; logging_settings | jq .
    ui_note 'auto缓冲：amd64为64KiB、arm64为4KiB；core保留核心默认。它不是TCP窗口，也不是每连接总内存硬上限。'
    ui_note '默认无逐包监控、无用户流量统计；状态仅打开/刷新面板时采样。'
    ui_note '日志阈值由小时维护检查，并非实时硬配额；文件可能在检查前超过阈值。'
    ui_note 'XHTTP继续使用packet-up；不自动改协议、不打开公网管理API、不强制改变BBR/MTU。'
}
s1_base_performance_profile() {
    local profile=${1:-} workers=1 buffer=auto
    if [[ -z $profile ]]; then
        select_value profile '选择资源预设（显示后还需确认；不修改账户、协议、节点或防火墙）' balanced \
          'eco|节省资源：1 Worker、短网站空闲、32KiB缓冲上限（arm64为4）、仅错误日志' \
          'balanced|均衡：1 Worker、600秒Xray空闲、架构适配缓冲、保留警告日志' \
          'throughput|吞吐试验：最多4 Worker、256KiB缓冲；增加内存开销，不保证更快'
    fi
    choice "$profile" 'eco balanced throughput' || die '预设为eco/balanced/throughput。'
    ui_note '预设会覆盖下列容量、空闲、缓冲和日志字段；已有其他高级参数不变。'
    local -a args=(nginx.access_log false nginx.proxy_access_log false)
    case "$profile" in
        eco)
            case $(uname -m) in aarch64|arm64) buffer=4;; *) buffer=32;; esac
            args+=(nginx.workers 1 nginx.connections 1024 nginx.nofile 8192 nginx.keepalive 15 nginx.ssl_cache 2 nginx.upstream_keepalive 2 nginx.xhttp_keepalive 2 nginx.gzip_level 1 nginx.error_log_level error xray.nofile 8192 xray.conn_idle 300 xray.buffer_kb "$buffer" xray.loglevel error);;
        balanced)
            args+=(nginx.workers 1 nginx.connections 1024 nginx.nofile 8192 nginx.keepalive 20 nginx.ssl_cache 4 nginx.upstream_keepalive 4 nginx.xhttp_keepalive 4 nginx.gzip_level 2 nginx.error_log_level warn xray.nofile 8192 xray.conn_idle 600 xray.buffer_kb auto xray.loglevel warning);;
        throughput)
            workers=$(getconf _NPROCESSORS_ONLN); [[ $workers =~ ^[1-9][0-9]*$ ]] || workers=1
            ((workers<=4)) || workers=4
            warn '吞吐预设不是低内存方案；请根据实际可用内存和测速结果选择。'
            args+=(nginx.workers "$workers" nginx.connections 2048 nginx.nofile 16384 nginx.keepalive 30 nginx.ssl_cache 8 nginx.upstream_keepalive 8 nginx.xhttp_keepalive 8 nginx.gzip_level 2 nginx.error_log_level warn xray.nofile 16384 xray.conn_idle 600 xray.buffer_kb 256 xray.loglevel warning);;
    esac
    local i
    for ((i=0;i<${#args[@]};i+=2)); do printf '  %s = %s\n' "${args[i]}" "${args[i+1]}"; done
    advanced_set "${args[@]}"
}
performance_logging() {
    local mode=${1:-} sample buffer flush
    if [[ -z $mode ]]; then
        select_value mode '网站性能日志（不含访问IP、URL/查询串；代理路径仍默认不记录）' off \
          'off|关闭访问日志：最低开销；错误日志保留' \
          'errors|只记录499和5xx：故障定位' \
          'sample|抽样网站请求＋全部499/5xx：记录分阶段耗时' \
          'full|记录全部网站请求：只建议短期排障'
    fi
    choice "$mode" 'off errors sample full' || die '日志模式为off/errors/sample/full。'
    if [[ $mode == off ]]; then advanced_set nginx.access_log false nginx.proxy_access_log false; return; fi
    sample=$(ng_value access_log_sample); buffer=$(ng_value access_log_buffer_kb); flush=$(ng_value access_log_flush)
    if [[ $mode == sample && -n $TTY_FD ]]; then ask_valid sample '正常请求抽样百分比（1～100）' "$sample" number 1 100; fi
    advanced_set nginx.access_log true nginx.access_log_mode "$mode" nginx.access_log_sample "$sample" nginx.access_log_buffer_kb "$buffer" nginx.access_log_flush "$flush"
}
performance_xray() {
    local idle handshake buffer cfg
    cfg=$(xray_settings)
    ask_valid idle 'Xray双向无数据的空闲上限（60～7200秒；不是最大连接寿命）' "$(jq -r .conn_idle <<< "$cfg")" number 60 7200
    ask_valid handshake '握手上限（10～120秒）' "$(jq -r .handshake <<< "$cfg")" number 10 120
    select_value buffer '每连接内部缓冲策略（不是TCP窗口）' "$(jq -r '.buffer_kb|tostring' <<< "$cfg")" \
       'auto|均衡：amd64 64KiB / arm64 4KiB' 'core|核心原生默认：不注入bufferSize' \
       '4|4KiB：极小缓冲' '32|32KiB：节省内存' '64|64KiB：折中' '128|128KiB：增加缓冲' '256|256KiB：高速链路试验'
    advanced_set xray.conn_idle "$idle" xray.handshake "$handshake" xray.buffer_kb "$buffer"
}
performance_retention() {
    local max tail keep cfg
    cfg=$(logging_settings)
    ask_valid max '单个当前日志的轮转触发值（MiB，1～64）' "$(jq -r .max_mb <<< "$cfg")" number 1 64
    ask_valid tail '每份归档只保留末尾多少KiB（16～1024）' "$(jq -r .tail_kb <<< "$cfg")" number 16 1024
    ask_valid keep '每种日志保留多少归档（1～5）' "$(jq -r .keep <<< "$cfg")" number 1 5
    advanced_set logging.max_mb "$max" logging.tail_kb "$tail" logging.keep "$keep"
}
performance_events() {
    local f="$ROOT/logs/runtime-events.jsonl"
    if [[ -r $f && ! -L $f ]]; then tail -n 30 "$f"; else info '暂无服务变更记录。'; fi
}
performance_rotate() {
    confirm '对达到阈值的本工具日志保留有界尾部并截断；不重启服务，较早日志不可恢复' || return 0
    rotate_logs
    ok '日志大小检查完成；未触碰系统journal或其他服务日志。'
}
performance_permissions() {
    ensure_component nginx
    confirm '修复网站只读、临时目录写入权限；不重启服务；禁止网站链接/跨挂载' || return 0
    begin_tx permission-repair
    worker_permissions "$(resolve_worker)"
    commit_tx
}
node_batch() {
    local action=${1:-} selections=${2:-} index count enabled=false candidate="$WORK/node-batch.json" indices='[]'
    if [[ -z $action ]]; then select_value action '批量节点操作（一次事务、至多一次Xray重启）' enable 'enable|启用' 'disable|停用'; fi
    choice "$action" 'enable disable' || die 'node batch只接受enable/disable。'
    node_list
    count=$(jq '.nodes|length' "$STATE"); ((count>0)) || die '暂无节点。'
    [[ -n $selections ]] || ask selections '输入序号，逗号分隔，如1,3,5；0取消' 0
    [[ $selections != 0 ]] || return 0
    selections=${selections//[[:space:]]/}
    [[ $selections =~ ^[1-9][0-9]*(,[1-9][0-9]*)*$ && ${#selections} -le 4096 ]] || die '序号格式无效。'
    local -a items=(); IFS=, read -r -a items <<< "$selections"
    for index in "${items[@]}"; do number "$index" 1 "$count" || die '序号越界。'; done
    indices=$(printf '%s\n' "${items[@]}" | jq -sc 'map(tonumber-1)|unique')
    [[ $action != enable ]] || enabled=true
    jq --argjson ids "$indices" --argjson en "$enabled" 'reduce $ids[] as $i (.; .nodes[$i].enabled=$en)' "$STATE" > "$candidate"
    if json_equal "$candidate" "$STATE"; then ok '所选节点已处于目标状态；没有服务动作。'; return; fi
    validate_state "$candidate"
    confirm "批量$action：${#items[@]}个选择；合并一次提交，Xray若重启会中断整个实例连接" || return 0
    begin_tx "node-batch:$action"
    install -m 600 "$candidate" "$STATE"
    apply_config; commit_tx
    recovery_firewall check || true
}

# Node records retain the 1.6.0 schema. Public TLS transport uses 443;
# .port for WS/XHTTP is a distinct loopback listener, never the public port.
s1_base_node_list() {
    printf '序号\t名称\t协议/模式\t入口\t后端/直连端口\t启用\n'
    jq -r '.nodes|to_entries[]|[(.key+1),.value.id,(.value.protocol+"/"+.value.mode),.value.entry,.value.port,.value.enabled]|@tsv' "$STATE"
}
node_select() {
    local ns_dest=$1 ns_value=${2:-} ns_row ns_key ns_label ns_interactive=no
    local -a ns_options=()
    if [[ -z $ns_value ]]; then
        ns_interactive=yes
        while IFS= read -r ns_row; do
            ns_key=$(jq -r .id <<< "$ns_row")
            ns_label=$(jq -r '"\(.id) | \(.protocol)/\(.mode) | 端口\(.port) | " + (if .enabled then "启用" else "停用" end)' <<< "$ns_row")
            ns_options+=("$ns_key|$ns_label")
        done < <(jq -c '.nodes[]' "$STATE")
        ((${#ns_options[@]})) || die '暂无节点，请先添加。'
        # Numeric interaction always means a displayed position, even if an ID is numeric.
        select_value ns_value '选择节点（输入序号）' '' "${ns_options[@]}"
    fi
    if [[ $ns_interactive == no ]] && ! jq -e --arg id "$ns_value" '.nodes[]|select(.id==$id)' "$STATE" >/dev/null; then
        if [[ $ns_value =~ ^[1-9][0-9]{0,7}$ ]]; then ns_value=$(jq -r --argjson i "$ns_value" '.nodes[$i-1].id // ""' "$STATE"); fi
    fi
    valid_name "$ns_value" && jq -e --arg id "$ns_value" '.nodes[]|select(.id==$id)' "$STATE" >/dev/null || die '节点不存在。'
    printf -v "$ns_dest" '%s' "$ns_value"
}
s5_legacy_unused_port() {
    local p=${1:-20000}
    while ((p<=65535)); do
        if [[ $p != 22 && $p != 80 && $p != 443 ]] && ! jq -e --argjson p "$p" '.nodes[]|select(.port==$p)' "$STATE" >/dev/null && [[ -z $(ss -H -lntu "sport = :$p") ]]; then printf '%s' "$p"; return; fi
        p=$((p+1))
    done
    die '没有找到可用端口。'
}
node_credential() {
    case "$1" in
        vless|vmess) new_uuid;;
        trojan) randhex 24;;
        shadowsocks)
            case "${2:-}" in 2022-blake3-aes-128-gcm) openssl rand -base64 16;; 2022-*) openssl rand -base64 32;; *) randhex 24;; esac;;
        *) die '协议不支持。';;
    esac
}
s1_base_node_add() {
    local guided=${1:-no} id protocol mode host domain='' port path='' method='' credential listen='0.0.0.0'
    local target='' sni='' private='' public='' short='' keys http_version=h2 item scheme
    ensure_component xray
    ask_valid id '节点名称（字母、数字、下划线、短横线）' "node-$(randhex 3)" valid_name
    if jq -e --arg id "$id" '.nodes[]|select(.id==$id or .entry==$id or .runtime_id==$id)' "$STATE" >/dev/null; then die '节点名称/入口已存在。'; fi
    scheme=$(get '.scheme // "A"')
    if [[ $guided == yes ]]; then
        protocol=vless; if [[ $scheme == B ]]; then mode=xhttp; else mode=reality; fi
    else
        select_value protocol '选择代理协议' vless 'vless|VLESS：支持REALITY、XHTTP、WS及TLS' 'vmess|VMess：支持WS及直接TLS' 'trojan|Trojan：需要TLS证书' 'shadowsocks|Shadowsocks：独立TCP/UDP端口'
        case "$protocol" in
            vless) select_value mode '选择VLESS传输' reality 'reality|REALITY直连：无需本机网站证书' 'xhttp|XHTTP：Nginx TLS + 本机后端' 'ws|WebSocket：Nginx TLS + 本机后端' 'tls|直接TLS：独立公网端口和证书';;
            vmess) select_value mode '选择VMess传输' ws 'ws|WebSocket + TLS' 'tls|直接TLS' 'ws-plain|裸WebSocket：无外层TLS，仅可信环境';;
            trojan) select_value mode '选择Trojan传输' ws 'ws|WebSocket + TLS' 'tls|直接TLS';;
            shadowsocks) mode=ss;;
        esac
    fi
    if [[ $mode == ws || $mode == xhttp || $mode == tls ]]; then
        site_select domain
        [[ $(jq -r --arg d "$domain" '.sites[]|select(.domain==$d)|.issued' "$STATE") == true ]] || die '所选网站尚未签发证书。'
        host=$domain
        if [[ $mode == tls ]]; then
            info '直接TLS使用独立公网端口；Cloudflare普通橙云不能代理任意TCP协议。'
            smart_host_select host '直接连接地址（源站IP或未代理域名）' "$(get '.host // ""')"
        fi
    else smart_host_select host '客户端连接的公网IP或域名' "$(get '.host // ""')"; fi
    case "$mode" in
        ws|xhttp)
            port=$(unused_port 20000); listen=127.0.0.1
            ask_valid path '代理路径（至少8位随机字符，保留前导/）' "/$(randhex 12)" valid_path
            if [[ $mode == xhttp && $guided != yes ]]; then
                select_value http_version '客户端HTTP版本' h2 'h2|HTTP/2：常规选项' 'h3|HTTP/3：仅已配置Cloudflare访问侧'
            fi;;
        *) smart_port_select port '公网监听端口' 8443
           [[ $port != 22 && $port != 80 && $port != 443 ]] || die '该端口为保留端口。';;
    esac
    case "$mode" in
        reality)
            smart_sni_select sni
            target="$sni:443"
            keys=$("$XRAY" x25519)
            private=$(awk -F': *' '/PrivateKey|Private key/{print $2;exit}' <<< "$keys")
            public=$(awk -F': *' '/PublicKey|Public key|Password/{print $2;exit}' <<< "$keys")
            [[ $private =~ ^[A-Za-z0-9_-]{43}$ && $public =~ ^[A-Za-z0-9_-]{43}$ ]] || die 'Xray x25519输出格式无法识别，未保存节点。'
            short=$(randhex 8);;
        ss) select_value method 'Shadowsocks算法（客户端须支持）' '2022-blake3-aes-128-gcm' '2022-blake3-aes-128-gcm|SS2022 AES-128' '2022-blake3-aes-256-gcm|SS2022 AES-256' '2022-blake3-chacha20-poly1305|SS2022 ChaCha20' 'aes-128-gcm|AES-128-GCM' 'aes-256-gcm|AES-256-GCM' 'chacha20-ietf-poly1305|ChaCha20-IETF-Poly1305';;
        ws-plain) warn '此模式没有外层TLS，仅用于明确需要的可信部署；不建议暴露到不可信网络。'
            ask_valid path 'WebSocket路径（至少8位，保留前导/）' "/$(randhex 12)" valid_path;;
    esac
    credential=$(node_credential "$protocol" "$method")
    item=$(jq -n --arg id "$id" --arg p "$protocol" --arg m "$mode" --arg h "$host" --arg d "$domain" --argjson port "$port" --arg path "$path" --arg method "$method" --arg c "$credential" --arg l "$listen" --arg t "$target" --arg s "$sni" --arg pk "$private" --arg pub "$public" --arg sid "$short" --arg hv "$http_version" '{id:$id,runtime_id:$id,entry:$id,protocol:$p,mode:$m,host:$h,domain:$d,port:$port,path:$path,method:$method,credential:$c,listen:$l,target:$t,sni:$s,privateKey:$pk,publicKey:$pub,shortId:$sid,http_version:$hv,enabled:true}')
    confirm "新增 $id ($protocol/$mode)，保留其他节点；Xray将按需重启" || return 0
    begin_tx "node-add:$id"
    json_update --argjson n "$item" --arg h "$host" '.nodes += [$n] | if (.host // "")=="" then .host=$h else . end'
    apply_config; commit_tx
    smart_after_node || true
    node_export "$id"
}
node_share() {
    local source id node protocol credential
    node_select source "${1:-}"
    node=$(jq -c --arg id "$source" '.nodes[]|select(.id==$id)' "$STATE"); protocol=$(jq -r .protocol <<< "$node")
    [[ $protocol != shadowsocks ]] || die '此实现不为Shadowsocks入口创建共享用户，请添加独立节点。'
    ask_valid id '新用户/节点名称' "user-$(randhex 3)" valid_name
    if jq -e --arg id "$id" '.nodes[]|select(.id==$id or .entry==$id or .runtime_id==$id)' "$STATE" >/dev/null; then die '名称已占用。'; fi
    credential=$(node_credential "$protocol")
    node=$(jq --arg id "$id" --arg c "$credential" '.id=$id|.runtime_id=$id|.credential=$c|.enabled=true' <<< "$node")
    confirm "共享 $source 的入口，新增独立凭据 $id；不新增监听端口" || return 0
    begin_tx "node-share:$id"; json_update --argjson n "$node" '.nodes+=[$n]'; apply_config; commit_tx; node_export "$id"
}
node_change() {
    local action=$1 id=${2:-} value=${3:-} node entry protocol credential
    node_select id "$id"
    node=$(jq -c --arg id "$id" '.nodes[]|select(.id==$id)' "$STATE"); entry=$(jq -r .entry <<< "$node")
    case "$action" in
        enable|disable|delete|rotate) ;;
        rename)
            [[ -n $value ]] || ask_valid value '新节点名称（回车保留）' "$id" valid_name
            [[ $value != "$id" ]] || { info '名称未变，不创建事务。'; return 0; }
            valid_name "$value" || die '名称无效。'
            if jq -e --arg id "$value" '.nodes[]|select(.id==$id)' "$STATE" >/dev/null; then die '新名称已存在。'; fi;;
        port)
            [[ -n $value ]] || smart_port_select value '新监听端口（共享入口同步更新）' "$(jq -r .port <<< "$node")" "$(jq -r .port <<< "$node")"
            valid_port "$value" && [[ $value != 22 && $value != 80 && $value != 443 ]] || die '端口无效。';;
        host)
            [[ -n $value ]] || smart_host_select value '新的客户端连接地址（整个共享入口）' "$(jq -r .host <<< "$node")"
            valid_host "$value" || die '连接地址无效。';;
        *) die '节点操作无效。';;
    esac
    if [[ $action == rename && $value == "$id" ]] ||
       [[ $action == host && $value == $(jq -r .host <<< "$node") ]] ||
       [[ $action == port && $value == $(jq -r .port <<< "$node") ]]; then
        ok '值未变化；未创建事务或操作服务。'; return 0
    fi
    confirm "对 $id 执行 $action；必要时重启Xray，当前连接可能中断" || return 0
    begin_tx "node-$action:$id"
    stable_node_ids
    case "$action" in
        enable|disable) local enabled=false; [[ $action != enable ]] || enabled=true
            json_update --arg id "$id" --argjson e "$enabled" '(.nodes[]|select(.id==$id)).enabled=$e';;
        delete) json_update --arg id "$id" '.nodes|=map(select(.id!=$id))';;
        rotate)
            protocol=$(jq -r .protocol <<< "$node"); credential=$(node_credential "$protocol" "$(jq -r '.method // ""' <<< "$node")")
            json_update --arg id "$id" --arg c "$credential" '(.nodes[]|select(.id==$id)).credential=$c';;
        rename) json_update --arg id "$id" --arg v "$value" '(.nodes[]|select(.id==$id)).id=$v';;
        port) json_update --arg e "$entry" --argjson v "$value" '(.nodes[]|select(.entry==$e)).port=$v';;
        host) json_update --arg e "$entry" --arg v "$value" '(.nodes[]|select(.entry==$e)).host=$v';;
    esac
    if [[ $action == rename || $action == host ]]; then
        validate_state "$STATE" no
        commit_tx
        ok '仅更新名称/客户端地址；Nginx、Xray均未重载或重启。'
    else
        apply_config; commit_tx
        recovery_firewall check || true
    fi
}
uri_encode() { jq -nr --arg s "$1" '$s|@uri'; }
base64_oneline() { base64 | tr -d '\r\n'; }
node_export() {
    local id n protocol mode host port credential domain path label uri security query method payload
    node_select id "${1:-}"
    n=$(jq -c --arg id "$id" '.nodes[]|select(.id==$id)' "$STATE")
    protocol=$(jq -r .protocol <<< "$n"); mode=$(jq -r .mode <<< "$n"); host=$(jq -r .host <<< "$n"); port=$(jq -r .port <<< "$n")
    credential=$(jq -r .credential <<< "$n"); domain=$(jq -r '.domain // ""' <<< "$n"); path=$(jq -r '.path // ""' <<< "$n"); label=$(uri_encode "$id")
    if [[ $mode == ws || $mode == xhttp ]]; then port=443; fi
    warn '下方包含访问凭据；不要发布到公共日志、聊天群或网页。'
    if [[ $protocol == vmess ]]; then
        payload=$(jq -nc --arg ps "$id" --arg add "$host" --arg port "$port" --arg id "$credential" --arg d "$domain" --arg path "$path" --arg mode "$mode" '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:(if $mode=="tls" then "tcp" else "ws" end),type:"none",host:$d,path:$path,tls:(if $mode=="ws-plain" then "" else "tls" end),sni:$d}')
        printf 'vmess://%s\n' "$(printf '%s' "$payload" | base64_oneline)"; return
    fi
    [[ $host != *:* ]] || host="[$host]"
    if [[ $protocol == shadowsocks ]]; then
        method=$(jq -r .method <<< "$n")
        if [[ $method == 2022-* ]]; then uri="$(uri_encode "$method"):$(uri_encode "$credential")"
        else uri=$(printf '%s:%s' "$method" "$credential" | base64_oneline | tr '+/' '-_' | tr -d '='); fi
        printf 'ss://%s@%s:%s#%s\n' "$uri" "$host" "$port" "$label"; return
    fi
    case "$mode" in
        reality) query="security=reality&type=tcp&flow=xtls-rprx-vision&fp=chrome&sni=$(uri_encode "$(jq -r .sni <<< "$n")")&pbk=$(uri_encode "$(jq -r .publicKey <<< "$n")")&sid=$(jq -r .shortId <<< "$n")";;
        xhttp) query="security=tls&type=xhttp&mode=packet-up&sni=$(uri_encode "$domain")&host=$(uri_encode "$domain")&path=$(uri_encode "$path/")&alpn=$(jq -r '.http_version // "h2"' <<< "$n")";;
        ws) query="security=tls&type=ws&sni=$(uri_encode "$domain")&host=$(uri_encode "$domain")&path=$(uri_encode "$path")";;
        tls) query="security=tls&type=tcp&sni=$(uri_encode "$domain")";;
        *) die '此节点没有可导出的链接。';;
    esac
    [[ $protocol != vless ]] || query="encryption=none&$query"
    printf '%s://%s@%s:%s?%s#%s\n' "$protocol" "$(uri_encode "$credential")" "$host" "$port" "$query" "$label"
    if [[ $mode == xhttp ]]; then info 'XHTTP分享链接的客户端支持有差异；可用 node client NAME 获取Xray客户端JSON。'; fi
}
node_client() {
    local id; node_select id "${1:-}"
    [[ $(jq -r --arg id "$id" '.nodes[]|select(.id==$id)|.mode' "$STATE") == xhttp ]] || die '此命令仅生成XHTTP客户端JSON；其他模式使用node export。'
    warn 'JSON包含UUID；本地SOCKS仅监听127.0.0.1:10808。'
    jq --arg id "$id" '.nodes[]|select(.id==$id)|. as $n|
      {log:{loglevel:"warning"},inbounds:[{listen:"127.0.0.1",port:10808,protocol:"socks",settings:{udp:true}}],outbounds:[{protocol:"vless",settings:{vnext:[{address:$n.host,port:443,users:[{id:$n.credential,encryption:"none"}]}]},streamSettings:{network:"xhttp",security:"tls",tlsSettings:{serverName:$n.domain,alpn:[($n.http_version // "h2")],allowInsecure:false},xhttpSettings:{path:($n.path+"/"),host:$n.domain,mode:"packet-up"}}}]}' "$STATE"
}

edge_show() {
    local d s; site_select d "${1:-}"
    s=$(jq -c --arg d "$d" '.sites[]|select(.domain==$d)' "$STATE")
    printf '%s\n' "$d"; edge_settings "$s" | jq .
    info '请求频率/连接/速度/爬虫限制仅作用于网站内容；不套用到WS/XHTTP节点或HTTP-01。'
}
edge_refresh() {
    cf_fetch
    begin_tx edge-refresh; cf_install_assets
    if component_ready nginx; then apply_config web; fi
    commit_tx
}
edge_edit() {
    local d key value s; site_select d
    edge_show "$d"
    ask_valid key '参数：bots/rate/burst/connections/kbps/static_ttl/gzip/origin/aop' rate choice 'bots rate burst connections kbps static_ttl gzip origin aop'
    s=$(jq -c --arg d "$d" '.sites[]|select(.domain==$d)' "$STATE")
    ask value "设置$key" "$(edge_settings "$s" | jq -r --arg k "$key" '.[$k]')"
    edge_set "$d" "$key" "$value"
}
performance_gzip() {
    local value=${1:-}
    [[ -n $value ]] || ask_valid value '全局网站压缩（仅未单独覆盖的网站；代理节点始终不压缩）' "$(get '.performance.gzip // false')" valid_bool
    valid_bool "$value" || die '开关必须为true/false。'
    confirm "网站gzip=$value" || return 0
    begin_tx performance; json_update --argjson v "$value" '.performance.gzip=$v'; apply_config web; commit_tx
}

wizard_step() { json_update --arg step "$1" '.wizard.last_step=$step|.wizard.last_result="进行中；中断后可继续"'; }
install_wizard() {
    local scheme host domain answer
    if [[ $(get '.wizard.selected // false') != true ]]; then
        if [[ $(get '.nodes|length') -gt 0 || $(get '.sites|length') -gt 0 ]]; then
            info '已读取现有部署，不重新询问原节点和网站参数。'
            json_update '.wizard.selected=true'
        else
            ask_valid scheme '部署方案：A=VLESS REALITY直连；B=网站TLS+VLESS XHTTP' "$(get '.scheme // "A"')" choice 'A B'
            ask_valid host '服务器公网IP或连接域名（不自动猜测）' "$(get '.host // ""')" valid_host
            json_update --arg s "$scheme" --arg h "$host" '.scheme=$s|.host=$h|.wizard.selected=true'
        fi
    fi
    scheme=$(get '.scheme // "A"')
    wizard_step xray
    install_component xray
    if [[ $scheme == B ]]; then
        wizard_step nginx; install_component nginx
        wizard_step acme; install_component acme
        wizard_step website
        domain=$(get '.preferences.domain // .sites[0].domain // ""')
        if [[ -z $domain ]] || ! jq -e --arg d "$domain" '.sites[]|select(.domain==$d)' "$STATE" >/dev/null; then
            site_configure
            domain=$(get '.preferences.domain // .sites[0].domain // ""')
        else info "复用已保存网站：$domain；需要改动时进入网站菜单。"; fi
        wizard_step certificate
        if [[ $(jq -r --arg d "$domain" '.sites[]|select(.domain==$d)|.issued' "$STATE") != true || $(jq -r --arg d "$domain" '.sites[]|select(.domain==$d)|.cert_settings_pending // false' "$STATE") == true ]]; then cert_issue "$domain"; fi
    fi
    wizard_step node
    if [[ $(get '.nodes|length') == 0 ]]; then node_add yes; else info '保留现有节点及凭据，不重新生成。'; fi
    json_update '.wizard.last_step="complete"|.wizard.last_result="已完成"'
    ok '部署向导完成；再次运行将读取现有配置。'
}
s1_base_status_show() {
    status_dashboard main
    printf 'VPSKit %s\n根目录：%s\n' "$VERSION" "$ROOT"
    if ! state_basic "$STATE"; then warn 'state.json缺失或损坏，未初始化覆盖；请查看历史/repair。'; return 0; fi
    jq -r '"保存配置版本：\(.manager // "unknown")\n方案：\(.scheme // "A")\n节点数：\(.nodes|length)；网站数：\(.sites|length)\n向导进度：\(.wizard.last_step // "未记录")"' "$STATE"
    local c unit active pid
    for c in xray nginx acme; do printf '%-8s 配置标记=%-5s 版本=%s\n' "$c" "$(get ".components.$c // false")" "$(get ".versions.$c // \"unknown\"")"; done
    for unit in vpskit-xray.service vpskit-nginx.service vpskit-maintain.timer; do
        active=$(systemctl is-active "$unit" 2>/dev/null || true); printf '%-28s %s\n' "$unit" "${active:-unknown}"
    done
    pid=$(systemctl show -p MainPID --value vpskit-nginx.service 2>/dev/null || true)
    if [[ $pid =~ ^[1-9][0-9]*$ && -d /proc/$pid ]]; then
        printf 'Nginx进程（Master为root是预期的；Worker必须非root）：\n'
        ps -o pid,ppid,user,stat,rss,args -p "$pid" --ppid "$pid" || true
    fi
    [[ ! -d $ROOT/backup/transaction ]] || warn '有未完成事务，请先运行repair。'
}
s1_base_doctor() {
    local issues=0 u='' runtime_user='' rc
    status_show || { warn '运行概况读取失败，继续检查。'; issues=$((issues+1)); }
    if ! state_basic "$STATE"; then warn '状态资料无效；请先恢复配置，未修改任何运行服务。'; return 1; fi
    if ! ( trap - ERR EXIT; validate_state ); then warn '保存配置校验失败。'; issues=$((issues+1)); fi
    if u=$(resolve_worker); then info "预期Worker账户：$u / UID $(id -u "$u")"
    else warn '无法选择合格Worker账户。'; issues=$((issues+1)); fi
    if component_ready nginx; then
        if ! nginx_cmd -t -p "$ROOT/" -c "$ROOT/config/nginx.conf"; then warn '当前Nginx配置语法检查失败。'; issues=$((issues+1)); fi
        runtime_user=$(nginx_conf_value user "$ROOT/config/nginx.conf" || true)
        if systemctl is-active --quiet vpskit-nginx.service; then
            if [[ $runtime_user == root ]]; then
                warn '当前仍在运行历史root Worker配置：迁移预检未完成，并非新配置已经降权。继续检查，不停止服务。'
                issues=$((issues+1))
            elif ! verify_nginx_runtime ''; then issues=$((issues+1)); fi
        fi
        if [[ -n $u ]]; then
            if runuser -u "$u" -- test -r "$STATE"; then warn '候选Worker能读取state.json。'; issues=$((issues+1)); fi
            if runuser -u "$u" -- test -x "$ROOT/certs"; then warn '候选Worker能遍历证书目录。'; issues=$((issues+1)); fi
        fi
    fi
    if component_ready xray; then
        if ! "$XRAY" run -test -config "$ROOT/config/xray.json"; then warn 'Xray配置校验失败。'; issues=$((issues+1)); fi
    fi
    printf '\n监听端口：\n'; ss -lntup || true
    printf '\n内存/Swap：\n'; free -h || true
    printf '\n当前拥塞控制：\n'; sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc 2>/dev/null || true
    if ((issues)); then
        warn "检查完成：发现 $issues 项问题；未自动重启/改权。预检记录：vpskit logs preflight 120。"
        return 1
    fi
    ok '上述本机检查完成；不等于外网连通性、CDN回源或实际吞吐测试通过。'
}
service_action() {
    local name=$1 action=$2
    choice "$name" 'nginx xray' && choice "$action" 'start stop restart' || die '服务操作无效。'
    ensure_component "$name"
    [[ -f $SYSTEMD/vpskit-$name.service ]] && grep -Fq '# VPSKIT_OWNED' "$SYSTEMD/vpskit-$name.service" || die '服务文件不属于VPSKit。'
    confirm "对vpskit-$name执行$action；可能中断现有连接" || return 0
    systemctl "$action" "vpskit-$name.service"
    if [[ $action != stop ]]; then systemctl is-active --quiet "vpskit-$name.service" || die '服务未运行。'; fi
}
s1_base_uninstall_keep_data() {
    local u
    warn '卸载只停止/删除本工具服务与命令入口。配置、证书、网站、代码、备份、Swap和防火墙规则全部保留。'
    confirm '执行保留数据的卸载' || return 0
    for u in "${UNITS[@]}"; do
        if [[ -f $SYSTEMD/$u ]] && grep -Fq '# VPSKIT_OWNED' "$SYSTEMD/$u"; then systemctl disable --now "$u" || die "停用 $u 失败，保留该服务文件和全部资料。"; rm -f "$SYSTEMD/$u"; fi
    done
    [[ ! -L $ENTRY || $(readlink "$ENTRY") != "$ROOT/vpskit.sh" ]] || rm -f "$ENTRY"
    systemctl daemon-reload
    ok "服务已移除，数据保留。恢复运行：sudo bash $ROOT/vpskit.sh apply"
}
legacy_restore_transaction() {
    local dir=$1 p u failed=0
    [[ -f $dir/ready && -f $dir/state.json && -d $dir/tree ]] || return 1
    state_basic "$dir/state.json" || return 1
    warn '恢复1.6.0旧格式事务；不把旧快照当作新格式删除。'
    systemctl stop vpskit-xray.service vpskit-nginx.service >/dev/null 2>&1 || true
    for p in bin nginx config certs acme; do
        [[ -d $dir/tree/$p && ! -L $dir/tree/$p ]] || return 1
        rm -rf -- "$ROOT/$p"; cp -a "$dir/tree/$p" "$ROOT/$p" || failed=1
    done
    cp -a "$dir/state.json" "$STATE" || failed=1
    for u in "${UNITS[@]}"; do
        if [[ -f $dir/units/$u ]]; then cp -a "$dir/units/$u" "$SYSTEMD/$u" || failed=1
        elif [[ -f $SYSTEMD/$u ]] && grep -Fq '# VPSKIT_OWNED' "$SYSTEMD/$u"; then systemctl disable --now "$u" >/dev/null 2>&1 || true; rm -f "$SYSTEMD/$u"; fi
    done
    chown 0:0 "$ROOT"; chmod 700 "$ROOT"
    systemctl daemon-reload || failed=1
    for u in "${UNITS[@]}"; do
        if [[ -f $dir/enabled ]] && grep -Fxq "$u" "$dir/enabled"; then systemctl enable "$u" >/dev/null 2>&1 || failed=1
        else systemctl disable "$u" >/dev/null 2>&1 || true; fi
    done
    if [[ -f $dir/active ]]; then while IFS= read -r u; do systemctl start "$u" || failed=1; done < "$dir/active"; fi
    if [[ -f $dir/stopped-external ]]; then
        while IFS= read -r u; do [[ -z $u ]] || systemctl start "$u" || failed=1; done < "$dir/stopped-external"
    fi
    ((failed==0))
}
selftest() {
    valid_domain example.com && ! valid_domain 'a;evil.com' && ! valid_domain '../example.com'
    valid_host 127.0.0.1 && valid_host ::1 && ! valid_host 999.1.1.1 && ! valid_host 1::2::3
    valid_path /abcdefgh1234 && ! valid_path / && ! valid_path '/../../etc'
    valid_upstream http://127.0.0.1:8000 && ! valid_upstream http://127.0.0.1:80
    valid_redirect https://example.com/path && ! valid_redirect 'https://example.com/;}'
    valid_uuid 00112233-4455-6677-8899-aabbccddeeff && ! valid_uuid xyz
    number 2048 128 65535 && ! number 08 1 10
    if command -v jq >/dev/null; then nginx_defaults | jq -e '.workers==1 and .connections==1024 and .worker_user=="auto"' >/dev/null; fi
    printf '内置纯校验自检通过；未安装组件、未变更系统。\n'
}


# The menu is a single registry: every visible item has a purpose, requirement,
# risk badge and an explicit dispatch route. No eval and no command strings.
s1_base_menu_catalog() {
    cat <<'VPSKIT_MENU_CATALOG'
main|1|部署与安装|新装、继续历史部署或单独安装组件|Debian/Ubuntu、root；下载组件需联网|nav|menu:install
main|2|节点与用户|新增、共享用户、改端口/地址、启停和导出|已安装 Xray；TLS 类节点还需域名与证书|nav|menu:nodes
main|3|网站与证书|网站内容、反向代理、跳转、签发与导入证书|网站需要 Nginx；自动证书还需 ACME|nav|menu:websites
main|4|网络与网站优化|BBR、MTU 探测、网站 gzip 和资源状态|内核调优需支持；MTU 只探测不改网卡|nav|menu:optimize
main|5|组件更新|独立更新 Nginx、Xray、ACME 或全部组件|需联网；组件变更可能重启相关服务|nav|menu:update
main|6|状态、日志与维护|运行状态、诊断、日志、服务启停及应用配置|诊断结果是本机视角；日志分享前脱敏|nav|menu:status
main|7|卸载管理|保留数据停用、卸载单个组件或完整清理|删除前先备份；危险操作须二次确认|danger|menu:uninstall
main|8|方案说明与命令帮助|查看方案 A/B、命令及使用流程|只读；无需先完成部署|nav|menu:help
main|9|配置文件与目录|显示配置、网站、证书、日志和备份位置|只显示路径，不显示 UUID、密码或私钥|read|paths
main|10|防火墙端口管理|查看、开放、关闭、同步和撤销托管规则|仅操作已启用的 UFW 或 firewalld；保护 SSH|nav|menu:firewall
main|11|Swap 虚拟内存|创建、恢复、查看和安全移除本工具 Swap|需磁盘空间及内核支持；不接管系统 Swap|nav|menu:swap
main|12|方案 B 防护与流量|爬虫、网站限流、缓存、Cloudflare 与 AOP|先确保网站可用；回源限制需正确配置橙云|nav|menu:edge
main|13|高级配置 · Nginx / Xray|Worker、连接容量、文件数、TLS 和超时|保留现有节点；部分参数变更需要重启|nav|menu:advanced
main|14|历史配置和恢复|创建快照、恢复配置、回滚和中断恢复|快照含敏感资料；不等于整机或网站文件备份|nav|menu:history
main|15|仅更新管理脚本|只替换管理代码，不更新组件或重启服务|提供可信的完整脚本或 HTTPS 源码地址|write|update-manager
install|1|继续部署向导|自动读取已保存参数，跳过已完成步骤|新机或未完成部署；需要联网|write|install-wizard
install|2|单独安装 Nginx|安装独立 Nginx，自动复用非 root 服务账户|需要软件源可用；不接管外部 Nginx|write|install-nginx
install|3|单独安装 Xray|补装代理组件，不覆盖已保存节点|需 GitHub 可达；已安装时不重复安装|write|install-xray
install|4|单独安装 ACME|补装证书工具，保留账户及续期资料|需联网；安装不等于已经签发证书|write|install-acme
install|5|修改方案与默认值|保存方案 A/B 和新建节点的默认连接地址|不自动改动已有节点、证书或网站|write|wizard-configure
install|6|查看部署进度|查看向导停在哪一步及已安装组件|只读；不重做任何部署步骤|read|wizard-status
nodes|1|查看节点列表|显示序号、名称、协议、入口和启用状态|只读；不显示访问凭据|read|node-list
nodes|2|新增节点|添加 REALITY、XHTTP、WS、TLS 或 Shadowsocks|Xray 已安装；所选传输需满足域名/证书条件|write|node-add
nodes|3|添加共享入口用户|复用同一监听端口，生成独立用户凭据|已有支持共享的入口；不新增公网端口|write|node-share
nodes|4|启用节点|让保存的节点重新参与运行配置|需端口可用；客户端与防火墙需匹配|write|node-enable
nodes|5|停用节点|保留节点资料，停止该用户的访问|该用户连接可能中断；其他共享用户保留|warn|node-disable
nodes|6|删除节点|删除选中用户的节点记录|删除不可直接撤销；可从历史快照恢复|danger|node-delete
nodes|7|自动轮换凭据|重新生成 UUID 或密码|客户端必须更新；现有连接可能中断|warn|node-rotate
nodes|8|导出分享链接|输出可导入客户端的节点 URI|链接含访问凭据，禁止公开发布|sensitive|node-export
nodes|9|导出 XHTTP 客户端 JSON|生成本地 SOCKS 的 Xray 客户端配置|仅 XHTTP 节点；JSON 含 UUID|sensitive|node-client
nodes|10|修改节点名称|修改用户显示名称，保留共享入口关系|名称须唯一；不会轮换访问凭据|write|node-rename
nodes|11|修改入口端口|同步修改整个共享入口的监听端口|同步客户端、防火墙和安全组；WS/XHTTP 仍走公网443|warn|node-port
nodes|12|修改连接地址|修改客户端连接域名、IPv4 或 IPv6|保留 TLS SNI/Host；同入口用户同步修改|write|node-host
nodes|13|指定 UUID 或密码|手动设置凭据，可留空自动生成|需符合协议格式；客户端必须同步更新|sensitive|node-credential
nodes|14|修改监听地址|选择 IPv4、IPv6 或双栈监听入口|仅直连入口；WS/XHTTP 后端保持回环监听|warn|node-listen
websites|1|查看网站列表|显示域名、内容类型、访问方式和证书状态|只读；不显示 DNS API 凭据|read|site-list
websites|2|新增网站|创建模板、静态站、本机反代或 HTTPS 跳转|已安装 Nginx；需自有域名|write|site-add
websites|3|修改网站内容与访问方式|编辑已有网站；保留内容文件和证书|不覆盖已存在模板；修改后检查依赖节点|write|site-edit
websites|4|移除网站绑定|停止该域名网站和自动续期，保留文件|必须先删除引用该网站的节点|danger|site-remove
websites|5|签发 / 重试证书|按已保存设置申请或重新签发证书|需 ACME；HTTP-01 需80可达，DNS-01 需 API权限|write|cert-issue
websites|6|证书有效期|查看当前证书到期时间|只读；尚未签发会明确提示|read|cert-status
websites|7|检查续期|按 ACME 到期策略检查，不强制重复签发|需联网；手动导入的证书不自动续期|write|cert-renew
websites|8|修改证书验证设置|保存邮箱、HTTP/DNS 验证及泛域名选项|保存不立即重签；泛域名需要 DNS-01|write|cert-settings
websites|9|导入证书与私钥|校验域名和密钥匹配后部署手动证书|提供本机 PEM 文件；暂停此域名 ACME 自动续期|sensitive|cert-import
optimize|1|资源与网络现状|查看内存、连接、拥塞控制和网卡 MTU|只读；不会修改系统参数|read|optimize-status
optimize|2|启用 BBR + fq|记录旧参数后启用内核拥塞控制|需内核提供 BBR；不保证提升所有链路性能|warn|optimize-bbr
optimize|3|撤销本工具 BBR 设置|恢复本工具记录的旧值并移除其持久化文件|只撤销可验证的托管设置；不覆盖外部新改动|warn|optimize-restore
optimize|4|MTU 路径探测|使用 tracepath 检查目标路径的 MTU|需 iputils-tracepath；只发送探测，不修改网卡|read|optimize-mtu
optimize|5|静态网站 gzip|启停轻量文本压缩，不压缩节点代理流量|Nginx 已安装；站点单独设置可覆盖全局值|write|performance-gzip
optimize|6|Nginx 容量设置|一起调整 Worker、连接数和文件数上限|需结合内存及并发；文件数至少为连接数+1024|write|advanced-capacity
update|1|更新 Nginx|从发行版软件源更新独立二进制|需联网；可能重启 Nginx，网站连接可能中断|write|update-nginx
update|2|更新 Xray|选择固定版本或显式 latest|需联网；重启会中断代理连接，先核对客户端兼容性|write|update-xray
update|3|更新 ACME|更新证书工具，保留证书和账户资料|需联网；不会直接重新申请所有证书|write|update-acme
update|4|仅更新管理代码|校验完整脚本后替换代码并备份旧版|不改 state.json、不升级组件、不重启服务|write|update-manager
update|5|更新全部已安装组件|依次更新已安装的组件，再询问是否更新管理代码|逐组件提交；失败保留已完成更新，可能多次中断连接|warn|update-all
status|1|查看运行状态|查看组件版本、服务状态和 Worker 身份|只读；不显示节点凭据|read|status
status|2|本机诊断|检查配置语法、权限、监听和服务进程|不能代替公网、CDN 或吞吐验收|read|doctor
status|3|Nginx 错误日志|显示最近 Nginx 错误记录|只读；分享前删除敏感地址与路径|read|logs-nginx
status|4|Xray 日志|显示最近代理运行错误记录|只读；分享前脱敏|read|logs-xray
status|5|管理操作日志|查看安装、更新与配置操作结果|只读；不会打印已保存密码或私钥|read|logs-manager
status|6|证书与维护日志|查看定时续期服务的近期 journal 记录|需要 systemd journal；分享前脱敏|read|logs-cert
status|7|Nginx 服务日志|查看启动服务的标准输出和错误|日志尚不存在时只提示，不新建文件|read|logs-service
status|8|网站访问日志|显示高级配置中启用的访问日志|默认关闭；日志包含访客 IP 和访问路径|read|logs-access
status|9|应用已保存配置|重新生成、验证并加载 Nginx/Xray 配置|首次降权或文件数变化可能重启服务|warn|apply
status|10|服务启动 / 停止 / 重启|单独控制本工具的 Nginx 或 Xray|不操作系统其他同名软件实例|nav|menu:services
status|11|DNS 与公网 HTTPS 检查|检查网站解析和公网响应，不修改 DNS|需网络；Cloudflare解析不必等于源站IP|read|network-check
status|12|配置文件与目录|显示配置与资料保存位置|只显示路径；不要公开包含密钥的目录|read|paths
status|13|启动失败诊断记录|查看最近一次预检或运行校验失败日志|只读；日志仅root可读；分享前脱敏|read|logs-diagnostics
status|14|强制恢复历史配置|按编号选择未完成事务、最近事务或快照|保留失败现场；可选择原样服务或兼容沙箱；核对防火墙|danger|recover
services|1|启动 Nginx|仅控制 vpskit-nginx 服务|已安装对应组件；停止或重启会中断相关连接|write|service:nginx:start
services|2|停止 Nginx|仅控制 vpskit-nginx 服务|已安装对应组件；停止或重启会中断相关连接|warn|service:nginx:stop
services|3|重启 Nginx|仅控制 vpskit-nginx 服务|已安装对应组件；停止或重启会中断相关连接|warn|service:nginx:restart
services|4|验证并重载 Nginx|仅控制 vpskit-nginx 服务|已安装对应组件；停止或重启会中断相关连接|write|service:nginx:reload
services|5|启动 Xray|仅控制 vpskit-xray 服务|已安装对应组件；停止或重启会中断相关连接|write|service:xray:start
services|6|停止 Xray|仅控制 vpskit-xray 服务|已安装对应组件；停止或重启会中断相关连接|warn|service:xray:stop
services|7|重启 Xray|仅控制 vpskit-xray 服务|已安装对应组件；停止或重启会中断相关连接|warn|service:xray:restart
services|8|重启全部组件|按顺序重启已配置Xray、Nginx和维护定时器|先做语法检查；会中断连接；不重签证书|warn|service:all:restart
services|9|重启整台VPS系统|正常重启操作系统及全部应用|需输入REBOOT和yes；SSH将断开；先恢复未完成事务|danger|system-reboot
uninstall|1|停用服务，保留数据|删除本工具服务与入口；网站、节点、证书、备份保留|不会删除 Swap/防火墙；以后可用完整脚本 apply 恢复|warn|uninstall-keep
uninstall|2|单独卸载 Xray|删除代理节点和 Xray 程序，保留网站|所有代理用户断开；先导出需要保留的资料|danger|uninstall-xray
uninstall|3|单独卸载 Nginx|移除独立 Nginx，保留其他资料|存在网站或 TLS 网关节点依赖时拒绝执行|danger|uninstall-nginx
uninstall|4|单独卸载 ACME|删除自动证书工具及其账户资料|存在自动续期证书依赖时拒绝执行|danger|uninstall-acme
uninstall|5|完整卸载 VPSKit|清理本工具资料、服务、已识别规则与 Swap|需输入删除口令；备份也会删除，未知外部资料不接管|danger|uninstall-all
help|1|方案 A / B 说明|对比 REALITY 直连与网站 TLS/XHTTP|只读；帮助选择部署模式|read|explain
help|2|完整命令帮助|查看命令、兼容别名及调用示例|只读；命令行与面板共用后端|read|help
help|3|Cloudflare 配置指引|说明橙云、严格 TLS、缓存排除和 AOP|需要自行在 Cloudflare 控制台配置|read|edge-guide
help|4|升级、恢复与安全说明|说明代码更新、配置应用、备份和权限边界|只读；历史快照不含网站内容和系统资源变更|read|workflow-help
help|5|面板颜色与操作提示|查看颜色含义、返回/取消及无颜色模式|支持 NO_COLOR 和 --no-color；日志不带颜色控制符|read|color-help
firewall|1|防火墙与所需端口|查看启用的管理器、规则和节点公网端口|只读；云安全组需另行检查|read|firewall-status
firewall|2|开放端口|显式添加带归属记录的 TCP/UDP 放行规则|仅已启用的 UFW/firewalld；SSH 端口交给管理员|warn|firewall-open
firewall|3|关闭端口|添加阻止新入站连接的规则|会影响相关业务；拒绝操作检测到的 SSH 端口|danger|firewall-close
firewall|4|同步当前所需端口|预览后开放网站及启用节点需要的公网端口|不会开放本机后端端口；不会自动关闭旧端口|write|firewall-sync
firewall|5|撤销本版托管规则|只撤销有本版归属记录、标识匹配的规则|外部规则和旧格式记录不盲目删除；可能改变可达性|danger|firewall-cleanup
swap|1|Swap 状态|查看实际使用量、归属文件与启动配置|只读；不把磁盘交换区当成新增物理内存|read|swap-status
swap|2|启用 / 恢复 1 GiB Swap|已有托管 Swap 则恢复，不重复分配|新建需 ext4/XFS 等支持、足够磁盘及内核权限|warn|swap-enable
swap|3|自定义容量|创建 256–8192 MiB 的托管交换文件|256 的倍数；预留至少1GiB磁盘，不覆盖现有Swap|warn|swap-custom
swap|4|安全移除本工具 Swap|先检查可用内存，再停用并删除交换文件|内存不足或 swapoff 失败时保留文件和启动配置|danger|swap-remove
edge|1|查看网站防护|查看各站爬虫、限额、缓存及回源设置|只读；不显示节点凭据|read|edge-status
edge|2|应用均衡预设|AI爬虫拦截、5请求/秒、20并发、1小时缓存与gzip|仅网站内容；不主动开启源站封锁或强制AOP|write|edge-profile
edge|3|爬虫策略|选择 off、ai、common、all 的 UA 拦截|UA可伪造；all会影响搜索引擎、API及监控|warn|edge-bots
edge|4|请求、并发和下载限额|调整请求频率、突发、并发及每响应速度|同出口IP共享额度；不是全机或代理用户带宽配额|write|edge-limits
edge|5|静态缓存与 gzip|设置静态资源缓存头和站点压缩|不强制缓存HTML/动态应用/节点流量|write|edge-cache
edge|6|限制 Cloudflare 回源|仅允许已验证的 Cloudflare 网段访问网站/网关|需要橙云；直连将被拒绝，ACME路径保留|warn|edge-origin
edge|7|AOP 回源客户端证书|切换 off、observe、enforce|先观察并探测成功，再强制；误配会中断访问|warn|edge-aop
edge|8|AOP 公网验证|通过公开域名检查本次回源是否为 SUCCESS|域名已走橙云；源站须有有效证书且启用observe|read|edge-probe
edge|9|更新 Cloudflare 官方资料|刷新IPv4/IPv6网段与公共AOP CA|需联网；失败保留旧资料|write|edge-refresh
edge|10|Cloudflare 配置指引|输出控制台设置和节点路径缓存排除原则|只提供指引，不自动修改外部账户|read|edge-guide
edge|11|网卡流量采样|显示网卡累计流量和约1秒速率|为接口总流量，不是节点计费统计|read|edge-traffic
edge|12|重置单站防护|关闭该站新增爬虫、限流、缓存及回源限制|不删除网站、节点或证书；需确认|warn|edge-reset
edge|13|按字段编辑防护|逐项编辑单站点防护参数|适用于了解参数范围的用户；保存前验证|write|edge-edit
advanced|1|查看保存值与实际值|显示合并默认值后的参数、CPU/内存及Worker身份|只读；连接上限不是用户人数|read|advanced-show
advanced|2|Worker / 连接数 / 文件数|一起调整并发容量，防止参数互相冲突|低内存先用1个Worker；auto按CPU而不是内存|write|advanced-capacity
advanced|3|选择非 root 服务账户|自动检测或手工选择已有合格服务账户|不创建用户；拒绝root及高权限/可交互登录账户|warn|advanced-user
advanced|4|其他 Nginx 参数|按编号设置Keepalive、TLS、HTTP/2及超时|每项显示当前值、单位、范围和影响|nav|menu:nginxparams
advanced|5|Xray 文件描述符上限|调整Xray的systemd LimitNOFILE|变更后需重启Xray，代理连接可能中断|warn|advanced-xray
advanced|6|恢复高级默认值|只恢复Nginx/Xray高级参数|保留节点、证书和网站；可能重启相关服务|warn|advanced-defaults
advanced|7|查看可复用服务账户|列出自动候选账户的UID及资格检查结果|只读；不会创建、删除或修改系统账户|read|advanced-users
advanced|8|非root与沙箱启动预检|独立UNIX套接字测试身份、静态读取和上传缓冲|不重启正式服务；会短暂启动受限测试进程|warn|advanced-preflight
nginxparams|1|HTTP Keepalive|空闲HTTP连接保留时间|5–300 秒；影响普通HTTP复用，不是WS连接寿命|write|param:keepalive
nginxparams|2|Keepalive 请求数|单连接最多处理的请求数|100–100000 次；过大不是无条件更快|write|param:keepalive_requests
nginxparams|3|TLS 会话缓存|共享TLS会话缓存容量|1–128 MiB；修改后重载验证，按内存设置|write|param:ssl_cache
nginxparams|4|TLS 会话复用时间|可复用TLS会话的有效时间|1–1440 分钟；不是HTTP连接超时|write|param:ssl_timeout
nginxparams|5|HTTP/2 开关|控制网站是否启用HTTP/2|true/false；存在启用XHTTP时仍保留HTTP/2|write|param:http2
nginxparams|6|请求头超时|读取客户端请求头的超时|5–300 秒；过短会影响弱网访问|write|param:client_header_timeout
nginxparams|7|普通请求体超时|读取网站请求体的空闲超时|5–3600 秒；节点流量有独立超时|write|param:client_body_timeout
nginxparams|8|网站响应发送超时|向客户端发送响应的空闲超时|5–3600 秒；不是整个文件下载总时长|write|param:send_timeout
nginxparams|9|连接上游超时|连接本机反向代理上游的等待时间|1–60 秒；本机上游通常无需设置很大|write|param:proxy_connect_timeout
nginxparams|10|节点上游读取超时|WS/XHTTP上游读取空闲超时|30–86400 秒；依据心跳和客户端行为设置|write|param:proxy_read_timeout
nginxparams|11|节点上游写入超时|WS/XHTTP上游发送空闲超时|30–86400 秒；保持与客户端行为协调|write|param:proxy_send_timeout
nginxparams|12|普通网站反代超时|本机应用的读写空闲超时|5–3600 秒；与节点长连接参数分开|write|param:site_proxy_timeout
nginxparams|13|普通网站上传上限|限制普通站点单请求体大小|1–4096 MiB；XHTTP节点不套用此限制|write|param:client_max_body_mb
nginxparams|14|网站访问日志开关|开启或关闭低开销性能访问日志|true/false；按所选模式记录耗时，不记录IP和路径|write|param:access_log
nginxparams|15|Worker 优雅退出期限|reload后旧Worker最多等待的时间|0–3600 秒；0不强制截止，非0可能断开长连接|write|param:worker_shutdown_timeout
nginxparams|16|网站上游连接池|每Worker保留的应用上游空闲连接数|0–128；0关闭；并非最大上游连接总数|write|param:upstream_keepalive
nginxparams|17|启动校验等待时间|容忍低配VPS和服务启动延迟|5–180 秒；不跳过身份和实际文件数检查|write|param:startup_timeout
nginxparams|18|服务沙箱模式|编号选择兼容或严格隔离，先预检再切换|1兼容/2严格；Worker保持非root，私钥保持root私有|warn|param:sandbox_mode
history|1|列出历史快照|显示快照时间、备注和版本|只读；快照含敏感凭据，不要公开|read|history-list
history|2|立即创建快照|保存当前配置、证书及ACME资料|当前state.json须有效；不备份网站内容|write|history-save
history|3|恢复配置与证书|从历史恢复配置及证书，验证后应用|现有程序必须满足依赖；可能重启服务|warn|history-full
history|4|仅恢复高级参数|取回旧的Nginx/Xray参数|保留当前节点、证书和网站；状态文件须有效|warn|history-advanced
history|5|回滚最近事务|恢复上一次操作前配置，可能含组件程序|将重启之前运行的服务；需有最近事务备份|warn|rollback
history|6|恢复中断事务|处理掉线或失败留下的未完成事务|检测到残留事务时优先执行此项|warn|repair
history|7|只恢复状态配置|使用历史节点/网站设置及当前证书重新生成|当前证书及组件必须满足历史配置要求|warn|history-state
history|8|查看当前部署进度|核对现有历史参数和向导完成情况|只读；不会重置部署|read|wizard-status
history|9|强制恢复（原样或兼容）|按序号选择事务或快照，不重新生成代理配置|绕过未完成事务门禁；保留失败现场；不绕过语法检查|danger|recover
main|16|资源、稳定性与轻量日志|预览服务变动、资源预设、缓冲策略与日志治理|不自动改变协议/内核；参数变化才按需应用|nav|menu:efficiency
main|17|简化重建 Nginx|当前备份→验证→只重建Nginx→成功后清旧历史|将重启Nginx；只清VPSKit已识别记录，保留本次备份|danger|rebuild
nodes|15|批量启停节点|按编号多选节点，一次提交并应用|若改变Xray配置会影响本实例连接；0取消|warn|node-batch
optimize|7|资源、稳定性与轻量日志|统一管理低开销与性能策略|预设需确认；只改指定字段，保留账户与协议|nav|menu:efficiency
advanced|9|资源与日志设置|容量、Xray空闲、连接缓冲、日志模式|先看当前值和动作预览；不保证所有链路提速|nav|menu:efficiency
efficiency|1|当前资源策略|显示保存的Nginx/Xray和日志设置|只读；不是进程内存硬上限|read|perf-show
efficiency|2|应用前差异预览|比较配置/证书/程序和服务单元|不启动测试实例，不重启/重载，不写状态|read|runtime-plan
efficiency|3|选择资源预设|节省资源、均衡或吞吐试验|列出将覆盖的参数；确认后一次应用|warn|perf-profile
efficiency|4|网站轻量性能日志|关闭、故障、抽样或全部网站请求|代理路径默认不记录；无URL/IP/查询串，非完整审计日志|write|perf-logging
efficiency|5|Xray空闲与缓冲|编号选择缓冲，设置双向空闲上限|修改需要重启Xray；缓冲不是TCP窗口|warn|perf-xray
efficiency|6|XHTTP上游连接池|每Worker每入口保留少量空闲连接|0～64；不缓存代理数据，不修改传输模式|write|param:xhttp_keepalive
efficiency|7|上游空闲连接回收|限制网站/XHTTP连接池的空闲时间|1～60秒；旧Nginx低于1.15.3时使用模块默认|write|param:upstream_idle
efficiency|8|网站压缩级别|轻量文本gzip强度|1～5；仅实际启用gzip的位置生效|write|param:gzip_level
efficiency|9|应用网站压缩|独立控制普通反向代理响应gzip|默认关闭；敏感动态页面需评估压缩侧信道风险|warn|param:proxy_gzip
efficiency|10|日志保留阈值|设置触发值、保留尾部和份数|小时检查不是实时硬上限；旧字节会被丢弃|write|perf-retention
efficiency|11|立即检查日志大小|仅轮转达到阈值的本工具日志|不压缩、不重启；并发写入可能丢少量日志|warn|perf-rotate
efficiency|12|近期服务变更原因|查看按需记录的动作和前后PID|只读；仅本版应用流程的服务变动|read|perf-events
efficiency|13|网站权限修复|显式修复上传文件的读取权限|不重启服务；扫描网站树并拒绝不安全链接|warn|perf-permissions
efficiency|0|返回上一级|不修改任何配置|未保存的输入不提交|back|back
main|0|退出面板|不修改任何配置|未保存的当前输入不提交|back|back
install|0|返回上一级|不修改任何配置|未保存的当前输入不提交|back|back
nodes|0|返回上一级|不修改任何配置|未保存的当前输入不提交|back|back
websites|0|返回上一级|不修改任何配置|未保存的当前输入不提交|back|back
optimize|0|返回上一级|不修改任何配置|未保存的当前输入不提交|back|back
update|0|返回上一级|不修改任何配置|未保存的当前输入不提交|back|back
status|0|返回上一级|不修改任何配置|未保存的当前输入不提交|back|back
services|0|返回上一级|不修改任何配置|未保存的当前输入不提交|back|back
uninstall|0|返回上一级|不修改任何配置|未保存的当前输入不提交|back|back
help|0|返回上一级|不修改任何配置|未保存的当前输入不提交|back|back
firewall|0|返回上一级|不修改任何配置|未保存的当前输入不提交|back|back
swap|0|返回上一级|不修改任何配置|未保存的当前输入不提交|back|back
edge|0|返回上一级|不修改任何配置|未保存的当前输入不提交|back|back
advanced|0|返回上一级|不修改任何配置|未保存的当前输入不提交|back|back
nginxparams|0|返回上一级|不修改任何配置|未保存的当前输入不提交|back|back
history|0|返回上一级|不修改任何配置|未保存的当前输入不提交|back|back
VPSKIT_MENU_CATALOG
}

# Colors are presentation-only: JSON, node URIs and on-disk logs stay plain.
COLOR_MODE=${VPSKIT_COLOR:-auto}
RED='' GREEN='' YELLOW='' BLUE='' CYAN='' MAGENTA='' BOLD='' DIM='' RESET=''
colors() {
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' MAGENTA='' BOLD='' DIM='' RESET=''
    [[ -z ${NO_COLOR:-} && $COLOR_MODE != never ]] || return 0
    if [[ $COLOR_MODE == always || ( -t 1 && ${TERM:-dumb} != dumb ) ]]; then
        RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
        BLUE=$'\033[94m'; CYAN=$'\033[96m'; MAGENTA=$'\033[95m'
        BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
    fi
}
ui_title() { printf '\n%s%s%s%s\n%s%s%s\n' "$BOLD" "$MAGENTA" "$1" "$RESET" "$DIM" '--------------------------------------------------------------------' "$RESET"; }
ui_note() { printf '  %s%s%s\n' "$DIM" "$*" "$RESET"; }
ui_status() {
    local label=$1 state=$2 c=$YELLOW
    case "$state" in active|running|正常|已安装) c=$GREEN;; failed|异常|损坏) c=$RED;; esac
    printf '  %s：%s%s%s\n' "$label" "$c" "$state" "$RESET"
}
s1_base_menu_title() {
    case "$1" in
        main) printf '主面板';; install) printf '部署与安装';; nodes) printf '节点与用户';;
        websites) printf '网站与证书';; optimize) printf '网络与网站优化';; update) printf '组件更新';;
        status) printf '状态、日志与维护';; services) printf '服务控制';; uninstall) printf '卸载管理';;
        help) printf '方案说明与帮助';; firewall) printf '防火墙端口管理';; swap) printf 'Swap 虚拟内存';;
        edge) printf '方案 B 防护与流量';; advanced) printf '高级配置 · Nginx / Xray';;
        efficiency) printf '资源、稳定性与轻量日志';;
        nginxparams) printf 'Nginx 参数设置';; history) printf '历史配置和恢复';;
        *) return 1;;
    esac
}
# Read-only, bounded status snapshot. No setup, writes, modprobe, requests, or
# service actions are allowed here. Config flags never prove a live process has
# loaded them. Refresh once per render; all menu badges use this same snapshot.
declare -A PANEL_TEXT=() PANEL_LEVEL=() PANEL_RAW=()
PANEL_DATA='' PANEL_TIME='' PANEL_PROC='/proc'
PANEL_BBR_CONF='/etc/sysctl.d/90-vpskit.conf'
PANEL_LEGACY_SWAP='/var/lib/vpskit/swapfile'
s3_prev_panel_clean() { printf '%s' "$*" | LC_ALL=C tr -d '\000-\037\177'; }
s3_prev_panel_put() {
    local key=$1 level=$2; shift 2
    PANEL_TEXT["$key"]=$(panel_clean "$*"); PANEL_LEVEL["$key"]=$level
}
panel_color() {
    case "$1" in good) printf '%s' "$GREEN";; bad) printf '%s' "$RED";;
        off) printf '%s' "$DIM";; info) printf '%s' "$CYAN";; *) printf '%s' "$YELLOW";; esac
}
s3_prev_panel_badge() {
    local key=$1 c
    [[ -n ${PANEL_TEXT[$key]:-} ]] || return 0
    c=$(panel_color "${PANEL_LEVEL[$key]:-warn}")
    printf '%s[当前：%s]%s' "$c" "${PANEL_TEXT[$key]}" "$RESET"
}
panel_line() { printf '  %s：' "$1"; panel_badge "$2"; printf '\n'; }
panel_exec() {
    # Never let a disconnected system bus or NSS helper freeze the panel.
    command -v timeout >/dev/null 2>&1 && command -v "$1" >/dev/null 2>&1 || return 127
    timeout --signal=TERM --kill-after=1s 2s "$@"
}
panel_jq() { jq -r "$1" <<< "$PANEL_DATA" 2>/dev/null; }
s3_prev_panel_read_state() {
    local row k v
    PANEL_DATA=''
    if ! command -v jq >/dev/null 2>&1; then panel_put config warn '无法读取：缺少 jq'; return 0; fi
    if [[ ! -e $STATE ]]; then
        if [[ -d ${STATE%/*} && ! -x ${STATE%/*} ]] || [[ -d $ROOT && ! -x $ROOT ]]; then
            panel_put config warn '无权限读取（不是未配置）'
        else panel_put config off '尚未初始化'; fi
        return 0
    fi
    if [[ ! -r $STATE ]]; then panel_put config warn '无权限读取'; return 0; fi
    if ! state_basic "$STATE" 2>/dev/null; then panel_put config bad '损坏或格式无效；请从历史恢复'; return 0; fi
    # Copy only non-secret summary fields. No passwords, paths, keys or tokens.
    if ! PANEL_DATA=$(jq -ce --argjson defaults "$(nginx_defaults)" --argjson xr "$(xray_defaults)" --argjson lg "$(logging_defaults)" '
      . as $s | ($s.advanced.nginx // {}) as $n |
      {scheme:($s.scheme // "A"),step:($s.wizard.last_step // "未记录"),
       components:($s.components|{nginx,xray,acme}),versions:($s.versions // {}|{nginx,xray,acme}),
       nginx:(($defaults * $n) | if ($n.access_log==true and ($n|has("access_log_mode")|not)) then .access_log_mode="full" else . end),xray_nofile:($s.advanced.xray.nofile // 8192),
       xray:($xr * ($s.advanced.xray // {})),logging:($lg * ($s.advanced.logging // {})),
       gzip:($s.performance.gzip // false),
       nodes:{total:($s.nodes|length),on:([$s.nodes[]|select(.enabled==true)]|length),
              off:([$s.nodes[]|select(.enabled!=true)]|length),
              xhttp:([$s.nodes[]|select(.enabled==true and .mode=="xhttp")]|length)},
       sites:[$s.sites[] | (.protection // {}) as $p |
         {domain,kind:(.kind // "custom"),issued:(.issued==true),pending:(.cert_settings_pending==true),
          access:(.access // "direct"),bots:($p.bots // "off"),rate:($p.rate // 0),
          connections:($p.connections // 0),kbps:($p.kbps // 0),static_ttl:($p.static_ttl // 0),
          gzip:(if ($p|has("gzip")) then $p.gzip else ($s.performance.gzip // false) end),
          override:($p|has("gzip")),origin:($p.origin // false),aop:($p.aop // "off")}]
      }' "$STATE" 2>/dev/null); then
        PANEL_DATA=''; panel_put config bad '配置字段异常；状态汇总不可用'; return 0
    fi
    panel_put config good '已读取历史配置（未写入）'
    while IFS=$'\t' read -r k v; do PANEL_RAW["cfg.$k"]=$v; done < <(
        jq -r '.nginx|to_entries[]|[.key,(.value|tostring)]|@tsv' <<< "$PANEL_DATA")
    PANEL_RAW[nodes.total]=$(panel_jq '.nodes.total'); PANEL_RAW[nodes.on]=$(panel_jq '.nodes.on')
    PANEL_RAW[nodes.off]=$(panel_jq '.nodes.off'); PANEL_RAW[nodes.xhttp]=$(panel_jq '.nodes.xhttp')
    PANEL_RAW[sites.total]=$(panel_jq '.sites|length')
    panel_put nodes info "配置启用 ${PANEL_RAW[nodes.on]} / ${PANEL_RAW[nodes.total]}；停用 ${PANEL_RAW[nodes.off]}"
    panel_put sites info "网站 ${PANEL_RAW[sites.total]}；证书登记 $(panel_jq '[.sites[]|select(.issued)]|length')（非有效期检查）"
    panel_put wizard info "方案 $(panel_jq '.scheme')；进度 $(panel_jq '.step')"
    for k in nginx xray acme; do
        PANEL_RAW["component.$k"]=$(panel_jq ".components.$k == true")
        PANEL_RAW["version.$k"]=$(panel_jq ".versions.$k // \"未记录\"")
    done
    # Numeric values are explicitly labelled saved, never actual run-time limits.
    panel_put capacity info "配置 Worker=${PANEL_RAW[cfg.workers]}；连接/Worker=${PANEL_RAW[cfg.connections]}；FD=${PANEL_RAW[cfg.nofile]}"
    panel_put worker.config info "配置账户 ${PANEL_RAW[cfg.resolved_user]:-${PANEL_RAW[cfg.worker_user]:-auto}}（自动模式不创建账户）"
    panel_put xray.nofile info "保存值 $(panel_jq '.xray_nofile')；实际进程值未核验"
    panel_put gzip off '全局配置关闭'
    [[ $(panel_jq '.gzip') != true ]] || panel_put gzip good '全局配置开启'
    local static_count enabled overrides
    static_count=$(panel_jq '[.sites[]|select(.kind=="template" or .kind=="custom")]|length')
    enabled=$(panel_jq '[.sites[]|select((.kind=="template" or .kind=="custom") and .gzip==true)]|length')
    overrides=$(panel_jq '[.sites[]|select((.kind=="template" or .kind=="custom") and .override)]|length')
    PANEL_TEXT[gzip]+="；静态站配置开启 $enabled/$static_count（单站覆盖 $overrides）"
    [[ $static_count == 0 || $enabled == 0 || $enabled == "$static_count" ]] || PANEL_LEVEL[gzip]=warn
    for k in keepalive keepalive_requests ssl_cache ssl_timeout http2 client_header_timeout client_body_timeout send_timeout proxy_connect_timeout proxy_read_timeout proxy_send_timeout site_proxy_timeout client_max_body_mb access_log worker_shutdown_timeout upstream_keepalive startup_timeout sandbox_mode; do
        v=${PANEL_RAW[cfg.$k]:-未知}
        case "$k" in
            http2|access_log)
                if [[ $v == true ]]; then panel_put "param.$k" good '配置开启'
                elif [[ $v == false ]]; then panel_put "param.$k" off '配置关闭'
                else panel_put "param.$k" warn "配置值异常 $v"; fi;;
            worker_shutdown_timeout) if [[ $v == 0 ]]; then panel_put "param.$k" off '配置关闭强制截止（0秒）'; else panel_put "param.$k" info "保存值 $v 秒"; fi;;
            upstream_keepalive) if [[ $v == 0 ]]; then panel_put "param.$k" off '配置关闭（0）'; else panel_put "param.$k" info "保存值 $v 个空闲连接/Worker"; fi;;
            ssl_cache|client_max_body_mb) panel_put "param.$k" info "保存值 $v MiB";;
            ssl_timeout) panel_put "param.$k" info "保存值 $v 分钟";;
            sandbox_mode) panel_put "param.$k" info "保存模式 $v（新配置仍要求非root Worker）";;
            keepalive_requests) panel_put "param.$k" info "保存值 $v 次";;
            *) panel_put "param.$k" info "保存值 $v 秒";;
        esac
    done
    if [[ ${PANEL_RAW[nodes.xhttp]} != 0 && ${PANEL_RAW[cfg.http2]} == false ]]; then
        panel_put param.http2 warn '网站开关关闭；启用的 XHTTP 会要求生成 HTTP/2 配置'
    fi
    # Multi-site policies are summarized as counts; zero sites is not "all off".
    local total=${PANEL_RAW[sites.total]} count expr label
    for k in bots limits cache origin aop; do
        if [[ $total == 0 ]]; then panel_put "edge.$k" off '尚无网站'; continue; fi
        case "$k" in
            bots) expr='.bots!="off"'; label='爬虫策略';;
            limits) expr='.rate>0 or .connections>0 or .kbps>0'; label='至少一项限额';;
            cache) expr='(.kind=="template" or .kind=="custom") and .static_ttl>0'; label='静态缓存';;
            origin) expr='.origin==true'; label='仅 Cloudflare 回源';;
            aop)
                panel_put edge.aop info "配置强制 $(panel_jq '[.sites[]|select(.aop=="enforce")]|length')；观察 $(panel_jq '[.sites[]|select(.aop=="observe")]|length')；关闭 $(panel_jq '[.sites[]|select(.aop=="off")]|length')"
                continue;;
        esac
        if count=$(panel_jq "[.sites[]|select($expr)]|length"); then
            if [[ $count == 0 ]]; then panel_put "edge.$k" off "$label：配置全部关闭（0/$total）"
            elif [[ $count == "$total" ]]; then panel_put "edge.$k" good "$label：配置全部开启（$count/$total）"
            else panel_put "edge.$k" warn "$label：部分配置开启（$count/$total）"; fi
        else panel_put "edge.$k" warn '设置格式异常，无法汇总'; fi
    done
    PANEL_TEXT[edge.cache]+="；静态站 gzip $enabled/$static_count"
}
s1_base_panel_system_data() {
    panel_exec systemctl show --no-pager \
      -p Id -p LoadState -p ActiveState -p SubState -p UnitFileState -p MainPID -p Result \
      vpskit-nginx.service vpskit-xray.service vpskit-maintain.timer vpskit-maintain.service
}
s1_base_panel_service_block() {
    local id=$1 load=$2 active=$3 sub=$4 boot=$5 pid=$6 result=$7 k
    case "$id" in vpskit-nginx.service) k=nginx;; vpskit-xray.service) k=xray;;
        vpskit-maintain.timer) k=timer;; vpskit-maintain.service) k=maintain;; *) return 0;; esac
    PANEL_RAW["$k.load"]=$load; PANEL_RAW["$k.active"]=$active; PANEL_RAW["$k.sub"]=$sub
    PANEL_RAW["$k.pid"]=$pid; PANEL_RAW["$k.boot"]=$boot
    case "$active" in
        failed) panel_put "service.$k" bad "故障（$sub；${result:-原因未记录}）";;
        activating) panel_put "service.$k" warn "启动中（$sub）";;
        deactivating) panel_put "service.$k" warn "停止中（$sub）";;
        reloading|refreshing) panel_put "service.$k" warn '运行中，正在重载';;
        active)
            if [[ $k == timer ]]; then panel_put "service.$k" good "已启用（$sub）"
            elif [[ $sub == running && $pid =~ ^[1-9][0-9]*$ ]]; then panel_put "service.$k" good "运行中（PID $pid）"
            elif [[ $k == maintain && $sub == exited ]]; then panel_put "service.$k" good '本次维护已完成（不是常驻进程）'
            else panel_put "service.$k" warn "已激活（$sub；非已确认 running）"; fi;;
        inactive)
            if [[ $load == not-found ]]; then panel_put "service.$k" off '未创建服务'
            elif [[ $k == maintain && $result == success ]]; then panel_put "service.$k" off '空闲（上次结果 success）'
            elif [[ $k == timer ]]; then panel_put "service.$k" off '已关闭（未调度）'
            else panel_put "service.$k" warn '已停止'; fi;;
        *) panel_put "service.$k" warn "状态未知（${active:-未返回}）";;
    esac
    # Loaded/enabled is independent of running. A masked unit can still be active.
    case "$boot" in
        enabled) panel_put "boot.$k" good '开启';;
        enabled-runtime) panel_put "boot.$k" warn '仅本次启动有效';;
        disabled) panel_put "boot.$k" off '关闭';;
        masked|masked-runtime) panel_put "boot.$k" warn '已屏蔽';;
        static|indirect) panel_put "boot.$k" info '由依赖/触发器管理';;
        linked|linked-runtime) panel_put "boot.$k" warn '已链接（不代表自启）';;
        *) panel_put "boot.$k" warn '未知/不适用';;
    esac
    if [[ $load == error || $load == bad-setting ]]; then
        panel_put "service.$k" bad "单元加载异常（$load；运行状态 $active）"
    elif [[ $load == masked && $active != active ]]; then panel_put "service.$k" warn '服务被屏蔽'; fi
}
panel_services() {
    local k output='' line key val id='' load='' active='' sub='' boot='' pid='' result=''
    for k in nginx xray timer maintain; do
        panel_put "service.$k" warn '无法查询（systemd 不可用/权限不足/超时）'
        panel_put "boot.$k" warn '未知'
    done
    # Parse property names, never depend on property ordering or --value order.
    if output=$(panel_system_data 2>/dev/null); then :; else :; fi
    while IFS= read -r line; do
        if [[ -z $line ]]; then
            panel_service_block "$id" "$load" "$active" "$sub" "$boot" "$pid" "$result"
            id=''; load=''; active=''; sub=''; boot=''; pid=''; result=''; continue
        fi
        key=${line%%=*}; val=${line#*=}
        case "$key" in Id) id=$val;; LoadState) load=$val;; ActiveState) active=$val;;
            SubState) sub=$val;; UnitFileState) boot=$val;; MainPID) pid=$val;; Result) result=$val;; esac
    done <<< "$output"$'\n'
}
panel_components() {
    local k file flag parent
    for k in nginx xray acme; do
        case "$k" in nginx) file=$NGINX;; xray) file=$XRAY;; acme) file=$ACME;; esac
        flag=${PANEL_RAW[component.$k]:-unknown}; parent=${file%/*}
        if [[ -x $file && ! -L $file ]]; then
            if [[ $flag == true ]]; then panel_put "component.$k" good "已安装；记录版本 ${PANEL_RAW[version.$k]:-未知}"
            else panel_put "component.$k" warn '程序存在；未登记/配置不可读'; fi
        elif [[ -d $parent && ! -x $parent ]] || [[ -d $ROOT && ! -x $ROOT ]]; then panel_put "component.$k" warn '无权限检查程序'
        elif [[ $flag == true ]]; then panel_put "component.$k" bad '已登记但程序缺失/不可执行'
        elif [[ -e $file || -L $file ]]; then panel_put "component.$k" warn '程序文件异常（非可执行普通文件）'
        else panel_put "component.$k" off '未安装'; fi
    done
}
s1_base_panel_workers() {
    local master=${PANEL_RAW[nginx.pid]:-} output pid uid args current=0 retiring=0 root_workers=0 uids='' fd limits='' fd_ok=true expected=${PANEL_RAW[cfg.workers]:-auto}
    panel_put worker.actual warn '无法核验（服务状态/进程不可读）'
    if [[ ${PANEL_RAW[nginx.active]:-} == inactive ]]; then panel_put worker.actual off '服务已停止，0 个 Worker'; return 0; fi
    [[ $master =~ ^[1-9][0-9]*$ ]] || return 0
    if ! output=$(panel_exec ps -ww --ppid "$master" -o pid=,uid=,args= 2>/dev/null); then return 0; fi
    while read -r pid uid args; do
        [[ $pid =~ ^[1-9][0-9]*$ && $uid =~ ^[0-9]+$ && $args == 'nginx: worker process'* ]] || continue
        if [[ $args == *'is shutting down'* ]]; then
            retiring=$((retiring+1)); [[ $uid != 0 ]] || root_workers=$((root_workers+1)); continue
        fi
        [[ $args != *'exiting'* ]] || continue
        current=$((current+1)); [[ $uid != 0 ]] || root_workers=$((root_workers+1))
        [[ " $uids " == *" $uid "* ]] || uids="${uids:+$uids }$uid"
        if [[ -r $PANEL_PROC/$pid/limits ]] && fd=$(awk '/^Max open files/{print $4;exit}' "$PANEL_PROC/$pid/limits" 2>/dev/null) && [[ -n $fd ]]; then
            [[ " $limits " == *" $fd "* ]] || limits="${limits:+$limits }$fd"
        else fd_ok=false; fi
    done <<< "$output"
    if ((root_workers>0)); then panel_put worker.actual bad "检测到 $root_workers 个 root Worker（应降权）"
    elif ((current==0)); then panel_put worker.actual warn "未观察到接入 Worker；正在退出 $retiring"
    else panel_put worker.actual good "接入 Worker $current；退出中 $retiring；UID $uids"; fi
    PANEL_RAW[worker.actual]=$current
    if [[ $expected != auto && $expected =~ ^[0-9]{1,3}$ ]] && ((current != 10#$expected)); then
        PANEL_TEXT[worker.actual]+="；与保存数量 ${PANEL_RAW[cfg.workers]} 不同"
        [[ ${PANEL_LEVEL[worker.actual]} == bad ]] || PANEL_LEVEL[worker.actual]=warn
    fi
    if ((current>0)) && [[ $fd_ok == true ]]; then panel_put worker.fd info "观测软上限 $limits（仅当前接入 Worker）"
    else panel_put worker.fd warn '实际 Worker FD 上限无法核验'; fi
}
panel_read_sysctl() {
    local path="$PANEL_PROC/sys/${1//./\/}" value
    if [[ -r $path ]] && IFS= read -r value < "$path"; then printf '%s' "$value"
    else panel_exec sysctl -n "$1" 2>/dev/null; fi
}
panel_bbr() {
    local cc='' q='' available='' record="$ROOT/data/bbr-v2.json" managed=false
    if cc=$(panel_read_sysctl net.ipv4.tcp_congestion_control); then :; else cc=''; fi
    if q=$(panel_read_sysctl net.core.default_qdisc); then :; else q=''; fi
    if available=$(panel_read_sysctl net.ipv4.tcp_available_congestion_control); then :; else available=''; fi
    PANEL_RAW[bbr.cc]=$cc; PANEL_RAW[bbr.qdisc]=$q
    if [[ -z $cc ]]; then panel_put bbr warn '未知（无法读取内核拥塞控制）'
    elif [[ $cc == bbr || $cc =~ ^bbr[0-9]+$ ]]; then
        if [[ $q == fq ]]; then panel_put bbr good "已开启（内核默认 $cc；默认队列 fq）"
        else panel_put bbr warn "BBR 已开启；默认队列 ${q:-未知}（未确认 fq）"; fi
    else panel_put bbr off "未开启（内核默认 $cc；默认队列 ${q:-未知}）"; fi
    if [[ -z $available ]]; then panel_put bbr.available warn '内核可用算法列表无法读取'
    elif [[ " $available " == *' bbr '* ]]; then panel_put bbr.available good '内核可用列表包含 bbr'
    else panel_put bbr.available warn '可用列表暂无 bbr；可能尚未加载模块，不能据此断定不支持'; fi
    if [[ -r $record && ! -L $record ]] && command -v jq >/dev/null 2>&1 &&
       jq -e '.owner=="VPSKIT_BBR_V2" and (.before.cc|type=="string") and (.before.qdisc|type=="string")' "$record" >/dev/null 2>&1; then
        if [[ -f $PANEL_BBR_CONF && ! -L $PANEL_BBR_CONF ]] && grep -Fxq '# VPSKIT_OWNED BBR_V2' "$PANEL_BBR_CONF" 2>/dev/null; then
            managed=true
            if [[ $cc == bbr && $q == fq ]]; then panel_put bbr.managed good '有本工具恢复记录；撤销前仍会核对'
            else panel_put bbr.managed warn '有恢复记录，但运行值不同/未知；不能直接认定可撤销'; fi
        else panel_put bbr.managed warn '有恢复记录；持久化文件缺失/归属待核对'; fi
    elif [[ -e $record ]]; then panel_put bbr.managed warn '记录损坏或无权限；不可自动判断'
    else panel_put bbr.managed off '无本版托管记录（不表示 BBR 关闭）'; fi
    PANEL_RAW[bbr.managed]=$managed
    local switch='未知'
    if [[ -n $cc ]]; then
        if [[ $cc == bbr || $cc =~ ^bbr[0-9]+$ ]]; then switch='开启'; else switch='关闭'; fi
    fi
    panel_put bbr.restore "${PANEL_LEVEL[bbr.managed]}" "BBR $switch；${PANEL_TEXT[bbr.managed]}"
}
panel_resources() {
    local values total available swap_total swap_free
    if values=$(awk '/^MemTotal:/{t=$2}/^MemAvailable:/{a=$2}/^SwapTotal:/{s=$2}/^SwapFree:/{f=$2} END{if(t>0) printf "%d %d %d %d",t,a,s,f;else exit 1}' "$PANEL_PROC/meminfo" 2>/dev/null); then
        read -r total available swap_total swap_free <<< "$values"
        panel_put resources info "内存可用 $((available/1024))/$((total/1024)) MiB；Swap已用 $(((swap_total-swap_free)/1024))/$((swap_total/1024)) MiB"
    else panel_put resources warn '无法读取系统内存信息'; fi
}
panel_swap() {
    local output='' file='' count size record="$ROOT/data/swap-v2.json" row
    if ! output=$(awk 'NR>1{print $1"\t"$3"\t"$4}' "$PANEL_PROC/swaps" 2>/dev/null); then
        panel_put swap warn '无法读取实际 Swap 状态'; panel_put swap.managed warn '无法读取实际 Swap 状态'; return 0
    fi
    count=$(awk 'NF{n++}END{print n+0}' <<< "$output")
    size=$(awk '{s+=$2}END{printf "%.0f",s/1024}' <<< "$output")
    if [[ $count == 0 ]]; then panel_put swap off '系统 Swap 未开启'
    else panel_put swap good "系统已开启 $count 项，合计 $size MiB"; fi
    if [[ -e $record ]]; then
        if [[ ! -L $record && -r $record ]] && command -v jq >/dev/null 2>&1 &&
           file=$(jq -er 'select(.owner=="VPSKIT_SWAP_V2")|.file|select(type=="string")' "$record" 2>/dev/null); then
            if [[ $file != "$ROOT/swap/swapfile" && $file != "$PANEL_LEGACY_SWAP" ]]; then panel_put swap.managed warn '托管记录路径异常；未操作'; return 0; fi
            if awk -v f="$file" '$1==f{ok=1}END{exit !ok}' <<< "$output"; then panel_put swap.managed good '本工具 Swap 已开启'
            elif [[ -f $file ]]; then panel_put swap.managed off '托管文件存在，当前未启用'
            else panel_put swap.managed warn '有托管记录，文件缺失且未启用'; fi
        else panel_put swap.managed warn '托管记录无效/不可读'; fi
    elif [[ -e $ROOT/swap/swapfile || -e $PANEL_LEGACY_SWAP ]]; then panel_put swap.managed warn '发现旧 Swap 文件；进入状态项核对归属'
    else panel_put swap.managed off '未创建本版托管 Swap'; fi
}
panel_firewall() {
    local uf=absent ff=absent output=''
    if command -v ufw >/dev/null 2>&1; then
        if output=$(panel_exec ufw status 2>/dev/null); then
            case "$output" in *'Status: active'*) uf=on;; *'Status: inactive'*) uf=off;; *) uf=unknown;; esac
        else uf=unknown; fi
    fi
    if command -v firewall-cmd >/dev/null 2>&1; then
        if output=$(panel_exec firewall-cmd --state 2>&1); then
            [[ $output != running ]] || ff=on
            [[ $ff != absent ]] || ff=unknown
        elif [[ $output == 'not running' ]]; then ff=off
        else ff=unknown; fi
    fi
    PANEL_RAW[firewall.ufw]=$uf; PANEL_RAW[firewall.firewalld]=$ff
    if [[ $uf == on && $ff == on ]]; then panel_put firewall bad 'UFW 与 firewalld 同时启用（本工具拒绝修改）'
    elif [[ $uf == unknown || $ff == unknown ]]; then panel_put firewall warn "查询不完整（UFW=$uf；firewalld=$ff）"
    elif [[ $uf == on ]]; then panel_put firewall good 'UFW 已开启'
    elif [[ $ff == on ]]; then panel_put firewall good 'firewalld 已开启'
    else panel_put firewall off '未检测到启用的 UFW/firewalld（不代表主机无防火墙）'; fi
    panel_put firewall.rules off '无本版规则记录'
    if [[ -e $ROOT/data/firewall-v2.json ]]; then
        if command -v jq >/dev/null 2>&1 && output=$(jq -er 'select(.owner=="VPSKIT_FIREWALL_V2" and .schema==2)|.rules|length' "$ROOT/data/firewall-v2.json" 2>/dev/null); then
            panel_put firewall.rules info "记录 $output 条（实际规则需进入状态项核对）"
        else panel_put firewall.rules warn '规则记录损坏/不可读'; fi
    fi
}
panel_history() {
    local count
    if [[ -d $ROOT/backup/history && -r $ROOT/backup/history && -x $ROOT/backup/history ]]; then
        count=$(find "$ROOT/backup/history" -mindepth 2 -maxdepth 2 -type f -name meta.json 2>/dev/null | wc -l)
        panel_put history info "发现 $count 份快照目录（尚未做完整性校验）"
    elif [[ -d $ROOT/backup/history ]]; then panel_put history warn '无权限读取历史目录'
    else panel_put history off '暂无历史快照'; fi
    if [[ -d $ROOT/backup/transaction ]]; then panel_put transaction bad '存在未完成事务；请优先恢复'
    else panel_put transaction good '未发现未完成事务'; fi
    if [[ -d $ROOT/backup/last ]]; then panel_put rollback info '存在最近事务备份（恢复时校验）'
    else panel_put rollback off '没有最近事务备份'; fi
}
s3_prev_panel_collect() {
    local group=${1:-all}
    PANEL_TEXT=(); PANEL_LEVEL=(); PANEL_RAW=(); PANEL_DATA=''
    PANEL_TIME=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
    panel_read_state
    if [[ -z $PANEL_DATA ]]; then
        local k
        for k in nodes sites wizard capacity worker.config xray.nofile gzip edge.bots edge.limits edge.cache edge.origin edge.aop; do
            panel_put "$k" warn "无法确认：${PANEL_TEXT[config]}"
        done
        while IFS= read -r k; do panel_put "param.$k" warn "无法确认：${PANEL_TEXT[config]}"; done < <(
            menu_catalog | awk -F'|' '$7~/^param:/{sub(/^param:/,"",$7);print $7}')
    fi
    panel_services; panel_components; panel_workers
    panel_bbr; panel_resources; panel_history
    case "$group" in main|swap|status|uninstall|all) panel_swap;; esac
    case "$group" in main|firewall|status|uninstall|all) panel_firewall;; esac
    # Every parameter remains visibly a saved/configured value. No nginx -T
    # here: it reads disk, not the in-memory configuration of existing workers.
    panel_put config.live warn '保存值不等于加载值；本面板不声称已核验进程内全部配置'
    if [[ ${PANEL_RAW[nginx.active]:-} == inactive || ${PANEL_RAW[nginx.active]:-} == failed ]]; then
        panel_put config.live warn 'Nginx 未运行；已保存的开关目前不能提供服务'
    fi
}
panel_site_table() {
    [[ -n $PANEL_DATA && ${PANEL_RAW[sites.total]:-0} != 0 ]] || return 0
    ui_note '逐站保存配置（非在线效果验证；最多显示12站；完整清单见“查看网站防护”）：'
    local domain kind gzip bots rate conn cache origin aop cert line n=0 c
    while IFS=$'\t' read -r domain kind gzip bots rate conn cache origin aop cert; do
        n=$((n+1)); [[ $n -le 12 ]] || break
        c=$DIM
        [[ $gzip != 开启 && $bots == off && $rate == 0 && $conn == 0 && $origin != 开启 && $aop == off ]] || c=$CYAN
        line=$(panel_clean "$domain [$kind] gzip=$gzip 爬虫=$bots 频率=$rate/s 并发=$conn 缓存=${cache}s 回源限制=$origin AOP=$aop TLS=$cert")
        printf '    %s%s%s\n' "$c" "$line" "$RESET"
    done < <(jq -r '.sites[]|[.domain,.kind,(if .kind=="proxy" or .kind=="redirect" then "不适用" elif .gzip then "开启" else "关闭" end),.bots,.rate,.connections,.static_ttl,(if .origin then "开启" else "关闭" end),.aop,(if .issued then "已登记" else "未签发" end)]|@tsv' <<< "$PANEL_DATA" 2>/dev/null)
}
panel_service_line() {
    local k=$1 label=$2
    printf '  %s：' "$label"; panel_badge "service.$k"
    printf '  自启：'; panel_badge "boot.$k"; printf '\n'
}
s1_base_panel_summary() {
    local group=${1:-main}
    ui_note "采样：$PANEL_TIME；每次进入/返回或输入 R 刷新，等待输入期间不自动采样。"
    panel_service_line nginx Nginx; panel_service_line xray Xray
    case "$group" in main|install|update|status|services|websites)
        panel_service_line timer '证书/维护定时器';;
    esac
    case "$group" in
        main)
            panel_line '状态资料' config; [[ -z $PANEL_DATA ]] || { panel_line '部署' wizard; panel_line '节点' nodes; panel_line '网站' sites; }
            panel_line '资源' resources; panel_line BBR bbr; panel_line '实际进程' worker.actual;;
        optimize)
            panel_line '资源' resources; panel_line BBR bbr; panel_line 'BBR 归属' bbr.managed
            ui_note 'BBR 显示内核默认算法；不是逐连接检查。默认队列 fq 不代表现有每张网卡都已更换队列。'
            panel_line 'Nginx 参数' capacity; panel_line '实际进程' worker.actual; panel_line '配置说明' config.live;;
        advanced|nginxparams)
            panel_line 'Nginx 参数' capacity; panel_line '账户' worker.config; panel_line '实际进程' worker.actual
            panel_line '实际文件数' worker.fd; panel_line '配置说明' config.live;;
        edge)
            panel_line '配置说明' config.live; panel_site_table;;
        firewall)
            panel_line '系统管理器' firewall; panel_line '归属记录' firewall.rules
            ui_note '这里只检测 UFW/firewalld；不判断云安全组、外部 nftables/iptables 或每个端口的公网可达性。';;
        swap) panel_line '系统 Swap' swap; panel_line '本工具 Swap' swap.managed; panel_line '资源' resources;;
        install|update|uninstall)
            panel_line 'Nginx 程序' component.nginx; panel_line 'Xray 程序' component.xray; panel_line 'ACME 程序' component.acme;;
        nodes) panel_line '节点保存状态' nodes; ui_note '节点已配置启用不等于客户端连通；还需 Xray、入口、证书及网络满足条件。';;
        websites) panel_line '网站登记' sites; panel_line 'ACME 程序' component.acme;;
        history) panel_line '快照' history; panel_line '事务' transaction; panel_line '配置读取' config;;
        status|services) panel_line '实际进程' worker.actual; panel_line '实际文件数' worker.fd; panel_line '配置说明' config.live;;
    esac
    if [[ ${PANEL_LEVEL[config]:-} == bad ]]; then panel_line '配置异常' config; fi
    if [[ ${PANEL_LEVEL[transaction]:-} == bad && $group != history ]]; then panel_line '待处理' transaction; fi
    if [[ $group == efficiency ]]; then
        panel_line '资源策略' efficiency
        panel_line 'Xray策略' efficiency.xray
        panel_line '网站日志' efficiency.log
        panel_line '日志保留' efficiency.retention
    fi
}
s3_prev_panel_route_key() {
    # A status key is explicit metadata, never an executable command.
    case "$1" in
        menu:install|install-wizard|wizard-configure|wizard-status) printf wizard;;
        menu:nodes|node-*) printf nodes;;
        menu:websites|site-*|cert-issue|cert-import|cert-settings|cert-status) printf sites;;
        cert-renew|logs-cert) printf service.timer;;
        menu:optimize|optimize-bbr) printf bbr;; optimize-restore) printf bbr.restore;;
        optimize-status) printf resources;; optimize-mtu) printf tool.tracepath;;
        performance-gzip) printf gzip;;
        install-nginx|update-nginx|uninstall-nginx) printf component.nginx;;
        install-xray|update-xray|uninstall-xray) printf component.xray;;
        install-acme|update-acme|uninstall-acme) printf component.acme;;
        menu:update|update-manager|update-all) printf code;;
        menu:status|status|doctor) printf service.nginx;;
        menu:services|logs-nginx|logs-service) printf service.nginx;;
        service:nginx:*) printf service.nginx;; service:xray:*|logs-xray) printf service.xray;;
        logs-access) printf param.access_log;;
        menu:firewall|firewall-status|firewall-open|firewall-close|firewall-sync) printf firewall;;
        firewall-cleanup) printf firewall.rules;;
        menu:swap|swap-status) printf swap;; swap-enable|swap-custom|swap-remove) printf swap.managed;;
        menu:edge|edge-status|edge-profile|edge-edit|edge-reset) printf sites;;
        edge-bots) printf edge.bots;; edge-limits) printf edge.limits;; edge-cache) printf edge.cache;;
        edge-origin) printf edge.origin;; edge-aop|edge-probe) printf edge.aop;;
        edge-refresh) printf edge.assets;; edge-traffic) printf tool.traffic;;
        menu:advanced|advanced-show|advanced-capacity|advanced-defaults|advanced-preflight) printf capacity;;
        advanced-user|advanced-users) printf worker.config;; advanced-xray) printf xray.nofile;;
        menu:efficiency|perf-profile|perf-show) printf efficiency;; perf-logging) printf efficiency.log;;
        perf-xray) printf efficiency.xray;; perf-retention|perf-rotate) printf efficiency.retention;;
        runtime-plan|perf-events|perf-permissions) printf config;; node-batch) printf nodes;;
        menu:nginxparams) printf config.live;; param:*) printf 'param.%s' "${1#param:}";;
        menu:history|history-list|history-full|history-state|history-advanced) printf history;;
        history-save|apply) printf config;; rollback) printf rollback;; repair|recover) printf transaction;;
        service:all:*) printf services.all;; system-reboot) :;; logs-diagnostics) printf diagnostics;;
        *) :;;
    esac
}
s3_prev_panel_efficiency() {
    local text
    if [[ -z $PANEL_DATA ]]; then
        for text in efficiency efficiency.log efficiency.xray efficiency.retention; do panel_put "$text" warn '无可读配置'; done
        return 0
    fi
    text=$(panel_jq '"配置 Worker=\(.nginx.workers)，连接/Worker=\(.nginx.connections)，XHTTP池=\(.nginx.xhttp_keepalive)"')
    panel_put efficiency info "$text"
    text=$(panel_jq '"配置空闲=\(.xray.conn_idle)s，缓冲=\(.xray.buffer_kb)，错误日志=\(.xray.loglevel)"')
    panel_put efficiency.xray info "$text"
    text=$(panel_jq 'if .nginx.access_log then "配置开启：\(.nginx.access_log_mode)，抽样参数\(.nginx.access_log_sample)%，\(.nginx.access_log_buffer_kb)KiB缓冲/\(.nginx.access_log_flush)s刷新" else "配置关闭；错误日志保留" end')
    panel_put efficiency.log info "$text"
    text=$(panel_jq '"配置阈值\(.logging.max_mb)MiB；每份尾部\(.logging.tail_kb)KiB×\(.logging.keep)；小时检查"')
    panel_put efficiency.retention info "$text"
}
s3_prev_panel_extras() {
    local latest_diag='' all_level=info level
    for level in "${PANEL_LEVEL[service.nginx]:-warn}" "${PANEL_LEVEL[service.xray]:-warn}"; do
        [[ $level != warn || $all_level == bad ]] || all_level=warn
        [[ $level != bad ]] || all_level=bad
    done
    panel_put services.all "$all_level" "Nginx：${PANEL_TEXT[service.nginx]:-未知}；Xray：${PANEL_TEXT[service.xray]:-未知}"
    if [[ -d $ROOT/logs/diagnostics && -x $ROOT/logs/diagnostics ]]; then
        latest_diag=$(find "$ROOT/logs/diagnostics" -maxdepth 1 -type f -name '*.log' -printf '%T@ %f\n' 2>/dev/null | sort -rn | head -n 1 || true)
    fi
    if [[ -n $latest_diag ]]; then panel_put diagnostics warn "最近诊断 ${latest_diag#* }"; else panel_put diagnostics info '暂无可读的失败诊断记录'; fi
    panel_efficiency
    panel_put code info "当前管理代码 $VERSION（不联网查询新版本）"
    if command -v tracepath >/dev/null 2>&1; then panel_put tool.tracepath good 'tracepath 已安装；仅按需探测'
    else panel_put tool.tracepath warn 'tracepath 未安装；按需安装 iputils-tracepath'; fi
    panel_put tool.traffic info '按需采样；不是常驻流量监控'
    if [[ -s $ROOT/config/edge/cf-v4.txt && -s $ROOT/config/edge/cf-v6.txt ]]; then panel_put edge.assets info '本地网段文件存在（时效/内容未核验）'
    else panel_put edge.assets warn '本地官方网段文件缺失/不可读'; fi
}
s3_prev_status_dashboard() {
    local group=${1:-main}
    menu_title "$group" >/dev/null || die '未知状态区；可用 main/optimize/advanced/edge/firewall/swap/services 等面板名。'
    panel_collect "$group"; panel_extras
    ui_title "VPSKit $VERSION  |  运行状态 · $(menu_title "$group")"
    panel_summary "$group"
}

s3_prev_menu_render() {
    local group=$1 row_group number title desc req risk route c badge key
    local heading; heading=$(menu_title "$group") || return 1
    if [[ ${2:-} != cached ]]; then panel_collect "$group"; panel_extras; fi
    ui_title "VPSKit $VERSION  |  $heading"
    panel_summary "$group"
    ui_note '蓝色=选项  绿色=只读/正常  黄色=注意  红色=危险  灰色=说明/关闭'
    while IFS='|' read -r row_group number title desc req risk route; do
        [[ $row_group == "$group" ]] || continue
        c=$BLUE; badge='设置'
        case "$risk" in read) c=$GREEN; badge='只读';; nav) c=$BLUE; badge='菜单';;
            write) c=$BLUE; badge='修改';; warn) c=$YELLOW; badge='注意';;
            danger) c=$RED; badge='危险';; sensitive) c=$YELLOW; badge='敏感';;
            back) c=$DIM; badge='返回';; esac
        printf '  %s%2s.%s %s%s%s %s[%s]%s' "$BLUE" "$number" "$RESET" "$c" "$title" "$RESET" "$c" "$badge" "$RESET"
        key=$(panel_route_key "$route")
        if [[ -n $key ]]; then printf '  '; panel_badge "$key"; fi
        printf '\n'
        printf '      %s用途：%s  |  要求：%s%s\n' "$DIM" "$desc" "$req" "$RESET"
    done < <(menu_catalog)
    ui_note '输入序号；R 刷新状态；0 返回；操作中 :q 取消后回到面板。危险操作默认不执行。'
}
s3_prev_menu_preview() {
    local group=${1:-main} g
    if [[ $group == all ]]; then
        panel_collect all; panel_extras
        while IFS= read -r g; do menu_render "$g" cached; done < <(menu_catalog | cut -d'|' -f1 | awk '!seen[$0]++')
    else menu_render "$group" || die '未知面板；使用 preview all 查看所有面板。'; fi
}
menu_run() {
    local rc answer
    # Run mutations in a fresh Bash process. Do not put the backend function in
    # `if fn`: that would suppress errexit inside it and bypass rollback guards.
    set +e
    VPSKIT_COLOR="$COLOR_MODE" bash "$SELF" "$@"
    rc=$?
    set -e
    case "$rc" in
        0) printf '\n%s[完成] 操作已结束。%s\n' "$GREEN" "$RESET";;
        130) printf '\n%s[取消] 已取消当前操作；已提交的配置保留。%s\n' "$YELLOW" "$RESET";;
        *) printf '\n%s[未完成] 退出码 %s；请阅读上方原因，再重试或进入历史恢复。%s\n' "$RED" "$rc" "$RESET";;
    esac
    if [[ ! -f $SELF ]]; then ui_note '管理脚本已卸载，退出面板。'; exit 0; fi
    ask answer '按回车返回当前菜单（:q退出面板）' ''
}
s1_base_menu_dispatch() {
    local route=$1 name action
    case "$route" in
        menu:*) menu_group "${route#menu:}";;
        param:*) menu_run advanced edit "nginx.${route#param:}";;
        service:*) name=${route#service:}; action=${name#*:}; name=${name%%:*}; menu_run service "$name" "$action";;
        install-wizard) menu_run install;; install-nginx) menu_run install nginx;; install-xray) menu_run install xray;; install-acme) menu_run install acme;;
        wizard-configure) menu_run wizard configure;; wizard-status) menu_run wizard status;;
        node-batch) menu_run node batch;; runtime-plan) menu_run plan;;
        perf-*) menu_run performance "${route#perf-}";;
        node-list) menu_run node list;; node-add) menu_run node add;; node-share) menu_run node share;;
        node-enable) menu_run node enable;; node-disable) menu_run node disable;; node-delete) menu_run node delete;;
        node-rotate) menu_run node rotate;; node-export) menu_run node export;; node-client) menu_run node client;;
        node-rename) menu_run node rename;; node-port) menu_run node port;; node-host) menu_run node host;;
        node-credential) menu_run node edit;; node-listen) menu_run node listen;;
        site-list) menu_run site list;; site-add) menu_run site add;; site-edit) menu_run site edit;; site-remove) menu_run site remove;;
        cert-issue) menu_run cert issue;; cert-status) menu_run cert status;; cert-renew) menu_run cert renew;;
        cert-settings) menu_run cert settings;; cert-import) menu_run cert import;;
        optimize-status) menu_run optimize status;; optimize-bbr) menu_run optimize bbr;; optimize-restore) menu_run optimize restore;; optimize-mtu) menu_run optimize mtu;;
        performance-gzip) menu_run performance gzip;;
        update-nginx) menu_run update nginx;; update-xray) menu_run update xray;; update-acme) menu_run update acme;;
        update-manager) menu_run update manager;; update-all) menu_run update all;;
        rebuild) menu_run rebuild --clean-history;;
        status) menu_run status;; doctor) menu_run doctor;; paths) menu_run paths;; apply) menu_run apply;;
        logs-*) menu_run logs "${route#logs-}";; network-check) menu_run network-check;;
        uninstall-keep) menu_run uninstall keep;; uninstall-xray) menu_run uninstall xray;; uninstall-nginx) menu_run uninstall nginx;; uninstall-acme) menu_run uninstall acme;; uninstall-all) menu_run uninstall all;;
        help) menu_run help;; explain) menu_run explain;; workflow-help) menu_run help workflow;; color-help) menu_run help colors;;
        firewall-*) menu_run firewall "${route#firewall-}";;
        swap-status) menu_run swap status;; swap-enable) menu_run swap enable;; swap-custom) menu_run swap custom;; swap-remove) menu_run swap remove;;
        edge-*) menu_run edge "${route#edge-}";;
        advanced-show) menu_run advanced show;; advanced-capacity) menu_run advanced edit capacity;; advanced-user) menu_run advanced edit nginx.worker_user;;
        advanced-xray) menu_run advanced edit xray.nofile;; advanced-defaults) menu_run advanced defaults;; advanced-users) menu_run advanced users;;
        history-list) menu_run history list;; history-save) menu_run history save;; history-full) menu_run history restore '' full;;
        history-state) menu_run history restore '' state;; history-advanced) menu_run history restore '' advanced;;
        recover) menu_run recover;; system-reboot) menu_run system reboot;;
        advanced-preflight) menu_run advanced preflight;;
        rollback) menu_run rollback;; repair) menu_run repair;; back) return;;
        *) die "面板路由不存在：$route";;
    esac
}
s3_prev_menu_group() {
    local group=${1:-main} option route
    menu_title "$group" >/dev/null || die '未知菜单。'
    while :; do
        menu_render "$group"
        ask option '请选择序号（R刷新状态）' 0
        [[ $option != r && $option != R ]] || continue
        if [[ ! $option =~ ^(0|[1-9][0-9]?)$ ]]; then warn '请输入面板中的数字序号。'; continue; fi
        route=$(menu_catalog | awk -F'|' -v g="$group" -v n="$option" '$1==g && $2==n {print $7}')
        if [[ -z $route ]]; then warn '该序号不存在，请重新选择。'; continue; fi
        [[ $route != back ]] || return 0
        menu_dispatch "$route"
    done
}
main_menu() { menu_group main; }

# Compatibility helpers restored as explicit actions, not automatic side effects.
record_update() {
    local file=$1 tmp; shift
    [[ ! -L $file && -d ${file%/*} && ! -L ${file%/*} ]] || die '记录路径不安全。'
    tmp=$(mktemp "${file%/*}/.record.XXXXXXXX")
    if ! jq "$@" "$file" > "$tmp"; then rm -f "$tmp"; die '记录更新失败。'; fi
    chmod 600 "$tmp"; mv -f -- "$tmp" "$file"
}
worker_users() {
    local u state row
    printf '候选账户\tUID\t主组\t检查结果\n'
    for u in vpskit-www www-data nginx http nobody; do
        if row=$(getent passwd "$u"); then
            state='不可选：需非root、禁用登录且无高权限组'
            if service_user_valid "$u"; then state='可复用'; fi
            printf '%s\t%s\t%s\t%s\n' "$u" "$(id -u "$u")" "$(id -gn "$u")" "$state"
        else printf '%s\t-\t-\t系统不存在（不会创建）\n' "$u"; fi
    done
    info '可指定其他已有合格账户；复用用户不等于不同服务之间的UID隔离。'
}
wizard_configure() {
    local scheme host
    ask_valid scheme '方案 A=REALITY直连；B=网站TLS+XHTTP' "$(get '.scheme // "A"')" choice 'A B'
    smart_host_select host '以后新增节点默认连接的公网IP或域名' "$(get '.host // ""')"
    confirm '仅保存向导方案和默认地址，不自动修改已有节点/网站' || return 0
    begin_tx wizard-preferences
    json_update --arg s "$scheme" --arg h "$host" '.scheme=$s|.host=$h|.wizard.selected=true'
    commit_tx
}
wizard_status() {
    if ! state_basic "$STATE" 2>/dev/null; then info '暂无可用配置；新装从部署向导开始，已有部署先恢复。'; return; fi
    jq -r '"方案：\(.scheme // "A")\n连接默认值：\(.host // "未设置")\n向导已选择：\(.wizard.selected // false)\n最后步骤：\(.wizard.last_step // "未记录")\n结果：\(.wizard.last_result // "未记录")\n组件：Xray=\(.components.xray) Nginx=\(.components.nginx) ACME=\(.components.acme)\n节点数：\(.nodes|length)；网站数：\(.sites|length)"' "$STATE"
    info '继续部署不会重新生成已有 UUID/密码；尚未提交的输入需要重新填写。'
}
cert_settings() {
    local d s e c w=false
    site_select d "${1:-}"
    s=$(jq -c --arg d "$d" '.sites[]|select(.domain==$d)' "$STATE")
    ask_valid e '证书联系邮箱' "$(jq -r '.email // ""' <<< "$s")" valid_email
    ask_valid c '验证：http=公网80；dns_cf=Cloudflare；dns_dp=DNSPod' "$(jq -r '.challenge // "http"' <<< "$s")" choice 'http dns_cf dns_dp'
    if [[ $c != http ]]; then ask_valid w '同时签发泛域名（需要DNS API权限）' "$(jq -r '.wildcard // false' <<< "$s")" valid_bool; fi
    confirm "保存 $d 证书设置；当前证书不变，需另行选择签发" || return 0
    begin_tx "cert-settings:$d"
    json_update --arg d "$d" --arg e "$e" --arg c "$c" --argjson w "$w" '
      (.sites[]|select(.domain==$d)) |= (. + {email:$e,challenge:$c,wildcard:$w,cert_settings_pending:true}) |
      .preferences += {email:$e,challenge:$c,wildcard:$w}'
    commit_tx
}
s5_legacy_cert_import_interactive() {
    local d cert key
    site_select d
    ask cert '完整证书链 PEM 文件绝对路径' ''
    ask key '私钥 PEM 文件绝对路径（不会打印内容）' ''
    [[ $cert == /* && $key == /* ]] || die '请提供绝对路径。'
    cert_import "$d" "$cert" "$key"
}
site_edit_existing() { local d; site_select d "${1:-}"; site_configure "$d"; }
s5_legacy_node_set_credential() {
    local id n p m value candidate="$WORK/credential.next.json"
    node_select id "${1:-}"
    n=$(jq -c --arg id "$id" '.nodes[]|select(.id==$id)' "$STATE")
    p=$(jq -r .protocol <<< "$n"); m=$(jq -r '.method // ""' <<< "$n")
    info 'VLESS/VMess需标准UUID；SS2022需对应长度Base64密钥；其他密码8–256字符且无空白。'
    secret value '输入新UUID/密码；留空自动生成'
    [[ -n $value ]] || value=$(node_credential "$p" "$m")
    jq --arg id "$id" --arg c "$value" '(.nodes[]|select(.id==$id)).credential=$c' "$STATE" > "$candidate"
    validate_state "$candidate" no
    confirm "修改 $id 的凭据；需要更新客户端，可能中断现有代理连接" || return 0
    begin_tx "node-credential:$id"; install -m 600 "$candidate" "$STATE"; apply_config; commit_tx
}
node_set_listen() {
    local id n value entry
    node_select id "${1:-}"
    n=$(jq -c --arg id "$id" '.nodes[]|select(.id==$id)' "$STATE")
    case $(jq -r .mode <<< "$n") in ws|xhttp) die 'WS/XHTTP后端固定为127.0.0.1；公网由Nginx监听。';; esac
    select_value value '选择监听地址（共享入口同步变更）' "$(jq -r '.listen // "0.0.0.0"' <<< "$n")" '0.0.0.0|全部IPv4接口：需核对公网防火墙' '::|IPv6/双栈：取决于系统设置' '127.0.0.1|仅本机IPv4' '::1|仅本机IPv6'
    if [[ $value == *:* ]]; then [[ -s /proc/net/if_inet6 ]] || die '系统未提供可用IPv6接口。'; fi
    entry=$(jq -r .entry <<< "$n")
    confirm "同步修改整个共享入口 $entry 的监听地址为 $value" || return 0
    begin_tx "node-listen:$id"
    json_update --arg e "$entry" --arg l "$value" '(.nodes[]|select(.entry==$e)).listen=$l'
    apply_config; commit_tx
    recovery_firewall check || true
}
component_update() {
    local name=$1 version=${2:-}
    choice "$name" 'xray nginx acme' || die '组件名称无效。'
    ensure_component "$name"
    if [[ $name == xray && -z $version ]]; then
        ask_valid version 'Xray版本（回车保留已装版本；latest显式选择最新）' "$(get '.versions.xray // "v26.3.27"')" valid_version
    fi
    version=${version:-$XRAY_DEFAULT_VERSION}
    confirm "更新组件 $name；配置保留，必要时重启相关服务" || return 0
    install_dependencies; install_component "$name" "$version" yes
}
update_all() {
    local name version="$XRAY_DEFAULT_VERSION"
    warn '逐组件提交，不是整机原子升级；后续失败不会撤销已成功的组件更新。'
    confirm '更新全部已安装组件；可能多次短暂中断连接' || return 0
    if component_ready xray; then
        ask_valid version 'Xray目标版本（latest为显式最新版）' "$(get '.versions.xray // "v26.3.27"')" valid_version
    fi
    install_dependencies
    for name in nginx xray acme; do
        if component_ready "$name"; then install_component "$name" "$version" yes; else info "$name 未安装，跳过。"; fi
    done
    if confirm '组件更新完成；是否继续单独更新管理代码'; then update_manager; fi
}
s1_base_service_control() {
    local name=$1 action=$2 old=''
    if choice "$name" 'start stop restart reload'; then local tmp=$name; name=$action; action=$tmp; fi
    if [[ $name == all ]]; then
        [[ $action == restart ]] || die '全部组件操作目前支持：service all restart。'
        restart_all_components; return
    fi
    if [[ $name == system ]]; then
        [[ $action == reboot ]] || die '系统操作为service system reboot或system reboot。'
        system_reboot; return
    fi
    if [[ $name == nginx && $action == reload ]]; then
        ensure_component nginx
        [[ -f $SYSTEMD/vpskit-nginx.service && ! -L $SYSTEMD/vpskit-nginx.service ]] && grep -Fq '# VPSKIT_OWNED' "$SYSTEMD/vpskit-nginx.service" || die '服务归属不匹配。'
        nginx_cmd -t -p "$ROOT/" -c "$ROOT/config/nginx.conf"
        confirm '配置检查成功，重载本工具Nginx（不重新生成配置）' || return 0
        local master; master=$(nginx_master_pid || true)
        [[ -z $master ]] || old=$(worker_generation "$master")
        systemctl reload vpskit-nginx.service
        if ! verify_nginx_runtime "$old"; then failure_diagnostics manual-reload || true; die '重载未观察到新Worker，未冒充成功。'; fi
    else service_action "$name" "$action"; fi
}
network_check() {
    local d code failed=0
    need curl; need getent
    while IFS= read -r d; do
        printf '\n域名：%s\n' "$d"
        if ! getent ahosts "$d"; then warn '当前系统未能解析该域名。'; failed=1; fi
        if code=$(curl --proto '=https' --connect-timeout 5 --max-time 12 -sS -o /dev/null -w '%{http_code}' "https://$d/"); then
            printf '公网 HTTPS 状态码：%s（未忽略证书验证）\n' "$code"
        else warn '公网HTTPS检查失败；检查DNS、证书、网络及Cloudflare回源。'; failed=1; fi
    done < <(jq -r '.sites[].domain' "$STATE")
    info 'Cloudflare解析返回边缘IP是正常情况；此检查不修改DNS，不等于节点客户端验收。'
    return "$failed"
}
edge_status_all() {
    local s d
    while IFS= read -r s; do d=$(jq -r .domain <<< "$s"); printf '\n%s\n' "$d"; edge_settings "$s" | jq .; done < <(jq -c '.sites[]' "$STATE")
    [[ ! -f $ROOT/config/edge/updated.epoch ]] || printf '\n官方资料刷新时间戳：%s\n' "$(cat "$ROOT/config/edge/updated.epoch")"
}
edge_probe_check() {
    local d=$1 token response
    token=$(get '.edge.probe // ""')
    [[ $token =~ ^[a-f0-9]{32}$ ]] || { warn '尚无探测标识；请先切换AOP到observe。'; return 1; }
    if ! response=$(curl --proto '=https' --connect-timeout 5 --max-time 15 --fail --silent --show-error \
      -H 'Cache-Control: no-cache' "https://$d/.well-known/vpskit-aop-$token?nonce=$(randhex 6)"); then
        warn '公网AOP检查失败；未关闭TLS校验，也未强制直连源站。'; return 1
    fi
    [[ $response == SUCCESS ]] || { warn "本次回源未返回SUCCESS（不输出未验证响应正文）。"; return 1; }
    ok "$d 本次公网请求的AOP证书检查为SUCCESS；不代表所有边缘永久可用。"
}
edge_probe() {
    local d; site_select d "${1:-}"
    jq -e --arg d "$d" '.sites[]|select(.domain==$d and .access=="cloudflare" and .issued and (.protection.aop // "off")!="off")' "$STATE" >/dev/null || die '需Cloudflare站点、有效TLS证书以及observe/enforce模式。'
    edge_probe_check "$d"
}
edge_batch() {
    local d=$1; shift
    local candidate="$WORK/edge-batch.json" key value s probe enforce=false current
    site_select d "$d"
    (($#>0 && $#%2==0)) || die '防护参数必须为键值对。'
    cp "$STATE" "$candidate"
    while (($#)); do
        key=$1; value=$2; shift 2
        case "$key" in
            bots) choice "$value" 'off ai common all' || die 'bots只能为off/ai/common/all。';;
            aop) choice "$value" 'off observe enforce' || die 'aop只能为off/observe/enforce。'; [[ $value != enforce ]] || enforce=true;;
            origin|gzip) valid_bool "$value" || die '开关值为true/false。';;
            rate) number "$value" 0 100 || die 'rate范围0–100。';;
            burst) number "$value" 1 200 || die 'burst范围1–200。';;
            connections) number "$value" 0 200 || die 'connections范围0–200。';;
            kbps) number "$value" 0 10240 || die 'kbps范围0–10240。';;
            static_ttl) number "$value" 0 604800 || die 'static_ttl范围0–604800秒。';;
            *) die '未知防护字段。';;
        esac
        if [[ $key == bots || $key == aop ]]; then
            jq --arg d "$d" --arg k "$key" --arg v "$value" '(.sites[]|select(.domain==$d)).protection[$k]=$v' "$candidate" > "$candidate.next"
        else jq --arg d "$d" --arg k "$key" --argjson v "$value" '(.sites[]|select(.domain==$d)).protection[$k]=$v' "$candidate" > "$candidate.next"; fi
        mv "$candidate.next" "$candidate"
    done
    probe=$(get '.edge.probe // ""')
    [[ -n $probe ]] || probe=$(randhex 16)
    jq --arg p "$probe" '.edge.probe=$p' "$candidate" > "$candidate.next"; mv "$candidate.next" "$candidate"
    s=$(jq -c --arg d "$d" '.sites[]|select(.domain==$d)' "$candidate")
    current=$(jq -r --arg d "$d" '.sites[]|select(.domain==$d)|.protection.aop // "off"' "$STATE")
    if [[ $enforce == true ]]; then
        [[ $current == observe || $current == enforce ]] || die '先设置AOP为observe，在Cloudflare启用AOP并验证后才能enforce。'
        edge_probe_check "$d" || die 'AOP验证未通过，未启用强制模式。'
    fi
    if [[ $(jq -r '.access // "direct"' <<< "$s") == cloudflare ]] && { ! cf_ready || [[ $(edge_settings "$s" | jq -r .aop) != off && ! -s $ROOT/config/edge/aop-ca.pem ]]; }; then cf_fetch; fi
    printf '将保存 %s 的防护设置：\n' "$d"; edge_settings "$s" | jq .
    warn '来源限制会拒绝直连；广泛UA拦截可能影响监控；网站限额不作用于节点代理。'
    confirm '保存并应用此站点防护' || return 0
    begin_tx "edge:$d"
    [[ ! -d $WORK/edge ]] || cf_install_assets
    install -m 600 "$candidate" "$STATE"
    validate_state; apply_config web
    if [[ $enforce == true ]]; then edge_probe_check "$d" || die '强制模式上线后复检失败，将回滚本次配置。'; fi
    commit_tx
}
edge_set() { edge_batch "$1" "$2" "$3"; }
edge_action() {
    local action=$1 d=${2:-} s value rate burst connections kbps ttl gzip
    site_select d "$d"; s=$(jq -c --arg d "$d" '.sites[]|select(.domain==$d)' "$STATE")
    case "$action" in
        profile) edge_batch "$d" bots ai rate 5 burst 30 connections 20 static_ttl 3600 gzip true;;
        reset) edge_batch "$d" bots off rate 0 burst 30 connections 0 kbps 0 static_ttl 0 gzip false origin false aop off;;
        limits)
            ask_valid rate '每IP网站请求/秒（0关闭，最高100）' "$(edge_settings "$s" | jq -r .rate)" number 0 100
            ask_valid burst '突发请求数（1–200）' "$(edge_settings "$s" | jq -r .burst)" number 1 200
            ask_valid connections '每IP并发网站请求（0关闭，最高200）' "$(edge_settings "$s" | jq -r .connections)" number 0 200
            ask_valid kbps '每响应限速KiB/s（0关闭，最高10240）' "$(edge_settings "$s" | jq -r .kbps)" number 0 10240
            edge_batch "$d" rate "$rate" burst "$burst" connections "$connections" kbps "$kbps";;
        cache)
            ask_valid ttl '静态资源缓存秒数（0关闭，最高604800）' "$(edge_settings "$s" | jq -r .static_ttl)" number 0 604800
            ask_valid gzip '站点静态文本gzip' "$(edge_settings "$s" | jq -r .gzip)" valid_bool
            edge_batch "$d" static_ttl "$ttl" gzip "$gzip";;
        bots) ask_valid value 'UA策略：off关闭/ai/common/all（all会影响SEO和监控）' "$(edge_settings "$s" | jq -r .bots)" choice 'off ai common all'; edge_set "$d" bots "$value";;
        origin) ask_valid value '仅允许Cloudflare网段回源；true开启/false关闭' "$(edge_settings "$s" | jq -r .origin)" valid_bool; edge_set "$d" origin "$value";;
        aop) ask_valid value 'AOP：off关闭/observe观察/enforce强制' "$(edge_settings "$s" | jq -r .aop)" choice 'off observe enforce'; edge_set "$d" aop "$value";;
        *) die '防护操作无效。';;
    esac
}
edge_guide() {
    cat <<'EOF'
Cloudflare 配置指引（只读；不调用外部账户API）
1. 域名指向源站并开启橙云；源站证书有效后采用 Full (strict)。
2. HTTP-01 要保证公网80挑战路径可达；DNS-01需要限定区域DNS编辑权限。
3. 网站静态资源可缓存；XHTTP前缀、WS路径、ACME挑战、AOP探测路径必须绕过缓存。
4. 先验证网站与节点，再开启Cloudflare来源限制；它不修改SSH和云安全组。
5. AOP顺序：源站observe → 控制台Authenticated Origin Pulls → 公网probe → enforce。
6. Cloudflare访客侧HTTP/3不等于源站QUIC；普通橙云不代理REALITY/任意TCP/SS。
7. UA拦截并非强身份验证；每IP限额会被同一NAT下的访客共享。
8. 代理路径与UUID不同，但仍属于部署信息；不要公开张贴完整配置。
EOF
}
edge_traffic() {
    local f iface rx tx r2 t2 delta_rx delta_tx
    local -A before_rx=() before_tx=()
    for f in /sys/class/net/*; do
        iface=${f##*/}; [[ $iface != lo ]] || continue
        read -r rx < "$f/statistics/rx_bytes"; read -r tx < "$f/statistics/tx_bytes"
        before_rx[$iface]=$rx; before_tx[$iface]=$tx
    done
    sleep 1
    printf '网卡\t累计接收MiB\t累计发送MiB\t采样接收KiB/s\t采样发送KiB/s\n'
    for iface in "${!before_rx[@]}"; do
        f="/sys/class/net/$iface"; [[ -d $f ]] || continue
        read -r r2 < "$f/statistics/rx_bytes"; read -r t2 < "$f/statistics/tx_bytes"
        delta_rx=$((r2-before_rx[$iface])); delta_tx=$((t2-before_tx[$iface]))
        if ((delta_rx<0 || delta_tx<0)); then warn "$iface 计数器重置，忽略速率样本。"; continue; fi
        awk -v n="$iface" -v rx="$r2" -v tx="$t2" -v dr="$delta_rx" -v dt="$delta_tx" 'BEGIN{printf "%s\t%.2f\t%.2f\t%.2f\t%.2f\n",n,rx/1048576,tx/1048576,dr/1024,dt/1024}'
    done
    info '约1秒采样，含网卡全部业务；不是精确计费，也不是每节点的流量。'
}
edge_maintenance() {
    cf_needed || return 0
    local epoch=0 now; now=$(date +%s)
    if [[ -r $ROOT/config/edge/updated.epoch ]]; then read -r epoch < "$ROOT/config/edge/updated.epoch"; fi
    [[ $epoch =~ ^[0-9]{1,12}$ ]] || epoch=0
    if ((now-epoch<604800)); then return 0; fi
    # Same maintenance lock, normal errexit scope; fetch first, apply transactionally.
    edge_refresh
}

optimize_status() {
    printf '内存与Swap：\n'; free -h
    printf '\n当前拥塞控制和默认队列：\n'; sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.tcp_available_congestion_control 2>/dev/null || true
    printf '\n网卡MTU：\n'; ip -brief link
    printf '\n连接概况：\n'; ss -s
    info '不自动增大TCP缓冲、不改网卡MTU；BBR与gzip均需主动选择。'
}
bbr_enable() {
    local file="$ROOT/data/bbr-v2.json" conf=/etc/sysctl.d/90-vpskit.conf oldcc oldq available tmp
    need sysctl
    [[ ! -L $conf && ! -L $file ]] || die '现有BBR配置/记录为链接，拒绝覆盖；旧版配置请先人工核对。'
    if [[ -e $conf ]]; then
        grep -Fxq '# VPSKIT_OWNED BBR_V2' "$conf" && [[ -s $file ]] || die '同名sysctl文件不属于本版，未覆盖。'
    fi
    if [[ -e $file ]]; then
        jq -e '.owner=="VPSKIT_BBR_V2" and (.before.cc|type=="string") and (.before.qdisc|type=="string")' "$file" >/dev/null || die 'BBR记录损坏，停止。'
    fi
    confirm '显式启用BBR和fq（不改接口MTU/SSH）；新连接收益需自行测试' || return 0
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control)
    if [[ " $available " != *' bbr '* ]]; then
        command -v modprobe >/dev/null && modprobe tcp_bbr || die '无法加载tcp_bbr；内核/容器可能不支持，未改sysctl。'
        available=$(sysctl -n net.ipv4.tcp_available_congestion_control)
        [[ " $available " == *' bbr '* ]] || die '内核未提供bbr。'
    fi
    oldcc=$(sysctl -n net.ipv4.tcp_congestion_control); oldq=$(sysctl -n net.core.default_qdisc)
    if [[ ! -e $file ]]; then
        jq -n --arg c "$oldcc" --arg q "$oldq" '{owner:"VPSKIT_BBR_V2",before:{cc:$c,qdisc:$q},stage:"pending"}' > "$file"
        chmod 600 "$file"
    fi
    if ! sysctl -w net.core.default_qdisc=fq || ! sysctl -w net.ipv4.tcp_congestion_control=bbr; then
        sysctl -w "net.core.default_qdisc=$oldq" "net.ipv4.tcp_congestion_control=$oldcc" || true
        die '应用失败，已尝试还原本次前的运行值；保留记录以便检查。'
    fi
    tmp=$(mktemp /etc/sysctl.d/.vpskit.XXXXXXXX)
    printf '# VPSKIT_OWNED BBR_V2\nnet.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' > "$tmp"
    chmod 644 "$tmp"; mv -f "$tmp" "$conf"
    record_update "$file" '.stage="active"'
    ok '已设置BBR与默认fq；未重设现有接口队列，也未修改MTU。'
}
bbr_restore() {
    local approved=${1:-no} file="$ROOT/data/bbr-v2.json" conf=/etc/sysctl.d/90-vpskit.conf cc q current
    [[ -e $file ]] || { info '没有本版BBR恢复记录；外部/旧版sysctl配置未改动。'; return; }
    [[ ! -L $file && ! -L $conf ]] || die 'BBR配置路径为链接，拒绝处理。'
    jq -e '.owner=="VPSKIT_BBR_V2"' "$file" >/dev/null || die 'BBR记录归属不匹配。'
    if [[ -e $conf ]]; then grep -Fxq '# VPSKIT_OWNED BBR_V2' "$conf" || die '持久化配置被外部改写，未删除。'; fi
    cc=$(jq -r .before.cc "$file"); q=$(jq -r .before.qdisc "$file")
    [[ $cc =~ ^[a-zA-Z0-9_-]+$ && $q =~ ^[a-zA-Z0-9_-]+$ ]] || die '旧参数格式无效。'
    [[ $approved == yes ]] || confirm "撤销本工具BBR设置，原值为 $cc / $q" || return 0
    current=$(sysctl -n net.ipv4.tcp_congestion_control)
    if [[ $current == bbr ]]; then sysctl -w "net.ipv4.tcp_congestion_control=$cc"; else warn '拥塞控制已被其他操作修改，不覆盖其当前值。'; fi
    current=$(sysctl -n net.core.default_qdisc)
    if [[ $current == fq ]]; then sysctl -w "net.core.default_qdisc=$q"; else warn '默认队列已被其他操作修改，不覆盖其当前值。'; fi
    rm -f -- "$conf" "$file"
    ok '本版BBR持久化设置已移除；不卸载内核模块、不改网卡。'
}
mtu_probe() {
    local target=${1:-} rc=0
    command -v tracepath >/dev/null || die '缺少tracepath；可先执行 apt-get install iputils-tracepath，再运行此只读探测。'
    [[ -n $target ]] || ask_valid target '探测目标域名/IPv4/IPv6（不修改本机MTU）' www.microsoft.com valid_host
    valid_host "$target" || die '探测目标无效。'
    timeout 20 tracepath -n "$target" || rc=$?
    if ((rc!=0)); then warn "探测退出码=$rc；ICMP过滤或超时不等于MTU配置错误。"; fi
    info '未修改任何接口MTU；不要把单次路径结果直接当作全局网卡设置。'
}
# Firewall V2 records are intentionally separate from legacy records. We do not
# guess ownership from an unrecognized historical schema and delete external rules.
fw_record_file() { printf '%s/data/firewall-v2.json' "$ROOT"; }
fw_records_init() {
    local f; f=$(fw_record_file)
    [[ ! -L $f ]] || die '防火墙记录不能为链接。'
    if [[ ! -e $f ]]; then printf '{"owner":"VPSKIT_FIREWALL_V2","schema":2,"rules":[]}\n' > "$f"; chmod 600 "$f"; fi
    jq -e '.owner=="VPSKIT_FIREWALL_V2" and .schema==2 and (.rules|type=="array")' "$f" >/dev/null || die '本版防火墙记录损坏，拒绝接管。'
}
fw_backend() {
    local uf=0 ff=0
    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then uf=1; fi
    if command -v firewall-cmd >/dev/null && firewall-cmd --state 2>/dev/null | grep -qx running; then ff=1; fi
    if ((uf && ff)); then die 'UFW与firewalld同时启用，拒绝修改；请由管理员明确使用一个。'; fi
    if ((uf)); then printf ufw; elif ((ff)); then printf firewalld; else die '未检测到已启用的UFW或firewalld；不会自动安装、启用或重置防火墙。'; fi
}
ssh_ports() {
    printf '22\n'
    local p
    if [[ -n ${SSH_CONNECTION:-} ]]; then p=${SSH_CONNECTION##* }; valid_port "$p" && printf '%s\n' "$p"; fi
    if command -v sshd >/dev/null; then sshd -T 2>/dev/null | awk '$1=="port"{print $2}' || true; fi
    ss -H -lntp 2>/dev/null | awk '/sshd/{n=split($4,a,":");print a[n]}' || true
}
fw_guard_port() {
    local port=$1 proto=$2 p
    valid_port "$port" && choice "$proto" 'tcp udp both' || die '端口/协议不合法。'
    if [[ $proto != udp ]]; then
        while IFS= read -r p; do
            [[ $p != "$port" ]] || die "端口 $port 是22或检测到的SSH端口；本工具不会为其开关或撤销规则。"
        done < <(ssh_ports | sort -un)
    fi
}
s5_legacy_fw_choose_zone() {
    local dest=$1 backend=$2 z=''
    if [[ $backend == firewalld ]]; then
        printf 'firewalld活动zone：\n' >&2; firewall-cmd --get-active-zones >&2
        ask z '明确选择公网接口/来源所属zone（不能只凭默认值猜测）' "$(firewall-cmd --get-default-zone)"
        [[ $z =~ ^[a-zA-Z0-9_-]+$ ]] && choice "$z" "$(firewall-cmd --get-zones)" || die 'zone不存在。'
    fi
    printf -v "$dest" '%s' "$z"
}
fw_id() { printf '%s:%s:%s:%s' "$1" "$2" "$3" "$4" | sha256sum | cut -c1-16; }
fw_rich_rule() {
    local family=$1 port=$2 proto=$3 action=$4 id=$5 decision=accept
    [[ $action != deny ]] || decision=drop
    # Limited log prefix provides a distinguishable ownership marker in rich rules.
    printf 'rule family="%s" priority="-100" port port="%s" protocol="%s" log prefix="VPSKIT-%s " limit value="1/m" %s' "$family" "$port" "$proto" "$id" "$decision"
}
fw_ufw_remove_tag() {
    local tag=$1 n output
    [[ $tag =~ ^VPSKIT-[a-f0-9]{16}$ ]] || die '规则标签格式无效。'
    output=$(ufw status numbered)
    while IFS= read -r n; do
        [[ $n =~ ^[0-9]+$ ]] || die 'UFW规则编号解析异常。'
        ufw --force delete "$n"
    done < <(awk -v tag="$tag" '$0 ~ ("# "tag"[[:space:]]*$") {line=$0;sub(/^\[ */,"",line);sub(/\].*$/,"",line);if(line~/^[0-9]+$/)print line}' <<< "$output" | sort -rn)
}
fw_remove_rule() {
    local backend=$1 zone=$2 port=$3 proto=$4 action=$5 id=$6 family rule
    [[ $id == "$(fw_id "$backend" "$zone" "$port" "$proto")" ]] || die '防火墙规则归属摘要不匹配。'
    fw_guard_port "$port" "$proto"
    if [[ $backend == ufw ]]; then fw_ufw_remove_tag "VPSKIT-$id"
    else
        for family in ipv4 ipv6; do
            rule=$(fw_rich_rule "$family" "$port" "$proto" "$action" "$id")
            if firewall-cmd --zone="$zone" --query-rich-rule="$rule" >/dev/null; then firewall-cmd --zone="$zone" --remove-rich-rule="$rule"; fi
            if firewall-cmd --permanent --zone="$zone" --query-rich-rule="$rule" >/dev/null; then firewall-cmd --permanent --zone="$zone" --remove-rich-rule="$rule"; fi
        done
    fi
}
fw_apply_rule() {
    local backend=$1 zone=$2 port=$3 proto=$4 action=$5 id tag f old family rule status existing
    fw_guard_port "$port" "$proto" || return 1
    choice "$backend" 'ufw firewalld' && choice "$proto" 'tcp udp' && choice "$action" 'allow deny' || die '防火墙规则字段错误。'
    [[ $backend != firewalld || $zone =~ ^[a-zA-Z0-9_-]+$ ]] || die 'zone字段无效。'
    fw_records_init || return 1; f=$(fw_record_file); id=$(fw_id "$backend" "$zone" "$port" "$proto"); tag="VPSKIT-$id"
    old=$(jq -r --arg id "$id" '.rules[]|select(.id==$id)|.action' "$f")
    if [[ $backend == ufw ]]; then
        status=$(ufw status numbered) || return 1
        # Avoid UFW silently re-labelling an existing unowned rule on the same port.
        existing=$(awk -v p="$port/$proto" -v tag="$tag" '{hit=0;for(i=1;i<=NF;i++)if($i==p)hit=1;if(hit && index($0,"# "tag)==0)print}' <<< "$status")
        [[ -z $existing ]] || die "检测到 $port/$proto 的外部UFW规则；为避免更改归属，请先人工核对规则顺序。"
    fi
    record_update "$f" --arg id "$id" --arg b "$backend" --arg z "$zone" --argjson p "$port" --arg pr "$proto" --arg a "$action" --arg old "${old:-}" '
      .rules=([.rules[]|select(.id!=$id)]+[{id:$id,backend:$b,zone:$z,port:$p,proto:$pr,action:$a,previous_action:$old,stage:"pending"}])' || return 1
    # Both possible actions are removed for crash recovery; only exact tagged/recorded rules.
    if [[ $backend == ufw ]]; then fw_ufw_remove_tag "$tag" || return 1
    else
        fw_remove_rule "$backend" "$zone" "$port" "$proto" allow "$id" || return 1
        fw_remove_rule "$backend" "$zone" "$port" "$proto" deny "$id" || return 1
    fi
    if [[ $backend == ufw ]]; then
        ufw insert 1 "$action" in proto "$proto" to any port "$port" comment "$tag" || return 1
        ufw status numbered | grep -Fq "# $tag" || die 'UFW未返回预期规则标识；保留pending记录。'
    else
        for family in ipv4 ipv6; do
            rule=$(fw_rich_rule "$family" "$port" "$proto" "$action" "$id")
            firewall-cmd --zone="$zone" --add-rich-rule="$rule" || return 1
            firewall-cmd --permanent --zone="$zone" --add-rich-rule="$rule" || return 1
            firewall-cmd --zone="$zone" --query-rich-rule="$rule" >/dev/null || return 1
            firewall-cmd --permanent --zone="$zone" --query-rich-rule="$rule" >/dev/null || return 1
        done
    fi
    record_update "$f" --arg id "$id" '(.rules[]|select(.id==$id)).stage="applied"' || return 1
    ok "$backend $zone：$port/$proto → $action（需外网及云安全组验收）"
}
s5_previous_firewall_required() {
    state_basic "$STATE" 2>/dev/null || return 0
    if component_ready nginx; then printf '80 tcp\n443 tcp\n'; fi
    jq -r '[.nodes[]|select(.enabled and .mode!="ws" and .mode!="xhttp" and (.listen // "0.0.0.0")!="127.0.0.1" and (.listen // "0.0.0.0")!="::1")]|unique_by(.entry)[]|"\(.port) tcp"+(if .mode=="ss" then "\n\(.port) udp" else "" end)' "$STATE"
}
firewall_show() {
    local f; f=$(fw_record_file)
    info '只读：不启用/重置防火墙；SSH由管理员管理；云安全组需单独放行。'
    if command -v ufw >/dev/null; then ufw status verbose || true; fi
    if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then firewall-cmd --get-active-zones; firewall-cmd --list-all-zones; fi
    printf '\n本工具所需公网端口：\n'; firewall_required | sort -k1,1n -k2,2 -u
    if [[ -f $f ]]; then printf '\n本版托管规则：\n'; jq . "$f"; fi
    if [[ -f $ROOT/data/firewall.json ]]; then warn '另有旧版firewall.json；它保持原样，本版不会猜测并删除未知格式规则。'; fi
    printf '\n受保护SSH端口：\n'; ssh_ports | sort -un
}
s5_legacy_firewall_change() {
    local action=$1 port=${2:-} proto=${3:-} backend zone p
    [[ -n $port ]] || ask_valid port '端口（1–65535；拒绝SSH端口）' '' valid_port
    [[ -n $proto ]] || ask_valid proto '协议：tcp/udp/both' tcp choice 'tcp udp both'
    fw_guard_port "$port" "$proto"; backend=$(fw_backend); fw_choose_zone zone "$backend"
    warn '关闭仅影响新入站连接；规则优先级、Docker及云安全组可能影响最终结果。'
    confirm "$backend zone=$zone：对 $port/$proto 执行 $action" || return 0
    if [[ $proto == both ]]; then for p in tcp udp; do fw_apply_rule "$backend" "$zone" "$port" "$p" "$action"; done
    else fw_apply_rule "$backend" "$zone" "$port" "$proto" "$action"; fi
}
firewall_sync() {
    local backend zone port proto rules
    rules=$(firewall_required | sort -u)
    [[ -n $rules ]] || { info '没有需同步的已配置公网端口。'; return; }
    backend=$(fw_backend); fw_choose_zone zone "$backend"
    printf '将放行以下端口；不自动关闭旧端口：\n%s\n' "$rules"
    while read -r port proto; do fw_guard_port "$port" "$proto"; done <<< "$rules"
    confirm '添加所需端口规则（多条规则非原子操作，失败可重试）' || return 0
    while read -r port proto; do fw_apply_rule "$backend" "$zone" "$port" "$proto" allow; done <<< "$rules"
}
firewall_cleanup() {
    local approved=${1:-no} f backend row b z p pr a id
    f=$(fw_record_file)
    [[ -s $f ]] || { info '没有本版托管规则记录；不删除外部或旧格式规则。'; return; }
    fw_records_init
    [[ $(jq '.rules|length' "$f") -gt 0 ]] || return 0
    backend=$(fw_backend)
    # Preflight all entries before removing anything.
    while IFS= read -r row; do
        b=$(jq -r .backend <<< "$row"); p=$(jq -r .port <<< "$row"); pr=$(jq -r .proto <<< "$row"); z=$(jq -r .zone <<< "$row")
        [[ $b == "$backend" ]] || die '记录包含其他/已停用防火墙的规则；请恢复对应管理器后单独清理。'
        [[ $b == ufw || $z =~ ^[a-zA-Z0-9_-]+$ ]] || die '记录zone异常。'
        fw_guard_port "$p" "$pr"
    done < <(jq -c '.rules[]' "$f")
    [[ $approved == yes ]] || confirm '仅撤销本版带记录和标识的规则；可能改变端口可达性' || return 0
    while IFS= read -r row; do
        b=$(jq -r .backend <<< "$row"); z=$(jq -r .zone <<< "$row"); p=$(jq -r .port <<< "$row"); pr=$(jq -r .proto <<< "$row"); id=$(jq -r .id <<< "$row")
        fw_remove_rule "$b" "$z" "$p" "$pr" allow "$id"
        fw_remove_rule "$b" "$z" "$p" "$pr" deny "$id"
        record_update "$f" --arg id "$id" '.rules|=map(select(.id!=$id))'
    done < <(jq -c '.rules[]' "$f")
    ok '本版托管规则已撤销；外部规则及旧格式归属记录未改动。'
}

swap_record() { printf '%s/data/swap-v2.json' "$ROOT"; }
swap_active() { swapon --noheadings --raw --show=NAME | grep -Fxq "$1"; }
swap_file_safe() {
    local file=$1
    [[ $file == "$ROOT/swap/swapfile" || $file == /var/lib/vpskit/swapfile ]] || return 1
    [[ -f $file && ! -L $file && ! -L ${file%/*} && $(stat -c %u "$file") == 0 && $(stat -c %h "$file") == 1 ]]
}
swap_current() {
    local f record file unit persistence='' matches=0
    record=$(swap_record)
    if [[ -e $record ]]; then
        [[ ! -L $record ]] && jq -e '.owner=="VPSKIT_SWAP_V2" and (.size_mib|type=="number") and (.file|type=="string")' "$record" >/dev/null || die 'Swap记录损坏或为链接。'
        file=$(jq -r .file "$record")
        [[ $file == "$ROOT/swap/swapfile" || $file == /var/lib/vpskit/swapfile ]] || die 'Swap记录指向非托管路径。'
        cat "$record"; return
    fi
    # Recognize both previous layouts only with concrete ownership evidence.
    file=''
    if [[ -e /var/lib/vpskit/swapfile ]]; then
        [[ ! -L /var/lib/vpskit && -f /var/lib/vpskit/.owned && $(cat /var/lib/vpskit/.owned) == VPSKIT_SWAP ]] || die '发现无法确认归属的旧Swap，未创建重复文件。'
        file=/var/lib/vpskit/swapfile; persistence=fstab; matches=$((matches+1))
    fi
    if [[ -e $ROOT/swap/swapfile ]]; then
        unit=$(systemd-escape -p --suffix=swap "$ROOT/swap/swapfile")
        [[ -f $ROOT/data/swap.json && -f $SYSTEMD/$unit && ! -L $SYSTEMD/$unit ]] && grep -Fq '# VPSKIT_OWNED' "$SYSTEMD/$unit" && grep -Fxq "What=$ROOT/swap/swapfile" "$SYSTEMD/$unit" || die '发现原版Swap但归属检查未通过；不会覆盖或重复创建。'
        file="$ROOT/swap/swapfile"; persistence=systemd; matches=$((matches+1))
    fi
    ((matches<=1)) || die '检测到两套历史Swap文件，请先由管理员核对，避免重复或错误移除。'
    [[ -n $file ]] || return 1
    swap_file_safe "$file" || die '历史Swap文件不是root独占的普通单链接文件。'
    [[ $(blkid -p -s TYPE -o value "$file" 2>/dev/null || true) == swap ]] || die '历史文件不是有效Swap，拒绝重新格式化。'
    jq -n --arg f "$file" --arg p "$persistence" --argjson n "$(( $(stat -c %s "$file")/1048576 ))" '{owner:"VPSKIT_SWAP_V2",file:$f,size_mib:$n,persistence:$p,stage:"formatted",adopted:true}'
}
swap_show() {
    local current unit
    free -h; swapon --show
    if [[ -e $(swap_record) || -e $ROOT/swap/swapfile || -e /var/lib/vpskit/swapfile ]]; then
        current=$(swap_current) || die '历史Swap归属检查失败，未做任何更改。'
        printf '\n识别到本工具Swap（不自动变更）：\n'; jq . <<< "$current"
        unit=$(systemd-escape -p --suffix=swap "$(jq -r .file <<< "$current")")
        printf '启动单元：%s\n' "$unit"; systemctl is-enabled "$unit" 2>/dev/null || true
    else info '没有可识别的本工具Swap；现有系统Swap保持不变。'; fi
}
swap_create() {
    local size=${1:-} current='' record file unit stage persistence fstype available expected temp
    need mkswap; need swapon; need systemd-escape; need blkid
    record=$(swap_record)
    # Capture failure without confusing absence with an ownership error (die exits 1).
    if [[ -e $record || -e $ROOT/swap/swapfile || -e /var/lib/vpskit/swapfile ]]; then
        current=$(swap_current) || die '历史Swap检查失败；没有创建新文件。'
        file=$(jq -r .file <<< "$current"); size=$(jq -r .size_mib <<< "$current")
        persistence=$(jq -r .persistence <<< "$current"); stage=$(jq -r .stage <<< "$current")
        warn "复用已有托管Swap $file（$size MiB），忽略新的容量请求；变更大小请先安全移除。"
        confirm '恢复/修复已有Swap，不重新分配另一份文件' || return 0
        printf '%s\n' "$current" > "$record"; chmod 600 "$record"
    else
        [[ -n $size ]] || ask_valid size 'Swap MiB（256–8192，256的倍数）' 1024 number 256 8192
        number "$size" 256 8192 && ((size%256==0)) || die '容量必须为256–8192且为256的倍数。'
        [[ ! -L $ROOT/swap ]] || die 'Swap目录不能为符号链接。'
        fstype=$(stat -f -c %T "$ROOT")
        case "$fstype" in ext2/ext3|xfs) ;; *) die "文件系统 $fstype 不在自动创建支持范围；Btrfs/ZFS/容器请自行核对。";; esac
        available=$(df -Pk "$ROOT" | awk 'NR==2{print $4}')
        ((available>=size*1024+1048576)) || die '磁盘不足；创建后要求至少保留1GiB可用空间。'
        confirm "创建 $size MiB Swap；只用独立systemd .swap单元，不改fstab，不修改其他Swap" || return 0
        file="$ROOT/swap/swapfile"; persistence=systemd; stage=allocating
        mkdir -p "$ROOT/swap"; chown 0:0 "$ROOT/swap"; chmod 700 "$ROOT/swap"
        jq -n --arg f "$file" --argjson n "$size" '{owner:"VPSKIT_SWAP_V2",file:$f,size_mib:$n,persistence:"systemd",stage:"allocating"}' > "$record"
        chmod 600 "$record"
        (set -C; : > "$file") || die 'Swap文件已被其他操作创建，停止。'
        chmod 600 "$file"
    fi
    file=$(jq -r .file "$record"); stage=$(jq -r .stage "$record")
    number "$size" 256 8192 || die '记录的Swap大小无效。'
    swap_file_safe "$file" || die 'Swap文件缺失或权限归属异常；保留记录，未自动重建。'
    if [[ $stage == allocating ]]; then
        swap_active "$file" && die '标记为未完成分配的文件却已在使用；拒绝覆盖。'
        dd if=/dev/zero of="$file" bs=1M count="$size" conv=fsync status=none
        [[ $(stat -c %s "$file") == "$((size*1048576))" ]] || die '分配大小不完整；记录保留，可重试恢复。'
        mkswap "$file"
        record_update "$record" '.stage="formatted"'
    fi
    [[ $(blkid -p -s TYPE -o value "$file" 2>/dev/null || true) == swap ]] || die '文件签名不是Swap；拒绝覆盖格式化。'
    chmod 600 "$file"
    persistence=$(jq -r .persistence "$record")
    if [[ $persistence == fstab ]]; then
        [[ -f /etc/fstab && ! -L /etc/fstab ]] || die 'fstab异常。'
        grep -Eq '^/var/lib/vpskit/swapfile[[:space:]].*# VPSKIT_SWAP$' /etc/fstab || die '旧版fstab归属行缺失；请人工核对，不自动写入未知启动配置。'
        if ! swap_active "$file"; then swapon "$file" || die 'Swap启用失败；文件和记录保留。'; fi
    else
        [[ $persistence == systemd ]] || die 'Swap启动方式字段无效。'
        unit=$(systemd-escape -p --suffix=swap "$file")
        if [[ -e $SYSTEMD/$unit ]]; then [[ ! -L $SYSTEMD/$unit ]] && grep -Fq '# VPSKIT_OWNED' "$SYSTEMD/$unit" || die '同名swap服务不属于本工具。'; fi
        cat > "$WORK/swap-unit" <<EOF
# VPSKIT_OWNED SWAP_V2
[Unit]
Description=VPSKit managed swap (not system swap)
[Swap]
What=$file
[Install]
WantedBy=swap.target
EOF
        install -m 644 "$WORK/swap-unit" "$SYSTEMD/$unit"
        record_update "$record" '.stage="unit-written"'
        systemctl daemon-reload
        systemctl enable --now "$unit" || die 'Swap单元启用失败；文件和阶段记录保留，修复权限后可重试。'
    fi
    swap_active "$file" || die '没有检测到实际激活的Swap；记录保留。'
    record_update "$record" '.stage="active"'
    ok '托管Swap已启用/恢复；没有额外创建第二份交换文件。'
}
swap_memory_guard() {
    local file=$1 used available
    used=$(swapon --bytes --noheadings --raw --show=NAME,USED | awk -v f="$file" '$1==f{print $2}')
    [[ $used =~ ^[0-9]+$ ]] || die '无法读取该Swap实际使用量，拒绝盲目swapoff。'
    available=$(awk '/MemAvailable:/{print $2*1024}' /proc/meminfo)
    [[ $available =~ ^[0-9]+$ ]] || available=$(awk '/MemAvailable:/{printf "%.0f",$2*1024}' /proc/meminfo)
    ((available>=used+134217728)) || die '可用RAM不足：至少需已用本工具Swap+128MiB；未关闭或删除任何文件。'
}
swap_remove() {
    local approved=${1:-no} record current file persistence unit
    record=$(swap_record)
    if [[ ! -e $record && ! -e $ROOT/swap/swapfile && ! -e /var/lib/vpskit/swapfile ]]; then info '没有本工具Swap。'; return; fi
    current=$(swap_current) || die '无法确认Swap归属。'
    file=$(jq -r .file <<< "$current"); persistence=$(jq -r .persistence <<< "$current")
    swap_file_safe "$file" || die 'Swap文件安全检查失败。'
    [[ $approved == yes ]] || confirm "仅移除 $file；先检查可用RAM，失败则保留文件" || return 0
    if swap_active "$file"; then swap_memory_guard "$file"; swapoff "$file" || die 'swapoff失败，文件及启动配置保持不变。'; fi
    if [[ $persistence == fstab ]]; then
        [[ -f /etc/fstab && ! -L /etc/fstab ]] || die 'fstab异常，文件保留。'
        mkdir -p "$ROOT/backup/system"; cp -a /etc/fstab "$ROOT/backup/system/fstab-before-swap-remove-$(date +%s)"
        sed -i '\|^/var/lib/vpskit/swapfile[[:space:]].*# VPSKIT_SWAP$|d' /etc/fstab
    else
        unit=$(systemd-escape -p --suffix=swap "$file")
        if [[ -f $SYSTEMD/$unit ]]; then
            [[ ! -L $SYSTEMD/$unit ]] && grep -Fq '# VPSKIT_OWNED' "$SYSTEMD/$unit" || die 'swap服务归属改变，未删除。'
            systemctl disable --now "$unit"; rm -f "$SYSTEMD/$unit"; systemctl daemon-reload
        fi
    fi
    swap_active "$file" && die 'Swap仍在使用，拒绝删除文件。'
    rm -f -- "$file" "$record"
    if [[ $file == /var/lib/vpskit/swapfile ]]; then rm -f /var/lib/vpskit/.owned; rmdir /var/lib/vpskit 2>/dev/null || true
    else
        if [[ -f $ROOT/data/swap.json ]]; then mkdir -p "$ROOT/backup/system"; mv "$ROOT/data/swap.json" "$ROOT/backup/system/swap-legacy-removed-$(date +%s).json"; fi
        rmdir "$ROOT/swap" 2>/dev/null || true
    fi
    ok '只移除了可验证的本工具Swap，其他系统Swap保持不变。'
}
s1_base_uninstall_component() {
    local name=$1
    choice "$name" 'nginx xray acme' || die '组件无效。'; ensure_component "$name"
    case "$name" in
        nginx) [[ $(get '.sites|length') == 0 ]] && ! jq -e '.nodes[]|select(.mode=="ws" or .mode=="xhttp")' "$STATE" >/dev/null || die '仍有网站/网关节点依赖Nginx，请先移除这些绑定。';;
        acme) ! jq -e '.sites[]|select(.issued and (.certificate_source // "acme")!="manual")' "$STATE" >/dev/null || die '仍有自动续期证书依赖ACME；先移除网站或明确改为手动证书。';;
    esac
    warn '单组件卸载保留其他组件与网站文件；Xray卸载会删除全部节点。'
    confirm "卸载 $name，并按剩余配置重新应用" || return 0
    begin_tx "uninstall:$name" components
    json_update --arg n "$name" '.components[$n]=false | del(.versions[$n]) | if $n=="xray" then .nodes=[] | .native_nodes=[] else . end'
    apply_config
    case "$name" in
        xray) rm -f "$XRAY" "$ROOT/config/xray.json";;
        nginx) rm -rf -- "$ROOT/nginx"; mkdir -m 700 "$ROOT/nginx"; rm -f "$ROOT/config/nginx.conf";;
        acme) rm -rf -- "$ROOT/acme"; mkdir -m 700 "$ROOT/acme";;
    esac
    if [[ $name != acme && -f $SYSTEMD/vpskit-$name.service ]]; then
        systemctl disable --now "vpskit-$name.service"; rm -f "$SYSTEMD/vpskit-$name.service"; systemctl daemon-reload
    fi
    commit_tx
    ok "已卸载 $name；系统共享依赖未卸载。"
}
s1_base_uninstall_all() {
    local answer u f target mounts
    [[ $ROOT == /opt/vpskit && $TX == 0 ]] || die '完整卸载仅允许正式安装路径且无活动事务。'
    [[ -f $ROOT/.vpskit-owned && $(cat "$ROOT/.vpskit-owned") == VPSKIT_V1 && ! -L $ROOT ]] || die '安装目录归属不匹配。'
    if [[ -f $ROOT/data/firewall.json ]]; then
        die '发现旧格式firewall.json；无法安全推断其规则归属。先用原管理器核对清理，或选择保留数据停用；本版拒绝丢弃清理记录。'
    fi
    if [[ -e /etc/sysctl.d/90-vpskit.conf || -L /etc/sysctl.d/90-vpskit.conf ]]; then
        [[ ! -L /etc/sysctl.d/90-vpskit.conf ]] && grep -Fxq '# VPSKIT_OWNED BBR_V2' /etc/sysctl.d/90-vpskit.conf && [[ -f $ROOT/data/bbr-v2.json ]] || die '存在旧版/外部sysctl文件，需先核对迁移或清理；未删除目录。'
    fi
    mounts=$(findmnt -rn -o TARGET)
    if grep -Fq "$ROOT/" <<< "$mounts"; then die '安装目录内存在子挂载，拒绝递归删除。'; fi
    for u in "${UNITS[@]}"; do
        [[ ! -e $SYSTEMD/$u ]] || { [[ ! -L $SYSTEMD/$u ]] && grep -Fq '# VPSKIT_OWNED' "$SYSTEMD/$u"; } || die "服务 $u 不属于本工具。"
    done
    warn "将删除 $ROOT 下的网站、节点、证书、日志和全部历史备份，以及本工具服务和入口。"
    warn '会撤销可识别的本版防火墙/BBR设置，并安全移除托管Swap；共享软件包和SSH不变。'
    confirm '已经另行备份，并确认执行完整卸载' || return 0
    ask answer '再次输入 DELETE VPSKIT 才会真正删除' ''
    [[ $answer == 'DELETE VPSKIT' ]] || { warn '删除口令不匹配，未执行卸载。'; return 0; }
    # Resource cleanup occurs before removing ownership records. Failures stop deletion.
    swap_remove yes
    firewall_cleanup yes
    bbr_restore yes
    for u in "${UNITS[@]}"; do
        if [[ -f $SYSTEMD/$u ]]; then systemctl disable --now "$u"; rm -f "$SYSTEMD/$u"; fi
    done
    if [[ -L $ENTRY && $(readlink "$ENTRY") == "$ROOT/vpskit.sh" ]]; then rm -f "$ENTRY"; fi
    systemctl daemon-reload
    [[ $ROOT == /opt/vpskit ]] || die '最终删除仅允许正式安装路径 /opt/vpskit。'
    [[ $TX == 0 ]] || die '存在活动配置事务，拒绝完整删除。'
    LOGFILE=''
    rm -rf --one-file-system -- "$ROOT"
    ok 'VPSKit完整资料已删除；没有卸载共享依赖、修改SSH或清空防火墙。'
}

log() {
    local level=$1 color='' reset=''; shift
    if [[ -t 2 || ${COLOR_MODE:-auto} == always ]]; then
        case "$level" in OK) color=$GREEN;; WARN) color=$YELLOW;; ERROR) color=$RED;; *) color=$CYAN;; esac
        reset=$RESET
    fi
    printf '%s[%s]%s %s\n' "$color" "$level" "$reset" "$*" >&2
    if [[ -n $LOGFILE && -d ${LOGFILE%/*} ]]; then
        local stamp; printf -v stamp '%(%Y-%m-%dT%H:%M:%S%z)T' -1
        printf '[%s] [%s] %s\n' "$stamp" "$level" "$*" >> "$LOGFILE"
    fi
}
ask() {
    local ap_dest=$1 ap_label=$2 ap_default=${3:-} ap_reply
    [[ -n $TTY_FD ]] || die '此操作需要交互终端；输入 :q 可取消。'
    printf '%s%s%s' "$BOLD" "$ap_label" "$RESET" >&2
    [[ -z $ap_default ]] || printf ' %s[%s]%s' "$CYAN" "$ap_default" "$RESET" >&2
    printf ': ' >&2
    IFS= read -r -u "$TTY_FD" ap_reply || die '输入已关闭。'
    [[ $ap_reply != :q ]] || exit 130
    printf -v "$ap_dest" '%s' "${ap_reply:-$ap_default}"
}
secret() {
    local sp_dest=$1 sp_label=$2 sp_reply
    [[ -n $TTY_FD ]] || die '凭据输入需要终端。'
    printf '%s%s%s（不回显；:q取消）: ' "$YELLOW" "$sp_label" "$RESET" >&2
    IFS= read -r -s -u "$TTY_FD" sp_reply || die '输入已关闭。'
    printf '\n' >&2
    [[ $sp_reply != :q ]] || exit 130
    printf -v "$sp_dest" '%s' "$sp_reply"
}
advanced_edit() {
    local key=${1:-} value workers connections nofile description='' candidate_user
    local -a user_options=('auto|自动检测并复用已有合格服务账户')
    ui_title '高级参数修改'
    if [[ -z $key || $key == capacity ]]; then
        ui_note '用途：同时设置进程数、连接槽位与文件数预算，避免逐项修改造成临时不一致。'
        ui_note '要求：小内存从1个Worker开始；反向代理连接包括客户端和上游，不等于用户人数。'
        ask_valid workers 'Worker数量（auto或1～64）' "$(ng_value workers)" valid_worker_count
        ask_valid connections '每个Worker连接上限（128～65535）' "$(ng_value connections)" number 128 65535
        ask_valid nofile 'Nginx文件数上限（2048～1048576，至少为连接数+1024）' "$(ng_value nofile)" number 2048 1048576
        advanced_set nginx.workers "$workers" nginx.connections "$connections" nginx.nofile "$nofile"
        return
    fi
    case "$key" in
        nginx.worker_user)
            worker_users
            ui_note '要求：已有非root、禁止交互登录的服务账户；auto复用合格账户，不创建新用户。'
            for candidate_user in vpskit-www www-data nginx http nobody; do
                if service_user_valid "$candidate_user"; then user_options+=("$candidate_user|$candidate_user / UID $(id -u "$candidate_user")"); fi
            done
            user_options+=('manual|输入其他已有非登录服务账户')
            select_value value '选择Worker服务账户' "$(ng_value worker_user)" "${user_options[@]}"
            [[ $value != manual ]] || ask_valid value '已有账户名称' '' service_user_valid
            advanced_set "$key" "$value"; return;;
        nginx.sandbox_mode)
            select_value value '选择沙箱模式（先启动独立测试Worker，不降低Worker身份）' "$(ng_value sandbox_mode)" \
              'compatible|兼容：ProtectSystem=full；root Master允许正常文件权限范围内写入' \
              'strict|严格：ProtectSystem=strict；只允许日志/运行目录写入'
            advanced_set "$key" "$value"; return;;
        nginx.proxy_gzip|nginx.proxy_access_log|nginx.access_log|nginx.http2)
            select_value value "设置 $key" "$(ng_value "${key#nginx.}")" 'false|关闭' 'true|开启'
            advanced_set "$key" "$value"; return;;
        xray.nofile)
            ui_note '用途：Xray进程文件描述符上限；要求2048～1048576且不超过内核nr_open；应用会按需重启Xray。'
            value=$(xray_nofile);;
        nginx.*)
            description=$(menu_catalog | awk -F'|' -v k="param:${key#nginx.}" '$7==k{print "用途："$4"；要求："$5;exit}')
            [[ -n $description ]] || die '该参数请通过 advanced set 修改，或从高级面板选择有效选项。'
            ui_note "$description"; value=$(ng_value "${key#nginx.}");;
        *) die '未知高级参数。';;
    esac
    ask value "设置 $key（true/false用于开关；:q取消）" "$value"
    advanced_set "$key" "$value"
}
s1_base_paths_show() {
    cat <<EOF_PATHS
管理代码：$ROOT/vpskit.sh
快捷命令：$ENTRY
持久配置：$STATE（含凭据，禁止公开）
生成配置：$ROOT/config/nginx.conf / xray.json
网站文件：$ROOT/www/<domain>/
证书/私钥：$ROOT/certs/<domain>/current/
ACME账户与DNS凭据：$ROOT/acme/config/
历史快照：$ROOT/backup/history/（最近$HISTORY_KEEP份，包含敏感资料）
最近事务回滚：$ROOT/backup/last/
代码备份：$ROOT/backup/code/
服务文件：$SYSTEMD/vpskit-*.service / vpskit-maintain.timer
日志：$ROOT/logs/
启动诊断：$ROOT/logs/diagnostics/
强制恢复现场：$ROOT/backup/rescue/（不自动清理，需另行妥善备份/管理）
防火墙归属：$ROOT/data/firewall-v2.json（旧版firewall.json保持原样）
BBR归属：$ROOT/data/bbr-v2.json；持久化：/etc/sysctl.d/90-vpskit.conf
新Swap文件：$ROOT/swap/swapfile；记录：$ROOT/data/swap-v2.json
旧增强版Swap：/var/lib/vpskit/swapfile（仅确认归属后复用）
不要直接编辑生成配置；使用节点、网站和高级配置菜单。
配置快照不包含网站内容、组件二进制、防火墙、BBR或Swap，不能代替整机备份。
EOF_PATHS
}
logs_show() {
    local name=${1:-nginx} lines=${2:-100} file
    number "$lines" 1 2000 || die '日志行数应为1～2000。'
    warn '日志可能包含IP、路径和错误信息，分享前请脱敏。'
    if [[ $name == cert ]]; then journalctl -u vpskit-maintain.service -n "$lines" --no-pager; return; fi
    if [[ $name == preflight || $name == diagnostics ]]; then
        local pattern='*.log'; [[ $name != preflight ]] || pattern='vpskit-preflight-*.service.log'
        file=$(find "$ROOT/logs/diagnostics" -maxdepth 1 -type f -name "$pattern" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2- || true)
        [[ -n $file && -f $file && ! -L $file ]] || { info '暂无启动失败诊断。'; return 0; }
        printf '文件：%s\n' "$file"; tail -n "$lines" "$file"; return
    fi
    if [[ $name == service ]]; then journalctl -u vpskit-nginx.service -n "$lines" --no-pager; return; fi
    case "$name" in nginx) file=nginx.log;; xray) file=xray.log;; manager) file=manage.log;; service) file=nginx-service.log;; access) file=access.log;; *) die '日志类型：nginx/xray/manager/service/access/cert/diagnostics/preflight。';; esac
    [[ -f $ROOT/logs/$file && ! -L $ROOT/logs/$file ]] || { info '日志文件尚不存在；访问日志需在高级配置中先开启。'; return; }
    tail -n "$lines" "$ROOT/logs/$file"
}
s1_base_usage() {
    case "${1:-}" in
        workflow)
            cat <<'TEXT'
已有部署：先下载完整文件 → bash -n → selftest → update manager 本地文件 → 进入面板。
只换面板/代码不改state.json、不调用重启或reload；之后明确修改配置才应用。
新装：1部署向导 → 选择A或B → 安装组件 → 网站/证书（B）→ 节点 → 导出客户端。
中断恢复：14历史 → 查看快照/恢复中断事务；不要删除state.json重新开始。
高级参数：13 → 当前值 → 修改 → 确认；连接数提升必须同时检查文件数与RAM。
网站/节点：修改前自动创建配置快照；恢复范围不含网站内容、防火墙、Swap或BBR。
危险操作：红色提示 + yes确认；完整删除额外要求输入DELETE VPSKIT。
TEXT
            return;;
        colors)
            cat <<'TEXT'
紫色：面板标题；蓝色：选项编号/菜单；青色：参数与当前值。
绿色：正常/只读；黄色：注意/敏感/需检查；红色：失败/危险删除；灰色：说明。
默认仅在支持颜色的交互终端输出ANSI颜色，重定向输出自动关闭。
关闭：vpskit --no-color；强制：vpskit --color=always；环境变量NO_COLOR优先关闭。
演示：bash ./vpskit.sh preview；全部面板：bash ./vpskit.sh preview all。
preview/help/version/selftest不要求root或systemd，不创建安装目录。
TEXT
            return;;
        '') ;; *) die '帮助主题可选 workflow 或 colors。';;
    esac
    cat <<'TEXT'
VPSKit 完整单文件管理器（当前版本请运行 vpskit version；独立增强版，非上游官方发布）
用法：sudo bash ./vpskit.sh [选项] [命令] / sudo vpskit [选项] [命令]
不带命令进入彩色管理面板；每项均显示用途、要求和风险类别。
新功能：
  plan                              应用前服务动作预览（不应用）
  performance show                  查看资源与日志策略
  performance profile [eco|balanced|throughput]  选择预设后确认
  performance logging [off|errors|sample|full]   网站性能日志
  performance xray / retention      编号配置Xray策略 / 日志保留
  performance events / rotate       查看服务变动 / 有界日志检查
  performance permissions           仅修复网站权限（不重启）
  node batch [enable|disable] [1,2,3] 编号多选启停，一次提交
  advanced set xray.conn_idle 600 xray.buffer_kb auto
变更通过配置/证书/二进制内容比较后按需应用；仍然必要的Xray重启会中断现有会话。
选项：--no-color / --color=auto|always|never（位于命令之前）

version | help [workflow|colors] | selftest | preview [面板|all]  只读，无需root
dashboard [面板名]                         只读状态摘要；不初始化、不改配置
面板每次进入/返回或输入 R/r 刷新；等待输入时不自动刷新。
“配置开启”不是进程内配置验证；systemd不可用时显示未知，不误报关闭。
install [xray|nginx|acme] [Xray版本]         新装/继续向导或单独组件
wizard configure|status                   默认方案配置/已保存进度
apply | status | doctor | paths | network-check
node list|add|share|export|client [名称]
node enable|disable|delete|rotate|edit|listen [名称]
node rename|port|host|address [名称] [值]    地址/端口同步共享入口
site list|add|edit|remove [域名]
cert issue|settings [域名] | cert status | cert renew
cert import [域名 /证书链.pem /私钥.pem]    无参数时交互选择
advanced show|users|defaults | advanced edit [参数键|capacity]
advanced set nginx.workers 2 nginx.connections 2048 nginx.nofile 8192
advanced set nginx.worker_user auto | advanced set xray.nofile 16384
history list | history save [备注]
history restore [快照序号或ID] [full|state|advanced] | rollback | repair [--force]
recover [transaction|last|快照序号或ID] | rollback --force   原样强制恢复，编号选择
update manager [/新版.sh|HTTPS地址] [独立确认的SHA256]  仅替换代码
update nginx|xray|acme [Xray版本] | update all           单独更新组件
optimize status|bbr|restore|mtu [目标] | performance gzip [true|false]
edge status|show [域名] | edge edit | edge refresh | edge guide | edge traffic
edge profile|bots|limits|cache|origin|aop|probe|reset [域名]
edge set 域名 bots|rate|burst|connections|kbps|static_ttl|gzip|origin|aop 值
service nginx|xray start|stop|restart | service nginx reload
service all restart                        重启已配置Xray、Nginx和维护定时器
system reboot                              二次确认后正常重启整台VPS，不使用force
advanced preflight                         单独验证非root与当前沙箱，不重启正式服务
logs [nginx|xray|manager|service|access|cert|diagnostics|preflight] [行数]
firewall status | firewall open|close [端口] [tcp|udp|both]
firewall sync | firewall cleanup           支持已启用的UFW或firewalld
swap status | swap enable | swap custom [MiB] | swap remove
maintenance                               证书、日志、官方Cloudflare资料维护
uninstall [keep|xray|nginx|acme|all]         停用保留/分组件/完整删除

rebuild [--plan|--clean-history]           保留当前Xray，备份→生成/验证→重建Nginx；成功后可清旧历史
rebuild-restore /opt/vpskit/rebuild-backups/实际ID  恢复本次重建前Nginx；不改Xray

Xray版本沿用固定默认v26.3.27；显式指定latest才查询最新版。
代码更新不会重置配置或重启服务；应用新配置需要明确执行apply/保存设置。
操作默认不批准；:q取消；完整卸载有二次口令。不要公开state.json和备份。
TEXT
}
explain() {
    cat <<'TEXT'
方案 A：VLESS REALITY 直接连接VPS；无需网站域名证书，但需要合适且可达的TLS目标。
方案 B：域名 → Nginx TLS → XHTTP/WS的127.0.0.1后端；可选Cloudflare橙云。
网站支持静态文件/模板、本机HTTP反向代理和HTTPS重定向。
可另行添加VMess、Trojan、直接TLS和Shadowsocks；共享入口用户共用监听配置。
Nginx主进程保留root，Worker复用已有合格非root服务账户，私钥和状态文件保持私有。
worker_connections计算客户端及上游连接，不等于可用用户数；提高限额不保证吞吐提升。
默认不抢占外部服务端口、不改SSH、不启用/重置防火墙、不自动设置BBR。
部署需Debian/Ubuntu、root、systemd及软件源/组件源连通；公网需自行配置DNS及云安全组。
TEXT
}
# 1.7.3 recovery primitives. All modifying commands run under the manager lock.
select_value() {
    local sv_dest=$1 sv_title=$2 sv_default=$3 sv_item sv_value sv_label sv_reply sv_index=0 sv_default_index=1
    shift 3
    local -a sv_values=()
    printf '\n%s\n' "$sv_title" >&2
    for sv_item in "$@"; do
        sv_value=${sv_item%%|*}; sv_label=${sv_item#*|}; sv_values+=("$sv_value"); sv_index=$((sv_index+1))
        [[ $sv_value != "$sv_default" ]] || sv_default_index=$sv_index
        printf '  %s%2d.%s %s\n' "$BLUE" "$sv_index" "$RESET" "$sv_label" >&2
    done
    ((${#sv_values[@]})) || die '没有可选项。'
    printf '   0. 取消本次操作\n' >&2
    while :; do
        ask sv_reply '输入序号' "$sv_default_index"
        [[ $sv_reply != 0 ]] || exit 130
        if number "$sv_reply" 1 "${#sv_values[@]}"; then
            printf -v "$sv_dest" '%s' "${sv_values[sv_reply-1]}"; return 0
        fi
        warn '请输入列表中的数字；0或:q取消。'
    done
}
permissions_save() {
    local dest=$1 path
    : > "$dest" || return 1
    for path in "$ROOT" "$ROOT/run" "$ROOT/logs"; do
        [[ ! -e $path ]] || stat --printf '%a\t%u\t%g\t%n\0' -- "$path" >> "$dest" || return 1
    done
    for path in "$ROOT/www" "$ROOT/run/nginx"; do
        [[ -d $path && ! -L $path ]] || continue
        # NUL records preserve spaces, tabs and newlines in legitimate file names.
        find -P "$path" -xdev \( -type d -o -type f \) -exec stat --printf '%a\t%u\t%g\t%n\0' -- {} + >> "$dest" || return 1
    done
    chmod 600 "$dest"
}
permissions_restore() {
    local source=$1 record mode owner group path rest failed=0
    [[ -f $source && ! -L $source ]] || return 1
    while IFS= read -r -d '' record; do
        mode=${record%%$'\t'*}; rest=${record#*$'\t'}
        owner=${rest%%$'\t'*}; rest=${rest#*$'\t'}
        group=${rest%%$'\t'*}; path=${rest#*$'\t'}
        [[ $mode =~ ^[0-7]{3,4}$ && $owner =~ ^[0-9]+$ && $group =~ ^[0-9]+$ ]] || return 1
        [[ $path == "$ROOT" || $path == "$ROOT/"* ]] || return 1
        [[ $path != *'/../'* && $path != *'/./'* && ! -L $path ]] || return 1
        [[ -e $path ]] || continue  # Snapshots do not restore deleted website content.
        [[ $(realpath -m -- "$path") == "$path" ]] || return 1
        chown "$owner:$group" -- "$path" && chmod "$mode" -- "$path" || failed=1
    done < "$source"
    ((failed==0))
}
nginx_unit_properties() {
    local mode=$1 limit=$2 protect=strict
    choice "$mode" 'strict compatible' || return 1
    [[ $mode != compatible ]] || protect=full
    cat <<EOF
LimitNOFILE=$limit
LimitCORE=0
UMask=0027
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=$protect
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ReadWritePaths=$ROOT/logs $ROOT/run
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_SETUID CAP_SETGID CAP_CHOWN CAP_DAC_OVERRIDE CAP_FOWNER CAP_KILL CAP_SYS_RESOURCE
# systemd seccomp setup may drop effective SETUID unless explicitly ambient.
# Nginx setuid(nonroot) clears ambient/effective privileges; worker checks remain mandatory.
AmbientCapabilities=CAP_SETUID CAP_SETGID
EOF
}
nginx_conf_value() {
    local key=$1 file=$2
    [[ -r $file ]] || return 1
    awk -v k="$key" '{sub(/#.*/, "");gsub(/[{};]/," & ");for(i=1;i<NF;i++)if($i==k){print $(i+1);exit}}' "$file"
}
nginx_pid_valid() {
    local pid=$1 title exe expected
    [[ $pid =~ ^[1-9][0-9]*$ && -r /proc/$pid/cmdline ]] || return 1
    title=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || return 1
    [[ $title == 'nginx: master process '* ]] || return 1
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || return 1
    exe=${exe% (deleted)}; expected=$(realpath -m "$NGINX")
    [[ $exe == "$expected" || ${exe%'.new'} == "$expected" ]]
}
s1_base_nginx_master_pid() {
    local pid=''
    pid=$(timeout 3 systemctl show -p MainPID --value vpskit-nginx.service 2>/dev/null || true)
    if nginx_pid_valid "$pid"; then printf '%s' "$pid"; return 0; fi
    if [[ -f $ROOT/run/nginx.pid && ! -L $ROOT/run/nginx.pid ]]; then
        read -r pid < "$ROOT/run/nginx.pid" || true
        if nginx_pid_valid "$pid"; then printf '%s' "$pid"; return 0; fi
    fi
    return 1
}
worker_generation() {
    local pid uid birth
    while read -r pid uid; do
        birth=$(proc_start_ticks "$pid" 2>/dev/null || true)
        [[ -z $birth ]] || printf '%s:%s ' "$pid" "$birth"
    done < <(master_workers "$1")
}
failure_diagnostics() {
    local reason=${1:-failure} dir file pid
    dir="$ROOT/logs/diagnostics"
    [[ ! -L $dir ]] || return 1
    mkdir -p -m 700 "$dir" || return 1; chmod 700 "$dir"
    file="$dir/$(date -u '+%Y%m%dT%H%M%SZ')-$(randhex 4).log"
    {
        printf 'VPSKit %s | %s | %s\n' "$VERSION" "$reason" "$(date -u '+%FT%TZ')"
        printf '\n[service state]\n'
        timeout 5 systemctl show vpskit-nginx.service -p ActiveState -p SubState -p Result -p MainPID -p ExecMainStatus -p LimitNOFILE -p FragmentPath -p DropInPaths -p ProtectSystem -p User 2>&1 || true
        printf '\n[recent systemd errors]\n'
        timeout 5 journalctl -u vpskit-nginx.service --no-pager -n 60 2>&1 || true
        printf '\n[recent Nginx errors; may contain request URLs, keep private]\n'
        [[ ! -f $ROOT/logs/nginx.log ]] || tail -n 60 "$ROOT/logs/nginx.log"
        printf '\n[processes, no credentials printed by manager]\n'
        pid=$(nginx_master_pid || true)
        if [[ -n $pid ]]; then
            ps -ww --ppid "$pid" -p "$pid" -o pid,ppid,uid,gid,stat,args || true
            while read -r pid _; do
                grep -E '^(Name|State|PPid|Uid|Gid|CapEff):' "/proc/$pid/status" 2>/dev/null || true
                grep '^Max open files' "/proc/$pid/limits" 2>/dev/null || true
            done < <(master_workers "$pid")
        fi
        printf '\n[path permissions, not contents]\n'
        stat -c '%a %U:%G %n' "$ROOT" "$ROOT/www" "$ROOT/run" "$ROOT/run/nginx" "$ROOT/logs" "$ROOT/config" "$ROOT/certs" 2>/dev/null || true
        printf '\n[required public ports from saved state]\n'
        firewall_required_state "$STATE" 2>/dev/null || true
    } > "$file" 2>&1
    chmod 600 "$file"
    warn "诊断已保存：$file（可能包含请求路径，只给root读取，分享前脱敏）。"
}
# Isolated worker launch under the SAME systemd sandbox/capability/FD settings.
# A private UNIX socket is used: no public port or production PID file is touched.
preflight_launch() {
    local probe=$1 unit=$2 mode=$3 limit=$4 property help maxrun wait_s
    wait_s=$(ng_value startup_timeout); number "$wait_s" 5 180 || wait_s=30
    maxrun=$((wait_s*2+30)); ((maxrun>=60)) || maxrun=60
    local -a early=() options=(--quiet --unit="$unit" --property=Type=simple --property=User=root --property=Restart=no --property=KillSignal=SIGQUIT --property=KillMode=mixed --property=TimeoutStopSec=8 "--property=RuntimeMaxSec=$maxrun" "--property=WorkingDirectory=$probe")
    while IFS= read -r property; do
        [[ -n $property && $property != \#* ]] || continue
        [[ $property != ReadWritePaths=* ]] || property="ReadWritePaths=$ROOT/logs $ROOT/run $probe"
        options+=("--property=$property")
    done < <(nginx_unit_properties "$mode" "$limit")
    help=$("$NGINX" -h 2>&1 || true)
    [[ $help != *'-e filename'* ]] || early=(-e "$probe/error.log")
    # Keep exactly the production capability/sandbox policy. No automatic fallback
    # to root workers, unsandboxed execution, or broader capabilities on failure.
    systemd-run "${options[@]}" "$NGINX" "${early[@]}" -p "$probe/" -c "$probe/nginx.conf" -g 'daemon off;'
}
preflight_stop() {
    local unit=$1
    if ! timeout 12 systemctl stop "$unit" >/dev/null 2>&1; then
        warn "独立预检服务 $unit 停止未确认；保留其临时目录，不操作正式服务。"
        return 1
    fi
    systemctl reset-failed "$unit" >/dev/null 2>&1 || true
}
preflight_diagnostics() {
    local probe=$1 unit=$2 stage=$3 dir="$ROOT/logs/diagnostics" file pid='' child text='' hint='' path
    [[ ! -L $dir ]] || return 1
    mkdir -p -m 700 "$dir" || return 1; chmod 700 "$dir" || return 1
    file="$dir/$unit.log"; [[ ! -L $file ]] || return 1
    if [[ -r $probe/nginx.pid ]]; then read -r pid < "$probe/nginx.pid" || true; fi
    {
        printf 'VPSKit %s | preflight stage=%s | ' "$VERSION" "$stage"; date -u '+%FT%TZ'
        printf 'This snapshot is captured BEFORE stopping the private probe. Production services are untouched.\n'
        printf '\n[transient service state]\n'
        timeout 4 systemctl show "$unit" -p ActiveState -p SubState -p Result -p MainPID -p ExecMainCode -p ExecMainStatus -p User -p Group -p LimitNOFILE -p CapabilityBoundingSet -p AmbientCapabilities -p SecureBits -p NoNewPrivileges -p ProtectSystem -p ProtectProc -p ProcSubset -p DropInPaths 2>&1 || true
        printf '\n[master + ALL direct child processes, including unrecognized ones]\n'
        if [[ $pid =~ ^[1-9][0-9]*$ ]]; then
            ps -ww -p "$pid" --ppid "$pid" -o pid=,ppid=,uid=,gid=,stat=,comm=,args= 2>&1 || true
            printf 'task children: '; cat "$RUNTIME_PROC/$pid/task/$pid/children" 2>/dev/null || true; printf '\n'
            for child in "$pid" $(ps --ppid "$pid" -o pid= 2>/dev/null || true); do
                [[ $child =~ ^[1-9][0-9]*$ ]] || continue
                printf '\nPID=%s\n' "$child"
                grep -E '^(Name|State|PPid|Uid|Gid|CapEff|CapPrm|CapInh|CapAmb|CapBnd|NoNewPrivs|Seccomp):' "$RUNTIME_PROC/$child/status" 2>/dev/null || true
                grep '^Max open files' "$RUNTIME_PROC/$child/limits" 2>/dev/null || true
                printf 'stat start_ticks='; proc_start_ticks "$child" || true; printf '\n'
            done
        fi
        printf '\n[private probe paths, permissions only]\n'
        for path in "$probe" "$probe/www" "$probe/www/health" "$probe/client" "$probe/proxy" "$probe/front.sock" "$probe/back.sock"; do
            stat -c '%a %U:%G %n' "$path" 2>/dev/null || true
        done
        printf '\n[Nginx error tail, max 16 KiB]\n'
        [[ ! -r $probe/error.log ]] || tail -c 16384 "$probe/error.log"
        printf '\n[launcher output, max 8 KiB]\n'
        [[ ! -r $probe/launch.log ]] || tail -c 8192 "$probe/launch.log"
        printf '\n[transient service journal, before cleanup]\n'
        timeout 4 journalctl -u "$unit" --no-pager -n 60 -o short-iso 2>&1 || true
    } > "$file" 2>&1
    chmod 600 "$file" || return 1
    if hint=$(preflight_failure_hint "$probe"); then warn "预检关键错误：$hint"; fi
    warn "预检失败（阶段=$stage）：$file；正式服务未停止。可运行 vpskit logs preflight 120。"
    # Failures only: bounded archive, not a monitoring daemon. Keep at most 12.
    local -a archive=(); local n
    mapfile -t archive < <(find "$dir" -maxdepth 1 -type f -name 'vpskit-preflight-*.service.log' -printf '%T@ %p\n' | sort -nr | cut -d' ' -f2-)
    for ((n=12;n<${#archive[@]};n++)); do [[ ${archive[n]} == "$file" || -L ${archive[n]} ]] || rm -f -- "${archive[n]}"; done
}
preflight_cleanup() {
    local result=$1 probe=$2 unit=$3 stage=$4
    trap - EXIT ERR INT TERM
    set +e
    # Preserve live process evidence before systemctl stop removes it.
    if ((result!=0)); then preflight_diagnostics "$probe" "$unit" "$stage" || true; fi
    case "$stage" in prepare|syntax) rm -rf -- "$probe"; exit "$result";; esac
    if preflight_stop "$unit"; then
        rm -rf -- "$probe"
    else
        if ((result==0)); then preflight_diagnostics "$probe" "$unit" cleanup || true; fi
        result=1
        warn "临时路径保留：$probe；预检服务设有按启动超时计算的自动运行期限。不要以此跳过正式预检。"
    fi
    exit "$result"
}
nginx_preflight() (
    trap - EXIT ERR INT TERM
    set -Eeuo pipefail
    local candidate=${1:-} probe unit user group limit workers connections mode pid='' token ready=0 path
    local stage=prepare help response observed_token observed_pid='' extra deadline last_diag=-1 msg
    local -a early=()
    need runuser; need curl; need systemd-run
    user=$(resolve_worker) || return 1; group=$(id -gn "$user") || return 1
    service_user_valid "$user" || { warn '候选Worker账户不可用。'; return 1; }
    mode=$(ng_value sandbox_mode); limit=$(ng_value nofile); workers=$(ng_value workers); connections=$(ng_value connections)
    probe=$(mktemp -d "$PREFLIGHT_BASE/vpskit-probe.XXXXXXXX") || return 1
    unit="vpskit-preflight-${probe##*.}.service"
    trap 'preflight_cleanup "$?" "$probe" "$unit" "$stage"' EXIT
    trap 'exit 130' INT; trap 'exit 143' TERM
    chown "0:$group" "$probe" || return 1; chmod 0750 "$probe" || return 1
    mkdir -p "$probe/www" "$probe/client" "$probe/proxy" || return 1
    chown "0:$group" "$probe/www" || return 1; chmod 0750 "$probe/www" || return 1
    chown "$user:$group" "$probe/client" "$probe/proxy" || return 1; chmod 0700 "$probe/client" "$probe/proxy" || return 1
    token="vpskit-preflight-$(randhex 12)" || return 1
    printf '%s' "$token" > "$probe/www/health" || return 1
    chown "0:$group" "$probe/www/health" || return 1; chmod 0640 "$probe/www/health" || return 1
    runuser -u "$user" -- test -r "$probe/www/health" || return 1
    runuser -u "$user" -- test -w "$probe/client" || return 1
    if runuser -u "$user" -- test -r "$STATE"; then warn '候选账户能读取状态凭据，拒绝使用。'; return 1; fi
    cat > "$probe/nginx.conf" <<EOF
user $user $group;
worker_processes $workers;
worker_rlimit_nofile $limit;
pid $probe/nginx.pid;
error_log $probe/error.log notice;
events { worker_connections $connections; }
http {
    access_log off;
    client_body_temp_path $probe/client;
    proxy_temp_path $probe/proxy;
    client_body_buffer_size 1k;
    client_max_body_size 1m;
    server {
        listen unix:$probe/front.sock;
        root $probe/www;
        location = /health { try_files /health =404; }
        location = /worker { return 200 "$token \$pid"; }
        location = /upload { proxy_pass http://unix:$probe/back.sock:; proxy_request_buffering on; }
    }
    server { listen unix:$probe/back.sock; location / { return 204; } }
}
EOF
    [[ -s $probe/nginx.conf ]] || return 1; chmod 600 "$probe/nginx.conf" || return 1
    help=$("$NGINX" -h 2>&1 || true)
    [[ $help != *'-e filename'* ]] || early=(-e "$probe/error.log")
    stage=syntax
    "$NGINX" "${early[@]}" -t -p "$probe/" -c "$probe/nginx.conf" || return 1
    if [[ -n $candidate && -s $candidate ]]; then
        mkdir -p "$probe/fastcgi" "$probe/uwsgi" "$probe/scgi" || return 1
        awk -v d="$probe" '
          $1=="pid" {print "pid "d"/candidate.pid;";next}
          $1=="error_log" {print "error_log "d"/error.log notice;";next}
          $1=="access_log" {print "access_log off;";next}
          $1=="client_body_temp_path" {print "client_body_temp_path "d"/client;";next}
          $1=="proxy_temp_path" {print "proxy_temp_path "d"/proxy;";next}
          $1=="fastcgi_temp_path" {print "fastcgi_temp_path "d"/fastcgi;";next}
          $1=="uwsgi_temp_path" {print "uwsgi_temp_path "d"/uwsgi;";next}
          $1=="scgi_temp_path" {print "scgi_temp_path "d"/scgi;";next}
          {print}' "$candidate" > "$probe/candidate.check.conf" || return 1
        "$NGINX" "${early[@]}" -t -p "$probe/" -c "$probe/candidate.check.conf" || return 1
    fi
    local dropins
    dropins=$(timeout 3 systemctl show -p DropInPaths --value vpskit-nginx.service 2>/dev/null || true)
    [[ -z $dropins ]] || warn "发现额外systemd覆盖文件：$dropins；独立预检不加载它们，正式服务仍需核对。"
    info "先预检Worker=$user、进程=$workers、FD=$limit、沙箱=$mode；仅本机UNIX套接字。"
    stage=launch
    if ! preflight_launch "$probe" "$unit" "$mode" "$limit" > "$probe/launch.log" 2>&1; then
        warn 'systemd未接受预检启动；正在保留启动错误。'; return 1
    fi
    stage=readiness
    deadline=$((SECONDS+$(ng_value startup_timeout)))
    while ((SECONDS<deadline)); do
        if ((SECONDS!=last_diag)); then
            last_diag=$SECONDS
            preflight_unit_failed "$unit" && return 1
            if msg=$(preflight_failure_hint "$probe"); then warn "预检启动错误：$msg"; return 1; fi
        fi
        if [[ -s $probe/nginx.pid ]]; then
            read -r pid < "$probe/nginx.pid" || true
            if nginx_pid_valid "${pid:-}"; then
                response=$(curl --noproxy '*' -fsS --connect-timeout 1 --max-time 1 --unix-socket "$probe/front.sock" http://localhost/worker 2>/dev/null || true)
                observed_token=''; observed_pid=''; extra=''
                read -r observed_token observed_pid extra <<< "$response"
                if [[ $observed_token == "$token" && $observed_pid =~ ^[1-9][0-9]*$ && -z $extra ]]; then ready=1; break; fi
            fi
        fi
        sleep .25
    done
    ((ready==1)) || { warn "预检未就绪：Master=${pid:-未发现}；私有HTTP探针未收到合法Worker响应。不是仅凭进程数判断。"; return 1; }
    stage=worker-identity
    verify_nginx_runtime '' "$pid" "$probe/nginx.conf" no "$unit" "$probe" "$observed_pid" || return 1
    stage=static-and-upload
    [[ $(curl --noproxy '*' -fsS --max-time 5 --unix-socket "$probe/front.sock" http://localhost/health) == "$token" ]] || { warn '预检Worker无法读取静态文件。'; return 1; }
    head -c 65536 /dev/zero > "$probe/upload.bin" || return 1
    [[ $(curl --noproxy '*' -sS --max-time 8 --unix-socket "$probe/front.sock" -o /dev/null -w '%{http_code}' --data-binary @"$probe/upload.bin" http://localhost/upload) == 204 ]] || { warn '预检请求体缓冲或本机代理失败。'; return 1; }
    if [[ -n $(find -P "$ROOT/www" -xdev \( -type l -o \( -type f -links +1 \) \) -print -quit) ]]; then
        warn '网站内含链接；请先改为实际文件后再切换账户。'; return 1
    fi
    stage=complete
    ok "非root预检通过：响应Worker PID=$observed_pid、身份/文件数/静态读取/上传缓冲均已核验。"
)
nginx_preflight_current() {
    ensure_component nginx
    # Preview the candidate produced by CURRENT code, not the old root-worker file.
    # Keep both state.json and the active Nginx config byte-for-byte unchanged.
    local candidate="$WORK/nginx.preflight.conf"
    validate_state
    render_nginx "$candidate"
    info '只验证新代码生成的候选配置，不应用、不创建历史事务、不重启正式Nginx/Xray。'
    nginx_preflight "$candidate"
}
history_dirs() {
    [[ -d $ROOT/backup/history ]] || return 0
    find "$ROOT/backup/history" -mindepth 1 -maxdepth 1 -type d -name '????????T??????Z-????????' -printf '%T@ %p\n' | sort -k1,1nr -k2,2r | cut -d' ' -f2-
}
history_select() {
    local hs_dest=$1 hs_input=${2:-} hs_dir hs_id hs_description
    local -a hs_ids=() hs_options=()
    while IFS= read -r hs_dir; do
        [[ -f $hs_dir/meta.json && -f $hs_dir/state.json ]] || continue
        hs_id=${hs_dir##*/}; hs_ids+=("$hs_id")
        hs_description=$(jq -r '"\(.created) | \(.reason) | \(.manager)"' "$hs_dir/meta.json" 2>/dev/null || printf '元信息损坏')
        hs_options+=("$hs_id|$hs_id | $(panel_clean "$hs_description")")
    done < <(history_dirs)
    ((${#hs_ids[@]})) || die '没有可恢复快照。'
    if [[ -z $hs_input ]]; then select_value hs_input '选择历史快照（最新在前）' "${hs_ids[0]}" "${hs_options[@]}"
    elif number "$hs_input" 1 "${#hs_ids[@]}"; then hs_input=${hs_ids[hs_input-1]}; fi
    [[ $hs_input =~ ^[0-9]{8}T[0-9]{6}Z-[a-f0-9]{8}$ && -d $ROOT/backup/history/$hs_input ]] || die '快照序号/ID无效。'
    printf -v "$hs_dest" '%s' "$hs_input"
}
s1_base_firewall_required_state() {
    local file=$1
    state_basic "$file" 2>/dev/null || return 0
    jq -r '
      (if .components.nginx==true then "80 tcp", (if any(.sites[]; .issued==true) then "443 tcp" else empty end) else empty end),
      ([.nodes[] | select(.enabled==true and .mode!="ws" and .mode!="xhttp" and
        (.listen // "0.0.0.0")!="127.0.0.1" and (.listen // "0.0.0.0")!="::1")]
       | unique_by(.entry)[] | "\(.port) tcp", (if .mode=="ss" then "\(.port) udp" else empty end))
      ' "$file" | sort -k1,1n -k2,2 -u
}
recovery_firewall() {
    local how=${1:-check} rules backend='' zone='' port proto answer output external failed=0 listening hint
    rules=$(firewall_required_state "$STATE")
    [[ -n $rules ]] || { info '当前保存配置没有需核对的公网监听端口。'; return 0; }
    backend=$(fw_backend 2>/dev/null) || backend=unknown
    printf '\n恢复/变更后的公网端口核对（不开放WS/XHTTP本机后端）：\n'
    while read -r port proto; do
        valid_port "$port" && choice "$proto" 'tcp udp' || { warn '状态含无效端口，停止网络核对。'; return 1; }
        listening='未发现监听'
        if [[ $proto == tcp ]]; then output=$(ss -H -lnt "sport = :$port" 2>/dev/null || true)
        else output=$(ss -H -lnu "sport = :$port" 2>/dev/null || true); fi
        [[ -z $output ]] || listening='存在本机监听（未验证应用协议）'
        hint='防火墙规则未知'
        if [[ $backend == ufw ]]; then
            output=$(ufw status numbered 2>/dev/null || true)
            if awk -v p="$port/$proto" '{hit=0;for(i=1;i<=NF;i++)if($i==p)hit=1;if(hit && /DENY|REJECT/)found=1} END {exit !found}' <<< "$output"; then hint='发现拒绝规则，需核对优先级'
            elif awk -v p="$port/$proto" '{hit=0;for(i=1;i<=NF;i++)if($i==p)hit=1;if(hit && /ALLOW/)found=1} END {exit !found}' <<< "$output"; then hint='存在ALLOW规则；来源/IPv6/顺序仍需核对'
            else hint='未确认匹配的UFW放行规则'; fi
        elif [[ $backend == firewalld ]]; then hint='firewalld开启；需按公网接口所在zone核对'; fi
        printf '  %s/%s：%s；%s\n' "$port" "$proto" "$listening" "$hint"
    done <<< "$rules"
    warn '本机规则/监听不等于公网可达；云安全组、外部防火墙、Docker/nftables链及IPv6需另外核对。'
    [[ $how != ask || -n $TTY_FD ]] || how=check
    if [[ $how == ask ]]; then
        select_value answer '端口处理方式（不修改SSH，不删除旧/外部规则）' check \
          'check|仅核对：保留当前防火墙，不修改规则' \
          'sync|显式补齐当前所需端口：只操作已启用的UFW/firewalld'
        how=$answer
    fi
    [[ $how == sync ]] || return 0
    if [[ $backend == unknown ]]; then warn '没有唯一可用的UFW/firewalld；未启用或重置任何防火墙，请人工核对。'; return 1; fi
    fw_choose_zone zone "$backend"
    confirm '按上列端口补齐本工具放行规则；不关闭旧端口、不覆盖外部规则、不操作云安全组' || return 0
    while read -r port proto; do
        if ! ( trap - EXIT ERR; fw_guard_port "$port" "$proto" ); then
            warn "跳过受保护/异常端口 $port/$proto。"; failed=1; continue
        fi
        # Run each update in an isolated child: a conflicting rule must not undo recovered services.
        if ! ( trap - EXIT ERR; set -e; fw_apply_rule "$backend" "$zone" "$port" "$proto" allow ); then
            warn "$port/$proto 未能自动补齐；保留已恢复服务，需人工核对。"; failed=1
        fi
    done <<< "$rules"
    ((failed==0))
}
service_wait_active() {
    local unit=$1 deadline=$((SECONDS+30)) state stable=0
    while ((SECONDS<=deadline)); do
        state=$(systemctl is-active "$unit" 2>/dev/null || true)
        if [[ $state == active ]]; then stable=$((stable+1)); ((stable<2)) || return 0
        elif [[ $state == failed ]]; then return 1
        else stable=0; fi
        sleep .3
    done
    warn "$unit 未在等待时间内稳定运行。"; return 1
}
recovery_make_units() {
    local dest=$1 snap=$2 limit user xlimit
    mkdir -p "$dest"
    limit=$(nginx_conf_value worker_rlimit_nofile "$snap/config/nginx.conf" || true); limit=${limit:-8192}
    number "$limit" 512 1048576 || return 1
    xlimit=$(jq -r '.advanced.xray.nofile // 8192' "$snap/state.json")
    number "$xlimit" 512 1048576 || return 1
    user=$(nginx_conf_value user "$snap/config/nginx.conf" || true)
    cat > "$dest/vpskit-nginx.service" <<EOF
# VPSKIT_OWNED
# recovery compatible unit; original nginx.conf remains unchanged
[Unit]
Description=VPSKit Nginx recovery (worker user: $user)
After=network-online.target
[Service]
Type=simple
User=root
ExecStartPre=/bin/bash $ROOT/vpskit.sh _service nginx-test
ExecStart=/bin/bash $ROOT/vpskit.sh _service nginx
ExecReload=/bin/bash $ROOT/vpskit.sh _service nginx-reload
KillSignal=SIGQUIT
KillMode=mixed
TimeoutStopSec=30
Restart=on-failure
RestartSec=5
$(nginx_unit_properties compatible "$limit")
[Install]
WantedBy=multi-user.target
EOF
    cat > "$dest/vpskit-xray.service" <<EOF
# VPSKIT_OWNED
[Unit]
Description=VPSKit Xray recovery
After=network-online.target
[Service]
Type=simple
User=root
ExecStart=/bin/bash $ROOT/vpskit.sh _service xray
Restart=on-failure
RestartSec=5
LimitNOFILE=$xlimit
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
UMask=0077
[Install]
WantedBy=multi-user.target
EOF
    cat > "$dest/vpskit-maintain.service" <<EOF
# VPSKIT_OWNED
[Unit]
Description=VPSKit maintenance
[Service]
Type=oneshot
User=root
ExecStart=/bin/bash $ROOT/vpskit.sh maintenance
TimeoutStartSec=30min
UMask=0077
EOF
    cat > "$dest/vpskit-maintain.timer" <<'EOF'
# VPSKIT_OWNED
[Unit]
Description=VPSKit daily maintenance
[Timer]
OnCalendar=daily
RandomizedDelaySec=3600
Persistent=true
[Install]
WantedBy=timers.target
EOF
}
force_recover() {
    local target=${1:-} origin bundle="$WORK/recovery-selected" rescue choice_mode confirmation u source state_file nguser
    local -a options=()
    [[ ! -d $ROOT/backup/transaction ]] || options+=('transaction|未完成事务的操作前配置（优先恢复此次失败之前）')
    [[ ! -d $ROOT/backup/last ]] || options+=('last|最近已提交事务的操作前配置')
    local hd desc
    while IFS= read -r hd; do
        [[ -f $hd/state.json && -f $hd/meta.json ]] || continue
        desc=$(jq -r '.reason // "历史快照"' "$hd/meta.json" 2>/dev/null || printf '元信息损坏')
        options+=("${hd##*/}|${hd##*/} | $(panel_clean "$desc")")
    done < <(history_dirs)
    ((${#options[@]})) || die '没有可用的事务或历史快照。'
    if [[ -z $target ]]; then select_value target '强制恢复来源（保留当前失败现场，不重新生成代理配置）' '' "${options[@]}"; fi
    case "$target" in
        transaction|last)
            origin="$ROOT/backup/$target"
            [[ -f $origin/ready && -d $origin/snapshot ]] || die '此来源不是完整的新格式事务；旧版tree格式请先运行普通repair。'
            ( snapshot_verify "$origin/snapshot" ) || die '所选事务快照校验失败。'
            cp -a "$origin" "$bundle";;
        *)
            history_select target "$target"; origin="$ROOT/backup/history/$target"
            snapshot_verify "$origin"
            mkdir -p "$bundle"
            cp -a "$origin" "$bundle/snapshot"
            mkdir -p "$bundle/units"
            [[ ! -d $origin/units ]] || cp -a "$origin/units/." "$bundle/units/"
            printf 'ready\n' > "$bundle/ready";;
    esac
    state_file="$bundle/snapshot/state.json"
    for u in nginx xray; do
        [[ $(jq -r ".components.$u // false" "$state_file") == true ]] || continue
        if [[ $u == nginx ]]; then source=$NGINX; [[ ! -x $bundle/programs/nginx/usr/sbin/nginx ]] || source="$bundle/programs/nginx/usr/sbin/nginx"
        else source=$XRAY; [[ ! -x $bundle/programs/bin/xray ]] || source="$bundle/programs/bin/xray"; fi
        [[ -x $source ]] || die "恢复需要$u程序，但当前和事务备份均缺失。"
    done
    select_value choice_mode '恢复服务方式' exact \
      'exact|原样恢复：使用备份中的服务单元和Nginx/Xray配置' \
      'compatible|兼容恢复：保留代理配置，只替换服务沙箱为兼容配置'
    nguser=$(nginx_conf_value user "$bundle/snapshot/config/nginx.conf" || true)
    if [[ $nguser == root ]]; then
        warn '选中的是历史root Worker配置；只允许你显式批准原样恢复，不会自动把新配置降级为root。'
        ask confirmation '输入 RESTORE ROOT WORKER 才允许恢复此历史身份' ''
        [[ $confirmation == 'RESTORE ROOT WORKER' ]] || return 0
    fi
    warn '强制恢复不绕过语法检查、不抢占外部端口；将启动已配置Nginx、有启用节点的Xray及维护定时器。'
    warn '当前配置/权限和未完成事务会另存至backup/rescue；网站文件、Swap、BBR和系统防火墙不被整盘回滚。'
    confirm "从 $target 执行强制恢复（$choice_mode）；可能短暂中断连接" || return 0
    rescue="$ROOT/backup/rescue/$(date -u '+%Y%m%dT%H%M%SZ')-$(randhex 4)"
    mkdir -p -m 700 "$rescue"
    snapshot_copy "$rescue/before" 'before-forced-recovery'
    [[ ! -d $ROOT/backup/transaction ]] || cp -a "$ROOT/backup/transaction" "$rescue/interrupted-transaction"
    cp -a "$bundle" "$rescue/selected-target"
    printf '%s\n' "$target" > "$rescue/source"
    if [[ $choice_mode == compatible || ! -f $bundle/units/vpskit-nginx.service || ! -f $bundle/units/vpskit-xray.service ]]; then
        mkdir -p "$WORK/recovery-units"
        recovery_make_units "$WORK/recovery-units" "$bundle/snapshot" || die '无法准备兼容服务单元。'
        for u in "${UNITS[@]}"; do
            if [[ $choice_mode == compatible || ! -f $bundle/units/$u ]]; then cp "$WORK/recovery-units/$u" "$bundle/units/$u"; fi
        done
        warn '使用兼容服务单元；旧快照缺少的单元已补齐，Nginx/Xray业务配置未重新生成。'
    fi
    # Force recovery means bring configured services back, not preserve a captured failed state.
    : > "$bundle/active"; : > "$bundle/enabled"
    if [[ $(jq -r '.components.xray // false' "$state_file") == true && $(jq '[.nodes[]|select(.enabled==true)]|length' "$state_file") -gt 0 ]]; then printf 'vpskit-xray.service\n' >> "$bundle/active"; fi
    [[ $(jq -r '.components.nginx // false' "$state_file") != true ]] || printf 'vpskit-nginx.service\n' >> "$bundle/active"
    printf 'vpskit-maintain.timer\n' >> "$bundle/active"
    cp "$bundle/active" "$bundle/enabled"
    ensure_manager_installed
    TX=0  # Never replace this rescue attempt with recursive automatic recovery.
    if ! restore_transaction "$bundle" force; then
        failure_diagnostics forced-recovery || true
        die "强制恢复未全部成功；失败现场及目标保留在 $rescue。未删除原未完成事务。"
    fi
    [[ ! -d $ROOT/backup/transaction ]] || rm -rf -- "$ROOT/backup/transaction"
    printf 'restored %s\n' "$(date -u '+%FT%TZ')" > "$rescue/result"
    ok "配置与服务恢复完成；原失败现场：$rescue"
    recovery_firewall ask || warn '服务已恢复，但部分网络放行未确认；请进入防火墙面板核对。'
}
restart_all_components() {
    local u count=0 failed=0 name
    local -a targets=()
    for name in xray nginx; do
        component_ready "$name" || continue
        if [[ $name == xray && $(jq '[.nodes[]|select(.enabled==true)]|length' "$STATE") == 0 ]]; then
            info 'Xray没有启用节点，跳过启动。'; continue
        fi
        u="vpskit-$name.service"
        [[ -f $SYSTEMD/$u && ! -L $SYSTEMD/$u ]] && grep -Fq '# VPSKIT_OWNED' "$SYSTEMD/$u" || die "缺少本工具服务单元：$u"
        if [[ $name == nginx ]]; then nginx_cmd -t -p "$ROOT/" -c "$ROOT/config/nginx.conf" || die "Nginx语法检查失败，未重启任何组件。"
        else "$XRAY" run -test -config "$ROOT/config/xray.json" || die "Xray配置检查失败，未重启任何组件。"; fi
        targets+=("$u")
    done
    if [[ -f $SYSTEMD/vpskit-maintain.timer && ! -L $SYSTEMD/vpskit-maintain.timer ]] && grep -Fq '# VPSKIT_OWNED' "$SYSTEMD/vpskit-maintain.timer"; then targets+=(vpskit-maintain.timer); fi
    ((${#targets[@]})) || { info '没有可重启的已配置组件。'; return 0; }
    printf '重启顺序：%s\n' "${targets[*]}"
    warn 'ACME不是常驻进程：只重启维护定时器，不立即重复签发证书；不重启系统，不改自启设置。'
    confirm '重启全部上述组件；当前网站和代理连接可能中断' || return 0
    for u in "${targets[@]}"; do
        systemctl reset-failed "$u" >/dev/null 2>&1 || true
        if ! systemctl restart "$u"; then warn "$u 重启命令失败。"; failed=1; continue; fi
        if [[ $u == vpskit-nginx.service ]]; then
            if ! verify_nginx_runtime '' '' "$ROOT/config/nginx.conf"; then failed=1; failure_diagnostics restart-all || true; fi
        elif ! service_wait_active "$u"; then failed=1; fi
    done
    ((failed==0)) || die '部分组件重启失败；已逐项报告，不会自动重启整个系统。'
    ok '全部目标组件已完成本机运行检查；不等于公网连接验收。'
}
system_reboot() {
    local reply u
    [[ ! -d $ROOT/backup/transaction ]] || die '存在未完成事务；先repair/recover恢复服务，避免带故障重启。'
    warn '将重启整台VPS：SSH、网站、代理及其他应用都会断开；请确保能使用云厂商控制台。'
    for u in vpskit-nginx.service vpskit-xray.service; do
        [[ -f $SYSTEMD/$u ]] || continue
        systemctl is-enabled --quiet "$u" || warn "$u 未启用开机启动，重启后可能不会自动恢复。"
    done
    ask reply '输入 REBOOT 确认重启整台VPS' ''
    [[ $reply == REBOOT ]] || { info '已取消系统重启。'; return 0; }
    confirm '最后确认：立即正常重启系统；本工具不使用强制重启参数' || return 0
    if state_basic "$STATE"; then history_save before-system-reboot; fi
    sync
    systemctl reboot || die '系统未接受重启请求；未尝试强制重启。'
    info '系统已接受正常重启请求；重启完成后需重新连接并检查状态。'
}

# 1.7.6: a single, current-state-only rebuild. Never use historical snapshots as input.
# Xray JSON/binary/unit are read-only throughout; rollback touches Nginx and state only.
rebuild_sync_state() {
    local out=$1 xconfig=$2 report=$3 node inbound entry mode protocol port path listen expected actual file
    state_basic "$STATE" || { warn '需要当前有效state.json以保留域名/证书/网站关联；不会猜测或初始化空配置。'; return 1; }
    [[ -f $xconfig && ! -L $xconfig ]] || return 1
    jq -e 'type=="object" and (.inbounds|type=="array") and
      (.inbounds|all(.tag|type=="string")) and ([.inbounds[].tag]|length==(unique|length))' "$xconfig" >/dev/null || {
        warn 'Xray配置不是受支持的单文件JSON或入口tag不唯一；未重建。'; return 1; }
    cp -- "$STATE" "$out" || return 1
    printf '入口\t传输\tXray实际端口\t路径来源\n' > "$report" || return 1
    # Refuse ambiguity: unknown/missing entries and mismatched credentials are not silently imported.
    expected=$(jq -c '[.nodes[]|select(.enabled)|.entry]|unique|sort' "$out") || return 1
    actual=$(jq -c '[.inbounds[].tag]|sort' "$xconfig") || return 1
    [[ $expected == "$actual" ]] || { warn '当前启用入口与Xray入口不一一对应；保留原服务，请先核对映射。'; return 1; }
    while IFS= read -r node; do
        entry=$(jq -r .entry <<< "$node"); mode=$(jq -r .mode <<< "$node"); protocol=$(jq -r .protocol <<< "$node")
        inbound=$(jq -ce --arg e "$entry" '.inbounds[]|select(.tag==$e)' "$xconfig") || return 1
        [[ $(jq -r .protocol <<< "$inbound") == "$protocol" ]] || { warn "入口 $entry 协议冲突。"; return 1; }
        port=$(jq -r .port <<< "$inbound"); valid_port "$port" || return 1
        listen=$(jq -r '.listen // "0.0.0.0"' <<< "$inbound")
        actual=$(jq -r '.streamSettings.network // "tcp"' <<< "$inbound")
        expected=$(jq -r '.streamSettings.security // "none"' <<< "$inbound")
        path=''
        case "$mode" in
            ws|xhttp)
                [[ $actual == "$mode" && $expected == none && $listen == 127.0.0.1 ]] || {
                    warn "入口 $entry 不是受支持的127.0.0.1 HTTP后端；未猜测TLS/地址。"; return 1; }
                if [[ $mode == ws ]]; then path=$(jq -r .streamSettings.wsSettings.path <<< "$inbound")
                else
                    [[ $(jq -r '.streamSettings.xhttpSettings.mode // "auto"' <<< "$inbound") == packet-up ]] || {
                        warn "入口 $entry 的XHTTP不是既有packet-up模式；请单独确认转发方案。"; return 1; }
                    path=$(jq -r .streamSettings.xhttpSettings.path <<< "$inbound")
                    [[ $path == */ ]] || { warn "入口 $entry 的XHTTP路径需要保留尾斜线，不能无依据改写。"; return 1; }
                    path=${path%/}
                fi
                valid_path "$path" || { warn "入口 $entry 路径超出本生成器的安全范围。"; return 1; };;
            ws-plain)
                [[ $actual == ws && $expected == none ]] || return 1
                path=$(jq -r .streamSettings.wsSettings.path <<< "$inbound"); valid_path "$path" || return 1;;
            tls|reality)
                [[ $actual == tcp || $actual == raw ]] && [[ $expected == "$mode" ]] || return 1;;
            ss) [[ $protocol == shadowsocks ]] || return 1;;
            *) warn "不支持自动重建的传输：$mode"; return 1;;
        esac
        if [[ $protocol == shadowsocks ]]; then
            [[ $(jq -r .settings.password <<< "$inbound") == "$(jq -r .credential <<< "$node")" &&
               $(jq -r .settings.method <<< "$inbound") == "$(jq -r .method <<< "$node")" ]] || return 1
        else
            expected=$(jq -c --arg e "$entry" '[.nodes[]|select(.enabled and .entry==$e)|.credential]|sort' "$out") || return 1
            actual=$(jq -c --arg p "$protocol" '[.settings.clients[]|(if $p=="trojan" then .password else .id end)]|sort' <<< "$inbound") || return 1
            [[ $expected == "$actual" ]] || { warn "入口 $entry 用户凭据与当前资料不一致；未覆盖或重新生成凭据。"; return 1; }
        fi
        file="$out.next"
        jq --arg e "$entry" --argjson p "$port" --arg path "$path" --arg l "$listen" '
          (.nodes[]|select(.entry==$e)) |= (.port=$p | .listen=$l |
          if $path!="" then .path=$path else . end)' "$out" > "$file" && mv -f "$file" "$out" || return 1
        printf '%s\t%s\t%s\t%s\n' "$entry" "$mode" "$port" "$([[ -n $path ]] && printf Xray || printf 直连-不经Nginx)" >> "$report" || return 1
    done < <(jq -c '[.nodes[]|select(.enabled)]|unique_by(.entry)[]' "$out")
    # Scope STATE only inside this subshell: original state is not migrated until commit.
    (
        STATE=$out
        migrate_state || exit 1
        remember_worker || exit 1
        validate_state || exit 1
    ) || return 1
    chmod 600 "$out" "$report"
}
rebuild_guard_layout() {
    local p dropins unit
    for p in "$ROOT/rebuild-backups" "$ROOT/config/nginx.conf" "$ROOT/config/xray.json" "$ROOT/config/.runtime-applied.json" "$SYSTEMD/vpskit-nginx.service"; do
        [[ ! -L $p ]] || { warn "拒绝符号链接目标：$p"; return 1; }
    done
    unit="$SYSTEMD/vpskit-nginx.service"
    [[ -f $unit ]] && grep -Fq '# VPSKIT_OWNED' "$unit" || { warn '现有Nginx服务并非本工具托管，拒绝接管。'; return 1; }
    dropins=$(timeout 5 systemctl show -p DropInPaths --value vpskit-nginx.service) || return 1
    [[ -z $dropins ]] || { warn "检测到额外服务覆盖文件：$dropins；简化重建不删除外部安全策略，请先核对。"; return 1; }
}
rebuild_guard_xray() {
    local pid port output
    systemctl is-active --quiet vpskit-xray.service || { warn '本模式要求现有Xray正在运行；不会代为重启Xray。'; return 1; }
    pid=$(systemctl show -p MainPID --value vpskit-xray.service) || return 1
    [[ $pid =~ ^[1-9][0-9]*$ ]] || return 1
    while IFS= read -r port; do
        output=$(ss -H -lntp "sport = :$port") || return 1
        [[ $output == *"pid=$pid,"* ]] || { warn "Xray配置端口 $port 未由当前Xray主进程监听；请先核对磁盘配置与运行进程。"; return 1; }
    done < <(jq -r '.inbounds[].port' "$ROOT/config/xray.json")
}
rebuild_backup_create() {
    local dest=$1
    [[ ! -e $dest && ! -L $dest ]] || return 1
    mkdir -p -m 700 "$ROOT/rebuild-backups" || return 1
    chmod 700 "$ROOT/rebuild-backups" || return 1
    snapshot_copy "$dest" current-before-nginx-rebuild || return 1
    [[ ! -f $ROOT/vpskit.sh ]] || cp -a "$ROOT/vpskit.sh" "$dest/manager-before.sh" || return 1
    jq '.includes += ["manager-before.sh"] | .excludes |= map(select(.!="manager code"))' "$dest/meta.json" > "$dest/.meta.next" || return 1
    mv -f "$dest/.meta.next" "$dest/meta.json" || return 1
    printf 'VPSKIT_REBUILD_V1\n' > "$dest/.rebuild-owned" || return 1
    (cd "$dest" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 -r sha256sum > SHA256SUMS) || return 1
    (snapshot_verify "$dest") || return 1
    info "当前配置应急备份已校验：$dest（含凭据/证书；不包含网站内容或旧历史集合）"
}
rebuild_restore_nginx() {
    local backup=$1 was_active=$2 unit="$SYSTEMD/vpskit-nginx.service" file
    (snapshot_verify "$backup") || return 1
    warn '正在只恢复本次重建前的Nginx配置/服务/权限；不停止或改写Xray。'
    systemctl stop vpskit-nginx.service || return 1
    for file in nginx.conf .runtime-applied.json; do
        if [[ -f $backup/config/$file ]]; then cp -a "$backup/config/$file" "$ROOT/config/$file" || return 1
        else rm -f -- "$ROOT/config/$file" || return 1; fi
    done
    cp -a "$backup/state.json" "$STATE" || return 1
    cp -a "$backup/units/vpskit-nginx.service" "$unit" || return 1
    permissions_restore "$backup/permissions.nul" || return 1
    systemctl daemon-reload || return 1
    systemctl reset-failed vpskit-nginx.service >/dev/null 2>&1 || true
    if [[ $was_active == yes ]]; then
        nginx_cmd -t -p "$ROOT/" -c "$ROOT/config/nginx.conf" || return 1
        systemctl start vpskit-nginx.service || return 1
        # Recovery of the explicitly captured baseline may temporarily restore legacy root workers.
        [[ $(nginx_conf_value user "$ROOT/config/nginx.conf" || true) != root ]] || warn '恢复的是操作前历史root Worker；未声称降权已完成。'
        verify_nginx_runtime '' '' "$ROOT/config/nginx.conf" yes || return 1
    fi
    return 0
}
rebuild_finish() {
    local result=$1 backup=$2 changed=$3 was_active=$4
    trap - EXIT ERR INT TERM
    set +e
    if ((result!=0)) && [[ $changed == yes ]]; then
        failure_diagnostics nginx-rebuild-failed || true
        if rebuild_restore_nginx "$backup" "$was_active"; then
            warn "本次重建未提交；已恢复原Nginx。旧历史未清理，应急备份保留：$backup"
        else warn "Nginx恢复失败；备份保留在 $backup。Xray未被本流程重启。"; fi
    elif ((result!=0)); then warn "重建在正式切换前停止；原服务/历史未清理。应急备份：${backup:-尚未创建}"; fi
    exit "$result"
}
rebuild_clean_history() {
    local item path mountpoint mounts
    mounts=$(findmnt -rn -o TARGET) || { warn '无法确认挂载点，未清理历史。'; return 1; }
    # Deliberately a fixed whitelist. NEVER journalctl --vacuum, shell history, cloud snapshots,
    # runtime PID/socket directories, active configs, certs, BBR, swap or firewall rules.
    local -a items=(history last rescue code transaction)
    for item in "${items[@]}"; do
        path="$ROOT/backup/$item"
        [[ ! -e $path && ! -L $path ]] && continue
        [[ -d $path && ! -L $path && $(realpath -m "$path") == "$path" ]] || { warn "未清理异常历史路径：$path"; return 1; }
        while IFS= read -r mountpoint; do
            [[ $mountpoint != "$path" && $mountpoint != "$path/"* ]] || { warn "历史目录包含挂载点，未清理：$mountpoint"; return 1; }
        done <<< "$mounts"
    done
    for item in "${items[@]}"; do
        path="$ROOT/backup/$item"
        [[ ! -d $path ]] || rm -rf --one-file-system -- "$path" || return 1
    done
    ok '已清理VPSKit已识别的历史/最近回滚/旧救援/旧代码/旧事务记录；当前应急备份保留。'
}
rebuild_command() (
    trap - EXIT ERR INT TERM
    set -Eeuo pipefail
    local option=${1:-} clean=no plan=no backup='' changed=no was_active=no before_x after_x xhash before_state before_nginx before_unit
    local candidate="$WORK/rebuild-state.json" report="$WORK/rebuild-map.tsv" ng="$WORK/rebuild-nginx.conf" units="$WORK/rebuild-units" old='' fingerprint tmp
    case "$option" in '') ;; --clean-history) clean=yes;; --plan) plan=yes;; *) die '用法：rebuild [--plan|--clean-history]。';; esac
    trap 'rebuild_finish "$?" "$backup" "$changed" "$was_active"' EXIT
    trap 'exit 130' INT; trap 'exit 143' TERM
    need findmnt; need ss; need timeout; need runuser
    state_basic "$STATE" || die '当前state.json缺失/损坏；Xray本身不能提供域名、证书和网站配置。'
    ensure_component nginx; ensure_component xray
    rebuild_guard_layout || exit 1
    rebuild_guard_xray || exit 1
    before_x=$(systemctl show -p MainPID --value vpskit-xray.service) || exit 1
    xhash=$(runtime_hash_file "$ROOT/config/xray.json") || exit 1
    before_state=$(runtime_hash_file "$STATE"); before_nginx=$(runtime_hash_file "$ROOT/config/nginx.conf")
    before_unit=$(runtime_hash_file "$SYSTEMD/vpskit-nginx.service")
    systemctl is-active --quiet vpskit-nginx.service && was_active=yes
    ui_title '简化重建：当前Xray → Nginx'
    ui_note '只读取当前资料，不读取旧快照；不改写Xray/UUID/凭据/证书，不升级任何组件。'
    ui_note '域名/证书/网站来自当前state.json；后端端口和路径以实际xray.json为准。'
    ui_note '修正Nginx Master权限并重启一次Nginx；经Nginx的现有连接会短暂中断。'
    if [[ $clean == yes ]]; then
        warn '成功后永久删除 /opt/vpskit/backup 下 history/last/rescue/code/transaction；不删除系统日志或云镜像。'
        warn '本次独立应急备份及此前重建备份保留；不是整机/网站内容备份。'
    else ui_note '默认不删除任何历史；加 --clean-history 才在成功后清理。'; fi
    if [[ $plan != yes ]]; then
        confirm '执行上述备份、验证、Nginx重建及所选清理操作；失败时恢复原Nginx' || exit 0
        backup="$ROOT/rebuild-backups/$(date -u '+%Y%m%dT%H%M%SZ')-$(randhex 4)"
        rebuild_backup_create "$backup" || exit 1
    fi
    rebuild_sync_state "$candidate" "$ROOT/config/xray.json" "$report" || exit 1
    cat "$report"
    (
        STATE=$candidate
        render_nginx "$ng" || exit 1
        render_units "$units" || exit 1
    ) || exit 1
    if [[ $plan == yes ]]; then
        ok '只读计划已生成：Xray不动；Nginx按本机版本生成，保留既有域名/证书/网站。未执行预检、备份或清理。'
        exit 0
    fi
    # Full original Xray configuration is syntax-tested but never regenerated.
    "$XRAY" run -test -config "$ROOT/config/xray.json" || exit 1
    ( STATE=$candidate; nginx_preflight "$ng" ) || exit 1
    [[ $(runtime_hash_file "$STATE") == "$before_state" &&
       $(runtime_hash_file "$ROOT/config/nginx.conf") == "$before_nginx" &&
       $(runtime_hash_file "$SYSTEMD/vpskit-nginx.service") == "$before_unit" &&
       $(runtime_hash_file "$ROOT/config/xray.json") == "$xhash" &&
       $(systemctl show -p MainPID --value vpskit-xray.service) == "$before_x" ]] || {
        warn '验证期间配置或Xray进程被外部改变，未切换。'; exit 1; }
    rebuild_guard_xray || exit 1
    # Install THIS complete manager for the new service entry. No separate update/apply is needed.
    ensure_manager_installed || exit 1
    changed=yes
    ( STATE=$candidate; worker_permissions "$(resolve_worker)" ) || exit 1
    nginx_cmd -t -p "$ROOT/" -c "$ng" || exit 1
    install -m 600 "$ng" "$ROOT/config/nginx.conf" || exit 1
    install -m 644 "$units/vpskit-nginx.service" "$SYSTEMD/vpskit-nginx.service" || exit 1
    systemctl daemon-reload || exit 1
    systemctl reset-failed vpskit-nginx.service >/dev/null 2>&1 || true
    systemctl restart vpskit-nginx.service || exit 1
    ( STATE=$candidate; verify_nginx_runtime '' '' "$ROOT/config/nginx.conf" ) || exit 1
    after_x=$(systemctl show -p MainPID --value vpskit-xray.service) || exit 1
    [[ $after_x == "$before_x" && $(runtime_hash_file "$ROOT/config/xray.json") == "$xhash" ]] || {
        warn 'Xray在重建期间发生外部变化；未提交Nginx结果。'; exit 1; }
    install -m 600 "$candidate" "$STATE" || exit 1
    fingerprint=$(runtime_fingerprint nginx "$ROOT/config/nginx.conf") || exit 1
    tmp="$WORK/rebuild-applied.json"
    if [[ -s $ROOT/config/.runtime-applied.json ]] && jq -e 'type=="object"' "$ROOT/config/.runtime-applied.json" >/dev/null 2>&1; then
        jq --argjson n "$fingerprint" '.schema=1 | .nginx=$n' "$ROOT/config/.runtime-applied.json" > "$tmp" || exit 1
    else jq -n --argjson n "$fingerprint" '{schema:1,nginx:$n}' > "$tmp" || exit 1; fi
    install -m 600 "$tmp" "$ROOT/config/.runtime-applied.json" || exit 1
    # Verification is done before the irreversible optional cleanup. Keep the captured baseline forever.
    (snapshot_verify "$backup") || exit 1
    printf 'committed\n' > "$backup/result" || exit 1
    changed=no
    ok "Nginx已重建并通过非root运行检查；Xray PID=$after_x及配置字节保持不变。"
    info "本次应急备份：$backup；可用 vpskit rebuild-restore $backup 恢复Nginx。"
    if [[ $clean == yes ]]; then rebuild_clean_history || warn '重建成功，但旧历史未完全清理；不会因此重启已恢复服务。'; fi
    recovery_firewall check || warn '公网端口未完全核对；本流程没有改变防火墙、SSH或云安全组。'
)
rebuild_restore_command() {
    local backup=${1:-} active=no
    [[ $backup == "$ROOT/rebuild-backups/"* && ${backup##*/} =~ ^[0-9]{8}T[0-9]{6}Z-[a-f0-9]{8}$ &&
       $(realpath -m "$backup") == "$backup" && ! -L $backup ]] || die '请提供输出中的本次应急备份绝对路径。'
    [[ -f $backup/.rebuild-owned && $(cat "$backup/.rebuild-owned") == VPSKIT_REBUILD_V1 ]] || die '不是本工具的重建备份。'
    rebuild_guard_layout || die '当前服务目录或外部覆盖文件不适合自动恢复。'
    snapshot_verify "$backup"
    confirm '只恢复该备份的Nginx/状态/权限；可能恢复历史root Worker并中断Nginx连接，不改Xray/防火墙' || return 0
    # Do not restore stale state against a subsequently modified Xray.
    cmp -s "$backup/config/xray.json" "$ROOT/config/xray.json" || die 'Xray后来已变化；拒绝把旧状态套用到新Xray。'
    if [[ -f $backup/active ]] && grep -Fxq vpskit-nginx.service "$backup/active"; then active=yes; fi
    rebuild_restore_nginx "$backup" "$active" || die "恢复失败；备份仍在：$backup"
    ok '已恢复该次重建前的Nginx与状态。'
    recovery_firewall check || true
}

main() {
    local command action flag
    while (($#)); do
        case "$1" in
            --no-color) COLOR_MODE=never; shift;;
            --color=*) COLOR_MODE=${1#--color=}; shift;;
            --color) (($#>=2)) || die '--color需要auto/always/never。'; COLOR_MODE=$2; shift 2;;
            --) shift; break;;
            *) break;;
        esac
    done
    choice "$COLOR_MODE" 'auto always never' || die '颜色模式只能为auto/always/never。'
    export VPSKIT_COLOR="$COLOR_MODE"
    colors
    command=${1:-menu}; action=${2:-}
    if [[ $command == emergency || ( $command == uninstall && $action == force ) || $command == reinstall ||
          ( $command == install && " $* " == *" --clean "* ) ]]; then
        smart_emergency_entry "$@"; return
    fi
    s4_lifecycle_guard "$command" "$action"
    case "$command:$action" in version:*|--version:*|-V:*|selftest:*|help:*|--help:*|-h:*|update:manager) ;;
        *) if command -v jq >/dev/null 2>&1; then mode_load; fi;; esac
    case "$command" in
        version|--version|-V) printf '%s\n' "$VERSION"; return;;
        help|--help|-h) usage "$action"; return;;
        explain) explain; return;;
        edge) if [[ $action == guide ]]; then edge_guide; return; fi;;
        selftest) selftest; return;;
        node) if [[ $action == protocols ]]; then xray_catalog; return; fi
              if [[ $action == overview ]]; then s3_node_overview; return; fi;;
        panel)
            if [[ $action == tree ]]; then s3_menu_tree; return; fi
            if [[ $action == search && -n ${3:-} ]]; then s3_menu_search "$3"; return; fi;;
        panel-action)
            case "$action" in tree) s3_menu_tree; return;; help-*) s3_help "${action#help-}"; return;; esac;;
        diagnostics) if [[ $action == summary ]]; then s3_diagnostics summary; return; fi;;
        performance) if [[ $action == recommend ]]; then s3_performance_recommend; return; fi;;
        preview) menu_preview "${2:-main}"; return;;
        dashboard) status_dashboard "${2:-main}"; return;;
        _service) service_runner "$action"; return;;
        menu|ports|panel|panel-action|cleanup|diagnostics|config|recovery|shared-global|mode|components|install|wizard|apply|plan|rebuild|rebuild-restore|status|doctor|paths|node|site|cert|advanced|history|rollback|repair|recover|system|update|edge|performance|optimize|service|logs|firewall|swap|maintenance|uninstall|network-check) ;;
        *) die '未知命令；使用help查看。';;
    esac
    system_check
    [[ -f $SELF && $SELF != /dev/fd/* && $SELF != /proc/* ]] || die '请先下载完整脚本为本地普通文件，再运行sudo bash ./vpskit.sh。'
    SELF=$(realpath -- "$SELF")
    if { exec {TTY_FD}<>/dev/tty; } 2>/dev/null; then :; else TTY_FD=''; fi
    if [[ $command == menu ]]; then menu_group "${2:-main}"; return; fi
    if [[ $command == panel ]]; then
        if [[ $action == search ]]; then local query; ask query '本地菜单关键词' ''; s3_menu_search "$query"; return; fi
        [[ -z $action ]] || die 'panel: tree/search。'; main_menu; return
    fi
    if [[ $command == panel-action && $action == search ]]; then s3_panel_action search; return; fi
    if [[ -z $action ]]; then
        case "$command" in
            uninstall) menu_group uninstall; return;;
            mode|components) menu_group providers; return;;
            config) menu_group configsafe; return;; recovery) menu_group history; return;;
            cleanup) menu_group housekeeping; return;; diagnostics) menu_group status; return;; service) menu_group services; return;;
            performance) menu_group efficiency; return;;
            node) menu_group nodes; return;; site) menu_group websites; return;; cert) menu_group certificates; return;;
            advanced|history|update|edge|firewall|swap|optimize) menu_group "$command"; return;;
        esac
    fi
    if [[ $command == uninstall || ( $command == components && $action == remove ) ]]; then
        s4_management_layout
        trap cleanup EXIT
        trap 'error_trap "$?" "$LINENO"' ERR
        trap 'exit 130' INT; trap 'exit 143' TERM
        need jq; need openssl
        if [[ $command == components ]]; then shared_remove_component "${3:-}"
        else s4_command "${action:-wizard}" "${@:3}"; fi
        return
    fi
    safe_layout
    trap cleanup EXIT
    trap 'error_trap "$?" "$LINENO"' ERR
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [[ $command == install ]]; then
        [[ ! -d $ROOT/backup/transaction ]] || die '安装前发现未完成事务，请先repair。'
        install_dependencies
        if [[ $action == shared || $action == isolated ]]; then
            mode_choose_new "$action"; action=''
        else mode_choose_new; fi
    fi
    need jq; need openssl
    if [[ $command == ports ]]; then smart_ports_command "${action:-show}" "${3:-}"; return; fi
    if [[ $command == cleanup ]]; then
        if (($#>=3)); then s3_cleanup_command "${action:-scan}" "$3"; else s3_cleanup_command "${action:-scan}"; fi
        return
    fi
    if [[ $command == diagnostics ]]; then s3_diagnostics "${action:-summary}"; return; fi
    if [[ $command == panel-action ]]; then
        case "$action" in cleanup-scan|cleanup-run|diagnostics-summary|diagnostics-export|schedule-show|perf-recommend|node-overview|log-preflight)
            s3_panel_action "$action"; return;; esac
    fi
    if [[ $command == update && $action == manager ]]; then
        update_manager "${3:-}" "${4:-}"; return
    fi
    if [[ $command == recovery ]]; then
        case "$action" in
            status) recovery_status; return;;
            repair) repair_transaction; return;;
            rollback) [[ ! -d $ROOT/backup/transaction ]] || die '先修复未完成事务。'; recovery_rollback_latest; return;;
            *) die 'recovery: status/repair/rollback。';;
        esac
    fi
    stage1_guard "$command" "$action"
    if [[ $command == mode || $command == components ]]; then
        if [[ -d $ROOT/backup/transaction ]]; then
            case "$command:$action" in mode:show|components:show|components:latest-xray) ;; *) die '存在未完成事务，请先repair；未改组件或模式。';; esac
        fi
        case "$command:$action" in
            mode:show|components:show) components_show; return;;
            mode:select) mode_select_empty "${3:-}"; return;;
            mode:migrate) state_basic "$STATE" || die '先完成初始部署。'; mode_migrate "${3:-}" "${4:---plan}"; return;;
            components:latest-xray) xray_release_info; return;;
            components:repair-apt-policy) repair_apt_policy; return;;
            components:adopt-acme) state_basic "$STATE" || die '先安装。'; record_init "$MODE"; adopt_acme "${3:-}"; return;;
            components:detach) [[ $MODE == shared ]] || die '需共享模式。'; shared_detach; return;;
            components:remove) [[ $MODE == shared ]] || die '需共享模式。'; shared_remove_component "${3:-}"; return;;
            *) die '查看help中的mode/components命令。';;
        esac
    fi
    case "$command" in
        rebuild) (($#<=2)) || die '用法：rebuild [--plan|--clean-history]。'; rebuild_command "${2:-}"; return;;
        rebuild-restore) (($#==2)) || die 'rebuild-restore需要一个本次备份绝对路径。'; rebuild_restore_command "$2"; return;;
        repair) repair_transaction "${2:-}"; return;;
        rollback) if [[ ${2:-} == --force ]]; then force_recover "${3:-}"; else rollback_last; fi; return;;
        recover) force_recover "${2:-}"; return;;
        history)
            case "$action" in list) history_list;; save) history_save "${3:-manual}";; restore) history_restore "${3:-}" "${4:-}";; *) die 'history: list/save/restore。';; esac
            return;;
        logs) logs_show "${2:-nginx}" "${3:-100}"; return;;
        status) status_show; return;; paths) paths_show; return;;
    esac
    if [[ -d $ROOT/backup/transaction ]]; then die '发现未完成事务；先运行repair，不要覆盖原配置。'; fi
    case "$command" in
        firewall)
            case "$action" in status) firewall_show;; open|allow) firewall_change allow "${3:-}" "${4:-}";; close|deny) firewall_change deny "${3:-}" "${4:-}";; sync) firewall_sync;; cleanup|clean) firewall_cleanup;; *) die 'firewall: status/open/close/sync/cleanup。';; esac; return;;
        swap)
            case "$action" in status) swap_show;; enable) swap_create 1024;; custom|create) swap_create "${3:-}";; remove|disable) swap_remove;; *) die 'swap: status/enable/custom/remove。';; esac; return;;
        optimize)
            case "$action" in status) optimize_status;; bbr) bbr_enable;; restore) bbr_restore;; mtu) mtu_probe "${3:-}";; gzip) state_basic "$STATE" || die '请先部署。'; performance_gzip "${3:-}";; *) die 'optimize: status/bbr/restore/mtu/gzip。';; esac; return;;
        wizard) if [[ $action == status ]]; then wizard_status; return; fi;;
        logs) logs_show "${2:-nginx}" "${3:-100}"; return;;
    esac
    if [[ $command == install || ( $command == wizard && $action == configure ) ]]; then init_state
    else state_basic "$STATE" || die '没有有效state.json；新装运行install，已有部署请从history恢复。'; fi
    record_init "$MODE"
    case "$command" in
        panel-action) s3_panel_action "$action";;
        install) if [[ -z $action ]]; then install_wizard; else install_component "$action" "${3:-$XRAY_DEFAULT_VERSION}"; fi;;
        wizard) [[ $action == configure ]] || die 'wizard: configure/status。'; wizard_configure;;
        config) case "$action" in check) config_check;; plan) runtime_plan_command;; diff) config_diff;; apply) apply_existing;; *) die 'config: check/plan/diff/apply。';; esac;;
        shared-global)
            if [[ $action == edit ]]; then
                local gw gc
                ask_valid gw '全局Worker（auto或1~64）' 1 valid_worker_count
                ask_valid gc '全局每Worker连接数（128~65535）' 1024 number 128 65535
                shared_global set "$gw" "$gc"
            else shared_global "${action:-show}" "${3:-}" "${4:-}"; fi;;
        apply) apply_existing;; plan) runtime_plan_command;; doctor) if doctor; then return 0; else trap - ERR; return 1; fi;; network-check) network_check;;
        node)
            case "$action" in
                protocols) xray_catalog;;
                native-add) native_add "${3:-}";;
                import) native_import "${3:-}" "${4:-}";;
                native) native_action "${3:-list}" "${4:-}";;
                batch) node_batch "${3:-}" "${4:-}";;
                batch-all) s3_node_batch "${3:-}" "${4:-}";;
                list) node_list;; add) node_add;; share) node_share "${3:-}";; export) node_export "${3:-}";; client) node_client "${3:-}";;
                edit|credential) node_set_credential "${3:-}";; listen) node_set_listen "${3:-}";; address) node_change host "${3:-}" "${4:-}";;
                enable|disable|delete|rotate|rename|port|host) node_change "$action" "${3:-}" "${4:-}";;
                *) die 'node: list/add/share/edit/listen/enable/disable/delete/rotate/rename/port/host/export/client。';;
            esac;;
        site) case "$action" in list) site_list;; add) site_configure "${3:-}";; edit) site_edit_existing "${3:-}";; remove) site_remove "${3:-}";; *) die 'site: list/add/edit/remove。';; esac;;
        cert)
            case "$action" in
                audit) cert_audit;; issue) cert_issue "${3:-}";; settings) cert_settings "${3:-}";; status) cert_status;; renew) cert_renew;;
                import) if (($#==2)); then cert_import_interactive; else (($#==5)) || die 'cert import需要域名、证书路径、私钥路径。'; cert_import "$3" "$4" "$5"; fi;;
                *) die 'cert: issue/settings/status/renew/import。';;
            esac;;
        advanced) case "$action" in preflight) nginx_preflight_current;; show) advanced_show;; users) worker_users;; edit) advanced_edit "${3:-}";; defaults) advanced_defaults;; set) shift 2; advanced_set "$@";; *) die 'advanced: show/users/edit/set/defaults/preflight。';; esac;;
        update) if [[ $action == all ]]; then update_all; else component_update "$action" "${3:-}"; fi;;
        edge)
            case "$action" in
                status) edge_status_all;; show) if [[ -n ${3:-} ]]; then edge_show "$3"; else edge_status_all; fi;;
                edit) edge_edit;; refresh) edge_refresh;; guide) edge_guide;; traffic) edge_traffic;; probe) edge_probe "${3:-}";;
                profile|bots|limits|cache|origin|aop|reset) edge_action "$action" "${3:-}";;
                set) (($#==5)) || die 'edge set需要域名、键、值。'; edge_set "$3" "$4" "$5";;
                *) die 'edge: status/edit/refresh/guide/traffic/probe/profile/bots/limits/cache/origin/aop/reset/set。';;
            esac;;
        performance)
            case "$action" in
                show) performance_show;; recommend) s3_performance_recommend;; benchmark) s3_web_bench "${3:-}" "${4:-3}";; profile) performance_profile "${3:-}" "${4:-}";; logging) performance_logging "${3:-}";;
                xray) performance_xray;; retention) performance_retention;; events) performance_events;;
                rotate) performance_rotate;; permissions) performance_permissions;;
                gzip) performance_gzip "${3:-}";; *) die 'performance: show/recommend/profile/benchmark/logging/xray/retention/events/rotate/permissions/gzip。';;
            esac;;
        service) service_control "$action" "${3:-}";;
        system) [[ $action == reboot ]] || die 'system: reboot。'; system_reboot;;
        maintenance) maintenance_tick;;
        uninstall) case "${action:-keep}" in keep) uninstall_keep_data;; all) uninstall_all;; nginx|xray|acme) uninstall_component "$action";; *) die 'uninstall: keep/xray/nginx/acme/all。';; esac;;
    esac
}

# -----------------------------------------------------------------------------
# VPSKit 2.0 stage 1: component providers, ownership and non-destructive migration.
# This section deliberately keeps the old isolated backend as a compatibility path.
# Shared Nginx global settings and third-party ACME account homes are never owned.
# -----------------------------------------------------------------------------
MODE=isolated
INSTALL_RECORD=''
SHARED_NGINX='/usr/sbin/nginx'
SHARED_MAIN='/etc/nginx/nginx.conf'
SHARED_INCLUDE='/etc/nginx/conf.d/vpskit-managed.conf'
SHARED_ACME_HOME='/usr/local/lib/acme.sh'
SHARED_ACME_ENTRY='/usr/local/bin/acme.sh'
ACME_HOME=''
NGINX_SERVICE='vpskit-nginx.service'
NGINX_CONFIG=''

install_record_path() { printf '%s/data/installation.json' "$ROOT"; }
mode_detect() {
    local file; file=$(install_record_path)
    if [[ -e $file ]]; then
        [[ -f $file && ! -L $file ]] || die '安装登记文件异常；未按默认模式继续。'
        jq -er 'select(.schema==1) | .mode | select(.=="shared" or .=="isolated")' "$file" || die '安装登记损坏；请恢复该文件，未猜测模式。'
    else printf 'isolated\n'; fi
}
mode_load() {
    INSTALL_RECORD=$(install_record_path)
    MODE=$(mode_detect) || return 1
    XRAY="$ROOT/bin/xray"
    NGINX="$ROOT/nginx/usr/sbin/nginx"; ACME="$ROOT/acme/acme.sh"; ACME_HOME="$ROOT/acme"
    NGINX_SERVICE=vpskit-nginx.service; NGINX_CONFIG="$ROOT/config/nginx.conf"
    UNITS=(vpskit-xray.service vpskit-nginx.service vpskit-maintain.service vpskit-maintain.timer)
    if [[ $MODE == shared ]]; then
        NGINX=$SHARED_NGINX; NGINX_SERVICE=nginx.service; NGINX_CONFIG=$SHARED_MAIN
        ACME_HOME=$SHARED_ACME_HOME; ACME="$ACME_HOME/acme.sh"
        UNITS=(vpskit-xray.service vpskit-maintain.service vpskit-maintain.timer)
        if [[ -f $INSTALL_RECORD ]]; then
            local p; p=$(jq -r '.components.acme | if .provider=="external" then .binary // "" else "" end' "$INSTALL_RECORD")
            if [[ -n $p ]]; then
                # An adopted installation must be an absolute, non-symlink executable.
                [[ $p == /* && $p != *[[:space:]]* && $p != *'/../'* && $p != *'/./'* ]] || die 'ACME登记路径非法。'
                ACME=$p; ACME_HOME=${p%/*}
            fi
        fi
    fi
}
provider_record_update() {
    local tmp; tmp=$(mktemp "$ROOT/data/.installation.XXXXXXXX")
    jq "$@" "$INSTALL_RECORD" > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp"; chown 0:0 "$tmp"; mv -f "$tmp" "$INSTALL_RECORD"
}
record_init() {
    local mode=${1:-isolated} existed=true c flag provider
    INSTALL_RECORD=$(install_record_path)
    [[ ! -e $INSTALL_RECORD ]] || { mode_load; return 0; }
    choice "$mode" 'isolated shared' || die '安装模式只能为shared/isolated。'
    [[ -f $STATE ]] || existed=false
    jq -n --arg m "$mode" --arg v "$VERSION" --arg t "$(date -u +%FT%TZ)" \
      '{schema:1,mode:$m,created:$t,manager:$v,components:{},owned_files:{},migration:null}' > "$INSTALL_RECORD"
    chmod 600 "$INSTALL_RECORD"
    # Legacy components belong to the private provider, NOT to any apt package.
    if [[ $existed == true ]]; then
        for c in nginx acme xray; do
            flag=$(get ".components.$c // false")
            [[ $flag == true ]] || continue
            provider_record_update --arg c "$c" '.components[$c]={provider:"private",origin:"legacy-vpskit",managed:true}'
        done
    fi
    mode_load
}
mode_choose_new() {
    if [[ -e $(install_record_path) ]]; then
        mode_load
        [[ -z ${1:-} || $1 == "$MODE" ]] || die '已登记另一安装模式；请用mode migrate显式切换。'
        return
    fi
    if [[ -f $STATE ]] && jq -e '(.nodes|length)>0 or ((.native_nodes // [])|length)>0 or (.sites|length)>0 or (.components|any(.==true))' "$STATE" >/dev/null; then
        [[ -z ${1:-} || $1 == isolated ]] || die '检测到旧独立部署；不能用install shared覆盖，请用mode migrate shared。'
        record_init isolated; info '识别旧部署：保持独立模式；更新脚本不会自动迁移。'; return
    fi
    local selected=${1:-}
    [[ -n $selected ]] || select_value selected '选择安装模式（只影响本项目；共享组件不共享密钥）' shared \
      'shared|系统共享：APT Nginx + 全局ACME命令，私有账户数据' \
      'isolated|独立隔离：沿用/opt/vpskit私有组件和服务'
    record_init "$selected"
}
record_component() {
    local name=$1 provider=$2 origin=$3 binary=$4 version=$5
    provider_record_update --arg c "$name" --arg p "$provider" --arg o "$origin" --arg b "$binary" --arg v "$version" \
      '.components[$c]=((.components[$c] // {}) + {provider:$p,origin:$o,binary:$b,version:$v,managed:($o!="external"),last_seen:(now|todate)})'
}
trusted_program() {
    local p=$1 dir mode
    [[ $p == /* && -f $p && ! -L $p && -x $p && $(stat -c %u "$p") == 0 ]] || return 1
    dir=$p
    while [[ $dir != / ]]; do
        [[ ! -L $dir && $(stat -c %u "$dir") == 0 ]] || return 1
        mode=$(stat -c %a "$dir"); (( (8#$mode & 0022)==0 )) || return 1
        dir=${dir%/*}; [[ -n $dir ]] || dir=/
    done
}
components_show() {
    mode_load
    ui_title '安装模式与组件归属（只读）'
    printf '模式：%s\nNginx：%s\n服务：%s\n主配置：%s\nACME程序：%s\nACME账户：%s/acme/config（不公开）\n' \
      "$MODE" "$NGINX" "$NGINX_SERVICE" "$NGINX_CONFIG" "$ACME" "$ROOT"
    if [[ -f $INSTALL_RECORD ]]; then jq '{schema,mode,components,owned_files,migration}' "$INSTALL_RECORD"; else info '旧版尚无安装登记；默认识别为独立，不修改原状态。'; fi
    ui_note '登记“已安装”不等于服务运行；系统共享组件更新/停止影响其他应用。'
}
apt_nginx_guarded() (
    # Prevent Debian maintainer scripts from starting a second nginx during migration.
    # Never overwrite an existing administrator policy. APT changes are not rollbackable.
    trap - EXIT ERR INT TERM
    set -Eeuo pipefail
    local policy=/usr/sbin/policy-rc.d created=no expected='' rc action=${1:-install}
    [[ ! -e $policy && ! -L $policy ]] || die '系统已有policy-rc.d；请管理员自行安装/升级nginx后重新复用，脚本不覆盖该策略。'
    trap 'rc=$?; trap - EXIT ERR; if [[ $created == yes && -f $policy && ! -L $policy ]] && [[ $(sha256sum "$policy" | cut -d" " -f1) == "$expected" ]]; then rm -f -- "$policy"; fi; exit "$rc"' EXIT
    (set -C; printf '#!/bin/sh\n# VPSKIT_TEMP_APT_POLICY\nexit 101\n' > "$policy") || exit 1
    created=yes; expected=$(sha256sum "$policy" | cut -d' ' -f1); chmod 755 "$policy"
    apt-get update
    if [[ $action == upgrade ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confold install --only-upgrade -y --no-install-recommends nginx
    else DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confold install -y --no-install-recommends nginx; fi
)
install_nginx_binary() {
    if [[ $MODE != shared ]]; then
        s1_base_install_nginx_binary
        record_component nginx private vpskit "$NGINX" "$(get '.versions.nginx')"; return
    fi
    local origin=external version status
    if [[ -x $SHARED_NGINX ]]; then
        trusted_program "$SHARED_NGINX" || die '系统Nginx程序/父目录不可信，未自动接管。'
        info '复用已有系统Nginx；不覆盖nginx.conf、不重装软件包。'
        if [[ ${SHARED_UPGRADE:-no} == yes ]]; then
            dpkg-query -S "$SHARED_NGINX" >/dev/null 2>&1 || die '现有Nginx不是APT可识别文件，拒绝通过APT升级。'
            apt_nginx_guarded upgrade
        fi
        origin=$(jq -r '.components.nginx | if .provider=="apt" then .origin // "external" else "external" end' "$INSTALL_RECORD")
    else
        [[ ! -e $SHARED_NGINX && ! -L $SHARED_NGINX ]] || die '系统Nginx路径存在异常文件。'
        apt_nginx_guarded install; origin=vpskit
    fi
    trusted_program "$SHARED_NGINX" || die 'APT未提供可信的/usr/sbin/nginx。'
    "$SHARED_NGINX" -t || die '系统Nginx原配置有错；未写入VPSKit配置。'
    version=$("$SHARED_NGINX" -v 2>&1); NGINX=$SHARED_NGINX
    record_component nginx apt "$origin" "$NGINX" "$version"
    json_update --arg v "$version" '.components.nginx=true | .versions.nginx=$v'
}
public_acme_wrapper() {
    local dest=$1 home=$2
    # Code is shared, default state is per UNIX user; callers can explicitly choose data homes.
    cat > "$dest" <<EOF
#!/bin/sh
# VPSKIT_SHARED_ACME_ENTRY_V1
umask 077
exec '$home/acme.sh' --home '$home' --config-home "\${ACME_CONFIG_HOME:-\$HOME/.acme.sh}" --cert-home "\${ACME_CERT_HOME:-\$HOME/.acme.sh}" "\$@"
EOF
    chmod 755 "$dest"
}
install_acme_binary() {
    if [[ $MODE != shared ]]; then
        s1_base_install_acme_binary
        record_component acme private vpskit "$ACME" "$(get '.versions.acme')"; return
    fi
    local origin version meta="$WORK/acme-release.json" source="$WORK/shared-acme-source" dir
    if [[ -x $ACME ]]; then
        trusted_program "$ACME" || die 'ACME程序或父目录不可信。'
        origin=$(jq -r '.components.acme.origin // "external"' "$INSTALL_RECORD")
        if [[ ${SHARED_UPGRADE:-no} != yes ]]; then
            version=$("$ACME" --version | tail -n1)
            local provider=external
            [[ $ACME != "$SHARED_ACME_HOME/acme.sh" || ! -f $SHARED_ACME_HOME/.vpskit-code ]] || provider=shared
            record_component acme "$provider" "$origin" "$ACME" "$version"
            json_update --arg v "$version" '.components.acme=true | .versions.acme=$v'
            info '复用共享ACME程序；账户/证书目录仍为VPSKit专属；没有创建全局cron。'; return
        fi
        [[ $ACME == "$SHARED_ACME_HOME/acme.sh" && -f $SHARED_ACME_HOME/.vpskit-code ]] || die '外部ACME只能由其原管理方式升级。'
    fi
    if [[ -e $SHARED_ACME_ENTRY || -L $SHARED_ACME_ENTRY ]]; then
        [[ -f $SHARED_ACME_ENTRY && ! -L $SHARED_ACME_ENTRY ]] && grep -Fxq '# VPSKIT_SHARED_ACME_ENTRY_V1' "$SHARED_ACME_ENTRY" || \
          die '全局acme.sh入口已存在；使用 components adopt-acme /实际/acme.sh 路径显式复用，不覆盖外部入口。'
    fi
    if [[ -e $SHARED_ACME_HOME ]]; then
        [[ -d $SHARED_ACME_HOME && ! -L $SHARED_ACME_HOME && -f $SHARED_ACME_HOME/.vpskit-code ]] || die 'ACME共享目录归属不明；未覆盖。'
    fi
    version=$(latest_release acmesh-official/acme.sh "$meta")
    fetch "https://github.com/acmesh-official/acme.sh/archive/refs/tags/$version.tar.gz" "$WORK/acme-shared.tar.gz"
    tar -tzf "$WORK/acme-shared.tar.gz" | awk '/(^\/|(^|\/)\.\.(\/|$))/{bad=1} END{exit bad}' || die 'ACME归档路径异常。'
    if tar -tvzf "$WORK/acme-shared.tar.gz" | awk 'substr($1,1,1)=="l" || substr($1,1,1)=="h"{bad=1} END{exit !bad}'; then die 'ACME归档含链接，未解压。'; fi
    mkdir -m 700 "$source"
    tar --no-same-owner --no-same-permissions -xzf "$WORK/acme-shared.tar.gz" --strip-components=1 -C "$source"
    sh -n "$source/acme.sh"
    mkdir -p -m 755 "$SHARED_ACME_HOME"
    install -m 755 "$source/acme.sh" "$SHARED_ACME_HOME/acme.sh.next"
    for dir in dnsapi deploy notify; do
        [[ -d $source/$dir ]] || continue
        [[ ! -L $SHARED_ACME_HOME/$dir ]] || die 'ACME插件目录是链接，拒绝更新。'
        mkdir -p "$SHARED_ACME_HOME/$dir"; cp -a "$source/$dir/." "$SHARED_ACME_HOME/$dir/"
        find -P "$SHARED_ACME_HOME/$dir" -type d -exec chmod 755 {} +
        find -P "$SHARED_ACME_HOME/$dir" -type f -exec chmod 644 {} +
    done
    mv -f "$SHARED_ACME_HOME/acme.sh.next" "$SHARED_ACME_HOME/acme.sh"
    printf 'VPSKIT_ACME_CODE_V1\n' > "$SHARED_ACME_HOME/.vpskit-code"; chmod 644 "$SHARED_ACME_HOME/.vpskit-code"
    public_acme_wrapper "$WORK/acme-entry" "$SHARED_ACME_HOME"
    install -m 755 "$WORK/acme-entry" "$SHARED_ACME_ENTRY"
    ACME_HOME=$SHARED_ACME_HOME; ACME="$ACME_HOME/acme.sh"
    record_component acme shared vpskit "$ACME" "$version"
    json_update --arg v "$version" '.components.acme=true | .versions.acme=$v'
    info '已安装全局acme.sh命令；未注册新cron；保留原VPSKit账户及续期数据。'
}
adopt_acme() {
    local p=${1:-}
    [[ $MODE == shared ]] || die '仅共享模式支持显式复用外部ACME。'
    [[ $p == */acme.sh ]] && trusted_program "$p" || die '请指定root拥有、不可被普通用户修改的真实acme.sh绝对路径（不要传软链接）。'
    confirm "复用程序 $p，仍使用VPSKit独立账户目录；不接管外部续期任务" || return 0
    local version; version=$("$p" --version | tail -n1)
    record_component acme external external "$p" "$version"
    ACME=$p; ACME_HOME=${p%/*}
    json_update --arg v "$version" '.components.acme=true | .versions.acme=$v'
}
acme_run() { ( umask 077; "$ACME" --home "${ACME_HOME:-$ROOT/acme}" --config-home "$ROOT/acme/config" --cert-home "$ROOT/acme/certstore" --no-color "$@" ); }
install_xray_binary() {
    s1_base_install_xray_binary "$@"
    record_component xray private vpskit "$XRAY" "$(get '.versions.xray')"
}
component_ready() {
    local f
    case "$1" in xray) f=$XRAY;; nginx) f=$NGINX;; acme) f=$ACME;; *) return 1;; esac
    [[ $(get ".components.$1 // false") == true && -x $f && ! -L $f ]]
}
resolve_worker() {
    if [[ $MODE != shared ]]; then s1_base_resolve_worker "$@"; return; fi
    local user
    user=$(nginx_conf_value user "$SHARED_MAIN" || true)
    [[ -n $user ]] || die '共享Nginx未在主配置中明确声明user；请管理员确认非root账户后再接入。'
    service_user_valid "$user" || die "系统Nginx账户 $user 不符合非root服务账户要求，未改写全局user。"
    printf '%s' "$user"
}
nginx_master_pid() {
    [[ $MODE != shared ]] || { systemctl show -p MainPID --value nginx.service; return; }
    s1_base_nginx_master_pid
}
render_units() {
    s1_base_render_units "$1"
    [[ $MODE != shared ]] || rm -f -- "$1/vpskit-nginx.service"
}
# Full legacy output is our own deterministic text, NOT arbitrary user nginx syntax.
# Extract only named HTTP resources + named virtual hosts, then apply tuning inside
# each VPSKit server. Do not put worker/access_log/gzip policy at shared http scope.
render_shared_nginx() {
    local dest=$1 full="$WORK/shared-full.conf" tuning="$WORK/shared-server-tuning.conf" a
    s1_base_render_nginx "$full"
    a=$(nginx_settings)
    awk '
      /^    server_tokens /{take=1}
      /^    (log_format|map|split_clients) /{take=0}
      take && !/^    (ssl_protocols|access_log) /{print}
      /^    access_log /{print}
    ' "$full" > "$tuning"
    {
        printf '# VPSKIT_SHARED_HTTP_V1\n# Owned by VPSKit; other config files and global nginx.conf are not modified.\n'
        awk -v tuning="$tuning" '
          /^    (log_format|map|split_clients) /{if(!started){started=1}}
          !started {next}
          /^    access_log / {next}
          /^    server \{$/ {
            if(!skipped){skip=1;skipped=1;next}
            print
            while((getline line < tuning)>0) print "    "line
            close(tuning);next
          }
          skip {if($0=="    }"){skip=0};next}
          /^}$/ {next}
          {gsub(/va_/,"vpskit_app_");gsub(/vx_/,"vpskit_xhttp_");gsub(/vr_/,"vpskit_rate_");gsub(/vc_/,"vpskit_conn_");print}
        ' "$full"
    } > "$dest"
    grep -q 'default_server' "$dest" && die '共享生成器禁止创建default_server。'
    return 0
}
shared_guard_file() {
    local path=$SHARED_INCLUDE hash expected
    [[ ! -L /etc/nginx && ! -L ${path%/*} && ! -L $path ]] || die '共享配置目录/文件不能是链接。'
    [[ ! -e $path ]] || { [[ -f $path ]] && grep -Fxq '# VPSKIT_SHARED_HTTP_V1' "$path"; } || die '同名配置不是VPSKit托管，未覆盖。'
    expected=$(jq -r '.owned_files.nginx_sha256 // ""' "$INSTALL_RECORD")
    if [[ -f $path && -n $expected ]]; then
        hash=$(sha256sum "$path" | cut -d' ' -f1)
        [[ $hash == "$expected" ]] || die '托管配置被外部修改；请先备份并人工合并，未静默覆盖。'
    fi
}
shared_syntax() {
    local dump="$WORK/shared-nginx-dump.txt"
    "$NGINX" -T -c "$SHARED_MAIN" > "$dump" 2> "$WORK/shared-nginx-errors.txt" || { cat "$WORK/shared-nginx-errors.txt" >&2; return 1; }
    grep -Fq "# configuration file $SHARED_INCLUDE:" "$dump" || { warn '系统主配置未include本工具片段；未自动修改nginx.conf。'; return 1; }
    if grep -Eq 'conflicting server name|duplicate' "$WORK/shared-nginx-errors.txt"; then cat "$WORK/shared-nginx-errors.txt" >&2; return 1; fi
}
s2_previous_shared_verify_runtime() {
    local old=${1:-} user uid master p u count=0 caps deadline=$((SECONDS+30)) stable=0
    user=$(resolve_worker); uid=$(id -u "$user")
    while ((SECONDS<deadline)); do
        count=0; master=$(systemctl show -p MainPID --value nginx.service 2>/dev/null || true)
        if [[ $master =~ ^[1-9][0-9]*$ ]]; then
            while read -r p u; do
                [[ " $old " != *" $p:"* ]] || continue
                [[ $u == "$uid" && $u != 0 ]] || { warn '共享Nginx Worker身份异常。'; return 1; }
                caps=$(awk '/^CapEff:/{print $2}' "/proc/$p/status" 2>/dev/null || true)
                [[ $caps =~ ^0+$ ]] || return 1
                count=$((count+1))
            done < <(master_workers "$master")
        fi
        if ((count>0)); then stable=$((stable+1)); ((stable>=2)) && return 0; else stable=0; fi
        sleep .2
    done
    warn '共享Nginx未观察到稳定的非root新Worker。'; return 1
}
shared_record_hash() {
    local hash=''; [[ ! -f $SHARED_INCLUDE ]] || hash=$(sha256sum "$SHARED_INCLUDE" | cut -d' ' -f1)
    provider_record_update --arg h "$hash" --arg p "$SHARED_INCLUDE" '.owned_files.nginx=$p | .owned_files.nginx_sha256=$h'
}
s2_previous_shared_plan() {
    local candidate="$WORK/shared-next.conf" x="$WORK/shared-xray.json"
    validate_state
    ui_title '共享模式应用预览'
    if [[ $(get '.components.nginx // false') == true ]]; then
        render_shared_nginx "$candidate"
        if cmp -s "$candidate" "$SHARED_INCLUDE"; then printf 'Nginx：片段无差异；证书内容变化仍需reload。\n'; else printf 'Nginx：更新本工具片段，校验全部配置后reload；不改系统主配置。\n'; fi
    fi
    if [[ $(get '.components.xray // false') == true ]]; then
        render_xray "$x"
        if json_equal "$x" "$ROOT/config/xray.json"; then printf 'Xray：配置无差异。\n'; else printf 'Xray：配置变化，应用时需要重启本实例。\n'; fi
    fi
    ui_note '只读；APT安装/升级、外部依赖及全局参数不在此计划中。'
}
s2_previous_shared_apply() {
    local scope=${1:-all} force=${2:-none} n="$WORK/shared-next.conf" x="$WORK/xray.next.json" unit old='' change=no cert_hash before_hash unit_change=no xchange=no xf='{}' before_xf='{}'
    ((TX==1)) || die '共享应用也必须在事务中执行。'
    migrate_state; validate_state; shared_guard_file
    if [[ $(get '.components.xray // false') == true && $scope == all ]]; then
        render_xray "$x"; "$XRAY" run -test -config "$x"
        xf=$(runtime_fingerprint xray "$x")
        before_xf=$(jq -c '.components.xray.applied // {}' "$INSTALL_RECORD")
        [[ $(jq -cS . <<< "$xf") == $(jq -cS . <<< "$before_xf") ]] || xchange=yes
    fi
    render_units "$WORK/shared-units"
    if [[ $(get '.components.nginx // false') == true ]]; then
        render_shared_nginx "$n"
        worker_permissions "$(resolve_worker)"
        if ! cmp -s "$n" "$SHARED_INCLUDE"; then change=yes; fi
        # Certificates may change at the SAME configured path.
        cert_hash=$(runtime_fingerprint nginx "$n" | jq -r .assets)
        before_hash=$(jq -r '.owned_files.certificates_sha256 // ""' "$INSTALL_RECORD")
        [[ $cert_hash == "$before_hash" && $force != nginx ]] || change=yes
        printf 'runtime\n' > "$ROOT/backup/transaction/phase"
        install -m 600 "$n" "$SHARED_INCLUDE"
        shared_syntax || die '共享Nginx全量语法/域名检查失败，恢复本工具原片段。'
    fi
    ensure_manager_installed
    for unit in "${UNITS[@]}"; do
        [[ $scope != web || $unit != vpskit-xray.service ]] || continue
        if [[ -e $SYSTEMD/$unit ]]; then
            [[ ! -L $SYSTEMD/$unit ]] && grep -Fxq '# VPSKIT_OWNED' "$SYSTEMD/$unit" || die '同名外部服务，未覆盖。'
        fi
        if ! cmp -s "$WORK/shared-units/$unit" "$SYSTEMD/$unit"; then
            printf 'runtime\n' > "$ROOT/backup/transaction/phase"
            install -m 644 "$WORK/shared-units/$unit" "$SYSTEMD/$unit"; unit_change=yes
            [[ $unit != vpskit-xray.service ]] || xchange=yes
        fi
    done
    [[ $unit_change != yes ]] || systemctl daemon-reload
    if [[ -f $x && $scope == all ]]; then
        if ! json_equal "$x" "$ROOT/config/xray.json" || [[ $force == xray || $xchange == yes ]]; then
            printf 'runtime\n' > "$ROOT/backup/transaction/phase"
            install -m 600 "$x" "$ROOT/config/xray.json"
            if (( $(jq '[.inbounds[]]|length' "$x") > 0 )); then
                warn 'Xray运行配置改变：重启本实例会中断代理连接。'
                s3_auto_enable vpskit-xray.service >/dev/null; systemctl restart vpskit-xray.service
                xray_wait_listeners || die 'Xray监听检查失败。'
            else systemctl disable --now vpskit-xray.service; fi
        elif (( $(jq '[.inbounds[]]|length' "$x") > 0 )) && ! systemctl is-active --quiet vpskit-xray.service; then
            systemctl enable --now vpskit-xray.service; xray_wait_listeners || die 'Xray未启动。'
        fi
    fi
    if [[ $scope == all && $(get '.components.xray // false') != true ]] && systemctl is-active --quiet vpskit-xray.service; then
        printf 'runtime\n' > "$ROOT/backup/transaction/phase"
        systemctl disable --now vpskit-xray.service
    fi
    if [[ -f $x ]]; then provider_record_update --argjson f "$xf" '.components.xray.applied=$f'; fi
    if [[ $(get '.components.nginx // false') == true ]]; then
        # Explicit migration is the only path allowed to stop the old private instance.
        if [[ ${MIGRATING_TO_SHARED:-no} == yes ]]; then systemctl disable --now vpskit-nginx.service; fi
        if systemctl is-active --quiet nginx.service; then
            if [[ $change == yes ]]; then
                old=$(worker_generation "$(nginx_master_pid)")
                if [[ $force == nginx ]]; then
                    warn '共享Nginx二进制更新：需要restart，影响全部共享网站。'
                    systemctl restart nginx.service; old=''
                else systemctl reload nginx.service; fi
                shared_verify_runtime "$old" || die '共享Nginx重载未通过检查。'
            fi
        else
            systemctl enable --now nginx.service
            shared_verify_runtime || die '共享Nginx启动未通过检查。'
        fi
        shared_record_hash
        provider_record_update --arg h "$cert_hash" '.owned_files.certificates_sha256=$h'
    fi
    systemctl enable --now vpskit-maintain.timer >/dev/null
    ok '共享模式已应用；未覆盖系统nginx.conf，未修改其他应用的配置。'
}
apply_config() {
    if [[ $MODE == shared ]]; then shared_apply "$@"; else s1_base_apply_config "$@"; fi
}
runtime_plan_command() { if [[ $MODE == shared ]]; then shared_plan; else s1_base_runtime_plan_command; fi; }
# Add provider metadata and the one shared file to backups. No whole /etc/nginx restore.
snapshot_copy() {
    s1_base_snapshot_copy "$@" || return 1
    local dest=$1
    [[ ! -f $(install_record_path) ]] || cp -a "$(install_record_path)" "$dest/installation.json" || return 1
    if [[ -f $SHARED_INCLUDE ]]; then
        grep -Fxq '# VPSKIT_SHARED_HTTP_V1' "$SHARED_INCLUDE" || return 1
        cp -a "$SHARED_INCLUDE" "$dest/shared-nginx.conf" || return 1
    fi
    if systemctl is-active --quiet nginx.service 2>/dev/null; then printf 'yes\n' > "$dest/system-nginx-active"; fi
    if systemctl is-enabled --quiet nginx.service 2>/dev/null; then printf 'yes\n' > "$dest/system-nginx-enabled"; fi
    (cd "$dest" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 -r sha256sum > SHA256SUMS) || return 1
}
s2_base_restore_transaction() {
    local dir=$1 how=${2:-normal} current=$MODE original=isolated prepared=no
    local RESTORE_PRESERVE_XRAY=no reason
    if [[ ! -d $dir/snapshot ]]; then s1_base_restore_transaction "$@"; return; fi
    ( snapshot_verify "$dir/snapshot" ) || { warn '恢复快照校验失败；未修改安装登记和共享配置。'; return 1; }
    reason=$(jq -r '.reason // ""' "$dir/snapshot/meta.json")
    if [[ $reason == mode-migrate:* ]]; then
        cmp -s "$ROOT/config/xray.json" "$dir/snapshot/config/xray.json" || { warn 'Xray配置发生外部变化；不自动回滚覆盖它。'; return 1; }
        if [[ -f $dir/programs/bin/xray ]]; then
            cmp -s "$ROOT/bin/xray" "$dir/programs/bin/xray" || { warn 'Xray二进制发生外部变化；停止模式自动恢复。'; return 1; }
        fi
        if [[ -f $dir/units/vpskit-xray.service ]]; then
            cmp -s "$SYSTEMD/vpskit-xray.service" "$dir/units/vpskit-xray.service" || { warn 'Xray服务被外部修改；停止自动恢复。'; return 1; }
        fi
        RESTORE_PRESERVE_XRAY=yes
    fi
    if [[ -f $dir/snapshot/installation.json ]]; then
        [[ ! -L $dir/snapshot/installation.json ]] && jq -e '.schema==1 and (.mode=="shared" or .mode=="isolated")' "$dir/snapshot/installation.json" >/dev/null || return 1
    fi
    if [[ -f $dir/snapshot/installation.json ]]; then original=$(jq -r .mode "$dir/snapshot/installation.json"); fi
    [[ ! -f $dir/phase || $(cat "$dir/phase") != prepared ]] || prepared=yes
    if [[ -f $dir/snapshot/installation.json ]]; then
        cp -a "$dir/snapshot/installation.json" "$(install_record_path)" || return 1
    elif [[ -f $(install_record_path) ]]; then rm -f -- "$(install_record_path)"; fi
    if [[ $current == shared || $original == shared ]]; then
        if [[ -f $dir/snapshot/shared-nginx.conf ]]; then
            [[ ! -L $SHARED_INCLUDE ]] || return 1
            cp -a "$dir/snapshot/shared-nginx.conf" "$SHARED_INCLUDE" || return 1
        elif [[ -f $SHARED_INCLUDE ]] && grep -Fxq '# VPSKIT_SHARED_HTTP_V1' "$SHARED_INCLUDE"; then rm -f -- "$SHARED_INCLUDE" || return 1; fi
        if [[ $prepared != yes && $original == isolated ]]; then
            if [[ ! -f $dir/snapshot/system-nginx-active ]]; then systemctl stop nginx.service || return 1
            else
                "$SHARED_NGINX" -t -c "$SHARED_MAIN" || return 1
                systemctl reload nginx.service || return 1
            fi
        fi
    fi
    mode_load
    s1_base_restore_transaction "$dir" "$how" || return 1
    if [[ $prepared != yes && ( $original == shared || -f $dir/snapshot/system-nginx-active ) ]]; then
        "$SHARED_NGINX" -t -c "$SHARED_MAIN" || return 1
        if systemctl is-active --quiet nginx.service; then systemctl reload nginx.service || return 1
        else systemctl start nginx.service || return 1; fi
    fi
    if [[ $RESTORE_PRESERVE_XRAY == yes && $prepared != yes ]]; then
        if [[ -f $dir/snapshot/system-nginx-enabled ]]; then systemctl enable nginx.service >/dev/null || return 1
        else systemctl disable nginx.service >/dev/null || return 1; fi
    fi
    return 0
}
install_component() {
    local name=$1 version=${2:-$XRAY_DEFAULT_VERSION} force=${3:-no}
    record_init "$MODE"
    if [[ $force == no ]] && component_ready "$name"; then ok "$name 已安装；不重复安装。"; return; fi
    if [[ $MODE == shared && $force == yes && ( $name == nginx || $name == acme ) ]]; then
        warn '共享组件更新会影响其他使用者；APT软件包不能靠配置快照自动降级。'
        confirm "升级共享 $name" || return 0
    fi
    local SHARED_UPGRADE=no; [[ $force != yes ]] || SHARED_UPGRADE=yes
    begin_tx "component:$name" components
    case "$name" in nginx) install_nginx_binary;; xray) install_xray_binary "$version";; acme) install_acme_binary;; *) die '组件只能为nginx/xray/acme。';; esac
    apply_config all "$name"; commit_tx
}
mode_select_empty() {
    local desired=${1:-}
    choice "$desired" 'shared isolated' || die 'mode select shared|isolated。'
    [[ ! -f $STATE ]] || ! jq -e '(.nodes|length)>0 or ((.native_nodes // [])|length)>0 or (.sites|length)>0 or (.components|any(.==true))' "$STATE" >/dev/null || die '已有部署不能直接改模式，请使用mode migrate。'
    if [[ -f $(install_record_path) ]]; then provider_record_update --arg m "$desired" '.mode=$m'; mode_load
    else record_init "$desired"; fi
    ok "空部署模式已选择：$MODE；尚未安装组件。"
}
mode_migrate() {
    local target=${1:-} action=${2:---plan} from=$MODE hash pid system_active=no
    choice "$target" 'shared isolated' && choice "$action" '--plan --apply' || die 'mode migrate shared|isolated --plan|--apply。'
    [[ $from != "$target" ]] || { info '已经处于目标模式。'; return; }
    ui_title "模式迁移：$from → $target"
    ui_note '保留节点凭据、Xray配置、网站与证书；切换Nginx会短暂中断网站/WS/XHTTP。软件包安装不自动回退。'
    if [[ $target == isolated ]]; then
        ui_note '共享→独立仅允许系统Nginx没有其他启用站点；发现外部站点时拒绝停止系统Nginx。'
    fi
    [[ $action != --plan ]] || { printf '动作：备份 → 安装/复用目标组件 → 生成配置 → 校验 → 切换 → 检查Xray不变 → 提交。\n'; return; }
    if [[ $target == isolated ]]; then
        shared_external_sites_check || die '共享Nginx仍有其他启用站点/未知server块；不能为迁移停止它。'
    fi
    confirm "迁移到 $target；将切换Nginx，不主动重启Xray" || return 0
    record_init "$from"
    hash=$(runtime_hash_file "$ROOT/config/xray.json"); pid=$(systemctl show -p MainPID --value vpskit-xray.service 2>/dev/null || true)
    begin_tx "mode-migrate:$from:$target" components
    provider_record_update --arg m "$target" --arg f "$from" '.mode=$m | .migration={from:$f,to:$m,status:"in-progress",started:(now|todate)}'
    mode_load
    if [[ $(get '.components.nginx // false') == true ]]; then install_nginx_binary; fi
    if [[ $(get '.components.acme // false') == true ]]; then install_acme_binary; fi
    if [[ $target == shared ]]; then
        local MIGRATING_TO_SHARED=yes
        apply_config web
    else
        # Validate before releasing shared ports. Keep external services untouched.
        migrate_state; remember_worker; render_nginx "$WORK/migrate-private.conf"
        nginx_preflight "$WORK/migrate-private.conf" || die '独立模式预检失败。'
        printf 'runtime\n' > "$ROOT/backup/transaction/phase"
        [[ ! -f $SHARED_INCLUDE ]] || rm -f -- "$SHARED_INCLUDE"
        systemctl stop nginx.service
        apply_config web nginx
        systemctl disable nginx.service >/dev/null
    fi
    [[ $(runtime_hash_file "$ROOT/config/xray.json") == "$hash" && $(systemctl show -p MainPID --value vpskit-xray.service 2>/dev/null || true) == "$pid" ]] || die '迁移期间Xray被外部改变，未提交。'
    provider_record_update '.migration.status="completed" | .migration.completed=(now|todate)'
    commit_tx
    ok '迁移完成；旧私有组件/共享软件包暂不删除，保留可恢复性。'
}
shared_external_sites_check() {
    local dump="$WORK/nginx-external.txt"
    "$SHARED_NGINX" -T -c "$SHARED_MAIN" > "$dump" 2>/dev/null || return 1
    awk -v owned="$SHARED_INCLUDE" '
      /^# configuration file / {file=$0;sub(/^# configuration file /,"",file);sub(/:$/,"",file);next}
      file!=owned {
        sub(/#.*/,"")
        if($0 ~ /(^|[;{}[:space:]])server[[:space:]]*\{/ || $0 ~ /(^|[;{}[:space:]])server_name[[:space:]]/ || $0 ~ /^[[:space:]]*server[[:space:]]*$/) {
          if(!seen[file]++) print "外部server: "file
          found=1
        }
      }
      END{exit found?1:0}' "$dump"
}
# Keep destructive shared-package removal separate from normal VPSKit uninstall.
s2_previous_shared_detach() {
    shared_guard_file
    confirm '仅移除VPSKit的Nginx片段；保留所有组件、证书、节点、网站和备份；共享Nginx将reload' || return 0
    begin_tx shared-detach
    printf 'runtime\n' > "$ROOT/backup/transaction/phase"
    [[ ! -f $SHARED_INCLUDE ]] || rm -f -- "$SHARED_INCLUDE"
    "$NGINX" -t -c "$SHARED_MAIN"
    if systemctl is-active --quiet nginx.service; then systemctl reload nginx.service; fi
    json_update '.components.nginx=false'
    provider_record_update '.owned_files |= del(.nginx,.nginx_sha256,.certificates_sha256)'
    commit_tx
    info '只移除网页入口；Xray直连节点不受此操作影响。停用全部节点请另行选择。'
}
s4_old_shared_remove_component() {
    local name=$1 token='' simulation="$WORK/remove-simulation.txt"
    choice "$name" 'nginx acme' || die '共享删除支持nginx/acme。'
    warn '这是系统级删除，不等于仅移除VPSKit配置；其他应用可能受影响。不能证明扫描覆盖全部依赖。'
    if [[ $name == nginx ]]; then
        [[ ! -f $SHARED_INCLUDE ]] || die '请先components detach，避免遗留启用的VPSKit片段。'
        shared_external_sites_check || die '检测到外部站点，拒绝自动移除共享Nginx；请管理员先迁移其他站点。'
        local owner
        local -a packages=()
        owner=$(dpkg-query -S "$SHARED_NGINX" 2>/dev/null | sed -n 's/: \/.*$//p' | head -n1)
        [[ $owner =~ ^nginx(-core|-full|-light|-extras)?(:[a-z0-9]+)?$ ]] || die '不能确认Nginx二进制属于受支持的APT包，未自动删除。'
        packages+=("$owner")
        if [[ $owner != nginx ]] && [[ $(dpkg-query -W -f='${db:Status-Status}' nginx 2>/dev/null || true) == installed ]]; then packages+=(nginx); fi
        apt-get -s remove "${packages[@]}" > "$simulation"; cat "$simulation"
        ask token '确认卸载系统Nginx（保留/etc/nginx和数据）；输入 REMOVE SHARED NGINX' ''
        [[ $token == 'REMOVE SHARED NGINX' ]] || return 0
        apt-get remove "${packages[@]}"
        json_update '.components.nginx=false'
        provider_record_update '.components.nginx.removed=true'
    else
        [[ $ACME == "$SHARED_ACME_HOME/acme.sh" && -f $SHARED_ACME_HOME/.vpskit-code && ! -L $SHARED_ACME_HOME ]] || die '外部ACME只允许解除引用，不能自动删除其程序。'
        if jq -e '.sites[]|select(.issued and (.certificate_source // "acme")!="manual")' "$STATE" >/dev/null; then
            die 'VPSKit仍有自动续期证书；先迁移续期责任或导入手动证书，再删除ACME程序。'
        fi
        ui_note '不会删除任何ACME账户/私钥；请先确认其他程序已迁移。不会删除或改写外部cron。'
        ask token '删除共享ACME程序；输入 REMOVE SHARED ACME' ''
        [[ $token == 'REMOVE SHARED ACME' ]] || return 0
        [[ ! -L $SHARED_ACME_ENTRY ]] && grep -Fxq '# VPSKIT_SHARED_ACME_ENTRY_V1' "$SHARED_ACME_ENTRY" || die '全局入口已被外部替换。'
        # Code only, never account homes. Reject child mounts and unexpected symlinks.
        local mounts path
        mounts=$(findmnt -rn -o TARGET) || die '无法检查挂载点。'
        while IFS= read -r path; do [[ $path != "$SHARED_ACME_HOME" && $path != "$SHARED_ACME_HOME/"* ]] || die '共享ACME包含挂载点。'; done <<< "$mounts"
        rm -f -- "$SHARED_ACME_ENTRY"; rm -rf --one-file-system -- "$SHARED_ACME_HOME"
        json_update '.components.acme=false'; provider_record_update '.components.acme.removed=true'
    fi
}
uninstall_component() {
    if [[ $MODE == shared && ( $1 == nginx || $1 == acme ) ]]; then
        local method; select_value method '共享组件卸载方式' config 'config|只解除VPSKit配置/引用，保留共享程序' 'component|删除共享程序（检查其他使用者并单独确认）'
        if [[ $method == component ]]; then shared_remove_component "$1"
        elif [[ $1 == nginx ]]; then shared_detach
        else
            jq -e '.sites[]|select(.issued and (.certificate_source // "acme")!="manual")' "$STATE" >/dev/null && die '仍有自动续期证书，先迁移续期责任。'
            confirm '停止VPSKit调用ACME，保留程序和账户数据' || return 0
            json_update '.components.acme=false'
        fi
    else s1_base_uninstall_component "$@"; fi
}
uninstall_all() { s4_wizard; }
uninstall_keep_data() { s4_command apply --scope=config; }
advanced_set() {
    if [[ $MODE == shared ]]; then
        local arg
        local -a filtered=(); local i key
        if [[ ${SHARED_LOCAL_PROFILE:-no} == yes ]]; then
            for ((i=1;i<=$#;i+=2)); do
                key=${!i}; local j=$((i+1))
                case "$key" in nginx.workers|nginx.connections|nginx.nofile) continue;; esac
                filtered+=("$key" "${!j}")
            done
            ui_note '共享资源预设：已跳过Worker/连接总量/全局FD；只应用本项目站点和Xray参数。'
            s1_base_advanced_set "${filtered[@]}"; return
        fi
        for arg in "$@"; do
            case "$arg" in nginx.workers|nginx.connections|nginx.nofile|nginx.worker_user|nginx.sandbox_mode|nginx.worker_shutdown_timeout)
                die '这是共享Nginx全局设置，会影响其他网站；阶段1不自动编辑系统主配置/服务限制，请由管理员统一管理。';;
            esac
        done
    fi
    s1_base_advanced_set "$@"
}
s3_prev_service_control() {
    # Normalize both legacy argument orders before choosing a provider.
    local name=$1 action=${2:-}
    if choice "$name" 'start stop restart reload'; then local swap=$name; name=$action; action=$swap; fi
    set -- "$name" "$action"
    if [[ $MODE == shared && ( $1 == nginx || $2 == nginx ) ]]; then
        local action=$2; [[ $1 == nginx ]] || action=$1
        choice "$action" 'start stop restart reload' || die '支持start/stop/restart/reload。'
        [[ $action == stop ]] || "$NGINX" -t -c "$SHARED_MAIN"
        confirm "对共享nginx.service执行$action；影响全部共享网站" || return 0
        systemctl "$action" nginx.service; return
    fi
    if [[ $MODE == shared && $1 == all ]]; then
        [[ $2 == restart ]] || die '全部组件只支持service all restart；未执行其他动作。'
        confirm '重启Xray与共享Nginx：全部共享网站和代理会短暂中断' || return 0
        if component_ready nginx; then "$NGINX" -t -c "$SHARED_MAIN"; fi
        if component_ready xray && [[ $(jq '.inbounds|length' "$ROOT/config/xray.json") -gt 0 ]]; then
            "$XRAY" run -test -config "$ROOT/config/xray.json"
            systemctl restart vpskit-xray.service; xray_wait_listeners || die 'Xray未就绪，未重启共享Nginx。'
        fi
        if component_ready nginx; then systemctl restart nginx.service; shared_verify_runtime; fi
        systemctl restart vpskit-maintain.timer
        return
    fi
    s1_base_service_control "$@"
}
status_show() {
    if [[ $MODE != shared ]]; then s1_base_status_show; return; fi
    components_show
    systemctl --no-pager --full status nginx.service vpskit-xray.service vpskit-maintain.timer || true
    printf '提示：共享Worker/FD参数以系统nginx.conf和进程实际值为准；VPSKit保存的全局参数不在共享模式应用。\n'
}
doctor() {
    [[ $MODE == shared ]] || { s1_base_doctor; return; }
    local errors=0
    components_show
    "$NGINX" -t -c "$SHARED_MAIN" || errors=$((errors+1))
    shared_verify_runtime || errors=$((errors+1))
    if component_ready xray; then "$XRAY" run -test -config "$ROOT/config/xray.json" || errors=$((errors+1)); fi
    printf '共享模式检查问题数：%s\n' "$errors"; ((errors==0))
}

# Native inbound records are independent of the legacy node schema. All enabled
# records are merged into ONE Xray instance and validated with the installed core.
# The catalogue never equates a transport (XHTTP/REALITY) with an inbound protocol.
xray_catalog() {
    cat <<'TEXT'
协议/组合                     创建方式             使用要求
VLESS REALITY / XHTTP / TLS    原节点向导           保留现有节点兼容
VMess / Trojan / Shadowsocks  原节点向导           旧协议保留，客户端必须支持
Shadowsocks 2022              原节点向导           独立TCP/UDP端口
VLESS Encryption              新协议向导           核心需支持vlessenc；默认TLS+加密
VLESS gRPC / HTTPUpgrade TLS  新协议向导           Xray直接TLS；独立端口，不走共享Nginx
Hysteria2                    新协议向导           TLS证书、UDP可达；Xray原生实现
MASQUE CONNECT-IP H2/H3       新协议向导           TLS、认证；按ALPN核对TCP/UDP
SOCKS5 / HTTP                新协议向导           认证；默认且限制回环监听
WireGuard/原生JSON组合         原生入站导入         安全校验+实际核心run -test，不接管系统路由
TUN / Tunnel                 本阶段不创建         涉及系统路由/设备授权，不能当普通公网节点
TEXT
    printf '\n核验基线：Xray v26.10.31（2026-11-01查询）；安装时latest通过官方API解析正式版。\n'
    [[ ! -x $XRAY ]] || "$XRAY" version | head -n2
    ui_note '“列出协议”不是客户端端到端通过。创建前对完整候选配置进行实际核心校验；不支持则不保存。'
}
xray_core_check() {
    local cfg=$1 out="$WORK/core-check.txt"
    [[ -x $XRAY ]] || die '先安装Xray。'
    if ! "$XRAY" run -test -config "$cfg" > "$out" 2>&1; then
        warn '当前Xray未接受候选配置；没有重启或保存节点。检查核心版本/字段/证书。'
        tail -n 20 "$out" >&2
        return 1
    fi
    return 0
}
native_validate() {
    local file=$1 n protocol listen port net path cert method inferred
    jq -e '(.native_nodes // []) as $n | ($n|type=="array") and
      ($n|all(type=="object" and (.enabled|type=="boolean") and (.id|type=="string") and (.inbound|type=="object"))) and
      ([$n[].id]|length==(unique|length)) and
      ([.nodes[].entry,$n[].inbound.tag]|unique|length)==([.nodes[].entry]|unique|length)+($n|length)' "$file" >/dev/null || die '原生节点结构或标签冲突。'
    while IFS= read -r n; do
        valid_name "$(jq -r .id <<< "$n")" || die '原生节点名称无效。'
        valid_name "$(jq -r .inbound.tag <<< "$n")" || die '原生节点tag无效。'
        port=$(jq -r .inbound.port <<< "$n"); valid_port "$port" || die '原生入站必须使用单个数值端口。'
        [[ $port != 22 && $port != 80 && $port != 443 ]] || die '阶段1原生入口必须使用独立非22/80/443端口。'
        protocol=$(jq -r .inbound.protocol <<< "$n"); listen=$(jq -r '.inbound.listen // ""' <<< "$n")
        choice "$listen" '0.0.0.0 :: 127.0.0.1 ::1' || die '原生入口必须显式指定支持的监听地址。'
        net=$(jq -r .network <<< "$n"); choice "$net" 'tcp udp tcp,udp' || die '入口网络需tcp/udp/tcp,udp。'
        if jq -e '.inbound.streamSettings|has("method")' <<< "$n" >/dev/null 2>&1 || choice "$protocol" 'hysteria masque'; then require_modern_xray; fi
        case "$protocol" in
          socks|http|mixed)
            choice "$listen" '127.0.0.1 ::1' || die 'SOCKS/HTTP仅允许回环监听，禁止意外开放公网代理。'
            [[ $protocol != socks ]] || [[ $(jq -r '.inbound.settings.auth // "noauth"' <<< "$n") == password ]] || die 'SOCKS必须显式auth=password。'
            jq -e '.inbound.settings.accounts|type=="array" and length>0 and all((.user|length)>0 and (.pass|length)>=12)' <<< "$n" >/dev/null || die 'SOCKS/HTTP需要强认证。';;
          hysteria)
            jq -e '.inbound | (.settings.version==2) and ((.settings.users // .settings.clients)|length>0 and all((.auth|type)=="string" and (.auth|length)>=12)) and (.streamSettings.security=="tls") and ((.streamSettings.method // .streamSettings.network)=="hysteria")' <<< "$n" >/dev/null || die 'Hysteria2需要users认证、hysteria传输及TLS。';;
          masque)
            jq -e '.inbound | ((.settings.users // .settings.clients)|length>0 and all((.pass|type)=="string" and (.pass|length)>=12 and (.email|length)>0)) and (.streamSettings.security=="tls") and ((.streamSettings.method // .streamSettings.network)=="masque")' <<< "$n" >/dev/null || die 'MASQUE需要认证、专用传输和TLS。';;
          vless|trojan|vmess)
            jq -e '.inbound.settings | (.users // .clients)|type=="array" and length>0' <<< "$n" >/dev/null || die '原生入口缺少认证用户。'
            if [[ $protocol != vmess ]] && ! choice "$listen" '127.0.0.1 ::1'; then
                if ! jq -e '.inbound.streamSettings.security=="tls" or .inbound.streamSettings.security=="reality"' <<< "$n" >/dev/null; then
                    [[ $protocol == vless ]] && jq -e '.inbound.settings.decryption|type=="string" and startswith("mlkem768x25519plus.")' <<< "$n" >/dev/null || die '公网VLESS/Trojan必须有TLS/REALITY或有效VLESS Encryption。'
                fi
            fi;;
          shadowsocks)
            jq -e '.inbound.settings.password|type=="string" and length>=12' <<< "$n" >/dev/null || die 'Shadowsocks缺少密钥。';;
          wireguard)
            jq -e '.inbound.settings | (.secretKey|length)>0 and (.peers|length)>0' <<< "$n" >/dev/null || die 'WireGuard入站缺少密钥/peer。';;
          *) die "本阶段不导入$protocol；TUN/透明代理需单独授权，不自动改变系统路由。";;
        esac
        method=$(jq -r '.inbound.streamSettings.method // .inbound.streamSettings.network // "raw"' <<< "$n")
        inferred=tcp
        case "$protocol:$method" in
            hysteria:*|wireguard:*|*:kcp|*:mkcp|*:hysteria) inferred=udp;;
            masque:*|*:masque)
                inferred=$(jq -r '(.inbound.streamSettings.tlsSettings.alpn // ["h3"]) as $a | if ($a|index("h2"))!=null and ($a|index("h3"))!=null then "tcp,udp" elif ($a|index("h2"))!=null then "tcp" else "udp" end' <<< "$n");;
            shadowsocks:*) inferred=$(jq -r '.inbound.settings.network // "tcp"' <<< "$n");;
            socks:*) [[ $(jq -r '.inbound.settings.udp // false' <<< "$n") != true ]] || inferred=tcp,udp;;
        esac
        [[ $net == "$inferred" ]] || die "声明网络$net与协议/传输所需$inferred不一致；避免错误放行或监听判断。"
        # Server certificate paths must be valid and confined to the administrator's
        # configured VPSKit certificate tree. Arbitrary files are not exposed.
        while IFS= read -r path; do
            [[ $path == "$ROOT/certs/"* && -f $path && $(realpath -m "$path") == "$ROOT/certs/"* ]] || die '原生TLS配置证书路径必须指向VPSKit证书目录。'
        done < <(jq -r '.inbound.streamSettings.tlsSettings.certificates[]? | .certificateFile,.keyFile | select(.!=null)' <<< "$n")
        if jq -e --argjson p "$port" '.nodes[]|select(.port==$p)' "$file" >/dev/null; then die '原生节点与已有节点端口冲突。'; fi
    done < <(jq -c '.native_nodes // [] | .[]' "$file")
    jq -e '[(.native_nodes // [])[].inbound.port]|length==(unique|length)' "$file" >/dev/null || die '原生节点端口重复。'
}
validate_state() { s1_base_validate_state "$@"; native_validate "${1:-$STATE}"; }
render_xray() {
    local dest=$1 tmp="$WORK/xray-base-$BASHPID.json"
    s1_base_render_xray "$tmp"
    jq --slurpfile s "$STATE" '.inbounds += [($s[0].native_nodes // [])[]|select(.enabled)|.inbound]' "$tmp" > "$dest"
    rm -f "$tmp"
}
all_xray_ports() {
    jq -r '([.nodes[]|select(.enabled)]|unique_by(.entry)[]|[.port,(if .mode=="ss" then "tcp,udp" else "tcp" end)]),
      ((.native_nodes // [])[]|select(.enabled)|[.inbound.port,.network]) | @tsv' "$STATE"
}
s2_previous_check_listener_ports() {
    local port net
    if [[ $(get '.components.nginx // false') == true ]]; then
        guard_port 80 "$NGINX_SERVICE"
        if jq -e '.sites[]|select(.issued)' "$STATE" >/dev/null; then guard_port 443 "$NGINX_SERVICE"; fi
    fi
    while read -r port net; do guard_port "$port" vpskit-xray.service; done < <(all_xray_ports)
}
xray_wait_listeners() {
    local end=$((SECONDS+15)) port net good
    while ((SECONDS<end)); do
        good=yes
        systemctl is-active --quiet vpskit-xray.service || good=no
        while read -r port net; do
            if [[ $net == *tcp* ]]; then [[ -n $(ss -H -lnt "sport = :$port") ]] || good=no; fi
            if [[ $net == *udp* ]]; then [[ -n $(ss -H -lnu "sport = :$port") ]] || good=no; fi
        done < <(all_xray_ports)
        [[ $good != yes ]] || return 0
        sleep .2
    done
    return 1
}
firewall_required_state() {
    local file=$1
    { s1_base_firewall_required_state "$file"
      jq -r '(.native_nodes // [])[]|select(.enabled and (.inbound.listen!="127.0.0.1" and .inbound.listen!="::1"))|
         .inbound.port as $p | (.network|split(",")[]) | "\($p) \(.)"' "$file"
    } | sort -k1,1n -k2,2 -u
}
native_commit() {
    local item=$1 candidate="$WORK/native-state.json" runtime="$WORK/native-xray.json"
    jq --argjson n "$item" '.native_nodes=((.native_nodes // []) + [$n])' "$STATE" > "$candidate"
    (STATE=$candidate; validate_state; render_xray "$runtime")
    xray_core_check "$runtime" || return 1
    local port; port=$(jq -r .inbound.port <<< "$item")
    [[ -z $(ss -H -lntup "sport = :$port") ]] || die '端口已占用；未保存原生节点。'
    confirm '核心配置校验通过，保存新节点并应用；Xray实例会重启一次。防火墙仅检查，不自动放行' || return 0
    begin_tx native-node-add
    install -m 600 "$candidate" "$STATE"
    apply_config; commit_tx
    smart_after_node || true
    ok '原生节点已保存；用node native export导出客户端JSON（敏感凭据）。'
}
native_add() {
    local kind=${1:-} id host domain='' port listen=0.0.0.0 pass user tag protocol network=tcp settings stream client='' item method alpn uuid flow='' keys dec enc
    ensure_component xray
    if [[ -z $kind ]]; then
        select_value kind '新协议/传输（编号选择；默认不改已有节点）' encryption \
          'encryption|VLESS Encryption + TLS / RAW' 'hysteria|Hysteria2（Xray原生，UDP）' \
          'masque|MASQUE CONNECT-IP（H2/H3）' 'grpc|VLESS gRPC + TLS直连' \
          'httpupgrade|VLESS HTTPUpgrade + TLS直连' 'socks|认证SOCKS5（仅本机）' 'http|认证HTTP代理（仅本机）'
    fi
    choice "$kind" 'encryption hysteria masque grpc httpupgrade socks http' || die '未知新协议类型。'
    if [[ $kind != socks && $kind != http ]]; then require_modern_xray; fi
    ask_valid id '显示名称' "native-$(randhex 3)" valid_name
    tag="vk-$(randhex 8)"
    smart_port_select port '独立监听端口' 9443
    [[ $port != 22 && $port != 80 && $port != 443 ]] || die '保留端口。'
    pass=$(openssl rand -hex 24); user="u-$(randhex 4)"; uuid=$(new_uuid)
    if [[ $kind == socks || $kind == http ]]; then
        host=127.0.0.1; listen=127.0.0.1; protocol=$kind
        settings=$(jq -n --arg u "$user" --arg p "$pass" --arg k "$kind" '{accounts:[{user:$u,pass:$p}]} + if $k=="socks" then {auth:"password",udp:false} else {} end')
        stream='{}'
        client=$(jq -n --arg p "$kind" --arg u "$user" --arg pass "$pass" --argjson port "$port" '{protocol:$p,settings:{servers:[{address:"127.0.0.1",port:$port,users:[{user:$u,pass:$pass}]}]}}')
    else
        site_select domain; cert_files_valid "$domain" || die '需要所选站点的有效TLS证书。'
        smart_host_select host '直连源站IP或DNS-only域名（不是Cloudflare橙云）' "$(get '.host // ""')"
        stream=$(jq -n --arg c "$ROOT/certs/$domain/current/fullchain.pem" --arg k "$ROOT/certs/$domain/current/key.pem" '{security:"tls",tlsSettings:{minVersion:"1.2",certificates:[{certificateFile:$c,keyFile:$k}]}}')
        case "$kind" in
            encryption)
                protocol=vless; method=raw
                keys=$("$XRAY" vlessenc) || die '当前核心没有vlessenc；先选择升级Xray。'
                # Take the FIRST matching pair together; never mix authentication types.
                dec=$(sed -n 's/^"decryption": "\([^"]*\)".*$/\1/p' <<< "$keys" | head -n1)
                enc=$(sed -n 's/^"encryption": "\([^"]*\)".*$/\1/p' <<< "$keys" | head -n1)
                [[ $dec == mlkem768x25519plus.* && $enc == mlkem768x25519plus.* ]] || die 'vlessenc格式不兼容，未自行拼接密钥。'
                settings=$(jq -n --arg id "$uuid" --arg d "$dec" --arg tag "$tag" '{decryption:$d,clients:[{id:$id,email:$tag,flow:"xtls-rprx-vision"}]}')
                client=$(jq -n --arg h "$host" --argjson port "$port" --arg id "$uuid" --arg e "$enc" '{protocol:"vless",settings:{vnext:[{address:$h,port:$port,users:[{id:$id,encryption:$e,flow:"xtls-rprx-vision"}]}]}}')
                stream=$(jq '.method="raw"' <<< "$stream");;
            grpc|httpupgrade)
                protocol=vless; method=$kind
                settings=$(jq -n --arg id "$uuid" --arg tag "$tag" '{decryption:"none",clients:[{id:$id,email:$tag}]}')
                client=$(jq -n --arg h "$host" --argjson port "$port" --arg id "$uuid" '{protocol:"vless",settings:{vnext:[{address:$h,port:$port,users:[{id:$id,encryption:"none"}]}]}}')
                if [[ $kind == grpc ]]; then
                    stream=$(jq --arg n "$tag" '.method="grpc"|.grpcSettings={serviceName:$n}|.tlsSettings.alpn=["h2"]' <<< "$stream")
                else stream=$(jq --arg p "/$tag" '.method="httpupgrade"|.httpupgradeSettings={path:$p}|.tlsSettings.alpn=["http/1.1"]' <<< "$stream"); fi;;
            hysteria)
                protocol=hysteria; network=udp
                settings=$(jq -n --arg p "$pass" --arg tag "$tag" '{version:2,users:[{auth:$p,email:$tag}]}')
                stream=$(jq '.method="hysteria"|.hysteriaSettings={version:2}|.tlsSettings.alpn=["h3"]' <<< "$stream")
                client=$(jq -n --arg h "$host" --argjson p "$port" '{protocol:"hysteria",settings:{version:2,address:$h,port:$p}}');;
            masque)
                protocol=masque
                select_value alpn '选择MASQUE传输' h3 'h3|HTTP/3，UDP' 'h2|HTTP/2，TCP' 'both|同一端口TCP+UDP'
                case "$alpn" in h3) network=udp;; both) network=tcp,udp;; esac
                settings=$(jq -n --arg p "$pass" --arg u "$user" '{users:[{email:$u,pass:$p}],address:["10.77.0.1/24","fd77::1/64"],mtu:1280}')
                stream=$(jq --arg a "$alpn" '.method="masque"|.masqueSettings={path:"/.well-known/masque/ip/{target}/{ipproto}/"}|.tlsSettings.alpn=(if $a=="both" then ["h3","h2"] else [$a] end)' <<< "$stream")
                client=$(jq -n --arg h "$host" --argjson p "$port" '{protocol:"masque",settings:{address:$h,port:$p}}');;
        esac
        client=$(jq --argjson s "$stream" --arg d "$domain" --arg k "$kind" --arg pass "$pass" --arg u "$user" \
          '.streamSettings=($s | del(.tlsSettings.certificates) | .tlsSettings.serverName=$d | .tlsSettings.allowInsecure=false) |
           if $k=="hysteria" then .streamSettings.hysteriaSettings.auth=$pass
           elif $k=="masque" then .streamSettings.masqueSettings.user=$u|.streamSettings.masqueSettings.pass=$pass else . end' <<< "$client")
    fi
    item=$(jq -n --arg id "$id" --arg tag "$tag" --arg p "$protocol" --argjson port "$port" --arg l "$listen" --argjson s "$settings" --argjson st "$stream" --arg n "$network" --arg h "$host" --arg d "$domain" --argjson c "$client" \
      '{id:$id,enabled:true,network:$n,host:$h,domain:$d,inbound:{tag:$tag,protocol:$p,port:$port,listen:$l,settings:$s,streamSettings:$st},client:$c}')
    native_commit "$item"
}
native_import() {
    local file=${1:-} network=${2:-} id host port item
    [[ -f $file && ! -L $file && $(stat -c %s "$file") -le 262144 ]] || die '需一个小于256KiB的原生InboundObject JSON普通文件。'
    jq -e 'type=="object" and has("protocol") and has("settings") and (has("inbounds")|not)' "$file" >/dev/null || die '只导入单个入站对象，不接受整套配置/出站/路由覆盖。'
    [[ -n $network ]] || select_value network '监听网络（必须与核心配置一致）' tcp 'tcp|TCP' 'udp|UDP' 'tcp,udp|TCP及UDP'
    ask_valid id '导入节点名称' "import-$(randhex 3)" valid_name
    ask_valid host '客户端连接地址（仅记录，不自动设置DNS）' "$(get '.host // "127.0.0.1"')" valid_host
    item=$(jq --arg id "$id" --arg tag "vk-$(randhex 8)" --arg n "$network" --arg h "$host" '{id:$id,enabled:true,host:$h,domain:"",network:$n,inbound:(. + {tag:$tag}),client:null}' "$file")
    native_commit "$item"
}
native_list() {
    jq -r '(.native_nodes // [])|to_entries[]|[(.key+1),.value.id,.value.inbound.protocol,.value.inbound.port,.value.network,.value.enabled]|@tsv' "$STATE"
}
native_action() {
    local action=${1:-list} id=${2:-} candidate="$WORK/native-action.json" runtime="$WORK/native-action-xray.json" n old
    [[ $action != list ]] || { native_list; return; }
    if [[ -z $id ]]; then
        local row; local -a choices=()
        while IFS= read -r row; do choices+=("$(jq -r .id <<< "$row")|$(jq -r '"\(.id) / \(.inbound.protocol) / \(.inbound.port)"' <<< "$row")"); done < <(jq -c '.native_nodes // [] | .[]' "$STATE")
        ((${#choices[@]})) || die '暂无原生节点。'
        select_value id '选择原生节点（编号）' '' "${choices[@]}"
    elif [[ $id =~ ^[1-9][0-9]*$ ]]; then id=$(jq -r --argjson i "$id" '.native_nodes[$i-1].id // ""' "$STATE"); fi
    jq -e --arg id "$id" '.native_nodes[]|select(.id==$id)' "$STATE" >/dev/null || die '原生节点不存在。'
    if [[ $action == export ]]; then
        n=$(jq -c --arg id "$id" '.native_nodes[]|select(.id==$id)|.client' "$STATE")
        [[ $n != null ]] || die '导入节点无自动客户端模板；请按原入站协议配置客户端。'
        warn '下面的客户端JSON包含凭据；只交给可信客户端。支持该协议的Xray版本是必要条件。'
        jq -n --argjson out "$n" '{log:{loglevel:"warning"},inbounds:[{listen:"127.0.0.1",port:10808,protocol:"socks",settings:{auth:"noauth",udp:true}}],outbounds:[$out]}'
        return
    fi
    choice "$action" 'enable disable delete rename' || die 'node native list/enable/disable/delete/rename/export。'
    cp "$STATE" "$candidate"
    case "$action" in
        enable|disable) n=false; [[ $action != enable ]] || n=true
            jq --arg id "$id" --argjson e "$n" '(.native_nodes[]|select(.id==$id)).enabled=$e' "$STATE" > "$candidate";;
        delete) jq --arg id "$id" '.native_nodes |= map(select(.id!=$id))' "$STATE" > "$candidate";;
        rename) ask_valid n '新显示名称' "$id" valid_name
            jq --arg id "$id" --arg n "$n" '(.native_nodes[]|select(.id==$id)).id=$n' "$STATE" > "$candidate";;
    esac
    (STATE=$candidate; validate_state; render_xray "$runtime")
    xray_core_check "$runtime" || return 1
    confirm "对原生节点$id执行$action；只改显示名称不会改变其运行tag" || return 0
    begin_tx "native-$action"
    install -m 600 "$candidate" "$STATE"
    apply_config; commit_tx
    recovery_firewall check || true
}
node_add() {
    if [[ ${1:-} == yes ]]; then s1_base_node_add "$@"; return; fi
    local type
    select_value type '选择节点创建入口' legacy \
      'legacy|常用：VLESS REALITY/XHTTP/WS/TLS、VMess、Trojan、SS/SS2022' \
      'native|扩展：VLESS Encryption、Hysteria2、MASQUE、gRPC、HTTPUpgrade、SOCKS/HTTP' \
      'catalog|查看协议与核心要求（不修改）'
    case "$type" in legacy) s1_base_node_add;; native) native_add;; catalog) xray_catalog;; esac
}
node_list() {
    s1_base_node_list
    if jq -e '(.native_nodes // [])|length>0' "$STATE" >/dev/null; then
        printf '\n原生扩展节点（独立编号；用 node native 管理）：\n序号\t名称\t协议\t端口\t网络\t启用\n'; native_list
    fi
}
# This command deliberately separates catalog inspection from installation/latest lookups.
xray_release_info() {
    local meta="$WORK/xray-latest.json" ver
    ver=$(latest_release XTLS/Xray-core "$meta")
    jq -r '[.tag_name,.published_at,(.prerelease|tostring)]|@tsv' "$meta"
    info "官方latest解析为 $ver；未下载或替换正在运行的核心。"
}

# Additive menus: preserve all 1.7.x numbers; stage-1 pages are explicitly labelled.
s2_base_menu_catalog() {
    s1_base_menu_catalog
    cat <<'MENU'
main|18|双安装模式与共享组件（阶段1）|选择模式、复用组件、迁移及检查归属|共享操作影响其他网站；旧部署不会自动迁移|nav|menu:providers
main|19|Xray新协议与原生节点|扩展协议向导、编号管理和客户端JSON|必须由实际Xray核心校验；TLS/UDP需客户端支持|nav|menu:native
providers|1|安装模式与组件归属|查看路径、来源和托管范围|只读；不把外部组件冒认为本工具安装|read|provider-show
providers|2|选择共享模式（空部署）|空部署使用APT Nginx及共享ACME程序|已有节点或网站需走迁移，不能直接改标签|write|mode-select-shared
providers|3|选择独立模式（空部署）|沿用私有目录及服务|不接管外部Nginx|write|mode-select-isolated
providers|4|预览迁移到共享模式|显示影响和执行次序|只读，不重启服务|read|mode-plan-shared
providers|5|执行迁移到共享模式|保留Xray及网站资料，切换Nginx服务|先备份；短暂断连；APT安装不能靠快照降级|warn|mode-apply-shared
providers|6|预览迁移到独立模式|显示独立服务切换要求|只读；共享Nginx存在其他站点则不能切走|read|mode-plan-isolated
providers|7|执行迁移到独立模式|安装私有组件并切换服务|其他共享站点存在时拒绝；保留旧程序备份|warn|mode-apply-isolated
providers|8|仅移除VPSKit共享Nginx配置|保留共享程序、证书、节点和网站文件|VPSKit网站会停止；其他站点只经历reload|danger|provider-detach
providers|9|移除共享Nginx程序|通过APT移除；保留配置文件|必须先移除本工具片段；发现其他站点拒绝|danger|provider-remove-nginx
providers|10|移除共享ACME程序|只删除本工具安装的程序，不删账户|需确认其他程序不用；自动续期未迁移时拒绝|danger|provider-remove-acme
providers|11|查询Xray最新正式版本|仅查询官方GitHub Release信息|需联网；不下载、不升级、不重启|read|provider-latest
providers|0|返回上一级|不修改设置|已提交的设置保留|back|back
native|1|协议目录与核心版本|列出协议、传输和使用要求|只读；目录不等于端到端已验证|read|native-catalog
native|2|创建扩展协议节点|VLESS Encryption、Hysteria2、MASQUE等|编号选择；实际核心测试通过才保存|write|native-add
native|3|查看原生节点|列出端口、协议、启用状态|不打印凭据|read|native-list
native|4|启用原生节点|编号选择后启用|Xray运行配置变化会重启本实例|write|native-enable
native|5|停用原生节点|编号选择后停用|其他节点仍保留但可能因重启短暂断连|warn|native-disable
native|6|修改原生节点名称|只更改显示名称，保留内部tag|无实质配置变化不重启|write|native-rename
native|7|导出客户端JSON|编号选择并输出客户端配置|包含凭据；只提供给可信客户端|sensitive|native-export
native|8|删除原生节点|编号选择后删除|不可撤销前会创建快照；不关闭全局防火墙|danger|native-delete
native|0|返回上一级|不修改设置|已提交的设置保留|back|back
MENU
}
s2_base_menu_title() {
    case "$1" in providers) printf '双安装模式与组件归属 · 阶段1';; native) printf 'Xray扩展协议与原生节点';; *) s1_base_menu_title "$1";; esac
}
s2_base_menu_dispatch() {
    case "$1" in
        provider-show) menu_run components show;;
        provider-detach) menu_run components detach;;
        provider-remove-*) menu_run components remove "${1#provider-remove-}";;
        provider-latest) menu_run components latest-xray;;
        mode-select-*) menu_run mode select "${1#mode-select-}";;
        mode-plan-*) menu_run mode migrate "${1#mode-plan-}" --plan;;
        mode-apply-*) menu_run mode migrate "${1#mode-apply-}" --apply;;
        native-catalog) menu_run node protocols;; native-add) menu_run node native-add;;
        native-*) menu_run node native "${1#native-}";;
        *) s1_base_menu_dispatch "$1";;
    esac
}
panel_system_data() {
    panel_exec systemctl show "$NGINX_SERVICE" vpskit-xray.service vpskit-maintain.timer vpskit-maintain.service \
      -p Id -p LoadState -p ActiveState -p SubState -p UnitFileState -p MainPID -p Result
}
panel_service_block() {
    local id=$1; shift
    [[ $id != nginx.service ]] || id=vpskit-nginx.service
    s1_base_panel_service_block "$id" "$@"
}
s3_prev_panel_summary() {
    ui_note "安装模式：$MODE；Nginx服务：$NGINX_SERVICE；共享只管理专属片段。"
    s1_base_panel_summary "$@"
    if [[ -r $STATE ]] && command -v jq >/dev/null 2>&1; then
        local summary
        summary=$(jq -r '(.native_nodes // []) | "扩展原生节点：启用 \([.[]|select(.enabled)]|length) / 总数 \(length)（与旧节点分开管理）"' "$STATE" 2>/dev/null || true)
        [[ -z $summary ]] || ui_note "$summary"
    fi
    if [[ $MODE == shared ]]; then ui_note 'Worker/连接总预算属于系统全局；旧高级面板中的保存值不作为共享Nginx生效值。'; fi
}
panel_workers() {
    # Do not compare shared worker count against the PRIVATE saved default.
    local saved=${PANEL_RAW[cfg.workers]:-}
    [[ $MODE != shared ]] || PANEL_RAW[cfg.workers]=auto
    s1_base_panel_workers
    [[ $MODE != shared ]] || PANEL_RAW[cfg.workers]=$saved
}
s2_base_usage() {
    s1_base_usage "$@"
    cat <<'HELP'

2.0 阶段1新增命令：
  mode show                          查看模式与归属；未登记旧部署默认isolated
  mode select shared|isolated        仅空部署选择（不安装、不重启）
  mode migrate shared|isolated --plan|--apply
  components show                    查看组件登记
  components adopt-acme /path/acme.sh 显式复用外部程序；私有账户不混用
  components detach                  只移除本工具共享Nginx片段，保留数据/程序
  components remove nginx|acme        卸载共享程序，检查使用者、独立危险确认
  components latest-xray              查询官方最新正式版，不安装
  components repair-apt-policy        明确清理被中断安装留下的本工具临时策略
  install shared|isolated             新安装选择模式后继续原向导
  node protocols                     只读协议目录
  node native-add [encryption|hysteria|masque|grpc|httpupgrade|socks|http]
  node import /path/inbound.json [tcp|udp|tcp,udp]
  node native list|enable|disable|delete|rename|export [序号或名称]

共享：nginx -t / nginx -s reload / systemctl reload nginx。
没有nginx --reload命令；reload不是restart。未执行此机真实VPS验收。
共享全局并发需使用shared-global单独授权；共享原样强制恢复旧入口仍禁用。
阶段4卸载使用 uninstall wizard；配置故障仍使用recovery执行阶段2恢复。
HELP
}
stage1_guard() {
    local command=$1 action=${2:-}
    if [[ $MODE == shared ]]; then
        case "$command" in
            rebuild|rebuild-restore|recover|rollback)
                die '该命令属于旧私有Nginx原样恢复；共享模式禁止覆盖系统服务。使用同模式history restore或repair自动事务恢复。';;
            advanced)
                [[ $action != preflight ]] || die '共享模式使用nginx -t和系统服务验证，不再启动私有沙箱预检；运行vpskit doctor。';;
        esac
        [[ $command != repair || $action != --force ]] || die '共享模式仅支持repair验证事务恢复；强制跨模式恢复请先人工核对归属。'
    fi
}
s2_previous_history_restore() {
    local id=${1:-} scope=${2:-} from
    history_select id "$id"
    from=isolated
    [[ ! -f $ROOT/backup/history/$id/installation.json ]] || from=$(jq -r .mode "$ROOT/backup/history/$id/installation.json")
    [[ $from == "$MODE" ]] || die '快照安装模式不同；请先显式模式迁移，不允许靠状态快照切换系统服务。'
    s1_base_history_restore "$id" "$scope"
}

require_modern_xray() {
    local installed
    installed=$("$XRAY" version 2>/dev/null | sed -n 's/^Xray \([0-9][0-9.]*\).*/\1/p' | head -n1)
    [[ $installed =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die '无法可靠读取Xray版本；未猜测新字段能力。'
    dpkg --compare-versions "$installed" ge 26.10.31 || die "此原生模板要求Xray >=26.10.31，当前$installed。先显式update xray latest；不会静默升级。"
}

render_nginx() { s1_base_render_nginx "$@"; }

# Safe explicit cleanup after an interrupted package installation (never replaces
# an administrator's policy file, and does not start services or run APT).
repair_apt_policy() {
    local path=/usr/sbin/policy-rc.d expected actual
    [[ -e $path || -L $path ]] || { info '没有policy-rc.d残留。'; return; }
    [[ -f $path && ! -L $path && $(stat -c %u "$path") == 0 ]] || die 'policy-rc.d归属不明；未删除。'
    expected=$(printf '#!/bin/sh\n# VPSKIT_TEMP_APT_POLICY\nexit 101\n' | sha256sum | cut -d' ' -f1)
    actual=$(sha256sum "$path" | cut -d' ' -f1)
    [[ $actual == "$expected" ]] || die '这是外部或已修改的policy-rc.d，未删除。'
    need fuser
    if fuser /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1; then
        die '包管理器锁正在使用，稍后再清理。'
    fi
    confirm '删除可校验的VPSKit临时APT启动策略；仅在确认没有包安装进行中执行' || return 0
    [[ $(sha256sum "$path" | cut -d' ' -f1) == "$expected" ]] || die '策略文件期间改变；未删除。'
    rm -f -- "$path"
    ok '临时APT策略已删除；未启动或重启服务。'
}
latest_release() {
    fetch "https://api.github.com/repos/$1/releases/latest" "$2"
    jq -er 'select(.draft==false and .prerelease==false) | .tag_name | select(test("^[A-Za-z0-9._-]+$"))' "$2" || die '官方API没有返回可验证的正式发布；不静默回退旧版。'
}

s3_prev_performance_profile() {
    local SHARED_LOCAL_PROFILE=no
    [[ $MODE != shared ]] || SHARED_LOCAL_PROFILE=yes
    s1_base_performance_profile "$@"
}
advanced_defaults() {
    [[ $MODE != shared ]] || ui_note '共享模式只重置本项目保存的默认值；不修改系统nginx.conf/服务全局参数。'
    s1_base_advanced_defaults "$@"
}

paths_show() {
    s1_base_paths_show
    printf '\n组件登记：%s\n当前模式：%s\n实际Nginx程序：%s\n实际Nginx主配置：%s\n实际服务：%s\nACME程序：%s\n' \
      "$(install_record_path)" "$MODE" "$NGINX" "$NGINX_CONFIG" "$NGINX_SERVICE" "$ACME"
    if [[ $MODE == shared ]]; then
        printf '共享片段：%s\n' "$SHARED_INCLUDE"
        ui_note '上方旧版私有nginx路径仅用于兼容/回滚；共享运行以系统主配置及专属片段为准。'
    fi
}

runtime_fingerprint() {
    local component=$1 config=$2 base files digest p
    base=$(s1_base_runtime_fingerprint "$component" "$config") || return 1
    if [[ $component != xray ]]; then printf '%s\n' "$base"; return; fi
    # Imported native TLS nodes may not have a named .domain record. Include their
    # actual file paths too, so same-path certificate renewals cannot be missed.
    files=$(jq -r '(.native_nodes // [])[]|select(.enabled)|.inbound.streamSettings.tlsSettings.certificates[]? | .certificateFile,.keyFile | select(type=="string")' "$STATE" | sort -u) || return 1
    [[ -n $files ]] || { printf '%s\n' "$base"; return; }
    digest=$({
        jq -r .assets <<< "$base"
        while IFS= read -r p; do printf '%s\n' "$p"; runtime_hash_file "$p"; done <<< "$files"
    } | sha256sum | cut -d' ' -f1)
    jq -c --arg h "$digest" '.assets=$h' <<< "$base"
}



# -----------------------------------------------------------------------------
# Stage 2: staged include graph, atomic publication, scoped recovery, certificate
# lifecycle and explicit shared-global edits. No extra daemon, no global reset.
# -----------------------------------------------------------------------------
S2_SHADOW='' S2_SHADOW_MAIN='' S2_INPUT_MANIFEST=''
S2_MAIN_OVERRIDE='' S2_OWN_OVERRIDE='' S2_GRAPH_COUNT=0 S2_OWN_SEEN=0
S2_GRAPH_BYTES=0

declare -A S2_GRAPH_DEST=() S2_GRAPH_BUSY=()

# Tokenize Nginx directives WITHOUT interpreting values as shell. Byte offsets
# allow exact-range replacements and preserve all unrelated text/comments.
# Output: first-byte, last-byte, context, name, terminator, decoded arguments.
# This is a bounded structural scanner, not a substitute for nginx -t.
s2_nginx_tokens() {
    [[ -f $1 && $(stat -c %s "$1") -le 2097152 ]] || return 1
    LC_ALL=C awk '
      function fail(m){print "Nginx structural scan: "m > "/dev/stderr";bad=1;exit 2}
      function flush(){if(tok!=""||quoted){a[++n]=tok;tok="";quoted=0}}
      function emit(last,term, i,ctx){
        flush();if(n==0)return
        ctx="main";for(i=1;i<=depth;i++)ctx=ctx"/"stack[i]
        printf "%d\t%d\t%s\t%s\t%s",begin,last,ctx,a[1],term
        for(i=2;i<=n;i++){
          if(a[i]~/[\t\r\n]/)fail("control character in directive")
          printf "\t%s",a[i]
        }
        printf "\n"
        if(term=="{")stack[++depth]=a[1]
        for(i=1;i<=n;i++)delete a[i]
        n=0;begin=0
      }
      {s=s $0 "\n"}
      END{
        if(bad)exit 2
        depth=0;n=0;tok="";q="";esc=0;comment=0;begin=0
        for(p=1;p<=length(s);p++){
          c=substr(s,p,1)
          if(comment){if(c=="\n")comment=0;continue}
          if(esc){tok=tok c;esc=0;continue}
          if(c=="\\"){if(!begin)begin=p;esc=1;continue}
          if(q!=""){
            if(c==q){q="";quoted=1}else tok=tok c
            continue
          }
          if(c=="\""||c==sprintf("%c",39)){if(!begin)begin=p;q=c;quoted=1;continue}
          if(c=="#"){flush();comment=1;continue}
          if(c=="$"&&substr(s,p+1,1)=="{"){
            if(!begin)begin=p
            end=index(substr(s,p+2),"}");if(!end)fail("unclosed variable")
            tok=tok substr(s,p,end+2);p+=end+1;continue
          }
          if(c~/[ \t\r\n]/){flush();continue}
          if(c==";"||c=="{"){emit(p,c);continue}
          if(c=="}"){
            if(n||tok!="")fail("missing semicolon")
            if(depth<=0)fail("unbalanced closing brace")
            delete stack[depth--];begin=0;continue
          }
          if(!begin)begin=p
          tok=tok c
        }
        if(q!=""||esc||n||tok!=""||depth)fail("unclosed directive/block")
      }' "$1"
}

s2_file_stamp() {
    local path=$1 target
    if [[ -L $path ]]; then
        target=$(readlink -f -- "$path") || return 1
        [[ -f $target ]] || return 1
        printf 'link:%s:%s\n' "$target" "$(runtime_hash_file "$target")"
    elif [[ -f $path ]]; then runtime_hash_file "$path"
    elif [[ ! -e $path ]]; then printf 'absent\n'
    else return 1; fi
}
s2_include_matches() {
    # Nginx include globs are expanded in lexical order. Reject dynamic includes.
    local pattern=$1 p
    [[ $pattern != *'$'* && $pattern != *$'\n'* && $pattern != *$'\r'* && $pattern != *$'\t'* ]] || return 1
    local -a matches=()
    if [[ $pattern == *'*'* || $pattern == *'?'* || $pattern == *'['* ]]; then
        mapfile -t matches < <(compgen -G "$pattern" | LC_ALL=C sort || true)
    elif [[ -e $pattern || -L $pattern ]]; then matches=("$pattern")
    elif [[ $pattern != "$SHARED_INCLUDE" ]]; then
        warn "include文件不存在：$pattern"; return 1
    fi
    # The managed file may not exist yet on first installation.
    if [[ $SHARED_INCLUDE == $pattern ]]; then matches+=("$SHARED_INCLUDE"); fi
    if ((${#matches[@]})); then
        printf '%s\n' "${matches[@]}" | LC_ALL=C sort -u
    fi
}
s2_graph_record() {
    jq -nc --arg k "$1" --arg p "$2" --arg h "$3" '{kind:$k,path:$p,stamp:$h}' >> "$S2_INPUT_MANIFEST"
}
s2_rewrite_ranges() {
    local file=$1 map=$2 out=$3
    LC_ALL=C awk -v map="$map" -v file_size="$(stat -c %s "$file")" '
      BEGIN{while((getline row < map)>0){split(row,a,"\t");b[++n]=a[1]+0;e[n]=a[2]+0;r[n]=substr(row,length(a[1])+length(a[2])+3)};close(map)}
      {s=s $0 "\n"}
      END{s=substr(s,1,file_size);pos=1;for(i=1;i<=n;i++){if(b[i]<pos||e[i]<b[i]||e[i]>length(s))exit 2;printf "%s%s",substr(s,pos,b[i]-pos),r[i];pos=e[i]+1}printf "%s",substr(s,pos)}' "$file" > "$out"
}
s2_quote_nginx() {
    local value=$1
    value=${value//\\/\\\\}; value=${value//\"/\\\"}
    printf '"%s"' "$value"
}
s2_graph_clone() {
    local original=$1 depth=${2:-0} source dest key rows map first last context name end argument extra pattern match replacement stamp
    ((depth<48 && S2_GRAPH_COUNT<512 && S2_GRAPH_BYTES<16777216)) || { warn 'Nginx include图超过安全上限。'; return 1; }
    [[ $original == /* && $original != *$'\n'* && $original != *$'\t'* ]] || return 1
    if [[ ${S2_GRAPH_BUSY[$original]:-} == yes ]]; then warn "include循环：$original"; return 1; fi
    if [[ -n ${S2_GRAPH_DEST[$original]:-} ]]; then return 0; fi
    source=$original
    if [[ $original == "$SHARED_INCLUDE" ]]; then source=$S2_OWN_OVERRIDE; S2_OWN_SEEN=$((S2_OWN_SEEN+1)); fi
    if [[ $original == "$SHARED_MAIN" && -n $S2_MAIN_OVERRIDE ]]; then source=$S2_MAIN_OVERRIDE; fi
    [[ -f $source ]] || { warn "无法读取配置：$original"; return 1; }
    [[ $(stat -c %s "$source") -le 2097152 ]] || return 1
    stamp=$(s2_file_stamp "$original") || return 1
    s2_graph_record file "$original" "$stamp" || return 1
    S2_GRAPH_COUNT=$((S2_GRAPH_COUNT+1)); S2_GRAPH_BYTES=$((S2_GRAPH_BYTES+$(stat -c %s "$source")))
    key=$(printf '%s' "$original" | sha256sum | cut -d' ' -f1)
    dest="$S2_SHADOW/$key.conf"; rows="$S2_SHADOW/$key.tokens"; map="$S2_SHADOW/$key.map"
    S2_GRAPH_DEST[$original]=$dest; S2_GRAPH_BUSY[$original]=yes
    s2_nginx_tokens "$source" > "$rows" || return 1
    : > "$map"
    while IFS=$'\t' read -r first last context name end argument extra; do
        if [[ $name != include ]]; then
            case "$name" in
                ssl_certificate|ssl_certificate_key|ssl_client_certificate|ssl_trusted_certificate|ssl_crl|ssl_dhparam|ssl_password_file|ssl_session_ticket_key|auth_basic_user_file|proxy_ssl_certificate|proxy_ssl_certificate_key|proxy_ssl_trusted_certificate|proxy_ssl_crl)
                    if [[ -n $argument && $argument != /* && $argument != data:* && $argument != engine:* && $argument != off && $argument != none ]]; then
                        [[ -z $extra && $argument != *'$'* ]] || { warn '相对/动态安全文件引用无法保持语义，请改绝对路径。'; return 1; }
                        printf '%s\t%s\t%s %s;\n' "$first" "$last" "$name" "$(s2_quote_nginx "${SHARED_MAIN%/*}/$argument")" >> "$map"
                    fi;;
            esac
            continue
        fi
        [[ $end == ';' && -n $argument && -z $extra ]] || { warn '无法可靠解析include；请改为单个静态路径。'; return 1; }
        if [[ $argument == /* ]]; then pattern=$argument; else pattern="${SHARED_MAIN%/*}/$argument"; fi
        [[ $pattern != *'/../'* && $pattern != *'/./'* ]] || { warn 'include路径请使用规范绝对路径（不含../或./）。'; return 1; }
        local matches_file="$S2_SHADOW/$key.$first.matches"
        s2_include_matches "$pattern" > "$matches_file" || return 1
        s2_graph_record glob "$pattern" "$(runtime_hash_file "$matches_file")" || return 1
        replacement=''
        while IFS= read -r match; do
            [[ -n $match ]] || continue
            s2_graph_clone "$match" "$((depth+1))" || return 1
            replacement+="include $(s2_quote_nginx "${S2_GRAPH_DEST[$match]}"); "
        done < "$matches_file"
        # Empty glob is valid in Nginx. Preserve a harmless comment/newline-free gap.
        printf '%s\t%s\t%s\n' "$first" "$last" "$replacement" >> "$map"
    done < "$rows"
    s2_rewrite_ranges "$source" "$map" "$dest" || return 1
    S2_GRAPH_BUSY[$original]=no
}
s2_shared_validate() {
    local candidate=$1 main_override=${2:-} token
    S2_MAIN_OVERRIDE=$main_override; S2_OWN_OVERRIDE=$candidate
    S2_SHADOW=$(mktemp -d "$WORK/nginx-shadow.XXXXXXXX") || return 1
    S2_INPUT_MANIFEST="$S2_SHADOW/inputs.jsonl"; : > "$S2_INPUT_MANIFEST"
    S2_GRAPH_DEST=(); S2_GRAPH_BUSY=(); S2_GRAPH_COUNT=0; S2_GRAPH_BYTES=0; S2_OWN_SEEN=0
    s2_graph_clone "$SHARED_MAIN" || return 1
    ((S2_OWN_SEEN>0)) || { warn '系统配置没有include本项目片段；未自动插入全局include。'; return 1; }
    S2_SHADOW_MAIN=${S2_GRAPH_DEST[$SHARED_MAIN]}
    # Kept in a private work directory; -T output can contain private settings.
    if ! "$NGINX" -T -c "$S2_SHADOW_MAIN" > "$S2_SHADOW/dump" 2> "$S2_SHADOW/errors"; then
        tail -n 12 "$S2_SHADOW/errors" >&2; return 1
    fi
    if grep -Eq 'conflicting server name|duplicate' "$S2_SHADOW/errors"; then
        tail -n 12 "$S2_SHADOW/errors" >&2; return 1
    fi
    s2_inputs_unchanged
}
s2_inputs_unchanged() {
    local row kind path before actual scratch="$WORK/input.matches"
    [[ -s $S2_INPUT_MANIFEST ]] || return 1
    while IFS= read -r row; do
        kind=$(jq -r .kind <<< "$row"); path=$(jq -r .path <<< "$row"); before=$(jq -r .stamp <<< "$row")
        case "$kind" in
            file) actual=$(s2_file_stamp "$path") || return 1;;
            glob) s2_include_matches "$path" > "$scratch" || return 1; actual=$(runtime_hash_file "$scratch");;
            *) return 1;;
        esac
        [[ $actual == "$before" ]] || { warn "验证期间配置/include集合发生外部变化：$path；未继续发布。"; return 1; }
    done < "$S2_INPUT_MANIFEST"
}

# Always replace from a same-directory temporary file. Never truncate a live
# config before validation. This gives atomic rename, not a multi-file ACID DB.
atomic_install() {
    local mode=$1 source=$2 target=$3 tmp parent=${3%/*} owner=0 group=0
    [[ -f $source && ! -L $source && -d $parent && ! -L $target && ! -L $parent ]] || return 1
    if [[ -f $target ]]; then read -r owner group < <(stat -c '%u %g' "$target"); fi
    tmp=$(mktemp "$parent/.vpskit-stage2.XXXXXXXX") || return 1
    if ! install -m "$mode" -o "$owner" -g "$group" "$source" "$tmp" || ! mv -fT -- "$tmp" "$target"; then rm -f -- "$tmp"; return 1; fi
}

# Intent is persisted BEFORE a publish. Recovery accepts only the old or intended
# digest; any third value is an external edit, not permission to force overwrite.
s2_journal_begin() {
    local dir="$ROOT/backup/transaction/stage2" mode
    ((TX==1)) && [[ -f $ROOT/backup/transaction/ready ]] || return 1
    [[ ! -d $dir ]] || return 0
    mkdir -m 700 "$dir" "$dir/files" "$dir/services" || return 1
    mode=$MODE
    printf '%s\n' "$mode" > "$dir/mode"
    : > "$dir/intents.jsonl"
}
s2_publish() {
    local source=$1 target=$2 mode=${3:-600} dir="$ROOT/backup/transaction/stage2" key old new
    s2_journal_begin || return 1
    [[ $target == "$ROOT/"* || $target == "$SHARED_INCLUDE" || $target == "$SHARED_MAIN" || $target == "$SYSTEMD/vpskit-"* ]] || return 1
    [[ ! -L $target ]] || return 1
    if cmp -s "$source" "$target"; then return 0; fi
    old=$(s2_file_stamp "$target") || return 1; new=$(runtime_hash_file "$source") || return 1
    key=$(printf '%s' "$target" | sha256sum | cut -d' ' -f1)
    if [[ ! -e $dir/files/$key.absent && ! -e $dir/files/$key.before ]]; then
        if [[ -f $target ]]; then cp -a -- "$target" "$dir/files/$key.before" || return 1
        else : > "$dir/files/$key.absent"; fi
    fi
    jq -nc --arg p "$target" --arg k "$key" --arg b "$old" --arg a "$new" --arg m "$mode" \
      '{path:$p,key:$k,before:$b,after:$a,mode:$m}' >> "$dir/intents.jsonl" || return 1
    [[ $(s2_file_stamp "$target") == "$old" ]] || return 1
    printf 'runtime\n' > "$ROOT/backup/transaction/phase"
    atomic_install "$mode" "$source" "$target"
}
s2_service_mark() {
    local service=$1 action=$2 dir="$ROOT/backup/transaction/stage2" before='' active=no enabled=no
    s2_journal_begin || return 1
    choice "$service" 'nginx.service vpskit-nginx.service vpskit-xray.service vpskit-maintain.timer' || return 1
    [[ ! -f $dir/services/$service.json ]] || return 0
    if systemctl is-active --quiet "$service"; then active=yes; fi
    if systemctl is-enabled --quiet "$service"; then enabled=yes; fi
    before=$(systemctl show -p MainPID --value "$service" 2>/dev/null || true)
    jq -n --arg s "$service" --arg a "$action" --arg p "$before" --arg active "$active" --arg enabled "$enabled" \
      '{service:$s,action:$a,before_pid:$p,active:$active,enabled:$enabled}' > "$dir/services/$service.json"
}
s2_journal_guard() {
    local dir=$1 row p key before after actual baseline
    [[ -f $dir/stage2/intents.jsonl ]] || return 0
    # Last expected content per path; pre-publish failure can still have old bytes.
    while IFS= read -r row; do
        p=$(jq -r .path <<< "$row"); key=$(jq -r .key <<< "$row")
        before=$(jq -r .before <<< "$row"); after=$(jq -r .after <<< "$row")
        [[ $p == "$ROOT/"* || $p == "$SHARED_INCLUDE" || $p == "$SHARED_MAIN" || $p == "$SYSTEMD/vpskit-"* ]] || return 1
        [[ $key =~ ^[a-f0-9]{64}$ && $key == "$(printf '%s' "$p" | sha256sum | cut -d' ' -f1)" && ! -L $p ]] || return 1
        actual=$(s2_file_stamp "$p") || return 1
        baseline=absent
        [[ ! -f $dir/stage2/files/$key.before ]] || baseline=$(runtime_hash_file "$dir/stage2/files/$key.before")
        [[ $actual == "$before" || $actual == "$after" || $actual == "$baseline" ]] || { warn "回滚冲突：$p 在发布后被外部改写；保留事务，不覆盖外部内容。"; return 1; }
    done < <(jq -sc 'group_by(.path)[] | .[-1]' "$dir/stage2/intents.jsonl")
}
s2_restore_files() {
    local dir=$1 row p key mode
    s2_journal_guard "$dir" || return 1
    while IFS= read -r row; do
        p=$(jq -r .path <<< "$row"); key=$(jq -r .key <<< "$row"); mode=$(jq -r .mode <<< "$row")
        if [[ -f $dir/stage2/files/$key.before ]]; then
            mode=$(stat -c %a "$dir/stage2/files/$key.before")
            atomic_install "$mode" "$dir/stage2/files/$key.before" "$p" || return 1
            chown --reference="$dir/stage2/files/$key.before" "$p" || return 1
        elif [[ -f $dir/stage2/files/$key.absent ]]; then rm -f -- "$p" || return 1
        else return 1; fi
    done < <(jq -sc 'group_by(.path)[] | .[0]' "$dir/stage2/intents.jsonl")
}
s2_restore_project() {
    local dir=$1 service row active enabled p old='' rc=0 action='' ngservice
    (snapshot_verify "$dir/snapshot") || return 1
    s2_journal_guard "$dir" || return 1
    if ! jq -se --arg p "$ROOT/config/xray.json" 'any(.[];.path==$p)' "$dir/stage2/intents.jsonl" >/dev/null; then
        if [[ -f $dir/snapshot/config/xray.json ]] && ! cmp -s "$dir/snapshot/config/xray.json" "$ROOT/config/xray.json"; then
            warn '未参与事务的Xray配置被外部修改；停止自动恢复，不覆盖它。'; return 1
        fi
    fi
    # Only this project's private state is restored. The rest of /etc/nginx is
    # neither copied from snapshots nor replaced by a historical directory tree.
    s2_restore_files "$dir" || return 1
    for p in config certs; do
        [[ -d $dir/snapshot/$p && ! -L $ROOT/$p && ! -L $dir/snapshot/$p ]] || return 1
        rm -rf -- "$ROOT/$p"; cp -a "$dir/snapshot/$p" "$ROOT/$p" || return 1
    done
    # ACME may have successfully obtained a certificate before activation failed.
    # Preserve its latest account/order state; old pending deployment files are in
    # the certificate snapshot. Do not revoke/reissue or roll CA state backwards.
    atomic_install 600 "$dir/snapshot/state.json" "$STATE" || return 1
    if [[ -f $dir/snapshot/installation.json ]]; then atomic_install 600 "$dir/snapshot/installation.json" "$(install_record_path)" || return 1; fi
    [[ ! -f $dir/snapshot/permissions.nul ]] || permissions_restore "$dir/snapshot/permissions.nul" || return 1
    mode_load || return 1
    if jq -se --arg prefix "$SYSTEMD/" 'any(.[];.path|startswith($prefix))' "$dir/stage2/intents.jsonl" >/dev/null; then
        systemctl daemon-reload || return 1
    fi
    if [[ -f $dir/stage2/services/vpskit-xray.service.json ]]; then
        row=$(cat "$dir/stage2/services/vpskit-xray.service.json"); active=$(jq -r .active <<< "$row")
        if [[ $active == yes ]]; then
            "$XRAY" run -test -config "$ROOT/config/xray.json" || return 1
            systemctl daemon-reload || return 1
            systemctl restart vpskit-xray.service || return 1
            xray_wait_listeners || return 1
        else systemctl stop vpskit-xray.service || return 1; fi
    fi
    ngservice=nginx.service
    [[ $MODE == shared ]] || ngservice=vpskit-nginx.service
    if [[ $MODE == isolated && -f $dir/stage2/services/$ngservice.json ]]; then
        row=$(cat "$dir/stage2/services/$ngservice.json"); active=$(jq -r .active <<< "$row"); action=$(jq -r .action <<< "$row")
        nginx_cmd -t -p "$ROOT/" -c "$ROOT/config/nginx.conf" || return 1
        if [[ $active == yes ]]; then
            [[ $(nginx_conf_value user "$ROOT/config/nginx.conf" || true) != root ]] || warn '正在恢复本事务之前的历史root Worker；不是降低新配置的校验标准。'
            old=''
            if [[ $action == reload ]] && systemctl is-active --quiet "$ngservice"; then
                old=$(worker_generation "$(nginx_master_pid)")
                systemctl reload "$ngservice" || return 1
            else systemctl restart "$ngservice" || return 1; fi
            verify_nginx_runtime "$old" '' "$ROOT/config/nginx.conf" yes || return 1
        else systemctl stop "$ngservice" || return 1; fi
    fi
    if [[ $MODE == shared && -f $dir/stage2/services/nginx.service.json ]]; then
        "$NGINX" -t -c "$SHARED_MAIN" || { warn '外部共享配置也可能有错；已恢复本项目资料，未强行重启共享Nginx。'; return 1; }
        row=$(cat "$dir/stage2/services/nginx.service.json"); active=$(jq -r .active <<< "$row")
        if [[ $active == yes ]]; then
            if systemctl is-active --quiet nginx.service; then
                old=$(worker_generation "$(nginx_master_pid)")
                systemctl reload nginx.service || return 1
            else systemctl start nginx.service || return 1; fi
            shared_verify_runtime "$old" || return 1
        else
            # The service was stopped before our start attempt; external sites may
            # have appeared. Do not automatically stop a new external workload.
            shared_external_sites_check || { warn '发现外部站点，保留共享服务运行，需人工确认原停止状态。'; return 1; }
            systemctl stop nginx.service || return 1
        fi
    fi
    if [[ -f $dir/stage2/services/vpskit-maintain.timer.json ]]; then
        active=$(jq -r .active "$dir/stage2/services/vpskit-maintain.timer.json")
        if [[ $active == yes ]]; then systemctl restart vpskit-maintain.timer || return 1
        else systemctl stop vpskit-maintain.timer || return 1; fi
    fi
    for p in "$dir/stage2/services/"*.json; do
        [[ -f $p ]] || continue
        row=$(cat "$p"); service=$(jq -r .service <<< "$row"); enabled=$(jq -r .enabled <<< "$row")
        if [[ $enabled == yes ]]; then systemctl enable "$service" >/dev/null || return 1
        else systemctl disable "$service" >/dev/null || return 1; fi
    done
    ok '已恢复本事务的项目配置；未改外部站点，未重启未参与本事务的Xray。'
}
restore_transaction() {
    local dir=$1 how=${2:-normal} before=isolated
    if [[ -f $dir/snapshot/installation.json ]]; then before=$(jq -r .mode "$dir/snapshot/installation.json"); fi
    if [[ -d $dir/stage2 ]]; then
        s2_journal_guard "$dir" || return 1
        if [[ $before == "$MODE" && ! -d $dir/programs ]]; then
            s2_restore_project "$dir"; return
        fi
    fi
    s2_base_restore_transaction "$@"
}

s2_shared_prepare() {
    local scope=${1:-all} force=${2:-none} unit base="$ROOT/config" oldng='{}' oldx='{}' certs beforecerts
    RUNTIME_SCOPE=$scope; RUNTIME_UNITS=()
    RUNTIME_NG=skip; RUNTIME_X=skip; RUNTIME_NG_REASON='配置/证书/程序无变化'; RUNTIME_X_REASON='未涉及Xray或运行内容无变化'
    RUNTIME_NG_HASH='{}'; RUNTIME_X_HASH='{}'
    render_units "$WORK/shared-units"
    for unit in "${UNITS[@]}"; do
        [[ $scope != web || $unit != vpskit-xray.service ]] || continue
        if [[ -e $SYSTEMD/$unit ]]; then
            [[ ! -L $SYSTEMD/$unit ]] && grep -Fxq '# VPSKIT_OWNED' "$SYSTEMD/$unit" || { warn "外部同名服务：$unit"; return 1; }
        fi
        cmp -s "$WORK/shared-units/$unit" "$SYSTEMD/$unit" || RUNTIME_UNITS+=("$unit")
    done
    if [[ $(get '.components.nginx // false') == true ]]; then
        render_shared_nginx "$WORK/shared-next.conf"
        RUNTIME_NG_HASH=$(runtime_fingerprint nginx "$WORK/shared-next.conf") || return 1
        certs=$(jq -r .assets <<< "$RUNTIME_NG_HASH")
        beforecerts=$(jq -r '.owned_files.certificates_sha256 // ""' "$INSTALL_RECORD")
        oldng=$(jq -c '.components.nginx.applied // {}' "$INSTALL_RECORD")
        if ! cmp -s "$WORK/shared-next.conf" "$SHARED_INCLUDE"; then RUNTIME_NG=reload; RUNTIME_NG_REASON='本项目片段变化'; fi
        if [[ $certs != "$beforecerts" ]]; then RUNTIME_NG=reload; RUNTIME_NG_REASON='证书/附属资料变化'; fi
        if [[ $(jq -r '.binary // ""' <<< "$oldng") != "" && $(jq -r .binary <<< "$oldng") != "$(jq -r .binary <<< "$RUNTIME_NG_HASH")" ]]; then
            RUNTIME_NG=restart; RUNTIME_NG_REASON='系统Nginx二进制变化（全部共享站点受影响）'
        fi
        [[ $force != nginx ]] || { RUNTIME_NG=restart; RUNTIME_NG_REASON='明确请求组件更新后的重启'; }
        if ! systemctl is-active --quiet nginx.service; then RUNTIME_NG=start; RUNTIME_NG_REASON='系统Nginx尚未运行'; fi
    fi
    if [[ $scope == all && $(get '.components.xray // false') == true ]]; then
        render_xray "$WORK/xray.next.json"
        RUNTIME_X_HASH=$(runtime_fingerprint xray "$WORK/xray.next.json") || return 1
        oldx=$(jq -c '.components.xray.applied // {}' "$INSTALL_RECORD")
        # A web-only operation or first shared attach must not rewrite Xray.
        if ! json_equal "$WORK/xray.next.json" "$ROOT/config/xray.json"; then RUNTIME_X=restart; RUNTIME_X_REASON='Xray运行配置变化'; fi
        if [[ $oldx != '{}' && $(jq -cS . <<< "$oldx") != "$(jq -cS . <<< "$RUNTIME_X_HASH")" ]]; then RUNTIME_X=restart; RUNTIME_X_REASON='Xray程序/证书内容变化'; fi
        if [[ $oldx == '{}' ]] && s2_xray_certificate_changed "$WORK/xray.next.json"; then
            RUNTIME_X=restart; RUNTIME_X_REASON='当前事务更换了Xray实际引用的证书（兼容尚无加载指纹的旧部署）'
        fi
        for unit in "${RUNTIME_UNITS[@]}"; do [[ $unit != vpskit-xray.service ]] || { RUNTIME_X=restart; RUNTIME_X_REASON='Xray服务定义变化'; }; done
        [[ $force != xray ]] || { RUNTIME_X=restart; RUNTIME_X_REASON='明确升级Xray'; }
        if (( $(jq '.inbounds|length' "$WORK/xray.next.json") == 0 )); then
            RUNTIME_X=skip
            if systemctl is-active --quiet vpskit-xray.service; then RUNTIME_X=stop; RUNTIME_X_REASON='没有启用入口'; fi
        elif ! systemctl is-active --quiet vpskit-xray.service; then RUNTIME_X=start; RUNTIME_X_REASON='Xray未运行'; fi
    elif [[ $scope == all ]] && systemctl is-active --quiet vpskit-xray.service; then RUNTIME_X=stop; RUNTIME_X_REASON='本项目已停用Xray组件'; fi
}
shared_plan() { validate_state; s2_shared_prepare all none || return 1; ui_title '共享模式差异计划（尚未发布）'; runtime_print_plan; }
shared_apply() {
    local scope=${1:-all} force=${2:-none} unit old='' before after need_permissions=no reason timer_changed=no
    ((TX==1)) || die '共享应用必须位于事务中。'
    s2_journal_begin
    migrate_state; validate_state; shared_guard_file; check_listener_ports
    s2_shared_prepare "$scope" "$force" || die '候选计划失败。'
    runtime_print_plan
    reason=$(jq -r '.reason // "apply"' "$ROOT/backup/transaction/snapshot/meta.json")
    case "$reason" in site:*|restore:*|mode-migrate:*|component:nginx) need_permissions=yes;; esac
    case "$RUNTIME_NG" in start|restart) need_permissions=yes;; esac
    case "$RUNTIME_X" in start|restart) "$XRAY" run -test -config "$WORK/xray.next.json";; esac
    if [[ $(get '.components.nginx // false') == true ]]; then
        if [[ $RUNTIME_NG != skip || $need_permissions == yes ]]; then
            [[ $need_permissions != yes ]] || worker_permissions "$(resolve_worker)"
            s2_shared_validate "$WORK/shared-next.conf" || die '候选Nginx含外部include的完整检查失败；未发布片段、未切换服务。'
        fi
    fi
    ensure_manager_installed
    s2_journal_begin
    if [[ $(get '.components.nginx // false') == true && $RUNTIME_NG != skip ]]; then
        s2_inputs_unchanged || die '检查后外部配置变化；取消提交。'
        shared_guard_file
        s2_publish "$WORK/shared-next.conf" "$SHARED_INCLUDE" 600 || die '原子发布片段失败。'
        shared_syntax || die '发布后再次检查失败；将只恢复本项目片段。'
    fi
    for unit in "${RUNTIME_UNITS[@]}"; do
        s2_publish "$WORK/shared-units/$unit" "$SYSTEMD/$unit" 644 || die '发布服务定义失败。'
        [[ $unit != vpskit-maintain.timer ]] || timer_changed=yes
    done
    ((${#RUNTIME_UNITS[@]}==0)) || systemctl daemon-reload
    if [[ $scope == all && -f $WORK/xray.next.json ]]; then s2_publish "$WORK/xray.next.json" "$ROOT/config/xray.json" 600 || die '发布Xray配置失败。'; fi
    if [[ $RUNTIME_X != skip ]]; then
        s2_service_mark vpskit-xray.service "$RUNTIME_X"
        before=$(systemctl show -p MainPID --value vpskit-xray.service 2>/dev/null || true)
        printf 'runtime\n' > "$ROOT/backup/transaction/phase"
        if [[ $RUNTIME_X == stop ]]; then systemctl disable --now vpskit-xray.service
        else
            s3_auto_enable vpskit-xray.service >/dev/null
            systemctl "$RUNTIME_X" vpskit-xray.service || die 'Xray服务动作失败；按事务恢复。'
            xray_wait_listeners || die 'Xray后端未就绪，未重载Nginx。'
        fi
        after=$(systemctl show -p MainPID --value vpskit-xray.service 2>/dev/null || true)
        runtime_record xray "$RUNTIME_X" "$RUNTIME_X_REASON" "$before" "$after" || true
    fi
    if [[ $RUNTIME_NG != skip ]]; then
        s2_service_mark nginx.service "$RUNTIME_NG"
        if [[ ${MIGRATING_TO_SHARED:-no} == yes ]]; then systemctl disable --now vpskit-nginx.service; fi
        before=$(systemctl show -p MainPID --value nginx.service 2>/dev/null || true)
        [[ $RUNTIME_NG != reload ]] || old=$(worker_generation "$before")
        printf 'runtime\n' > "$ROOT/backup/transaction/phase"
        [[ $RUNTIME_NG != start ]] || s3_auto_enable nginx.service >/dev/null
        systemctl "$RUNTIME_NG" nginx.service || die '共享Nginx服务动作失败；按事务恢复。'
        shared_verify_runtime "$old" || die '共享Nginx未观察到新Worker，尝试恢复本次变更。'
        after=$(systemctl show -p MainPID --value nginx.service 2>/dev/null || true)
        runtime_record nginx "$RUNTIME_NG" "$RUNTIME_NG_REASON" "$before" "$after" || true
    fi
    if [[ $(get '.components.nginx // false') == true ]]; then
        shared_record_hash
        provider_record_update --argjson f "$RUNTIME_NG_HASH" '.components.nginx.applied=$f | .owned_files.certificates_sha256=$f.assets'
    fi
    if [[ $scope == all && -f $WORK/xray.next.json ]]; then provider_record_update --argjson f "$RUNTIME_X_HASH" '.components.xray.applied=$f'; fi
    s3_timer_reconcile "$timer_changed" || die '维护定时器处理失败。'
    ok '按差异应用完成；外部配置未覆盖。无差异的组件未重载/重启。'
}

config_check() {
    validate_state
    if [[ $(get '.components.xray // false') == true ]]; then
        render_xray "$WORK/check-xray.json"; "$XRAY" run -test -config "$WORK/check-xray.json" || return 1
    fi
    if [[ $(get '.components.nginx // false') == true ]]; then
        if [[ $MODE == shared ]]; then
            shared_guard_file; render_shared_nginx "$WORK/check-shared.conf"
            s2_shared_validate "$WORK/check-shared.conf" || return 1
        else
            render_nginx "$WORK/check-nginx.conf"
            nginx_cmd -t -p "$ROOT/" -c "$WORK/check-nginx.conf" || return 1
        fi
    fi
    ok '候选生成与语法检查通过；未保存状态/发布配置/重载服务。语法检查不等于运行或公网验证。'
}
config_diff() {
    runtime_plan_command
    local target candidate
    if [[ $MODE == shared ]]; then target=$SHARED_INCLUDE; candidate="$WORK/shared-next.conf"
    else target="$ROOT/config/nginx.conf"; candidate="$WORK/nginx.next.conf"; fi
    printf '\n脱敏文件差异摘要（不显示UUID/密钥/URL/Token）：\n'
    if [[ -f $candidate ]]; then printf '  Nginx：当前SHA256=%s\n          候选SHA256=%s\n' "$(runtime_hash_file "$target")" "$(runtime_hash_file "$candidate")"; fi
    candidate="$WORK/xray.next.json"
    if [[ -f $candidate ]]; then
        local f
        for f in "$ROOT/config/xray.json" "$candidate"; do
            if [[ -f $f ]]; then jq -S '[.inbounds[]|{protocol,listen,port,network:(.streamSettings.network // "tcp")}] | sort_by(.port,.protocol)' "$f"
            else printf '[]\n'; fi
        done | awk '{print "  "$0}'
        ui_note '上方依次为当前/候选的协议监听摘要；凭据变化仅体现在计划和内容摘要中，不打印凭据。'
    fi
}

# Certificates: immutable revisions + atomic current pointer. Never prune the
# old revision before the service has accepted a new pair. Pending != deployed.
s2_certificate_validate() {
    local domain=$1 cert=$2 key=$3 min=${4:-86400} a b from now
    valid_domain "$domain" && number "$min" 0 2592000 || return 1
    [[ -f $cert && -s $cert && ! -L $cert && -f $key && -s $key && ! -L $key ]] || return 1
    openssl x509 -in "$cert" -noout -checkend "$min" >/dev/null || { warn '证书有效期不足。'; return 1; }
    openssl x509 -in "$cert" -noout -checkhost "$domain" >/dev/null || { warn '证书域名不匹配。'; return 1; }
    from=$(openssl x509 -in "$cert" -noout -startdate) || return 1
    from=$(date -u -d "${from#notBefore=}" +%s) || return 1; now=$(date +%s)
    ((from<=now+300)) || { warn '证书尚未生效（或本机时钟异常）。'; return 1; }
    openssl pkey -in "$key" -passin pass: -check -noout >/dev/null 2>&1 || { warn '私钥无效或仍加密，拒绝无人值守部署。'; return 1; }
    a=$(openssl x509 -in "$cert" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum) || return 1
    b=$(openssl pkey -in "$key" -passin pass: -pubout -outform DER | sha256sum) || return 1
    [[ $a == "$b" ]] || { warn '证书与私钥不匹配。'; return 1; }
    openssl crl2pkcs7 -nocrl -certfile "$cert" -outform DER >/dev/null 2>&1 || { warn '证书链PEM格式无效。'; return 1; }
}
deploy_certificate() {
    local domain=$1 base="$ROOT/certs/$1" rev cert key current old
    ((TX==1)) || die '证书发布必须处于事务中。'
    cert="$base/pending/fullchain.pem"; key="$base/pending/key.pem"
    s2_certificate_validate "$domain" "$cert" "$key" || die '待部署证书检查失败，未切换证书引用。'
    [[ ! -L $base && ! -L $base/pending ]] || die '证书目录不允许为链接。'
    if [[ -L $base/current ]]; then
        current=$(realpath -e "$base/current") || die '当前证书链接失效。'
        [[ $current == "$base/rev-"* && $current != *'/../'* ]] || die '当前证书链接越界。'
    fi
    if cmp -s "$cert" "$base/current/fullchain.pem" && cmp -s "$key" "$base/current/key.pem"; then info "证书内容未变：$domain；跳过版本创建。"; return; fi
    rev="rev-$(date +%s)-$(randhex 4)"; mkdir -m 700 "$base/$rev"
    install -m 600 "$cert" "$base/$rev/fullchain.pem"; install -m 600 "$key" "$base/$rev/key.pem"
    # First import from a legacy real current directory: preserve it as a revision.
    if [[ -d $base/current && ! -L $base/current ]]; then
        old="rev-legacy-$(date +%s)-$(randhex 4)"; mv "$base/current" "$base/$old"
    fi
    [[ ! -e $base/current.next && ! -L $base/current.next ]] || die '存在待处理证书指针，请先恢复事务。'
    ln -s "$rev" "$base/current.next"; mv -Tf "$base/current.next" "$base/current"
    json_update --arg d "$domain" '(.sites[]|select(.domain==$d)) |= (. + {issued:true,cert_settings_pending:false})'
    info "证书新版本已准备：$domain；旧版本保留，尚需服务验证。"
}
cert_renew() {
    component_ready acme || return 0
    local domain changed=no rc=0 failure=0 source
    local -a domains=()
    mapfile -t domains < <(jq -r '.sites[]|select(.issued and (.certificate_source // "acme")!="manual")|.domain' "$STATE")
    ((${#domains[@]})) || { info '没有由本项目自动续期的证书。'; return 0; }
    if component_ready nginx; then acme_web_permissions; fi
    # Renew only registered automatic domains. --renew respects the ACME due date
    # unless --force is supplied (we do not supply it). Manual/imported certificates
    # and orphan account entries are not accidentally renewed by a global --cron.
    for domain in "${domains[@]}"; do
        rc=0; acme_run --renew -d "$domain" --ecc || rc=$?
        if ((rc!=0 && rc!=2)); then warn "$domain ACME返回$rc；仍检查已有待部署结果。"; failure=1; fi
        source="$ROOT/certs/$domain/pending"
        [[ -s $source/fullchain.pem && -s $source/key.pem ]] || continue
        if cmp -s "$source/fullchain.pem" "$ROOT/certs/$domain/current/fullchain.pem" && cmp -s "$source/key.pem" "$ROOT/certs/$domain/current/key.pem"; then continue; fi
        if ! s2_certificate_validate "$domain" "$source/fullchain.pem" "$source/key.pem"; then
            warn "$domain 新证书未通过验证，仍使用原证书；其他有效域名继续处理。"; failure=1; continue
        fi
        if [[ $changed == no ]]; then begin_tx certificate-renewal; changed=yes; fi
        deploy_certificate "$domain"
    done
    if [[ $changed == yes ]]; then apply_config; commit_tx; fi
    ((failure==0)) || { warn '部分续期未成功；已通过验证并提交的更新保留，请检查ACME日志。'; return 1; }
}
cert_audit() {
    local domain source cert key expiry cfg schedule=0
    ui_title '证书与续期责任检查（只读）'
    printf '模式：%s；续期账户：%s/acme/config；服务：%s\n' "$MODE" "$ROOT" "$NGINX_SERVICE"
    while IFS= read -r domain; do
        source=$(jq -r --arg d "$domain" '.sites[]|select(.domain==$d)|.certificate_source // "acme"' "$STATE")
        cert="$ROOT/certs/$domain/current/fullchain.pem"; key="$ROOT/certs/$domain/current/key.pem"
        printf '%s [%s] ' "$domain" "$source"
        if [[ -s $cert && -s $key ]]; then openssl x509 -in "$cert" -noout -enddate || true
        else printf '当前证书/私钥缺失\n'; fi
    done < <(jq -r '.sites[].domain' "$STATE")
    # Print only source locations, NEVER cron arguments/DNS tokens.
    for cfg in /etc/crontab /etc/cron.d/* /var/spool/cron/crontabs/root; do
        [[ -f $cfg && ! -L $cfg ]] || continue
        if grep -Ev '^[[:space:]]*#' "$cfg" | grep -F 'acme' | grep -Fq "$ROOT/acme"; then
            printf '注意：%s 中发现本项目ACME路径引用，可能重复续期；未自动删除。\n' "$cfg"; schedule=1
        fi
    done
    [[ $schedule != 0 ]] || ui_note '未在常见cron路径发现本账户重复引用；不能证明不存在外部调度器。'
    ui_note '证书资料仍在原私有目录；共享的是程序，不开放私钥。导入证书的信任链/公网可达性仍需外部验证。'
}

shared_global() {
    local action=${1:-show} workers=${2:-} connections=${3:-} main="$SHARED_MAIN" rows="$WORK/global.tokens" map="$WORK/global.map" candidate="$WORK/global.next.conf" first last context name term value extra wcount=0 ccount=0 phrase='' old=''
    [[ $MODE == shared ]] || die '共享全局入口只适用于shared；独立模式继续用advanced。'
    shared_guard_file
    [[ -f $SHARED_INCLUDE ]] || die '先安装并应用本项目共享片段，再管理共享全局参数。'
    [[ -f $main && ! -L $main ]] || die '主配置不是普通文件；不自动编辑链接。'
    s2_nginx_tokens "$main" > "$rows" || die '无法解析系统主配置；未修改。'
    if [[ $action == show ]]; then
        ui_title '系统Nginx全局值（影响所有共享网站）'
        awk -F '\t' '$3=="main"&&($4=="user"||$4=="worker_processes"||$4=="worker_rlimit_nofile"){print $4" = "$6}
          $3=="main/events"&&$4=="worker_connections"{print $4" = "$6}' "$rows"
        ui_note '未显示的指令可能在include中或使用默认值；不把项目保存值冒充全局生效值。'
        ui_note '本入口仅支持主文件中明确且唯一的worker_processes/worker_connections；账户、沙箱、systemd FD仍由管理员管理。'
        return
    fi
    choice "$action" 'plan set' && valid_worker_count "$workers" && number "$connections" 128 65535 || die 'shared-global plan|set <auto或1~64> <128~65535>。'
    : > "$map"
    while IFS=$'\t' read -r first last context name term value extra; do
        if [[ $context == main && $name == worker_processes && $term == ';' && -z $extra ]]; then
            printf '%s\t%s\tworker_processes %s;\n' "$first" "$last" "$workers" >> "$map"; wcount=$((wcount+1))
        elif [[ $context == main/events && $name == worker_connections && $term == ';' && -z $extra ]]; then
            printf '%s\t%s\tworker_connections %s;\n' "$first" "$last" "$connections" >> "$map"; ccount=$((ccount+1))
        fi
    done < "$rows"
    ((wcount==1 && ccount==1)) || die '全局参数不在主文件中唯一声明；拒绝跨include猜测编辑，请管理员统一调整。'
    s2_rewrite_ranges "$main" "$map" "$candidate" || die '无法生成精确范围修改。'
    if cmp -s "$candidate" "$main"; then info '系统全局值相同，无需修改或重载。'; return; fi
    s2_shared_validate "$SHARED_INCLUDE" "$candidate" || die '全局候选配置校验失败；主配置未变。'
    printf '全局修改计划：worker_processes=%s；worker_connections=%s\n' "$workers" "$connections"
    ui_note '只替换这两个指令，其他字节保留；将重载整个共享Nginx；不自动提高文件数，需与系统LimitNOFILE协调。'
    [[ $action != plan ]] || return 0
    ask phrase '影响所有共享网站，输入 GLOBAL NGINX 确认' ''
    [[ $phrase == 'GLOBAL NGINX' ]] || return 0
    s2_inputs_unchanged || die '确认期间系统配置发生变化，未修改。'
    begin_tx shared-global
    s2_journal_begin
    s2_publish "$candidate" "$main" "$(stat -c %a "$main")" || die '主文件原子发布失败。'
    shared_syntax || die '全量检查失败，将恢复本次两个指令。'
    s2_service_mark nginx.service reload
    if systemctl is-active --quiet nginx.service; then
        old=$(worker_generation "$(nginx_master_pid)")
        systemctl reload nginx.service
        shared_verify_runtime "$old" || die '全局变更重载失败。'
    fi
    provider_record_update --arg h "$(runtime_hash_file "$main")" --arg w "$workers" --argjson c "$connections" \
      '.shared_global={approved_at:(now|todate),main_sha256:$h,workers:$w,connections:$c}'
    commit_tx
    ok '全局指令已通过单独授权更新；普通项目恢复不会还原整个系统主配置。'
}

recovery_status() {
    local dir="$ROOT/backup/transaction" row
    ui_title '配置事务与恢复状态（只读）'
    if [[ ! -d $dir ]]; then info '无未完成事务。'; return; fi
    printf '事务目录：%s\n' "$dir"
    [[ ! -f $dir/phase ]] || printf '阶段：%s\n' "$(cat "$dir/phase")"
    if [[ -f $dir/snapshot/meta.json ]]; then jq '{created,reason,manager}' "$dir/snapshot/meta.json"; fi
    if [[ -f $dir/stage2/intents.jsonl ]]; then
        printf '已记录发布意图（只显示路径）：\n'
        jq -sr 'map(.path)|unique[]' "$dir/stage2/intents.jsonl"
        s2_journal_guard "$dir" || { warn '有外部编辑冲突，不能自动覆盖。'; return 1; }
    fi
    ui_note 'repair只恢复本事务；不会执行防火墙重置、软件包降级或跨模式历史覆盖。'
}

# A historical snapshot is INPUT to the current generator, not a command to copy
# system nginx.conf/units. Mode/global ownership remain current. Whole-machine
# and package-state restore is explicitly outside this operation.
history_restore() {
    local id=${1:-} scope=${2:-} dir candidate="$WORK/history-candidate.json" from=isolated p
    history_select id "$id"; dir="$ROOT/backup/history/$id"
    snapshot_verify "$dir"
    [[ ! -f $dir/installation.json ]] || from=$(jq -r .mode "$dir/installation.json")
    [[ $from == "$MODE" ]] || die '禁止跨安装模式直接恢复；请先显式迁移。'
    if [[ -z $scope ]]; then
        select_value scope '按编号选择恢复范围（不覆盖共享全局设置）' state \
          'state|状态配置：按当前模式重新生成，保留当前证书' \
          'nodes|仅节点：含传统/原生节点及其凭据，可能重启Xray' \
          'web|仅网站及Nginx项目参数：不删除其他应用配置' \
          'advanced|仅高级资源参数：不改节点和网站' \
          'certs|仅项目证书：校验后按引用更新对应服务' \
          'full|项目状态+证书+防护资料：不覆盖全局Nginx/软件包/ACME账户'
    fi
    choice "$scope" 'state nodes web advanced certs full' || die '范围支持state/nodes/web/advanced/certs/full。'
    case "$scope" in
        nodes) jq --slurpfile h "$dir/state.json" '.nodes=$h[0].nodes | .native_nodes=($h[0].native_nodes // [])' "$STATE" > "$candidate";;
        web) jq --slurpfile h "$dir/state.json" '.sites=$h[0].sites | .performance=$h[0].performance | .advanced.nginx=$h[0].advanced.nginx | .edge=($h[0].edge // .edge)' "$STATE" > "$candidate";;
        advanced) jq --slurpfile h "$dir/state.json" '.advanced=$h[0].advanced' "$STATE" > "$candidate";;
        certs) cp "$STATE" "$candidate";;
        state|full) jq --slurpfile current "$STATE" '.components=$current[0].components | .versions=$current[0].versions' "$dir/state.json" > "$candidate";;
    esac
    # Validate after staging certs for full/certs; node->site relationships still
    # remain checked by validate_state before service changes.
    validate_advanced "$candidate"
    confirm "恢复$id，范围=$scope；只恢复本项目，服务按差异动作，防火墙仅核对" || return 0
    cp -a "$dir" "$WORK/selected-history"; dir="$WORK/selected-history"
    begin_tx "restore:$id:$scope"
    s2_journal_begin
    case "$scope" in
        full|certs)
            # Check all certificates that would be referenced before replacing any.
            while IFS= read -r p; do
                local c="$dir/certs/$p/current/fullchain.pem" k="$dir/certs/$p/current/key.pem"
                # Snapshot symlinks are restricted to their own tree by snapshot_verify.
                c=$(realpath -e "$c") || die '快照缺少引用证书。'; k=$(realpath -e "$k") || die '快照缺少私钥。'
                s2_certificate_validate "$p" "$c" "$k" 0 || die '快照证书过期/域名或密钥不符，未恢复。'
            done < <(jq -r '.sites[]|select(.issued)|.domain' "$candidate")
            rm -rf -- "$ROOT/certs"; cp -a "$dir/certs" "$ROOT/certs";;
    esac
    case "$scope" in full|web)
        if [[ -d $dir/config/edge && ! -L $dir/config/edge ]]; then rm -rf -- "$ROOT/config/edge"; cp -a "$dir/config/edge" "$ROOT/config/edge"; fi;;
    esac
    atomic_install 600 "$candidate" "$STATE"
    apply_config
    commit_tx
    recovery_firewall check || warn '部分端口状态未知；未自动增删防火墙规则。'
}

commit_tx() {
    local dir="$ROOT/backup/transaction/stage2"
    if [[ -d $dir ]]; then
        runtime_hash_file "$STATE" > "$dir/committed-state.sha256"
        runtime_hash_file "$(install_record_path)" > "$dir/committed-installation.sha256"
    fi
    s2_base_commit_tx
}
recovery_rollback_latest() {
    local dir="$ROOT/backup/last" saved now
    [[ -d $dir/stage2 && -f $dir/stage2/committed-state.sha256 ]] || die '最近事务不是可校验的阶段2事务；请使用编号history restore。'
    [[ $(cat "$dir/stage2/mode") == "$MODE" ]] || die '模式不同，请使用显式迁移。'
    saved=$(cat "$dir/stage2/committed-state.sha256"); now=$(runtime_hash_file "$STATE")
    [[ $saved == "$now" ]] || die '状态后来已变，拒绝精确回滚覆盖；请选择历史范围恢复。'
    [[ $(cat "$dir/stage2/committed-installation.sha256") == "$(runtime_hash_file "$(install_record_path)")" ]] || die '组件登记后来已变；拒绝精确回滚。'
    s2_journal_guard "$dir" || die '发现外部文件改动；未覆盖。'
    confirm '原样撤销最近阶段2事务；可能恢复历史root Worker，按涉及范围重载/重启，保留本次前备份' || return 0
    history_save before-stage2-rollback
    restore_transaction "$dir" manual || die '最近事务恢复未完成，资料保留。'
    mkdir -p "$ROOT/backup/rescue"
    mv "$dir" "$ROOT/backup/rescue/rolled-back-$(date +%s)-$(randhex 4)"
    recovery_firewall check || true
}

s3_prev_menu_catalog() {
    s2_base_menu_catalog
    cat <<'MENU'
main|20|配置生成和安全恢复|候选校验、差异计划、选择性恢复和续期检查|共享模式不覆盖其他网站；写入前确认|nav|menu:configsafe
configsafe|1|候选配置检查|生成并校验完整候选配置，不发布|共享模式递归检查静态include；无需重启|read|config-check
configsafe|2|服务动作计划|查看无需动作、重载、重启和启动原因|只在临时目录生成；计划不是运行验收|read|config-plan
configsafe|3|脱敏差异摘要|显示摘要与监听协议，不打印密钥|不直接输出原始Xray配置|read|config-diff
configsafe|4|应用保存配置|校验后原子发布本项目配置|可能重启涉及组件；先确认动作计划|warn|apply
configsafe|5|按范围恢复历史|编号选择状态、节点、网站、证书或参数|保留安装模式；共享全局参数不随历史覆盖|warn|history-restore
configsafe|6|未完成事务状态|查看阶段、受影响文件及外部编辑冲突|只读；不自动覆盖冲突|read|recovery-status
configsafe|7|修复未完成事务|按本次事务记录恢复|不重置防火墙；冲突时保留现场|warn|repair
configsafe|8|撤销最近阶段2事务|当前摘要仍匹配时精确回滚|可能重载服务；回滚前另存当前快照|warn|recovery-rollback
configsafe|9|证书与续期检查|有效期、来源和常见重复cron引用|不打印DNS凭据；不能发现全部外部调度|read|cert-audit
configsafe|10|查看系统全局Nginx参数|区分系统全局与项目保存值|仅共享模式；不修改|read|shared-global-show
configsafe|11|调整共享全局并发|仅改主文件唯一Worker和connections指令|影响全部网站；需独立输入GLOBAL NGINX确认|danger|shared-global-edit
configsafe|0|返回上一级|不修改配置|未保存输入不提交|back|back
MENU
}
s3_prev_menu_title() { if [[ $1 == configsafe ]]; then printf '配置生成和安全恢复'; else s2_base_menu_title "$@"; fi; }
s3_prev_menu_dispatch() {
    local route=$1
    case "$route" in
        config-check) menu_run config check;; config-plan) menu_run config plan;; config-diff) menu_run config diff;;
        history-restore) menu_run history restore;;
        recovery-status) menu_run recovery status;; recovery-rollback) menu_run recovery rollback;;
        cert-audit) menu_run cert audit;; shared-global-show) menu_run shared-global show;;
        shared-global-edit) menu_run shared-global edit;;
        *) s2_base_menu_dispatch "$@";;
    esac
}
s3_prev_usage() {
    s2_base_usage "$@"
    cat <<'HELP'

阶段2新增（不会自动迁移安装模式）：
  config check|plan|diff|apply      候选检查 / 服务计划 / 脱敏摘要 / 显式应用
  recovery status|repair|rollback  查看事务 / 修复 / 撤销最近阶段2事务
  history restore [编号] [范围]    state/nodes/web/advanced/certs/full
  cert audit                      证书与本账户重复续期引用检查
  shared-global show              查看共享全局；不是项目保存值
  shared-global plan|set W C       明确授权修改主配置的Worker/连接数
  shared-global edit              按提示填写W/C，再独立确认
共享的候选检查支持静态include/通配符/常规引号；动态include/循环/过大配置拒绝自动处理。
精确回滚遇外部修改会停止；未覆盖整个/etc/nginx、账户数据库、防火墙或软件包。
HELP
}

shared_verify_runtime() {
    local old=${1:-} user uid master p u count=0 caps birth deadline stable=0 expected wait_s
    user=$(resolve_worker) || return 1; uid=$(id -u "$user") || return 1
    expected=$(nginx_conf_value worker_processes "$SHARED_MAIN" || true)
    [[ $expected != auto ]] || expected=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 1)
    [[ $expected =~ ^[1-9][0-9]*$ ]] || expected=1
    wait_s=$(ng_value startup_timeout 2>/dev/null || printf 30); number "$wait_s" 5 180 || wait_s=30
    deadline=$((SECONDS+wait_s))
    while ((SECONDS<deadline)); do
        count=0; master=$(systemctl show -p MainPID --value nginx.service 2>/dev/null || true)
        if nginx_pid_valid "$master"; then
            while read -r p u; do
                birth=$(proc_start_ticks "$p" 2>/dev/null || true)
                [[ -n $birth && " $old " != *" $p:$birth "* ]] || continue
                [[ $u == "$uid" && $u != 0 ]] || { warn '共享Nginx新Worker身份异常。'; return 1; }
                caps=$(awk '/^CapEff:/{print $2}' "/proc/$p/status" 2>/dev/null || true)
                [[ $caps =~ ^0+$ ]] || { warn '共享Worker仍持有有效capabilities。'; return 1; }
                count=$((count+1))
            done < <(master_workers "$master")
        fi
        if ((count>=expected)); then stable=$((stable+1)); ((stable>=2)) && return 0; else stable=0; fi
        sleep .2
    done
    warn "共享Nginx未观察到足够稳定的新Worker（预期$expected，观察到$count）；不视为重载成功。"; return 1
}

cert_import() {
    local domain=$1 cert=$2 key=$3 remove_failed=no
    site_select domain "$domain"
    s2_certificate_validate "$domain" "$cert" "$key" || die '输入证书/密钥校验失败；未改变签发资料或服务。'
    confirm "为$domain导入证书并暂停该域名自动续期；先验证服务，再处理ACME旧登记" || return 0
    begin_tx "cert-import:$domain"
    s2_journal_begin
    mkdir -p "$ROOT/certs/$domain/pending"
    install -m 600 "$cert" "$ROOT/certs/$domain/pending/fullchain.pem"
    install -m 600 "$key" "$ROOT/certs/$domain/pending/key.pem"
    deploy_certificate "$domain"
    json_update --arg d "$domain" '(.sites[]|select(.domain==$d)).certificate_source="manual"'
    apply_config
    commit_tx
    # Only after successful activation. Even if --remove fails, domain-filtered
    # renewal above skips manual certificates and will not overwrite this import.
    if component_ready acme && [[ -d $ROOT/acme/certstore/${domain}_ecc ]]; then
        acme_run --remove -d "$domain" --ecc || remove_failed=yes
    fi
    [[ $remove_failed != yes ]] || warn '手动证书已生效且不会被本项目自动续期覆盖；ACME旧登记清理失败，资料保留。'
}

# During explicit isolated -> shared migration, the old owned listener is valid.
# Check every listening PID rather than disabling collision checks altogether.
s2_migration_port_guard() {
    local port=$1 output pid
    local -a pids=()
    output=$(ss -H -lntup "sport = :$port") || return 1
    [[ -n $output ]] || return 0
    mapfile -t pids < <(printf '%s\n' "$output" | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)
    ((${#pids[@]})) || { warn "端口$port被占用且无法确认归属；不抢占。"; return 1; }
    for pid in "${pids[@]}"; do
        grep -Eq '/(vpskit-nginx|nginx)\.service(/|$)' "/proc/$pid/cgroup" || { warn "端口$port有非本次迁移服务占用；未停止外部进程。"; return 1; }
    done
}
check_listener_ports() {
    local port net
    if [[ $(get '.components.nginx // false') == true ]]; then
        if [[ ${MIGRATING_TO_SHARED:-no} == yes ]]; then
            s2_migration_port_guard 80 || die '迁移端口80冲突。'
            if jq -e '.sites[]|select(.issued)' "$STATE" >/dev/null; then s2_migration_port_guard 443 || die '迁移端口443冲突。'; fi
        else
            guard_port 80 "$NGINX_SERVICE"
            if jq -e '.sites[]|select(.issued)' "$STATE" >/dev/null; then guard_port 443 "$NGINX_SERVICE"; fi
        fi
    fi
    while read -r port net; do guard_port "$port" vpskit-xray.service; done < <(all_xray_ports)
}
s2_delete_owned() {
    local target=$1 dir="$ROOT/backup/transaction/stage2" old key
    [[ $target == "$SHARED_INCLUDE" && -f $target && ! -L $target ]] || return 1
    s2_journal_begin || return 1
    old=$(s2_file_stamp "$target") || return 1
    key=$(printf '%s' "$target" | sha256sum | cut -d' ' -f1)
    [[ -f $dir/files/$key.before ]] || cp -a -- "$target" "$dir/files/$key.before" || return 1
    jq -nc --arg p "$target" --arg k "$key" --arg b "$old" '{path:$p,key:$k,before:$b,after:"absent",mode:"600"}' >> "$dir/intents.jsonl" || return 1
    [[ $(s2_file_stamp "$target") == "$old" ]] || return 1
    printf 'runtime\n' > "$ROOT/backup/transaction/phase"
    rm -f -- "$target"
}
shared_detach() {
    local candidate="$WORK/detach-empty.conf" old=''
    shared_guard_file
    [[ -f $SHARED_INCLUDE ]] || { info '本项目共享片段已经撤下。'; return; }
    # Empty virtual include verifies the remaining system graph before deletion.
    # A direct (non-glob) include must be removed by its owner; otherwise deletion
    # would leave a broken path. We retain the file and reject that topology.
    printf '# VPSKIT_OWNED empty candidate for detach validation\n' > "$candidate"
    s2_shared_validate "$candidate" || die '撤下后的候选检查失败；片段未动。'
    if jq -se --arg p "$SHARED_INCLUDE" 'any(.[];.kind=="glob" and .path==$p)' "$S2_INPUT_MANIFEST" >/dev/null; then
        die '主配置直接include本项目文件；需管理员先调整为conf.d通配包含，未删除片段。'
    fi
    confirm '只撤下VPSKit片段并reload共享Nginx；保留外部网站、组件、证书与Xray' || return 0
    begin_tx shared-detach
    s2_journal_begin
    s2_inputs_unchanged || die '候选检查后外部配置已变；取消撤下。'
    shared_guard_file
    s2_delete_owned "$SHARED_INCLUDE" || die '撤下片段失败。'
    "$NGINX" -t -c "$SHARED_MAIN" || die '撤下后系统配置失败；按事务恢复。'
    if systemctl is-active --quiet nginx.service; then
        s2_service_mark nginx.service reload
        old=$(worker_generation "$(nginx_master_pid)")
        systemctl reload nginx.service || die '撤下后的重载失败；按事务恢复。'
        shared_verify_runtime "$old" || die '撤下后的Worker检查失败；按事务恢复。'
    fi
    json_update '.components.nginx=false'
    provider_record_update '.owned_files |= del(.nginx,.nginx_sha256,.certificates_sha256)'
    commit_tx
    info '仅撤下本项目网站入口；其他网站及Xray直连入口保留。'
}

# No recorded fingerprint after a web-only migration: compare referenced files
# with the current transaction snapshot, not only the unchanged certificate path.
s2_xray_certificate_changed() {
    local file=$1 path relative old
    [[ -d $ROOT/backup/transaction/snapshot/certs ]] || return 1
    while IFS= read -r path; do
        [[ $path == "$ROOT/certs/"* ]] || continue
        relative=${path#"$ROOT/"}; old="$ROOT/backup/transaction/snapshot/$relative"
        cmp -s "$path" "$old" || return 0
    done < <(jq -r '[..|objects|.certificateFile?,.keyFile?|select(type=="string")]|unique[]' "$file")
    return 1
}
site_remove() {
    local domain prefix had_acme=no
    site_select domain "${1:-}"; prefix="$ROOT/certs/$domain/"
    if jq -e --arg d "$domain" --arg p "$prefix" '
      any(.nodes[];.domain==$d) or
      any((.native_nodes // [])[]; (.domain // "")==$d or
        any(.inbound|..|strings; startswith($p)))' "$STATE" >/dev/null; then
        die '传统/原生节点仍引用此网站或证书；先迁移这些节点，未撤续期登记。'
    fi
    if component_ready acme && jq -e --arg d "$domain" '.sites[]|select(.domain==$d and .issued)' "$STATE" >/dev/null; then had_acme=yes; fi
    confirm "撤下$domain网站绑定；保留内容及证书，成功应用后再移除该域名续期登记" || return 0
    begin_tx "site-remove:$domain"; s2_journal_begin
    json_update --arg d "$domain" '.sites |= map(select(.domain!=$d))'
    apply_config web
    commit_tx
    if [[ $had_acme == yes ]]; then
        acme_run --remove -d "$domain" --ecc || warn '网站已撤下；旧ACME登记移除失败，资料保留。本项目续期不会处理已移除的网站。'
    fi
}




# Stage 3 menu registry: no shell fragments are stored or evaluated.
s4_previous_menu_catalog() {
cat <<'VPSKIT_STAGE3_MENU'
main|1|部署与安装模式|新装、复用组件、模式迁移|共享/独立双模式；不覆盖已有节点|nav|menu:install
main|2|代理节点与用户|统一查看传统和扩展节点|运行参数变更可能重启整个Xray实例|nav|menu:nodes
main|3|网站与反向代理|静态站、模板、本机应用和重定向|只管理本项目站点；不修改外部网站|nav|menu:websites
main|4|ACME 与 SSL 证书|签发、导入、续期和有效期检查|私钥及DNS凭据保持私有|nav|menu:certificates
main|5|Nginx 高级配置|容量、超时、连接池及全局授权|共享模式全局参数有独立确认|nav|menu:advanced
main|6|Xray 高级配置|空闲、缓冲、日志及原生协议|不自动开启公网管理API|nav|menu:xray
main|7|网络与防火墙|BBR、MTU、端口和防火墙|不自动修改SSH或云安全组|nav|menu:network
main|8|Cloudflare 与网站防护|真实IP、回源限制、AOP和网站限流|网站防护与节点代理参数分开|nav|menu:edge
main|9|性能与系统资源|资源建议、预设比较、Swap和按需测速|不新增常驻监控；不保证吞吐提升|nav|menu:efficiency
main|10|服务运行与重启|控制服务、自启和整机重启|共享Nginx动作影响全部共享网站|nav|menu:services
main|11|组件与管理脚本更新|单独更新管理代码和组件|组件更新可能重启，代码更新不自动重启|nav|menu:update
main|12|备份、恢复与迁移|范围恢复、事务修复和模式迁移|快照不等于整机备份|nav|menu:history
main|13|运行状态与日志|运行摘要、有限日志和脱敏报告|保存配置不等于实际加载状态|nav|menu:status
main|14|系统维护与垃圾清理|先预览过期文件再确认删除|保留事务、救援备份、证书和活动日志|nav|menu:housekeeping
main|15|卸载与组件移除|保留数据停用、撤配置或移除组件|依赖预览、外部备份；共享组件与数据分别确认|danger|menu:uninstall
main|16|帮助与使用说明|命令、目录、菜单检索和使用边界|只读；保留旧命令入口|nav|menu:help
main|0|退出面板|不修改配置|已提交的配置保留|back|back
install|1|新装共享模式|以系统Nginx和共享ACME程序进行部署|已有部署不能直接改模式；需走迁移|write|s3-install-shared
install|2|新装独立模式|使用私有组件和服务|不抢占外部程序端口|write|s3-install-isolated
install|3|继续部署向导|自动读取已保存参数，跳过已完成步骤|新机或未完成部署；需要联网|write|install-wizard
install|4|查看当前部署进度|核对现有历史参数和向导完成情况|只读；不会重置部署|read|wizard-status
install|5|单独安装或补装组件|进入对应功能控制区|查看当前状态后按序号选择|nav|menu:installcomponents
install|6|模式、归属与外部程序复用|进入对应功能控制区|查看当前状态后按序号选择|nav|menu:providers
install|7|模式迁移|进入对应功能控制区|查看当前状态后按序号选择|nav|menu:migration
install|8|修改方案与默认值|保存方案 A/B 和新建节点的默认连接地址|不自动改动已有节点、证书或网站|write|wizard-configure
install|9|配置文件与目录|显示配置与资料保存位置|只显示路径；不要公开包含密钥的目录|read|paths
install|0|返回上一级|不修改配置|已提交的配置保留|back|back
installcomponents|1|安装或复用 Nginx|按当前模式选择APT系统包或独立程序|共享模式不覆盖系统主配置|write|install-nginx
installcomponents|2|单独安装 Xray|补装代理组件，不覆盖已保存节点|需 GitHub 可达；已安装时不重复安装|write|install-xray
installcomponents|3|安装或复用 ACME|按当前模式安装程序，账户资料保持私有|不重复创建续期任务|write|install-acme
installcomponents|0|返回上一级|不修改配置|已提交的配置保留|back|back
providers|1|安装模式与组件归属|查看路径、来源和托管范围|只读；不把外部组件冒认为本工具安装|read|provider-show
providers|2|选择共享模式（空部署）|空部署使用APT Nginx及共享ACME程序|已有节点或网站需走迁移，不能直接改标签|write|mode-select-shared
providers|3|选择独立模式（空部署）|沿用私有目录及服务|不接管外部Nginx|write|mode-select-isolated
providers|4|显式复用外部 acme.sh|只登记可执行程序，项目账户仍独立|必须提供可信的已安装绝对路径|warn|s3-adopt-acme
providers|5|修复中断的APT启动抑制|只处理本工具有归属的policy-rc.d|需要检查文件归属，不覆盖外部策略|warn|s3-repair-apt-policy
providers|6|查询Xray最新正式版本|仅查询官方GitHub Release信息|需联网；不下载、不升级、不重启|read|provider-latest
providers|7|迁移安装模式|进入对应功能控制区|查看当前状态后按序号选择|nav|menu:migration
providers|0|返回上一级|不修改配置|已提交的配置保留|back|back
migration|1|预览迁移到共享模式|显示影响和执行次序|只读，不重启服务|read|mode-plan-shared
migration|2|执行迁移到共享模式|保留Xray及网站资料，切换Nginx服务|先备份；短暂断连；APT安装不能靠快照降级|warn|mode-apply-shared
migration|3|预览迁移到独立模式|显示独立服务切换要求|只读；共享Nginx存在其他站点则不能切走|read|mode-plan-isolated
migration|4|执行迁移到独立模式|安装私有组件并切换服务|其他共享站点存在时拒绝；保留旧程序备份|warn|mode-apply-isolated
migration|5|未完成事务状态|查看阶段、受影响文件及外部编辑冲突|只读；不自动覆盖冲突|read|recovery-status
migration|6|修复未完成事务|按本次事务记录恢复|不重置防火墙；冲突时保留现场|warn|repair
migration|0|返回上一级|不修改配置|已提交的配置保留|back|back
nodes|1|全部节点总览|传统和扩展节点统一编号，分TCP/UDP查看监听|本机监听不等于公网/客户端连通|read|s3-node-overview
nodes|2|新增节点|添加 REALITY、XHTTP、WS、TLS 或 Shadowsocks|Xray 已安装；所选传输需满足域名/证书条件|write|node-add
nodes|3|创建扩展协议节点|VLESS Encryption、Hysteria2、MASQUE等|编号选择；实际核心测试通过才保存|write|native-add
nodes|4|传统节点管理|进入对应功能控制区|查看当前状态后按序号选择|nav|menu:legacy
nodes|5|扩展原生节点管理|进入对应功能控制区|查看当前状态后按序号选择|nav|menu:native
nodes|6|统一编号批量启停|传统/原生节点合并一次提交|运行配置变更至多一次Xray生命周期动作|warn|s3-node-batch
nodes|7|添加共享入口用户|复用同一监听端口，生成独立用户凭据|已有支持共享的入口；不新增公网端口|write|node-share
nodes|8|节点导出|进入对应功能控制区|查看当前状态后按序号选择|nav|menu:nodeexport
nodes|9|协议目录与核心版本|列出协议、传输和使用要求|只读；目录不等于端到端已验证|read|native-catalog
nodes|10|同步当前所需端口|预览后开放网站及启用节点需要的公网端口|不会开放本机后端端口；不会自动关闭旧端口|write|firewall-sync
nodes|11|候选配置检查|生成并校验完整候选配置，不发布|共享模式递归检查静态include；无需重启|read|config-check
nodes|0|返回上一级|不修改配置|已提交的配置保留|back|back
legacy|1|查看节点列表|显示序号、名称、协议、入口和启用状态|只读；不显示访问凭据|read|node-list
legacy|2|启用节点|让保存的节点重新参与运行配置|需端口可用；客户端与防火墙需匹配|write|node-enable
legacy|3|停用节点|保留节点资料，停止该用户的访问|该用户连接可能中断；其他共享用户保留|warn|node-disable
legacy|4|删除节点|删除选中用户的节点记录|删除不可直接撤销；可从历史快照恢复|danger|node-delete
legacy|5|批量启停节点|按编号多选节点，一次提交并应用|若改变Xray配置会影响本实例连接；0取消|warn|node-batch
legacy|6|编辑传统节点|进入对应功能控制区|查看当前状态后按序号选择|nav|menu:nodeedit
legacy|7|添加共享入口用户|复用同一监听端口，生成独立用户凭据|已有支持共享的入口；不新增公网端口|write|node-share
legacy|8|导出节点|进入对应功能控制区|查看当前状态后按序号选择|nav|menu:nodeexport
legacy|0|返回上一级|不修改配置|已提交的配置保留|back|back
nodeedit|1|修改节点名称|修改用户显示名称，保留共享入口关系|名称须唯一；不会轮换访问凭据|write|node-rename
nodeedit|2|修改入口端口|同步修改整个共享入口的监听端口|同步客户端、防火墙和安全组；WS/XHTTP 仍走公网443|warn|node-port
nodeedit|3|修改连接地址|修改客户端连接域名、IPv4 或 IPv6|保留 TLS SNI/Host；同入口用户同步修改|write|node-host
nodeedit|4|指定 UUID 或密码|手动设置凭据，可留空自动生成|需符合协议格式；客户端必须同步更新|sensitive|node-credential
nodeedit|5|修改监听地址|选择 IPv4、IPv6 或双栈监听入口|仅直连入口；WS/XHTTP 后端保持回环监听|warn|node-listen
nodeedit|6|自动轮换凭据|重新生成 UUID 或密码|客户端必须更新；现有连接可能中断|warn|node-rotate
nodeedit|0|返回上一级|不修改配置|已提交的配置保留|back|back
nodeexport|1|导出分享链接|输出可导入客户端的节点 URI|链接含访问凭据，禁止公开发布|sensitive|node-export
nodeexport|2|导出 XHTTP 客户端 JSON|生成本地 SOCKS 的 Xray 客户端配置|仅 XHTTP 节点；JSON 含 UUID|sensitive|node-client
nodeexport|3|导出客户端JSON|编号选择并输出客户端配置|包含凭据；只提供给可信客户端|sensitive|native-export
nodeexport|0|返回上一级|不修改配置|已提交的配置保留|back|back
native|1|协议目录与核心版本|列出协议、传输和使用要求|只读；目录不等于端到端已验证|read|native-catalog
native|2|创建扩展协议节点|VLESS Encryption、Hysteria2、MASQUE等|编号选择；实际核心测试通过才保存|write|native-add
native|3|查看原生节点|列出端口、协议、启用状态|不打印凭据|read|native-list
native|4|启用原生节点|编号选择后启用|Xray运行配置变化会重启本实例|write|native-enable
native|5|停用原生节点|编号选择后停用|其他节点仍保留但可能因重启短暂断连|warn|native-disable
native|6|修改原生节点名称|只更改显示名称，保留内部tag|无实质配置变化不重启|write|native-rename
native|7|导出客户端JSON|编号选择并输出客户端配置|包含凭据；只提供给可信客户端|sensitive|native-export
native|8|删除原生节点|编号选择后删除|不可撤销前会创建快照；不关闭全局防火墙|danger|native-delete
native|9|导入受支持的原生入站JSON|校验协议、监听、证书引用及当前核心|本机普通文件；不接管系统路由|warn|s3-native-import
native|0|返回上一级|不修改配置|已提交的配置保留|back|back
websites|1|查看网站列表|显示域名、内容类型、访问方式和证书状态|只读；不显示 DNS API 凭据|read|site-list
websites|2|新增网站|创建模板、静态站、本机反代或 HTTPS 跳转|已安装 Nginx；需自有域名|write|site-add
websites|3|修改网站内容与访问方式|编辑已有网站；保留内容文件和证书|不覆盖已存在模板；修改后检查依赖节点|write|site-edit
websites|4|移除网站绑定|停止该域名网站和自动续期，保留文件|必须先删除引用该网站的节点|danger|site-remove
websites|5|静态网站 gzip|启停轻量文本压缩，不压缩节点代理流量|Nginx 已安装；站点单独设置可覆盖全局值|write|performance-gzip
websites|6|静态缓存与 gzip|设置静态资源缓存头和站点压缩|不强制缓存HTML/动态应用/节点流量|write|edge-cache
websites|7|普通网站反代超时|本机应用的读写空闲超时|5–3600 秒；与节点长连接参数分开|write|param:site_proxy_timeout
websites|8|网站上游连接池|每Worker保留的应用上游空闲连接数|0–128；0关闭；并非最大上游连接总数|write|param:upstream_keepalive
websites|9|网站权限修复|显式修复上传文件的读取权限|不重启服务；扫描网站树并拒绝不安全链接|warn|perf-permissions
websites|10|候选配置检查|生成并校验完整候选配置，不发布|共享模式递归检查静态include；无需重启|read|config-check
websites|11|配置计划与发布|进入对应功能控制区|查看当前状态后按序号选择|nav|menu:configsafe
websites|0|返回上一级|不修改配置|已提交的配置保留|back|back
certificates|1|证书有效期|查看当前证书到期时间|只读；尚未签发会明确提示|read|cert-status
certificates|2|签发 / 重试证书|按已保存设置申请或重新签发证书|需 ACME；HTTP-01 需80可达，DNS-01 需 API权限|write|cert-issue
certificates|3|修改证书验证设置|保存邮箱、HTTP/DNS 验证及泛域名选项|保存不立即重签；泛域名需要 DNS-01|write|cert-settings
certificates|4|导入证书与私钥|校验域名和密钥匹配后部署手动证书|提供本机 PEM 文件；暂停此域名 ACME 自动续期|sensitive|cert-import
certificates|5|检查续期|按 ACME 到期策略检查，不强制重复签发|需联网；手动导入的证书不自动续期|write|cert-renew
certificates|6|证书与续期检查|有效期、来源和常见重复cron引用|不打印DNS凭据；不能发现全部外部调度|read|cert-audit
certificates|7|证书与维护日志|查看定时续期服务的近期 journal 记录|需要 systemd journal；分享前脱敏|read|logs-cert
certificates|8|维护定时器|进入对应功能控制区|查看当前状态后按序号选择|nav|menu:schedule
certificates|9|安装模式与组件归属|查看路径、来源和托管范围|只读；不把外部组件冒认为本工具安装|read|provider-show
certificates|0|返回上一级|不修改配置|已提交的配置保留|back|back
advanced|1|查看保存值与实际值|显示合并默认值后的参数、CPU/内存及Worker身份|只读；连接上限不是用户人数|read|advanced-show
advanced|2|Worker / 连接数 / 文件数|一起调整并发容量，防止参数互相冲突|仅独立模式；共享全局参数从单独授权入口调整|write|advanced-capacity
advanced|3|查看系统全局Nginx参数|区分系统全局与项目保存值|仅共享模式；不修改|read|shared-global-show
advanced|4|调整共享全局并发|仅改主文件唯一Worker和connections指令|影响全部网站；需独立输入GLOBAL NGINX确认|danger|shared-global-edit
advanced|5|HTTP、TLS与超时参数|进入对应功能控制区|查看当前状态后按序号选择|nav|menu:nginxparams
advanced|6|连接复用和压缩|进入对应功能控制区|查看当前状态后按序号选择|nav|menu:perfparams
advanced|7|Worker 与权限预检|进入对应功能控制区|查看当前状态后按序号选择|nav|menu:worker
advanced|8|候选配置和发布|进入对应功能控制区|查看当前状态后按序号选择|nav|menu:configsafe
advanced|9|恢复高级默认值|只恢复Nginx/Xray高级参数|保留节点和网站；共享模式不修改全局主配置|warn|advanced-defaults
advanced|0|返回上一级|不修改配置|已提交的配置保留|back|back
worker|1|选择非 root 服务账户|自动检测或手工选择已有合格服务账户|不创建用户；拒绝root及高权限/可交互登录账户|warn|advanced-user
worker|2|查看可复用服务账户|列出自动候选账户的UID及资格检查结果|只读；不会创建、删除或修改系统账户|read|advanced-users
worker|3|非root与沙箱启动预检|独立UNIX套接字测试身份、静态读取和上传缓冲|不重启正式服务；会短暂启动受限测试进程|warn|advanced-preflight
worker|4|服务沙箱模式|编号选择兼容或严格隔离，先预检再切换|1兼容/2严格；Worker保持非root，私钥保持root私有|warn|param:sandbox_mode
worker|5|启动校验等待时间|容忍低配VPS和服务启动延迟|5–180 秒；不跳过身份和实际文件数检查|write|param:startup_timeout
worker|6|网站权限修复|显式修复上传文件的读取权限|不重启服务；扫描网站树并拒绝不安全链接|warn|perf-permissions
worker|0|返回上一级|不修改配置|已提交的配置保留|back|back
nginxparams|1|HTTP Keepalive|空闲HTTP连接保留时间|5–300 秒；影响普通HTTP复用，不是WS连接寿命|write|param:keepalive
nginxparams|2|Keepalive 请求数|单连接最多处理的请求数|100–100000 次；过大不是无条件更快|write|param:keepalive_requests
nginxparams|3|TLS 会话缓存|共享TLS会话缓存容量|1–128 MiB；修改后重载验证，按内存设置|write|param:ssl_cache
nginxparams|4|TLS 会话复用时间|可复用TLS会话的有效时间|1–1440 分钟；不是HTTP连接超时|write|param:ssl_timeout
nginxparams|5|HTTP/2 开关|控制网站是否启用HTTP/2|true/false；存在启用XHTTP时仍保留HTTP/2|write|param:http2
nginxparams|6|请求头超时|读取客户端请求头的超时|5–300 秒；过短会影响弱网访问|write|param:client_header_timeout
nginxparams|7|普通请求体超时|读取网站请求体的空闲超时|5–3600 秒；节点流量有独立超时|write|param:client_body_timeout
nginxparams|8|网站响应发送超时|向客户端发送响应的空闲超时|5–3600 秒；不是整个文件下载总时长|write|param:send_timeout
nginxparams|9|连接上游超时|连接本机反向代理上游的等待时间|1–60 秒；本机上游通常无需设置很大|write|param:proxy_connect_timeout
nginxparams|10|节点上游读取超时|WS/XHTTP上游读取空闲超时|30–86400 秒；依据心跳和客户端行为设置|write|param:proxy_read_timeout
nginxparams|11|节点上游写入超时|WS/XHTTP上游发送空闲超时|30–86400 秒；保持与客户端行为协调|write|param:proxy_send_timeout
nginxparams|12|普通网站反代超时|本机应用的读写空闲超时|5–3600 秒；与节点长连接参数分开|write|param:site_proxy_timeout
nginxparams|13|普通网站上传上限|限制普通站点单请求体大小|1–4096 MiB；XHTTP节点不套用此限制|write|param:client_max_body_mb
nginxparams|14|Worker 优雅退出期限|reload后旧Worker最多等待的时间|0–3600 秒；0不强制截止，非0可能断开长连接|write|param:worker_shutdown_timeout
nginxparams|0|返回上一级|不修改配置|已提交的配置保留|back|back
perfparams|1|网站上游连接池|每Worker保留的应用上游空闲连接数|0–128；0关闭；并非最大上游连接总数|write|param:upstream_keepalive
perfparams|2|XHTTP上游连接池|每Worker每入口保留少量空闲连接|0～64；不缓存代理数据，不修改传输模式|write|param:xhttp_keepalive
perfparams|3|上游空闲连接回收|限制网站/XHTTP连接池的空闲时间|1～60秒；旧Nginx低于1.15.3时使用模块默认|write|param:upstream_idle
perfparams|4|网站压缩级别|轻量文本gzip强度|1～5；仅实际启用gzip的位置生效|write|param:gzip_level
perfparams|5|应用网站压缩|独立控制普通反向代理响应gzip|默认关闭；敏感动态页面需评估压缩侧信道风险|warn|param:proxy_gzip
perfparams|6|静态网站 gzip|启停轻量文本压缩，不压缩节点代理流量|Nginx 已安装；站点单独设置可覆盖全局值|write|performance-gzip
perfparams|7|静态缓存与 gzip|设置静态资源缓存头和站点压缩|不强制缓存HTML/动态应用/节点流量|write|edge-cache
perfparams|8|普通网站上传上限|限制普通站点单请求体大小|1–4096 MiB；XHTTP节点不套用此限制|write|param:client_max_body_mb
perfparams|0|返回上一级|不修改配置|已提交的配置保留|back|back
xray|1|Xray空闲与缓冲|编号选择缓冲，设置双向空闲上限|修改需要重启Xray；缓冲不是TCP窗口|warn|perf-xray
xray|2|Xray 文件描述符上限|调整Xray的systemd LimitNOFILE|变更后需重启Xray，代理连接可能中断|warn|advanced-xray
xray|3|协议目录与核心版本|列出协议、传输和使用要求|只读；目录不等于端到端已验证|read|native-catalog
xray|4|扩展节点与原生导入|进入对应功能控制区|查看当前状态后按序号选择|nav|menu:native
xray|5|候选配置检查|生成并校验完整候选配置，不发布|共享模式递归检查静态include；无需重启|read|config-check
xray|6|脱敏差异摘要|显示摘要与监听协议，不打印密钥|不直接输出原始Xray配置|read|config-diff
xray|7|更新 Xray|选择固定版本或显式 latest|需联网；重启会中断代理连接，先核对客户端兼容性|write|update-xray
xray|8|Xray 日志|显示最近代理运行错误记录|只读；分享前脱敏|read|logs-xray
xray|9|Xray错误日志级别|按编号选择warning/error/none|关闭错误日志将减少诊断线索；需要应用配置|warn|s3-xray-log
xray|0|返回上一级|不修改配置|已提交的配置保留|back|back
network|1|资源与网络现状|查看内存、连接、拥塞控制和网卡 MTU|只读；不会修改系统参数|read|optimize-status
network|2|BBR 与MTU探测|进入对应功能控制区|查看当前状态后按序号选择|nav|menu:optimize
network|3|防火墙控制|进入对应功能控制区|查看当前状态后按序号选择|nav|menu:firewall
network|4|DNS 与公网 HTTPS 检查|检查网站解析和公网响应，不修改 DNS|需网络；Cloudflare解析不必等于源站IP|read|network-check
network|5|同步当前所需端口|预览后开放网站及启用节点需要的公网端口|不会开放本机后端端口；不会自动关闭旧端口|write|firewall-sync
network|6|网卡流量采样|显示网卡累计流量和约1秒速率|为接口总流量，不是节点计费统计|read|edge-traffic
network|7|节点监听总览|TCP/UDP端口和启用状态分开显示|只在本机读取，不自动开放端口|read|s3-node-overview
network|0|返回上一级|不修改配置|已提交的配置保留|back|back
optimize|1|资源与网络现状|查看内存、连接、拥塞控制和网卡 MTU|只读；不会修改系统参数|read|optimize-status
optimize|2|启用 BBR + fq|记录旧参数后启用内核拥塞控制|需内核提供 BBR；不保证提升所有链路性能|warn|optimize-bbr
optimize|3|撤销本工具 BBR 设置|恢复本工具记录的旧值并移除其持久化文件|只撤销可验证的托管设置；不覆盖外部新改动|warn|optimize-restore
optimize|4|MTU 路径探测|使用 tracepath 检查目标路径的 MTU|需 iputils-tracepath；只发送探测，不修改网卡|read|optimize-mtu
optimize|5|静态网站 gzip|启停轻量文本压缩，不压缩节点代理流量|Nginx 已安装；站点单独设置可覆盖全局值|write|performance-gzip
optimize|6|Worker / 连接数 / 文件数|一起调整并发容量，防止参数互相冲突|仅独立模式；共享全局参数从单独授权入口调整|write|advanced-capacity
optimize|7|资源预设|进入对应功能控制区|查看当前状态后按序号选择|nav|menu:efficiency
optimize|0|返回上一级|不修改配置|已提交的配置保留|back|back
firewall|1|防火墙与所需端口|查看启用的管理器、规则和节点公网端口|只读；云安全组需另行检查|read|firewall-status
firewall|2|开放端口|显式添加带归属记录的 TCP/UDP 放行规则|仅已启用的 UFW/firewalld；SSH 端口交给管理员|warn|firewall-open
firewall|3|关闭端口|添加阻止新入站连接的规则|会影响相关业务；拒绝操作检测到的 SSH 端口|danger|firewall-close
firewall|4|同步当前所需端口|预览后开放网站及启用节点需要的公网端口|不会开放本机后端端口；不会自动关闭旧端口|write|firewall-sync
firewall|5|撤销本版托管规则|只撤销有本版归属记录、标识匹配的规则|外部规则和旧格式记录不盲目删除；可能改变可达性|danger|firewall-cleanup
firewall|0|返回上一级|不修改配置|已提交的配置保留|back|back
edge|1|查看网站防护|查看各站爬虫、限额、缓存及回源设置|只读；不显示节点凭据|read|edge-status
edge|2|应用均衡预设|AI爬虫拦截、5请求/秒、20并发、1小时缓存与gzip|仅网站内容；不主动开启源站封锁或强制AOP|write|edge-profile
edge|3|爬虫策略|选择 off、ai、common、all 的 UA 拦截|UA可伪造；all会影响搜索引擎、API及监控|warn|edge-bots
edge|4|请求、并发和下载限额|调整请求频率、突发、并发及每响应速度|同出口IP共享额度；不是全机或代理用户带宽配额|write|edge-limits
edge|5|静态缓存与 gzip|设置静态资源缓存头和站点压缩|不强制缓存HTML/动态应用/节点流量|write|edge-cache
edge|6|限制 Cloudflare 回源|仅允许已验证的 Cloudflare 网段访问网站/网关|需要橙云；直连将被拒绝，ACME路径保留|warn|edge-origin
edge|7|AOP 回源客户端证书|切换 off、observe、enforce|先观察并探测成功，再强制；误配会中断访问|warn|edge-aop
edge|8|AOP 公网验证|通过公开域名检查本次回源是否为 SUCCESS|域名已走橙云；源站须有有效证书且启用observe|read|edge-probe
edge|9|更新 Cloudflare 官方资料|刷新IPv4/IPv6网段与公共AOP CA|需联网；失败保留旧资料|write|edge-refresh
edge|10|Cloudflare 配置指引|输出控制台设置和节点路径缓存排除原则|只提供指引，不自动修改外部账户|read|edge-guide
edge|11|网卡流量采样|显示网卡累计流量和约1秒速率|为接口总流量，不是节点计费统计|read|edge-traffic
edge|12|重置单站防护|关闭该站新增爬虫、限流、缓存及回源限制|不删除网站、节点或证书；需确认|warn|edge-reset
edge|13|按字段编辑防护|逐项编辑单站点防护参数|适用于了解参数范围的用户；保存前验证|write|edge-edit
edge|0|返回上一级|不修改配置|已提交的配置保留|back|back
efficiency|1|资源预算与建议|结合物理内存、可用量及cgroup上限给出建议|只读；不按建议自动写配置|read|s3-perf-recommend
efficiency|2|预设差异预览|显示当前值与目标值，以及预计服务动作|需要可读配置；不保存、不重启|read|s3-profile-plan
efficiency|3|选择资源预设|节省资源、均衡或吞吐试验|列出将覆盖的参数；确认后一次应用|warn|perf-profile
efficiency|4|当前资源策略|显示保存的Nginx/Xray和日志设置|只读；不是进程内存硬上限|read|perf-show
efficiency|5|应用前差异预览|比较配置/证书/程序和服务单元|不启动测试实例，不重启/重载，不写状态|read|runtime-plan
efficiency|6|Xray空闲与缓冲|编号选择缓冲，设置双向空闲上限|修改需要重启Xray；缓冲不是TCP窗口|warn|perf-xray
efficiency|7|连接池与压缩|进入对应功能控制区|查看当前状态后按序号选择|nav|menu:perfparams
efficiency|8|轻量日志设置|进入对应功能控制区|查看当前状态后按序号选择|nav|menu:logging
efficiency|9|Swap 管理|进入对应功能控制区|查看当前状态后按序号选择|nav|menu:swap
efficiency|10|网站响应分阶段检查|按域名编号采样DNS/TCP/TLS/首字节/总时长|最多3次GET，不关闭TLS/AOP，不测速整条代理|read|s3-web-bench
efficiency|11|网卡流量采样|显示网卡累计流量和约1秒速率|为接口总流量，不是节点计费统计|read|edge-traffic
efficiency|0|返回上一级|不修改配置|已提交的配置保留|back|back
swap|1|Swap 状态|查看实际使用量、归属文件与启动配置|只读；不把磁盘交换区当成新增物理内存|read|swap-status
swap|2|启用 / 恢复 1 GiB Swap|已有托管 Swap 则恢复，不重复分配|新建需 ext4/XFS 等支持、足够磁盘及内核权限|warn|swap-enable
swap|3|自定义容量|创建 256–8192 MiB 的托管交换文件|256 的倍数；预留至少1GiB磁盘，不覆盖现有Swap|warn|swap-custom
swap|4|安全移除本工具 Swap|先检查可用内存，再停用并删除交换文件|内存不足或 swapoff 失败时保留文件和启动配置|danger|swap-remove
swap|0|返回上一级|不修改配置|已提交的配置保留|back|back
services|1|Nginx 服务控制|进入对应功能控制区|查看当前状态后按序号选择|nav|menu:nginxservice
services|2|Xray 服务控制|进入对应功能控制区|查看当前状态后按序号选择|nav|menu:xrayservice
services|3|证书/日志维护调度|进入对应功能控制区|查看当前状态后按序号选择|nav|menu:schedule
services|4|重启全部组件|按顺序重启已配置Xray、Nginx和维护定时器|先做语法检查；会中断连接；不重签证书|warn|service:all:restart
services|5|重启整台VPS系统|正常重启操作系统及全部应用|需输入REBOOT和yes；SSH将断开；先恢复未完成事务|danger|system-reboot
services|6|查看运行状态|查看组件版本、服务状态和 Worker 身份|只读；不显示节点凭据|read|status
services|7|近期服务变更原因|查看按需记录的动作和前后PID|只读；仅本版应用流程的服务变动|read|perf-events
services|0|返回上一级|不修改配置|已提交的配置保留|back|back
nginxservice|1|启动Nginx|显式执行start；动作前确认|共享Nginx影响全部网站；自启设置不立即启停|warn|service:nginx:start
nginxservice|2|停止Nginx|显式执行stop；动作前确认|共享Nginx影响全部网站；自启设置不立即启停|danger|service:nginx:stop
nginxservice|3|平滑重载Nginx|显式执行reload；动作前确认|共享Nginx影响全部网站；自启设置不立即启停|warn|service:nginx:reload
nginxservice|4|重启Nginx|显式执行restart；动作前确认|共享Nginx影响全部网站；自启设置不立即启停|warn|service:nginx:restart
nginxservice|5|启用开机自启Nginx|显式执行enable；动作前确认|共享Nginx影响全部网站；自启设置不立即启停|warn|service:nginx:enable
nginxservice|6|关闭开机自启Nginx|显式执行disable；动作前确认|共享Nginx影响全部网站；自启设置不立即启停|warn|service:nginx:disable
nginxservice|0|返回上一级|不修改配置|已提交的配置保留|back|back
xrayservice|1|启动Xray|显式执行start；动作前确认|实例重启影响所有代理；自启设置不立即启停|warn|service:xray:start
xrayservice|2|停止Xray|显式执行stop；动作前确认|实例重启影响所有代理；自启设置不立即启停|danger|service:xray:stop
xrayservice|3|重启Xray|显式执行restart；动作前确认|实例重启影响所有代理；自启设置不立即启停|warn|service:xray:restart
xrayservice|4|启用开机自启Xray|显式执行enable；动作前确认|实例重启影响所有代理；自启设置不立即启停|warn|service:xray:enable
xrayservice|5|关闭开机自启Xray|显式执行disable；动作前确认|实例重启影响所有代理；自启设置不立即启停|warn|service:xray:disable
xrayservice|0|返回上一级|不修改配置|已提交的配置保留|back|back
schedule|1|查看维护状态|显示本工具定时器与最近尝试/成功时间|不查询或删除其他程序的调度|read|s3-schedule-show
schedule|2|启动定时器|只控制vpskit-maintain.timer|关闭后本工具证书续期和日志检查停止；不改变外部ACME|warn|s3-schedule-start
schedule|3|停止定时器|只控制vpskit-maintain.timer|关闭后本工具证书续期和日志检查停止；不改变外部ACME|warn|s3-schedule-stop
schedule|4|启用维护自启|只控制vpskit-maintain.timer|关闭后本工具证书续期和日志检查停止；不改变外部ACME|warn|s3-schedule-enable
schedule|5|关闭维护自启|只控制vpskit-maintain.timer|关闭后本工具证书续期和日志检查停止；不改变外部ACME|warn|s3-schedule-disable
schedule|6|证书与续期检查|有效期、来源和常见重复cron引用|不打印DNS凭据；不能发现全部外部调度|read|cert-audit
schedule|7|立即检查日志大小|仅轮转达到阈值的本工具日志|不压缩、不重启；并发写入可能丢少量日志|warn|perf-rotate
schedule|0|返回上一级|不修改配置|已提交的配置保留|back|back
update|1|更新 Nginx|从发行版软件源更新独立二进制|需联网；可能重启 Nginx，网站连接可能中断|write|update-nginx
update|2|更新 Xray|选择固定版本或显式 latest|需联网；重启会中断代理连接，先核对客户端兼容性|write|update-xray
update|3|更新 ACME|更新证书工具，保留证书和账户资料|需联网；不会直接重新申请所有证书|write|update-acme
update|4|仅更新管理代码|校验完整脚本后替换代码并备份旧版|不改 state.json、不升级组件、不重启服务|write|update-manager
update|5|更新全部已安装组件|依次更新已安装的组件，再询问是否更新管理代码|逐组件提交；失败保留已完成更新，可能多次中断连接|warn|update-all
update|6|查询Xray最新正式版本|仅查询官方GitHub Release信息|需联网；不下载、不升级、不重启|read|provider-latest
update|0|返回上一级|不修改配置|已提交的配置保留|back|back
history|1|列出历史快照|显示快照时间、备注和版本|只读；快照含敏感凭据，不要公开|read|history-list
history|2|立即创建快照|保存当前配置、证书及ACME资料|当前state.json须有效；不备份网站内容|write|history-save
history|3|按范围恢复历史|编号选择状态、节点、网站、证书或参数|保留安装模式；共享全局参数不随历史覆盖|warn|history-restore
history|4|只恢复状态配置|使用历史节点/网站设置及当前证书重新生成|当前证书及组件必须满足历史配置要求|warn|history-state
history|5|仅恢复高级参数|取回旧的Nginx/Xray参数|保留当前节点、证书和网站；状态文件须有效|warn|history-advanced
history|6|未完成事务状态|查看阶段、受影响文件及外部编辑冲突|只读；不自动覆盖冲突|read|recovery-status
history|7|修复未完成事务|按本次事务记录恢复|不重置防火墙；冲突时保留现场|warn|repair
history|8|撤销最近阶段2事务|当前摘要仍匹配时精确回滚|可能重载服务；回滚前另存当前快照|warn|recovery-rollback
history|9|安装模式迁移|进入对应功能控制区|查看当前状态后按序号选择|nav|menu:migration
history|10|独立模式旧版本救援|进入对应功能控制区|查看当前状态后按序号选择|nav|menu:legacyrecovery
history|0|返回上一级|不修改配置|已提交的配置保留|back|back
legacyrecovery|1|强制恢复（原样或兼容）|按序号选择事务或快照，不重新生成代理配置|绕过未完成事务门禁；保留失败现场；不绕过语法检查|danger|recover
legacyrecovery|2|回滚最近事务|恢复旧版本最近事务；优先使用阶段2精确撤销|将重启之前运行的服务；需有最近事务备份|warn|rollback
legacyrecovery|3|简化重建 Nginx|当前备份→验证→只重建Nginx→成功后清旧历史|仅独立模式；重启Nginx，成功后清旧记录并保留本次备份|danger|rebuild
legacyrecovery|4|重建范围预览|查看仅重建Nginx的影响|只适用于独立模式，不切换服务|read|s3-rebuild-plan
legacyrecovery|0|返回上一级|不修改配置|已提交的配置保留|back|back
configsafe|1|候选配置检查|生成并校验完整候选配置，不发布|共享模式递归检查静态include；无需重启|read|config-check
configsafe|2|服务动作计划|查看无需动作、重载、重启和启动原因|只在临时目录生成；计划不是运行验收|read|config-plan
configsafe|3|脱敏差异摘要|显示摘要与监听协议，不打印密钥|不直接输出原始Xray配置|read|config-diff
configsafe|4|应用保存配置|校验后原子发布本项目配置|可能重启涉及组件；先确认动作计划|warn|apply
configsafe|5|未完成事务状态|查看阶段、受影响文件及外部编辑冲突|只读；不自动覆盖冲突|read|recovery-status
configsafe|6|修复未完成事务|按本次事务记录恢复|不重置防火墙；冲突时保留现场|warn|repair
configsafe|7|撤销最近阶段2事务|当前摘要仍匹配时精确回滚|可能重载服务；回滚前另存当前快照|warn|recovery-rollback
configsafe|8|按范围恢复历史|编号选择状态、节点、网站、证书或参数|保留安装模式；共享全局参数不随历史覆盖|warn|history-restore
configsafe|9|证书与续期检查|有效期、来源和常见重复cron引用|不打印DNS凭据；不能发现全部外部调度|read|cert-audit
configsafe|0|返回上一级|不修改配置|已提交的配置保留|back|back
status|1|查看运行状态|查看组件版本、服务状态和 Worker 身份|只读；不显示节点凭据|read|status
status|2|本机诊断|检查配置语法、权限、监听和服务进程|不能代替公网、CDN 或吞吐验收|read|doctor
status|3|运行摘要与问题提示|读取服务/端口/资源与内核计数，保留边界说明|不自动修复，不扫整个journal|read|s3-diagnostics-summary
status|4|导出默认脱敏诊断|只导出白名单结构化状态，不含配置/原始日志|仍需分享前核对；不包含域名/IP/UUID/token|write|s3-diagnostics-export
status|5|日志查看|进入对应功能控制区|查看当前状态后按序号选择|nav|menu:logview
status|6|低开销日志设置|进入对应功能控制区|查看当前状态后按序号选择|nav|menu:logging
status|7|近期服务变更原因|查看按需记录的动作和前后PID|只读；仅本版应用流程的服务变动|read|perf-events
status|8|DNS 与公网 HTTPS 检查|检查网站解析和公网响应，不修改 DNS|需网络；Cloudflare解析不必等于源站IP|read|network-check
status|9|证书与续期检查|有效期、来源和常见重复cron引用|不打印DNS凭据；不能发现全部外部调度|read|cert-audit
status|10|配置文件与目录|显示配置与资料保存位置|只显示路径；不要公开包含密钥的目录|read|paths
status|0|返回上一级|不修改配置|已提交的配置保留|back|back
logview|1|Nginx 错误日志|显示最近 Nginx 错误记录|只读；分享前删除敏感地址与路径|read|logs-nginx
logview|2|Xray 日志|显示最近代理运行错误记录|只读；分享前脱敏|read|logs-xray
logview|3|网站访问日志|显示高级配置中启用的访问日志|默认关闭；日志包含访客 IP 和访问路径|read|logs-access
logview|4|证书与维护日志|查看定时续期服务的近期 journal 记录|需要 systemd journal；分享前脱敏|read|logs-cert
logview|5|Nginx 服务日志|查看启动服务的标准输出和错误|日志尚不存在时只提示，不新建文件|read|logs-service
logview|6|启动失败诊断记录|查看最近一次预检或运行校验失败日志|只读；日志仅root可读；分享前脱敏|read|logs-diagnostics
logview|7|最近预检错误|读取有限行本工具预检诊断|可能含地址/路径；分享前脱敏|read|s3-log-preflight
logview|8|近期服务变更原因|查看按需记录的动作和前后PID|只读；仅本版应用流程的服务变动|read|perf-events
logview|0|返回上一级|不修改配置|已提交的配置保留|back|back
logging|1|网站轻量性能日志|关闭、故障、抽样或全部网站请求|代理路径默认不记录；无URL/IP/查询串，非完整审计日志|write|perf-logging
logging|2|日志保留阈值|设置触发值、保留尾部和份数|小时检查不是实时硬上限；旧字节会被丢弃|write|perf-retention
logging|3|立即检查日志大小|仅轮转达到阈值的本工具日志|不压缩、不重启；并发写入可能丢少量日志|warn|perf-rotate
logging|4|网站访问日志开关|开启或关闭低开销性能访问日志|true/false；按所选模式记录耗时，不记录IP和路径|write|param:access_log
logging|5|代理路径访问日志|默认关闭；按编号启停|全量代理日志可能产生额外写入，显式确认|warn|s3-proxy-log
logging|6|日志缓冲和抽样参数|设置缓冲、刷新间隔与正常请求抽样率|有界参数；缓冲未刷盘记录可能丢失|write|s3-log-tuning
logging|7|组件错误日志级别|保留warn/error等，不提供常驻debug|错误日志关闭会减少故障依据|warn|s3-error-log
logging|0|返回上一级|不修改配置|已提交的配置保留|back|back
housekeeping|1|扫描可清理项目|显示过期任务、旧诊断和可裁剪历史的大小|按需扫描；不自动删除，不跟随链接|read|s3-cleanup-scan
housekeeping|2|按类别清理过期文件|先列出具体候选，确认后删除|保留至少最近2份快照；有事务时禁止|danger|s3-cleanup-run
housekeeping|3|立即检查日志大小|仅轮转达到阈值的本工具日志|不压缩、不重启；并发写入可能丢少量日志|warn|perf-rotate
housekeeping|4|日志保留阈值|设置触发值、保留尾部和份数|小时检查不是实时硬上限；旧字节会被丢弃|write|perf-retention
housekeeping|5|未完成事务状态|查看阶段、受影响文件及外部编辑冲突|只读；不自动覆盖冲突|read|recovery-status
housekeeping|6|维护定时器|进入对应功能控制区|查看当前状态后按序号选择|nav|menu:schedule
housekeeping|7|配置文件与目录|显示配置与资料保存位置|只显示路径；不要公开包含密钥的目录|read|paths
housekeeping|0|返回上一级|不修改配置|已提交的配置保留|back|back
uninstall|1|安装模式与组件归属|查看路径、来源和托管范围|只读；不把外部组件冒认为本工具安装|read|provider-show
uninstall|2|停用服务，保留数据|独立模式停用保留数据；共享模式仅撤下项目Nginx片段|不会删除 Swap/防火墙；以后可用完整脚本 apply 恢复|warn|uninstall-keep
uninstall|3|仅移除VPSKit共享Nginx配置|保留共享程序、证书、节点和网站文件|VPSKit网站会停止；其他站点只经历reload|danger|provider-detach
uninstall|4|共享组件受限移除|进入对应功能控制区|查看当前状态后按序号选择|nav|menu:sharedremove
uninstall|5|独立组件卸载|进入对应功能控制区|查看当前状态后按序号选择|nav|menu:isolatedremove
uninstall|6|配置文件与目录|显示配置与资料保存位置|只显示路径；不要公开包含密钥的目录|read|paths
uninstall|7|卸载范围与阶段说明|说明配置、程序、数据的不同删除范围|共享程序/数据删除分别确认；不清外部账户|read|s3-help-uninstall
uninstall|0|返回上一级|不修改配置|已提交的配置保留|back|back
sharedremove|1|仅移除VPSKit共享Nginx配置|保留共享程序、证书、节点和网站文件|VPSKit网站会停止；其他站点只经历reload|danger|provider-detach
sharedremove|2|移除共享Nginx程序|通过APT移除；保留配置文件|必须先移除本工具片段；发现其他站点拒绝|danger|provider-remove-nginx
sharedremove|3|移除共享ACME程序|只删除本工具安装的程序，不删账户|需确认其他程序不用；自动续期未迁移时拒绝|danger|provider-remove-acme
sharedremove|0|返回上一级|不修改配置|已提交的配置保留|back|back
isolatedremove|1|单独卸载 Xray|删除代理节点和 Xray 程序，保留网站|所有代理用户断开；先导出需要保留的资料|danger|uninstall-xray
isolatedremove|2|单独卸载 Nginx|移除独立 Nginx，保留其他资料|存在网站或 TLS 网关节点依赖时拒绝执行|danger|uninstall-nginx
isolatedremove|3|单独卸载 ACME|删除自动证书工具及其账户资料|存在自动续期证书依赖时拒绝执行|danger|uninstall-acme
isolatedremove|4|完整卸载 VPSKit|清理本工具资料、服务、已识别规则与 Swap|需输入删除口令；备份也会删除，未知外部资料不接管|danger|uninstall-all
isolatedremove|0|返回上一级|不修改配置|已提交的配置保留|back|back
help|1|完整命令帮助|查看命令、兼容别名及调用示例|只读；命令行与面板共用后端|read|help
help|2|升级、恢复与安全说明|说明代码更新、配置应用、备份和权限边界|只读；历史快照不含网站内容和系统资源变更|read|workflow-help
help|3|面板颜色与操作提示|查看颜色含义、返回/取消及无颜色模式|支持 NO_COLOR 和 --no-color；日志不带颜色控制符|read|color-help
help|4|方案 A / B 说明|对比 REALITY 直连与网站 TLS/XHTTP|只读；帮助选择部署模式|read|explain
help|5|配置文件与目录|显示配置与资料保存位置|只显示路径；不要公开包含密钥的目录|read|paths
help|6|完整功能目录|显示16模块与子菜单树|只读；未实现项不作为可执行按钮|read|s3-tree
help|7|搜索菜单功能|只检索本地菜单名称/用途/要求|不联网，不搜索凭据或配置内容|read|s3-search
help|8|共享模式操作边界|说明站点设置与系统全局设置|共享卸载检查已发现依赖，但不能证明所有外部应用均未使用|read|s3-help-shared
help|9|性能和日志说明|说明节省资源与传输速度的取舍|不把监听/参数当成公网性能保证|read|s3-help-performance
help|0|返回上一级|不修改配置|已提交的配置保留|back|back
VPSKIT_STAGE3_MENU
}
menu_title() {
    case "$1" in
        main) printf '%s' '主面板';;
        install) printf '%s' '部署与安装模式';;
        installcomponents) printf '%s' '单独安装或补装组件';;
        providers) printf '%s' '模式与组件归属';;
        migration) printf '%s' '安装模式迁移';;
        nodes) printf '%s' '代理节点与用户';;
        legacy) printf '%s' '传统节点管理';;
        nodeedit) printf '%s' '编辑传统节点';;
        nodeexport) printf '%s' '节点导出';;
        native) printf '%s' '扩展原生节点管理';;
        websites) printf '%s' '网站与反向代理';;
        certificates) printf '%s' 'ACME 与 SSL 证书';;
        advanced) printf '%s' 'Nginx 高级配置';;
        worker) printf '%s' 'Worker 与启动权限';;
        nginxparams) printf '%s' 'HTTP / TLS / 超时参数';;
        perfparams) printf '%s' '连接复用与网站压缩';;
        xray) printf '%s' 'Xray 高级配置';;
        network) printf '%s' '网络与防火墙';;
        optimize) printf '%s' 'BBR / MTU / 网络优化';;
        firewall) printf '%s' '防火墙端口管理';;
        edge) printf '%s' 'Cloudflare 与网站防护';;
        efficiency) printf '%s' '性能与系统资源';;
        swap) printf '%s' 'Swap 虚拟内存';;
        services) printf '%s' '服务运行与重启';;
        nginxservice) printf '%s' 'Nginx 服务控制';;
        xrayservice) printf '%s' 'Xray 服务控制';;
        schedule) printf '%s' '证书和日志维护调度';;
        update) printf '%s' '组件与管理脚本更新';;
        history) printf '%s' '备份、恢复与迁移';;
        legacyrecovery) printf '%s' '独立模式旧版本救援';;
        configsafe) printf '%s' '配置生成与发布';;
        status) printf '%s' '运行状态与日志';;
        logview) printf '%s' '日志查看';;
        logging) printf '%s' '低开销日志设置';;
        housekeeping) printf '%s' '系统维护与垃圾清理';;
        uninstall) printf '%s' '卸载与组件移除';;
        sharedremove) printf '%s' '共享组件受限移除';;
        isolatedremove) printf '%s' '独立组件与完整卸载';;
        help) printf '%s' '帮助与使用说明';;
        *) return 1;;
    esac
}
# Stage 3: terminal-only navigation and one bounded, sanitized state snapshot.
# No network requests, sleeps, raw-log reads or periodic background monitors here.
S3_DETAILS=1
S3_PAGE_SIZE=12
S3_CATALOG=''
S3_RESOURCE_PROC='/proc'
S3_CGROUP_ROOT='/sys/fs/cgroup'
S3_RESOURCE_JSON=''
S3_PANEL_PAGE=0
s3_catalog_load() { [[ -n $S3_CATALOG ]] || S3_CATALOG=$(menu_catalog); }
s3_alias() {
    case "${1:-main}" in cert|certs) printf certificates;; performance) printf efficiency;;
        recovery) printf history;; advanced-nginx) printf advanced;; *) printf '%s' "${1:-main}";; esac
}
panel_clean() { local value="$*"; printf '%s' "${value//[[:cntrl:]]/}"; }
panel_put() {
    local key=$1 level=$2 value; shift 2; value="$*"
    PANEL_TEXT["$key"]=${value//[[:cntrl:]]/}; PANEL_LEVEL["$key"]=$level
}
panel_badge() {
    local key=$1 c=$YELLOW
    [[ -n ${PANEL_TEXT[$key]:-} ]] || return 0
    case ${PANEL_LEVEL[$key]:-warn} in good) c=$GREEN;; bad) c=$RED;; off) c=$DIM;; info) c=$CYAN;; esac
    printf '%s[当前：%s]%s' "$c" "${PANEL_TEXT[$key]}" "$RESET"
}
panel_read_state() {
    local kind key level value data
    PANEL_DATA=''
    command -v jq >/dev/null 2>&1 || { panel_put config warn '无法读取：缺少 jq'; return 0; }
    if [[ ! -r $STATE ]]; then
        if [[ -e $STATE || ( -d ${STATE%/*} && ! -x ${STATE%/*} ) || ( -d $ROOT && ! -x $ROOT ) ]]; then panel_put config warn '无权限读取（不是未配置）'
        else panel_put config off '尚未初始化'; fi
        return 0
    fi
    [[ -f $STATE && ! -L $STATE && $(stat -c %s "$STATE" 2>/dev/null) -le 16777216 ]] || { panel_put config bad '状态文件类型/大小异常'; return 0; }
    # One parse of state, one projection pass. Never cache raw credentials or tokens.
    if ! data=$(jq -ce --argjson nd "$(nginx_defaults)" --argjson xd "$(xray_defaults)" --argjson ld "$(logging_defaults)" '
      if .schema!=1 or (.nodes|type)!="array" or (.sites|type)!="array" or (.components|type)!="object" then error("state") else . end |
      . as $s | (.advanced.nginx // {}) as $n | (.native_nodes // []) as $native |
      {scheme:(.scheme // "A"),step:(.wizard.last_step // "未记录"),components:(.components|{nginx,xray,acme}),versions:((.versions // {})|{nginx,xray,acme}),
       nginx:(($nd*$n)|with_entries(select(.key as $k | ($nd|has($k)) or $k=="resolved_user" or $k=="resolved_uid")) |
         if ($n.access_log==true and ($n|has("access_log_mode")|not)) then .access_log_mode="full" else . end),
       xray:($xd*(.advanced.xray // {})|with_entries(select(.key as $k|$xd|has($k)))),
       logging:($ld*(.advanced.logging // {})|with_entries(select(.key as $k|$ld|has($k)))),
       xray_nofile:(.advanced.xray.nofile // 8192),gzip:(.performance.gzip // false),
       nodes:{total:((.nodes|length)+($native|length)),on:([(.nodes[],$native[])|select(.enabled==true)]|length),
         off:([(.nodes[],$native[])|select(.enabled!=true)]|length),legacy:(.nodes|length),native:($native|length),
         xhttp:([.nodes[]|select(.enabled==true and .mode=="xhttp")]|length)},
       sites:[.sites[]|(.protection // {}) as $p |
         {domain,kind:(.kind // "custom"),issued:(.issued==true),pending:(.cert_settings_pending==true),access:(.access // "direct"),
          bots:($p.bots // "off"),rate:($p.rate // 0),connections:($p.connections // 0),kbps:($p.kbps // 0),static_ttl:($p.static_ttl // 0),
          gzip:(if ($p|has("gzip")) then $p.gzip else ($s.performance.gzip // false) end),override:($p|has("gzip")),origin:($p.origin // false),aop:($p.aop // "off")}]
      }' "$STATE" 2>/dev/null); then panel_put config bad '损坏或字段异常；请从历史恢复'; return 0; fi
    PANEL_DATA=$data
    panel_put config good '已读取历史配置（未写入）'
    while IFS=$'\t' read -r kind key level value; do
        if [[ $kind == raw ]]; then PANEL_RAW["$key"]=$value; else panel_put "$key" "$level" "$value"; fi
    done < <(jq -r '
      def raw($k;$v): ["raw",$k,"-",($v|tostring)]; def text($k;$l;$v): ["text",$k,$l,$v];
      . as $d | .nodes as $n | (.sites|length) as $total |
      [.sites[]|select(.kind=="custom" or .kind=="template")] as $static |
      ([ $static[]|select(.gzip)]|length) as $gz |
      ((.nginx|to_entries[]|raw("cfg."+.key;.value)),
       (.nodes|to_entries[]|raw("nodes."+.key;.value)),raw("sites.total";$total),
       (.components|to_entries[]|raw("component."+.key;(.value==true))),
       (.versions|to_entries[]|raw("version."+.key;(.value // "未记录"))),
       text("nodes";"info";"配置启用 \($n.on) / \($n.total)；停用 \($n.off)；传统\($n.legacy)/原生\($n.native)"),
       text("sites";"info";"网站 \($total)；证书登记 \([.sites[]|select(.issued)]|length)（非有效期检查）"),
       text("wizard";"info";"方案 \(.scheme)；进度 \(.step)"),
       text("capacity";"info";"配置 Worker=\(.nginx.workers)；连接/Worker=\(.nginx.connections)；FD=\(.nginx.nofile)"),
       text("worker.config";"info";"配置账户 \(.nginx.resolved_user // .nginx.worker_user)（自动模式不创建账户）"),
       text("xray.nofile";"info";"保存值 \(.xray_nofile)；实际进程值未核验"),
       text("gzip";(if $gz>0 and $gz<($static|length) then "warn" elif .gzip then "good" else "off" end);
         "全局配置\(if .gzip then "开启" else "关闭" end)；静态站配置开启 \($gz)/\($static|length)（单站覆盖 \([$static[]|select(.override)]|length)）"),
       (.nginx|to_entries[]|.key as $k|.value as $v|
         text("param."+$k;(if ($v|type)=="boolean" then (if $v then "good" else "off" end) else "info" end);
         if ($v|type)=="boolean" then (if $v then "配置开启" else "配置关闭" end)
         elif $k=="worker_shutdown_timeout" and $v==0 then "配置关闭强制截止（0秒）"
         elif ($k=="upstream_keepalive" or $k=="xhttp_keepalive") and $v==0 then "配置关闭（0）"
         elif $k=="ssl_cache" or $k=="client_max_body_mb" then "保存值 \($v) MiB"
         elif $k=="ssl_timeout" then "保存值 \($v) 分钟"
         elif $k=="sandbox_mode" then "保存模式 \($v)（新配置仍要求非root Worker）"
         elif ($k|test("timeout$|^keepalive$|upstream_idle|access_log_flush")) then "保存值 \($v) 秒"
         else "保存值 \($v)" end)),
       text("edge.aop";"info";"配置强制 \([.sites[]|select(.aop=="enforce")]|length)；观察 \([.sites[]|select(.aop=="observe")]|length)；关闭 \([.sites[]|select(.aop=="off")]|length)"),
       ([ ["bots","爬虫策略",([.sites[]|select(.bots!="off")]|length)],
          ["limits","至少一项限额",([.sites[]|select(.rate>0 or .connections>0 or .kbps>0)]|length)],
          ["cache","静态缓存",([.sites[]|select((.kind=="custom" or .kind=="template") and .static_ttl>0)]|length)],
          ["origin","仅 Cloudflare 回源",([.sites[]|select(.origin)]|length)] ][] |
        text("edge."+.[0];(if .[2]==0 then "off" elif .[2]==$total then "good" else "warn" end);
          if $total==0 then "尚无网站" else "\(.[1])：\(if .[2]==0 then "配置全部关闭" elif .[2]==$total then "配置全部开启" else "部分配置开启" end)（\(.[2])/\($total)）" end)),
       text("efficiency";"info";"配置 Worker=\(.nginx.workers)，连接/Worker=\(.nginx.connections)，XHTTP池=\(.nginx.xhttp_keepalive)"),
       text("efficiency.xray";"info";"配置空闲=\(.xray.conn_idle)s，缓冲=\(.xray.buffer_kb)，错误日志=\(.xray.loglevel)"),
       text("efficiency.log";"info";if .nginx.access_log then "配置开启：\(.nginx.access_log_mode)，抽样参数\(.nginx.access_log_sample)%，\(.nginx.access_log_buffer_kb)KiB缓冲/\(.nginx.access_log_flush)s刷新" else "配置关闭；错误日志保留" end),
       text("efficiency.retention";"info";"配置阈值\(.logging.max_mb)MiB；每份尾部\(.logging.tail_kb)KiB×\(.logging.keep)；小时检查")
      )|@tsv' <<< "$PANEL_DATA")
    if [[ ${PANEL_RAW[nodes.xhttp]:-0} != 0 && ${PANEL_RAW[cfg.http2]:-} == false ]]; then
        panel_put param.http2 warn '网站开关关闭；启用的 XHTTP 会要求生成 HTTP/2 配置'
    fi
}
panel_efficiency() {
    [[ -n $PANEL_DATA ]] && return 0
    local key
    for key in efficiency efficiency.log efficiency.xray efficiency.retention; do panel_put "$key" warn '无可读配置'; done
}
panel_collect() {
    local group=${1:-all} k
    PANEL_TEXT=(); PANEL_LEVEL=(); PANEL_RAW=(); PANEL_DATA=''
    printf -v PANEL_TIME '%(%Y-%m-%d %H:%M:%S %Z)T' -1
    panel_read_state
    if [[ -z $PANEL_DATA ]]; then
        for k in nodes sites wizard capacity worker.config xray.nofile gzip edge.bots edge.limits edge.cache edge.origin edge.aop; do
            panel_put "$k" warn "无法确认：${PANEL_TEXT[config]}"
        done
    fi
    panel_services; panel_components; panel_resources
    # All badges in one drawing share a snapshot. Slow subsystems are on-demand.
    case "$group" in main|advanced|nginxparams|worker|nginxservice|services|status|efficiency|all) panel_workers;; esac
    case "$group" in main|network|optimize|efficiency|status|all) panel_bbr;; esac
    case "$group" in main|swap|efficiency|status|housekeeping|uninstall|all) panel_swap;; esac
    case "$group" in network|firewall|status|uninstall|all) panel_firewall;;
        *) panel_put firewall info '按需检查（网络/防火墙面板）'; panel_put firewall.rules info '按需检查归属';; esac
    # Never scan backup trees on every main-screen rendering.
    if [[ -e $ROOT/backup/transaction || -L $ROOT/backup/transaction ]]; then panel_put transaction bad '存在未完成事务；先恢复，禁止清理'
    else panel_put transaction good '未发现未完成事务'; fi
    case "$group" in history|configsafe|legacyrecovery|housekeeping|all) panel_history;;
        *) panel_put history info '进入备份面板时读取快照列表';; esac
    panel_put config.live warn '保存值不等于加载值；不声称已核验进程内全部配置'
    if [[ ${PANEL_RAW[nginx.active]:-} == inactive || ${PANEL_RAW[nginx.active]:-} == failed ]]; then panel_put config.live warn 'Nginx 未运行；保存开关目前不能提供服务'; fi
    if [[ $MODE == shared ]]; then
        panel_put capacity info '共享全局：不使用项目保存的Worker/连接数；请查看全局参数'
        panel_put worker.config info '共享模式复用系统Nginx账户；本页不改全局账户'
    fi
}
panel_extras() {
    local all_level=info level
    for level in "${PANEL_LEVEL[service.nginx]:-warn}" "${PANEL_LEVEL[service.xray]:-warn}"; do
        [[ $level != warn || $all_level == bad ]] || all_level=warn
        [[ $level != bad ]] || all_level=bad
    done
    panel_put services.all "$all_level" "Nginx：${PANEL_TEXT[service.nginx]:-未知}；Xray：${PANEL_TEXT[service.xray]:-未知}"
    panel_efficiency
    panel_put code info "当前代码 $VERSION（不联网查询）"
    panel_put mode info "${MODE:-isolated} / $NGINX_SERVICE"
    panel_put diagnostics info '按需读取诊断；不自动扫描日志'
    if [[ -e $ROOT/.uninstall-pending.json ]]; then panel_put uninstall bad '存在未完成卸载；查看收据后resume/restore'
    elif [[ -e $ROOT/.uninstalled.json ]]; then panel_put uninstall off '项目已停用/删除；保留独立卸载备份'
    else panel_put uninstall info '项目未标记卸载；先预览依赖，不默认删共享程序'; fi
    if command -v tracepath >/dev/null 2>&1; then panel_put tool.tracepath good 'tracepath 已安装；仅按需探测'
    else panel_put tool.tracepath warn 'tracepath 未安装；需 iputils-tracepath'; fi
    panel_put tool.traffic info '按需采样；不是常驻监控'
    panel_put cleanup info '先扫描再选择；事务/救援/证书和活动日志保留'
    if [[ -s $ROOT/config/edge/cf-v4.txt && -s $ROOT/config/edge/cf-v6.txt ]]; then panel_put edge.assets info '本地网段文件存在（时效未核验）'
    else panel_put edge.assets warn '本地网段文件缺失/不可读'; fi
}
panel_summary() {
    local group=${1:-main}
    ui_note "模式：$MODE；Nginx：$NGINX_SERVICE；采样：$PANEL_TIME"
    ui_note '同一画面共用采样；等待输入期间不自动采样；R 刷新状态。'
    panel_service_line nginx Nginx; panel_service_line xray Xray
    case "$group" in main|services|schedule|certificates|status|housekeeping|install) panel_service_line timer '证书/日志维护';; esac
    case "$group" in
        main) panel_line '配置' config; panel_line '节点' nodes; panel_line '网站' sites; panel_line '资源' resources; panel_line BBR bbr; panel_line '实际Worker' worker.actual;;
        advanced|nginxparams|worker|nginxservice) panel_line '容量' capacity; panel_line '实际Worker' worker.actual; panel_line '实际文件数' worker.fd; panel_line '配置说明' config.live;;
        nodes|legacy|native|nodeedit|nodeexport|xray) panel_line '全部节点' nodes; panel_line 'Xray策略' efficiency.xray; ui_note '配置启用和本机监听不能证明客户端连通；协议支持仍需实际核心和客户端核验。';;
        websites|certificates) panel_line '网站' sites; panel_line 'ACME程序' component.acme;;
        efficiency|perfparams|logging) panel_line '资源' resources; panel_line '资源策略' efficiency; panel_line 'Xray策略' efficiency.xray; panel_line '日志' efficiency.log; panel_line '日志保留' efficiency.retention;;
        optimize|network) panel_line BBR bbr; panel_line 'BBR归属' bbr.managed; panel_line '资源' resources; panel_line '防火墙' firewall;;
        firewall) panel_line '防火墙' firewall; panel_line '规则归属' firewall.rules; ui_note '未检查云安全组和全部外部nftables规则。';;
        swap) panel_line '系统Swap' swap; panel_line '托管Swap' swap.managed; panel_line '资源' resources;;
        edge) panel_site_table;;
        history|legacyrecovery|configsafe|housekeeping) panel_line '事务' transaction; panel_line '历史' history;;
        providers|installcomponents|update|uninstall|sharedremove|isolatedremove) panel_line 'Nginx' component.nginx; panel_line 'ACME' component.acme; panel_line 'Xray' component.xray; panel_line '卸载状态' uninstall;;
        status|services) panel_line '实际Worker' worker.actual; panel_line '配置说明' config.live;;
    esac
    [[ ${PANEL_LEVEL[transaction]:-} != bad ]] || panel_line '待处理' transaction
    if [[ $MODE == shared ]]; then ui_note '共享实例：只修改项目配置；全局并发和共享服务操作需额外确认。'; fi
}
panel_route_key() {
    case "$1" in
        s4-*|menu:uninstall|menu:sharedremove) printf uninstall;;
        s3-node-*|native-*|menu:legacy|menu:native|menu:nodeedit|menu:nodeexport) printf nodes;;
        menu:network) printf bbr;; menu:certificates|cert-audit) printf sites;; menu:logging|s3-log-*|s3-proxy-log|s3-error-log|s3-xray-log) printf efficiency.log;;
        menu:providers|menu:migration|provider-*|mode-*) printf mode;;
        menu:xray) printf efficiency.xray;; menu:housekeeping|s3-cleanup-*) printf cleanup;;
        menu:nginxservice) printf service.nginx;; menu:xrayservice) printf service.xray;;
        menu:schedule|s3-schedule-*) printf service.timer;;
        s3-perf-*|s3-profile-plan|s3-web-bench) printf resources;;
        s3-diagnostics-*|s3-log-preflight) printf diagnostics;;
        menu:worker) printf worker.actual;; config-*|menu:configsafe|shared-global-*) printf config.live;;
        recovery-*|history-restore) printf transaction;;
        *) s3_prev_panel_route_key "$@";;
    esac
}
s3_route_disabled() {
    local route=$1
    if [[ $MODE == shared ]]; then
        case "$route" in
            advanced-capacity|advanced-user|advanced-preflight|param:sandbox_mode|param:worker_shutdown_timeout)
                printf '共享模式需由系统管理；容量请使用共享全局授权入口'; return 0;;
            rebuild|s3-rebuild-plan|recover|rollback|uninstall-all)
                printf '此旧流程仅限独立模式；请使用阶段2范围恢复/共享组件移除'; return 0;;
        esac
    else
        case "$route" in shared-global-*|provider-detach|provider-remove-*) printf '仅共享模式可用'; return 0;; esac
    fi
    return 1
}
menu_render() {
    local group; group=$(s3_alias "${1:-main}")
    local rg number title desc req risk route c badge key disabled ordinal=0 total=0 first=1 last=99999 page=${S3_PANEL_PAGE:-0} heading
    heading=$(menu_title "$group") || return 1
    s3_catalog_load
    if [[ ${2:-} != cached ]]; then panel_collect "$group"; panel_extras; fi
    ui_title "VPSKit $VERSION  |  $heading"; panel_summary "$group"
    ui_note '蓝色=选项  绿色=只读/正常  黄色=注意  红色=危险  灰色=说明/关闭'
    while IFS='|' read -r rg number title desc req risk route; do [[ $rg != "$group" || $number == 0 ]] || total=$((total+1)); done <<< "$S3_CATALOG"
    if [[ ${S3_PAGED:-no} == yes && $group != main ]]; then
        ((page*S3_PAGE_SIZE<total)) || page=0
        first=$((page*S3_PAGE_SIZE+1)); last=$((first+S3_PAGE_SIZE-1))
    fi
    while IFS='|' read -r rg number title desc req risk route; do
        [[ $rg == "$group" ]] || continue
        if [[ $number != 0 ]]; then ordinal=$((ordinal+1)); ((ordinal>=first && ordinal<=last)) || continue; fi
        c=$BLUE; badge='修改'
        case "$risk" in read) c=$GREEN; badge='只读';; nav) badge='菜单';; warn) c=$YELLOW; badge='注意';; danger) c=$RED; badge='危险';; sensitive) c=$YELLOW; badge='敏感';; back) c=$DIM; badge='返回';; esac
        disabled=''; if disabled=$(s3_route_disabled "$route"); then c=$DIM; badge='当前不可用'; fi
        printf '  %s%2s.%s %s%s%s %s[%s]%s' "$BLUE" "$number" "$RESET" "$c" "$title" "$RESET" "$c" "$badge" "$RESET"
        key=$(panel_route_key "$route"); [[ -z $key ]] || { printf '  '; panel_badge "$key"; }
        printf '\n'
        if [[ ${S3_DETAILS:-1} == 1 ]]; then printf '      %s用途：%s  |  要求：%s%s\n' "$DIM" "$desc" "$req" "$RESET"; fi
        [[ -z $disabled ]] || ui_note "$disabled"
    done <<< "$S3_CATALOG"
    if [[ $last != 99999 && $total -gt $S3_PAGE_SIZE ]]; then ui_note "第$((page+1))/$(((total+S3_PAGE_SIZE-1)/S3_PAGE_SIZE))页；N 下一页 / P 上一页；其他页序号也可直接输入。"; fi
    ui_note '序号进入；R刷新；D展开/折叠说明；/关键词搜索；H主页；0返回；:q退出。'
}
menu_preview() {
    local group=${1:-main} g
    local S3_PAGED=no S3_DETAILS=1
    s3_catalog_load
    if [[ $group == all ]]; then
        panel_collect all; panel_extras
        while IFS= read -r g; do menu_render "$g" cached; done < <(printf '%s\n' "$S3_CATALOG" | cut -d'|' -f1 | awk '!seen[$0]++')
    else menu_render "$group" || die '未知面板；preview all 查看全部。'; fi
}
status_dashboard() {
    local group; group=$(s3_alias "${1:-main}")
    menu_title "$group" >/dev/null || die '未知状态面板。'
    panel_collect "$group"; panel_extras
    ui_title "VPSKit $VERSION  |  运行状态 · $(menu_title "$group")"; panel_summary "$group"
}
menu_group() {
    local group option route reason total page=0 selected g n title desc req risk key
    group=$(s3_alias "${1:-main}"); menu_title "$group" >/dev/null || die '未知菜单。'
    local -a stack=(); local S3_PAGED=yes
    s3_catalog_load
    while :; do
        S3_PANEL_PAGE=$page; menu_render "$group"
        ask option '请选择序号（R刷新 / H主页 / 0返回）' 0
        case "$option" in
            R|r) continue;; D|d) S3_DETAILS=$((1-S3_DETAILS)); continue;;
            H|h) group=main; stack=(); page=0; continue;;
            N|n|P|p)
                total=$(printf '%s\n' "$S3_CATALOG" | awk -F'|' -v g="$group" '$1==g&&$2!="0"{n++}END{print n+0}')
                if [[ $option == N || $option == n ]]; then (( (page+1)*S3_PAGE_SIZE>=total )) || page=$((page+1)); else ((page==0)) || page=$((page-1)); fi
                continue;;
            /*)
                s3_menu_search "${option:1}"
                continue;;
            0)
                if ((${#stack[@]})); then group=${stack[-1]}; unset 'stack[-1]'; page=0; continue; fi
                return 0;;
        esac
        [[ $option =~ ^[1-9][0-9]{0,2}$ ]] || { warn '请输入有效序号；或 /关键词 查找功能。'; continue; }
        route=''
        while IFS='|' read -r g n title desc req risk key; do [[ $g != "$group" || $n != "$option" ]] || { route=$key; break; }; done <<< "$S3_CATALOG"
        [[ -n $route ]] || { warn '该序号不存在。'; continue; }
        if reason=$(s3_route_disabled "$route"); then warn "$reason"; continue; fi
        if [[ $route == menu:* ]]; then stack+=("$group"); group=${route#menu:}; page=0; continue; fi
        menu_dispatch "$route"
    done
}
s3_menu_search() {
    local query=${1:-} g n title desc req risk route count=0
    [[ -n $query && ${#query} -le 80 && $query != *[[:cntrl:]]* ]] || { ui_note '格式：/关键词，例如 /BBR、/证书、/连接池'; return 0; }
    s3_catalog_load
    while IFS='|' read -r g n title desc req risk route; do
        [[ $n != 0 && $g != main ]] || continue
        if [[ $title == *"$query"* || $desc == *"$query"* || $req == *"$query"* ]]; then
            printf '  %s → %s. %s\n' "$(menu_title "$g")" "$n" "$title"
            count=$((count+1)); ((count<30)) || { ui_note '最多显示30项，请使用更具体关键词。'; break; }
        fi
    done <<< "$S3_CATALOG"
    ((count>0)) || ui_note '未找到匹配菜单。'
    return 0
}
s3_menu_tree() {
    local g n title desc req risk route child
    s3_catalog_load
    printf 'VPSKit %s 功能目录（0返回，R刷新，H主页）\n' "$VERSION"
    declare -gA S3_TREE_SEEN=()
    s3_tree_group main '' ' main '
}
s3_tree_group() {
    local group=$1 prefix=$2 visited=$3 g n title desc req risk route child
    S3_TREE_SEEN["$group"]=1
    while IFS='|' read -r g n title desc req risk route; do
        [[ $g == "$group" && $n != 0 ]] || continue
        printf '%s%s. %s\n' "$prefix" "$n" "$title"
        if [[ $route == menu:* ]]; then
            child=${route#menu:}
            if [[ ${S3_TREE_SEEN[$child]:-0} == 1 ]]; then printf '%s   ↳ 已在上层目录列出\n' "$prefix"
            else s3_tree_group "$child" "$prefix   " "$visited$child "; fi
        fi
    done <<< "$S3_CATALOG"
}

s3_resources() {
    local total=0 avail=0 swap_total=0 swap_free=0 cpus=1 limit=0 headroom=0 cgroup=no path='' dir v used quota period budget depth=0
    local vals
    if vals=$(awk '/^MemTotal:/{t=$2}/^MemAvailable:/{a=$2}/^SwapTotal:/{s=$2}/^SwapFree:/{f=$2}END{if(t>0)printf "%.0f %.0f %.0f %.0f",t*1024,a*1024,s*1024,f*1024;else exit 1}' "$S3_RESOURCE_PROC/meminfo" 2>/dev/null); then
        read -r total avail swap_total swap_free <<< "$vals"
    fi
    cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 1); number "$cpus" 1 65536 || cpus=1
    limit=$total; headroom=$avail
    # Detect cgroup-v2 limits, including a parent cap. Namespace-relative roots and
    # unknown v1 paths fall back to the visible root, never escape it via ../.
    if [[ -r $S3_RESOURCE_PROC/self/cgroup ]]; then
        path=$(awk -F: '$1=="0"&&$2==""{print $3;exit}' "$S3_RESOURCE_PROC/self/cgroup")
    fi
    if [[ $path == /* && $path != *'..'* && $path != *[[:cntrl:]]* && -d $S3_CGROUP_ROOT$path ]]; then dir="$S3_CGROUP_ROOT${path%/}"; else dir=$S3_CGROUP_ROOT; fi
    while [[ $dir == "$S3_CGROUP_ROOT" || $dir == "$S3_CGROUP_ROOT/"* ]] && ((depth<48)); do
        depth=$((depth+1))
        if [[ -r $dir/memory.max ]] && IFS= read -r v < "$dir/memory.max" && [[ $v =~ ^[0-9]{1,18}$ ]] && ((v>0)); then
            cgroup=yes
            ((limit>0 && limit<=v)) || limit=$v
            if [[ -r $dir/memory.current ]] && IFS= read -r used < "$dir/memory.current" && [[ $used =~ ^[0-9]{1,18}$ ]]; then
                budget=$((v>used?v-used:0)); ((budget>=headroom)) || headroom=$budget
            fi
        fi
        if [[ -r $dir/cpu.max ]] && read -r quota period < "$dir/cpu.max" && [[ $quota =~ ^[0-9]{1,18}$ && $period =~ ^[0-9]{1,18}$ ]] && ((quota>0&&period>0)); then
            budget=$(((quota+period-1)/period)); ((budget>=cpus)) || cpus=$budget
        fi
        [[ $dir != "$S3_CGROUP_ROOT" ]] || break
        dir=${dir%/*}
    done
    ((headroom<=limit || limit==0)) || headroom=$limit
    jq -nc --argjson total "$total" --argjson available "$avail" --argjson limit "$limit" --argjson headroom "$headroom" \
      --argjson st "$swap_total" --argjson sf "$swap_free" --argjson cpus "$cpus" --arg cg "$cgroup" \
      '{physical_bytes:$total,available_bytes:$available,effective_limit_bytes:$limit,headroom_bytes:$headroom,swap_used_bytes:([$st-$sf,0]|max),cpus:$cpus,cgroup_v2_limit:($cg=="yes"),recommendation:(if $limit==0 then "unknown" elif $limit<805306368 then "eco" else "balanced" end)}'
}
s3_performance_recommend() {
    local r; r=$(s3_resources) || die '无法读取资源。'
    ui_title '资源预算与建议（不自动应用）'
    jq -r '"物理内存：\((.physical_bytes/1048576)|floor) MiB；有效可见上限：\((.effective_limit_bytes/1048576)|floor) MiB",
      "当前可用/约束余量：\((.headroom_bytes/1048576)|floor) MiB；Swap已用：\((.swap_used_bytes/1048576)|floor) MiB",
      "CPU预算：\(.cpus)；检测到cgroup-v2内存限制：\(.cgroup_v2_limit)","建议起点：\(.recommendation)（不是自动调参或速度保证）"' <<< "$r"
    if state_basic "$STATE" 2>/dev/null; then
        local d w pool
        d=$(nginx_settings); w=$(jq -r .workers <<< "$d")
        if [[ $MODE == shared ]]; then ui_note '共享全局Worker未按项目保存值推断；请先查看 shared-global show。'
        else
            [[ $w != auto ]] || w=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 1)
            number "$w" 1 65536 || w=1
            pool=$(jq -nr --argjson w "$w" --argjson n "$d" --slurpfile s "$STATE" \
              '$s[0] as $s | ([ $s.sites[]|select((.upstream // "")!="") ]|length) as $web |
              ([ $s.nodes[]|select(.enabled and .mode=="xhttp") ]|unique_by(.entry)|length) as $xh |
              "按保存配置估算：连接槽位 \($w*$n.connections)；上游空闲池上限约 \($w*($web*$n.upstream_keepalive+$xh*$n.xhttp_keepalive))（不含活动上游连接）"')
            ui_note "$pool"
        fi
    fi
    ui_note 'Swap不是物理内存；空闲池只限制空闲连接。Xray内部缓冲不是每条连接总内存硬上限。'
    ui_note '建议依据可见资源，不检测所有宿主机/容器限制；吞吐预设仅显式试验。未改BBR、MTU、协议或公网API。'
}
declare -a S3_PROFILE_ARGS=()
s3_profile_args() {
    local profile=$1 workers=1 buffer=auto key i
    S3_PROFILE_ARGS=(nginx.access_log false nginx.proxy_access_log false)
    case "$profile" in
        eco)
            case $(uname -m) in aarch64|arm64) buffer=4;; *) buffer=32;; esac
            S3_PROFILE_ARGS+=(nginx.workers 1 nginx.connections 1024 nginx.nofile 8192 nginx.keepalive 15 nginx.ssl_cache 2 nginx.upstream_keepalive 2 nginx.xhttp_keepalive 2 nginx.gzip_level 1 nginx.error_log_level error xray.nofile 8192 xray.conn_idle 300 xray.buffer_kb "$buffer" xray.loglevel error);;
        balanced)
            S3_PROFILE_ARGS+=(nginx.workers 1 nginx.connections 1024 nginx.nofile 8192 nginx.keepalive 20 nginx.ssl_cache 4 nginx.upstream_keepalive 4 nginx.xhttp_keepalive 4 nginx.gzip_level 2 nginx.error_log_level warn xray.nofile 8192 xray.conn_idle 600 xray.buffer_kb auto xray.loglevel warning);;
        throughput)
            workers=$(s3_resources | jq -r '.cpus'); number "$workers" 1 65536 || workers=1; ((workers<=4)) || workers=4
            S3_PROFILE_ARGS+=(nginx.workers "$workers" nginx.connections 2048 nginx.nofile 16384 nginx.keepalive 30 nginx.ssl_cache 8 nginx.upstream_keepalive 8 nginx.xhttp_keepalive 8 nginx.gzip_level 2 nginx.error_log_level warn xray.nofile 16384 xray.conn_idle 600 xray.buffer_kb 256 xray.loglevel warning);;
        *) die '预设为eco/balanced/throughput。';;
    esac
    if [[ $MODE == shared ]]; then
        local -a filtered=()
        for ((i=0;i<${#S3_PROFILE_ARGS[@]};i+=2)); do
            key=${S3_PROFILE_ARGS[i]}
            case "$key" in nginx.workers|nginx.connections|nginx.nofile) continue;; esac
            filtered+=("$key" "${S3_PROFILE_ARGS[i+1]}")
        done
        S3_PROFILE_ARGS=("${filtered[@]}")
    fi
}
performance_profile() {
    local profile=${1:-} option=${2:-} candidate="$WORK/profile-candidate.json" current target i
    [[ -z $option || $option == --plan ]] || die '用法：performance profile [eco|balanced|throughput] [--plan]。'
    if [[ -z $profile ]]; then select_value profile '选择预设（随后预览差异，不自动保存）' balanced \
        'eco|节省资源：小连接池、较小缓冲、较短空闲回收' 'balanced|均衡：保留警告日志，连接复用适中' 'throughput|吞吐试验：增加内存/连接开销，不保证更快'; fi
    s3_profile_args "$profile"
    [[ $profile != throughput ]] || warn '吞吐试验增加内存占用；低内存VPS建议先使用eco/balanced。'
    cp "$STATE" "$candidate"
    for ((i=0;i<${#S3_PROFILE_ARGS[@]};i+=2)); do advanced_assign "$candidate" "${S3_PROFILE_ARGS[i]}" "${S3_PROFILE_ARGS[i+1]}"; done
    validate_advanced "$candidate"
    current=$(jq -nc --argjson n "$(nginx_settings)" --argjson x "$(xray_settings)" '{nginx:$n,xray:$x}')
    target=$(jq -nc --argjson n "$(nginx_settings "$candidate")" --argjson x "$(xray_settings "$candidate")" '{nginx:$n,xray:$x}')
    ui_title "资源预设：$profile（保存值 → 目标值）"
    jq -nr --argjson a "$current" --argjson b "$target" '
      $b|paths(scalars) as $p | ($b|getpath($p)) as $v | ($a|getpath($p)) as $old |
      select($v!=$old) | "  \($p|join("."))：\($old) → \($v)"'
    [[ $MODE != shared ]] || ui_note '共享模式跳过系统全局Worker、连接总量和全局文件数；外部站点设置不变。'
    if [[ $option == --plan ]]; then
        (STATE=$candidate; runtime_plan_command)
        ui_note '预览未保存、未应用。真正执行仍需重新验证。'
        return 0
    fi
    advanced_set "${S3_PROFILE_ARGS[@]}"
}
s3_log_tuning() {
    local sample buffer flush
    ask_valid sample '正常网站请求抽样比例（1～100%）' "$(ng_value access_log_sample)" number 1 100
    ask_valid buffer '访问日志缓冲（4～64KiB）' "$(ng_value access_log_buffer_kb)" number 4 64
    ask_valid flush '缓冲最长刷新间隔（1～300秒）' "$(ng_value access_log_flush)" number 1 300
    advanced_set nginx.access_log_sample "$sample" nginx.access_log_buffer_kb "$buffer" nginx.access_log_flush "$flush"
}
s3_error_log() {
    local ng xr
    select_value ng 'Nginx项目错误日志级别' "$(ng_value error_log_level)" 'warn|warn：保留警告（默认）' 'error|error：只记错误' 'crit|crit：只记严重问题'
    select_value xr 'Xray错误日志级别' "$(xray_settings | jq -r .loglevel)" 'warning|warning：保留警告（默认）' 'error|error：只记错误' 'none|none：关闭，丢失诊断信息'
    advanced_set nginx.error_log_level "$ng" xray.loglevel "$xr"
}
s3_xray_log() {
    local xr
    select_value xr 'Xray错误日志级别' "$(xray_settings | jq -r .loglevel)" 'warning|warning：保留警告' 'error|error：只记错误' 'none|none：关闭错误日志'
    advanced_set xray.loglevel "$xr"
}
s3_web_bench() {
    local domain=${1:-} count=${2:-3} scheme=http row rc i
    site_select domain "$domain"
    number "$count" 1 3 || die '最多执行3次采样。'
    [[ $(jq -r --arg d "$domain" '.sites[]|select(.domain==$d)|.issued' "$STATE") != true ]] || scheme=https
    ui_note '只GET项目网站首页，最多1MiB/15秒；不跟随重定向、不跳过TLS验证，不测整条代理吞吐。'
    printf '序号\tHTTP\tDNS累计\tTCP累计\tTLS累计\t首字节累计\t总耗时\tcurl退出码\n'
    for ((i=1;i<=count;i++)); do
        rc=0
        row=$(curl --noproxy '*' --proto '=http,https' --silent --show-error --connect-timeout 5 --max-time 15 --max-filesize 1048576 \
            --user-agent 'VPSKit-Diagnostic/1.0' -o /dev/null -w '%{http_code}\t%{time_namelookup}\t%{time_connect}\t%{time_appconnect}\t%{time_starttransfer}\t%{time_total}' "$scheme://$domain/") || rc=$?
        printf '%s\t%s\t%s\n' "$i" "$row" "$rc"
    done
    ui_note '这些时间从请求开始累计；首字节不是纯后端时间。403/AOP拒绝不等于服务器慢。请在实际客户端网络另行比较。'
}
s3_schedule_show() {
    status_dashboard schedule
    local f="$ROOT/data/maintenance-epochs.json"
    if [[ -f $f && ! -L $f && -r $f && $(stat -c %s "$f") -lt 65536 ]]; then
        jq '{cert_attempt,cert_success,edge_attempt}' "$f"; ui_note '时间值为Unix秒；没有字段表示尚未记录，不等于任务关闭。'
    fi
}
service_control() {
    local name=${1:-} action=${2:-} unit
    if choice "$name" 'start stop restart reload enable disable'; then local tmp=$name; name=$action; action=$tmp; fi
    if [[ $name == timer || $action == enable || $action == disable ]]; then
        choice "$name" 'nginx xray timer' && choice "$action" 'enable disable start stop restart' || die '服务控制参数无效。'
        case "$name" in nginx) unit=$NGINX_SERVICE;; xray) unit=vpskit-xray.service;; timer) unit=vpskit-maintain.timer;; esac
        if [[ $unit != nginx.service ]]; then
            [[ -f $SYSTEMD/$unit && ! -L $SYSTEMD/$unit ]] && grep -Fq '# VPSKIT_OWNED' "$SYSTEMD/$unit" || die '服务归属不匹配；未操作。'
        else systemctl cat nginx.service >/dev/null || die '共享nginx.service不存在。'; fi
        if [[ $name == timer && ( $action == stop || $action == disable ) ]]; then warn '这会停止或阻止下次开机的VPSKit证书/日志维护；不影响其他ACME任务。'; fi
        [[ $unit != nginx.service ]] || warn '共享服务的自启状态影响其他共享网站。'
        confirm "对$unit执行$action；enable/disable只改自启，不立即启停" || return 0
        systemctl "$action" "$unit" || die '服务操作失败，未保存偏好。'
        local pref=enabled value=false
        case "$action" in enable) value=true;; disable) value=false;; start|restart) pref=active; value=true;; stop) pref=active; value=false;; esac
        json_update --arg n "$name" --arg k "$pref" --argjson v "$value" '.preferences.services[$n][$k]=$v'
        ok '服务操作已完成并保存偏好；enable/disable不隐含立即启停。'
        return 0
    fi
    s3_prev_service_control "$name" "$action"
}
s3_node_rows() {
    jq -c '[.nodes|to_entries[]|{kind:"legacy",index:.key,id:.value.id,enabled:.value.enabled,protocol:(.value.protocol+"/"+.value.mode),port:.value.port,network:(if .value.mode=="ss" then "tcp,udp" else "tcp" end),gateway:(.value.mode=="ws" or .value.mode=="xhttp")}] +
      [(.native_nodes // [])|to_entries[]|{kind:"native",index:.key,id:.value.id,enabled:.value.enabled,protocol:.value.inbound.protocol,port:.value.inbound.port,network:.value.network,gateway:false}]' "$STATE"
}
s3_node_overview() {
    state_basic "$STATE" || die '没有可读节点状态。'
    local tcp='' udp='' tcpok=yes udpok=yes rows line number name protocol port network enabled gateway kind status tp up
    rows=$(s3_node_rows)
    tcp=$(panel_exec ss -H -lnt 2>/dev/null) || tcpok=no
    udp=$(panel_exec ss -H -lnu 2>/dev/null) || udpok=no
    tcp=$(awk '{n=split($4,a,":");print a[n]}' <<< "$tcp" | sort -u)
    udp=$(awk '{n=split($4,a,":");print a[n]}' <<< "$udp" | sort -u)
    printf '统一序号\t类型\t名称\t协议/传输\t本机端口\t配置状态\t监听观察\n'
    while IFS=$'\t' read -r number kind name protocol port network enabled gateway; do
        [[ -n $number ]] || continue
        tp=''; up=''; status=''
        if [[ $network == *tcp* ]]; then
            if [[ $tcpok != yes ]]; then tp='TCP未知'; elif [[ $'\n'$tcp$'\n' == *$'\n'"$port"$'\n'* ]]; then tp='TCP有监听'; else tp='TCP未观察到'; fi
        fi
        if [[ $network == *udp* ]]; then
            if [[ $udpok != yes ]]; then up='UDP未知'; elif [[ $'\n'$udp$'\n' == *$'\n'"$port"$'\n'* ]]; then up='UDP有监听'; else up='UDP未观察到'; fi
        fi
        [[ $gateway != true ]] || port="$port(本机后端)"
        status=停用; [[ $enabled != true ]] || status=启用
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s %s\n' "$number" "$kind" "$(panel_clean "$name")" "$(panel_clean "$protocol")" "$port" "$status" "$tp" "$up"
    done < <(jq -r 'to_entries[]|[(.key+1),.value.kind,.value.id,.value.protocol,.value.port,.value.network,.value.enabled,.value.gateway]|@tsv' <<< "$rows")
    ui_note '统一序号仅用于总览和batch-all；旧node/native命令仍使用各自编号。本机端口存在不证明属于此节点或公网可达。'
}
s3_node_batch() {
    local action=${1:-} selection=${2:-} rows total index indices candidate="$WORK/unified-node-batch.json" enabled=false
    [[ -n $action ]] || select_value action '统一批量节点操作' enable 'enable|启用所选节点' 'disable|停用所选节点'
    choice "$action" 'enable disable' || die '仅支持enable/disable。'
    s3_node_overview; rows=$(s3_node_rows); total=$(jq length <<< "$rows")
    ((total>0)) || die '没有节点。'
    [[ -n $selection ]] || ask selection '输入统一序号，逗号分隔；0取消' 0
    [[ $selection != 0 ]] || return 0
    selection=${selection//[[:space:]]/}
    [[ ${#selection} -le 4096 && $selection =~ ^[1-9][0-9]*(,[1-9][0-9]*)*$ ]] || die '统一序号格式无效。'
    local -a list=(); IFS=, read -r -a list <<< "$selection"
    for index in "${list[@]}"; do number "$index" 1 "$total" || die '统一序号越界。'; done
    indices=$(printf '%s\n' "${list[@]}" | jq -sc 'map(tonumber-1)|unique')
    [[ $action != enable ]] || enabled=true
    jq --argjson rows "$rows" --argjson ids "$indices" --argjson en "$enabled" '
      reduce $ids[] as $id (.; $rows[$id] as $r |
        if $r.kind=="legacy" then .nodes[$r.index].enabled=$en else .native_nodes[$r.index].enabled=$en end)' "$STATE" > "$candidate"
    if json_equal "$candidate" "$STATE"; then ok '全部所选节点已是目标状态；未创建事务或操作服务。'; return; fi
    validate_state "$candidate"
    confirm "对$(jq length <<< "$indices")个传统/原生节点执行$action；一次提交，可能重启整个Xray实例" || return 0
    begin_tx "unified-node-batch:$action"
    install -m 600 "$candidate" "$STATE"
    apply_config; commit_tx
    recovery_firewall check || true
}
# Explicit autostart/timer choices survive subsequent ordinary config applies.
# Never use a global systemctl wrapper: manual actions and external services retain
# their actual systemd semantics. A false preference prevents automatic enabling;
# it does not undo a later administrator action outside this manager.
s3_service_preference() {
    local name=$1 key=$2
    jq -er --arg name "$name" --arg key "$key" '
      (.preferences.services[$name] // {}) as $p |
      if ($p|has($key)|not) then true elif ($p[$key]|type)=="boolean" then $p[$key] else error("invalid service preference") end
      | tostring' "$STATE"
}
s3_auto_enable() {
    local unit=$1 name
    case "$unit" in nginx.service|vpskit-nginx.service) name=nginx;; vpskit-xray.service) name=xray;; *) return 1;; esac
    local enabled; enabled=$(s3_service_preference "$name" enabled) || die '服务自启偏好损坏；未自动覆盖。'
    if [[ $enabled == true ]]; then systemctl enable "$unit" || return $?; fi
    return 0
}
s3_timer_reconcile() {
    local changed=${1:-no} enabled active running=no boot=no action
    enabled=$(s3_service_preference timer enabled) || die '维护自启偏好损坏。'
    active=$(s3_service_preference timer active) || die '维护运行偏好损坏。'
    if systemctl is-enabled --quiet vpskit-maintain.timer; then boot=yes; fi
    if systemctl is-active --quiet vpskit-maintain.timer; then running=yes; fi
    if [[ $enabled == true && $boot == no ]]; then
        ((TX!=1)) || s2_service_mark vpskit-maintain.timer enable
        systemctl enable vpskit-maintain.timer >/dev/null || return 1
    fi
    if [[ $active == true ]]; then
        action=''
        if [[ $running == no ]]; then action=start
        elif [[ $changed == yes || $changed == true ]]; then action=restart; fi
        if [[ -n $action ]]; then
            ((TX!=1)) || s2_service_mark vpskit-maintain.timer "$action"
            systemctl "$action" vpskit-maintain.timer || return 1
        fi
    fi
}

# Cleanup has a fixed allowlist and uses the same manage.lock as all mutations.
# It never removes incomplete transactions, last/rescue/rebuild backups or certs.
s3_cleanup_safe() {
    local path=$1 kind=$2 mp all
    [[ $path != *[[:cntrl:]]* && ! -L $path && $(realpath -m -- "$path") == "$path" ]] || return 1
    case "$kind" in
        temp) [[ ${path%/*} == "$ROOT/tmp" && ${path##*/} =~ ^job\.[a-zA-Z0-9]{8}$ && -d $path && $path != "$WORK" ]] || return 1;;
        diagnostics) [[ ${path%/*} == "$ROOT/logs/diagnostics" && ${path##*/} =~ ^([0-9]{8}T[0-9]{6}Z-[a-f0-9]{8}|vpskit-preflight-[a-zA-Z0-9]{8}\.service)\.log$ && -f $path ]] || return 1;;
        code) [[ ${path%/*} == "$ROOT/backup/code" && ${path##*/} =~ ^[0-9]{8}T[0-9]{6}Z-[a-f0-9]{8}\.sh$ && -f $path ]] || return 1
            grep -Fq '# VPSKIT_SINGLE_FILE' "$path" || return 1;;
        history) [[ ${path%/*} == "$ROOT/backup/history" && ${path##*/} =~ ^[0-9]{8}T[0-9]{6}Z-[a-f0-9]{8}$ && -d $path ]] || return 1
            [[ -f $path/meta.json && ! -L $path/meta.json ]] && jq -e '.snapshot_schema==1' "$path/meta.json" >/dev/null 2>&1 || return 1;;
        *) return 1;;
    esac
    [[ $(stat -c %u -- "$path") == 0 ]] || return 1
    if [[ -f $path ]]; then [[ $(stat -c %h -- "$path") == 1 ]] || return 1; fi
    all=$(findmnt -rn -o TARGET) || return 1
    while IFS= read -r mp; do
        [[ $mp != "$path" && $mp != "$path/"* ]] || return 1
    done <<< "$all"
    return 0
}
s3_cleanup_stamp() {
    local path=$1
    if [[ -f $path ]]; then stat -c '%d:%i:%s:%Y:%Z:%h:%a:%u:%g' -- "$path"
    else
        timeout 12 find -P "$path" -xdev -printf '%y\0%P\0%s\0%T@\0%C@\0%i\0%n\0%m\0%U\0%G\0%l\0' | sha256sum | cut -d' ' -f1
    fi
}
s3_cleanup_candidates() {
    local wanted=${1:-all} path age now count=0 kept=0 stamp bytes seen=0
    printf -v now '%(%s)T' -1
    local kind base
    for kind in temp diagnostics history code; do
        [[ $wanted == all || $wanted == "$kind" ]] || continue
        case "$kind" in temp) base="$ROOT/tmp";; diagnostics) base="$ROOT/logs/diagnostics";; history) base="$ROOT/backup/history";; code) base="$ROOT/backup/code";; esac
        [[ -d $base && ! -L $base && $(realpath -m "$base") == "$base" ]] || continue
        kept=0; seen=0
        while IFS= read -r -d '' path; do
            path=${path#* }; seen=$((seen+1)); ((seen<=1000)) || { warn "目录$base候选太多；只检查最近1000项。"; break; }
            s3_cleanup_safe "$path" "$kind" || continue
            if [[ $kind == history ]]; then
                if ! ( trap - ERR EXIT; snapshot_verify "$path" ) >/dev/null 2>&1; then continue; fi
                kept=$((kept+1)); ((kept>2)) || continue
            elif [[ $kind == code ]]; then kept=$((kept+1)); ((kept>2)) || continue
            elif [[ $kind == diagnostics ]]; then kept=$((kept+1)); ((kept>10)) || continue; fi
            age=$(stat -c %Y -- "$path"); [[ $age =~ ^[0-9]+$ ]] || continue
            case "$kind" in temp) ((now-age>172800)) || continue;; history) ((now-age>86400)) || continue;; *) ((now-age>604800)) || continue;; esac
            stamp=$(s3_cleanup_stamp "$path") || continue
            bytes=$(timeout 12 du -sx -B1 -- "$path" 2>/dev/null | awk '{print $1}') || continue
            [[ $bytes =~ ^[0-9]+$ ]] || continue
            printf '%s\t%s\t%s\t%s\n' "$kind" "$bytes" "$stamp" "$path"
            count=$((count+1)); ((count<200)) || return 0
        done < <(find -P "$base" -mindepth 1 -maxdepth 1 \( -type f -o -type d \) -printf '%T@ %p\0' | sort -zrn)
    done
}
s3_cleanup_command() {
    local action=${1:-scan} kind=${2:-all} manifest="$WORK/cleanup-candidates.tsv" cat bytes stamp path n=0 total=0 actual=0 result=0
    choice "$action" 'scan run' || die 'cleanup: scan 或 run [temp|diagnostics|history|code|all]。'
    if [[ $action == run && $# -lt 2 ]]; then
        select_value kind '选择清理类别（会先显示候选再确认）' all \
          'temp|超过48小时的临时任务' 'diagnostics|超过7天且不在最新10份中的诊断' \
          'history|至少保留最近2份有效快照，其他超过1天的历史' 'code|至少保留最近2份，其他超过7天的旧管理脚本' 'all|上述四类；不含事务/救援/重建备份'
    fi
    choice "$kind" 'temp diagnostics history code all' || die '清理类别无效。'
    [[ -f $ROOT/.vpskit-owned && ! -L $ROOT/.vpskit-owned && $(cat "$ROOT/.vpskit-owned") == VPSKIT_V1 ]] || die '未确认安装目录归属；不扫描删除候选。'
    if [[ $action == run && ( -e $ROOT/backup/transaction || -L $ROOT/backup/transaction ) ]]; then die '存在未完成事务；禁止清理，请先recovery status/repair。'; fi
    s3_cleanup_candidates "$kind" > "$manifest"
    ui_title '清理预览（仅固定白名单；不会重启服务）'
    while IFS=$'\t' read -r cat bytes stamp path; do
        [[ -n $cat ]] || continue
        n=$((n+1)); total=$((total+bytes))
        printf '  %d. [%s] %s KiB  %s\n' "$n" "$cat" "$((bytes/1024))" "$path"
    done < "$manifest"
    printf '候选 %s 项，文件占用合计约 %s KiB（硬链接/稀疏文件可能影响实际释放量）。\n' "$n" "$((total/1024))"
    ui_note '永不自动删除：state/config/certs/acme/www/run、活动日志、transaction/last/rescue、rebuild-backups、系统journal和防火墙/Swap记录。'
    [[ $action == run && $n -gt 0 ]] || return 0
    confirm '删除以上过期白名单项；删除的旧资料不可恢复；最新备份与活动配置保留' || return 0
    [[ ! -e $ROOT/backup/transaction && ! -L $ROOT/backup/transaction ]] || die '确认期间出现事务，取消清理。'
    while IFS=$'\t' read -r cat bytes stamp path; do
        [[ -n $cat ]] || continue
        if ! s3_cleanup_safe "$path" "$cat" || [[ $(s3_cleanup_stamp "$path") != "$stamp" ]]; then warn "文件发生变化/归属异常，跳过：$path"; result=1; continue; fi
        if rm -rf --one-file-system -- "$path"; then actual=$((actual+1)); else warn "清理失败，保留其余现场：$path"; result=1; fi
    done < "$manifest"
    ok "清理完成$actual/$n项；没有服务动作。"
    return "$result"
}
s3_log_counts() {
    local f
    for f in "$ROOT/logs/nginx.log" "$ROOT/logs/xray.log"; do
        [[ -f $f && -r $f && ! -L $f ]] || continue
        tail -c 65536 -- "$f"
    done | awk 'BEGIN{IGNORECASE=1} {s=tolower($0);if(s~/setuid|permission denied/)p++;if(s~/too many open files/)f++;if(s~/worker_connections are not enough/)w++;if(s~/upstream timed out/)t++;if(s~/connection refused/)r++}
      END{printf "{\"permission_matches\":%d,\"fd_matches\":%d,\"worker_slots_matches\":%d,\"upstream_timeout_matches\":%d,\"refused_matches\":%d}",p,f,w,t,r}'
}
s3_diagnostic_json() {
    local resources counts ng xr nt ns time valid=false selected='{}'
    panel_collect status; panel_extras
    resources=$(s3_resources); counts=$(s3_log_counts)
    ng=${PANEL_RAW[nginx.active]:-unknown}; xr=${PANEL_RAW[xray.active]:-unknown}; nt=${PANEL_RAW[timer.active]:-unknown}
    for ns in ng xr nt; do [[ ${!ns} =~ ^[a-z-]{1,32}$ ]] || printf -v "$ns" unknown; done
    printf -v time '%(%Y-%m-%dT%H:%M:%S%z)T' -1
    if [[ -n $PANEL_DATA ]]; then
        valid=true
        selected=$(jq -c '{nodes:.nodes,websites:(.sites|length),registered_certificates:([.sites[]|select(.issued)]|length),
          access_log:(.nginx.access_log==true),proxy_access_log:(.nginx.proxy_access_log==true)}' <<< "$PANEL_DATA")
    fi
    jq -n --arg version "$VERSION" --arg mode "$MODE" --arg at "$time" --arg ng "$ng" --arg xr "$xr" --arg nt "$nt" \
      --argjson valid "$valid" --argjson config "$selected" --argjson res "$resources" --argjson logs "$counts" \
      --argjson tx "$( [[ -e $ROOT/backup/transaction || -L $ROOT/backup/transaction ]] && printf true || printf false )" \
      '{schema:1,manager:$version,mode:$mode,collected:$at,services:{nginx:$ng,xray:$xr,maintenance_timer:$nt},state_readable:$valid,configuration_summary:$config,resources:$res,unfinished_transaction:$tx,
        recent_error_tail_counters:$logs,scope:"Counts cover at most last 64KiB per project error file; not unique failures or a time window. No raw logs/config/addresses/credentials included.",
        checks:"Local snapshot only; not client reachability, throughput, DNS/CDN or root-cause certification."}'
}
s3_diagnostics() {
    local action=${1:-summary} report dir file f n=0
    choice "$action" 'summary export' || die 'diagnostics: summary/export。'
    report=$(s3_diagnostic_json) || return 1
    if [[ $action == summary ]]; then printf '%s\n' "$report"; return; fi
    dir="$ROOT/logs/reports"
    [[ ! -L $dir && $(realpath -m "$dir") == "$dir" ]] || die '报告目录存在异常链接。'
    mkdir -p -m 700 "$dir"; chmod 700 "$dir"
    file="$dir/summary-$(date -u +%Y%m%dT%H%M%SZ)-$(randhex 4).json"
    printf '%s\n' "$report" > "$file"; chmod 600 "$file"
    # Only generated report files, never arbitrary user exports.
    while IFS= read -r -d '' f; do
        f=${f#* }
        [[ ${f##*/} =~ ^summary-[0-9]{8}T[0-9]{6}Z-[a-f0-9]{8}\.json$ && ! -L $f && $(stat -c %u "$f") == 0 ]] || continue
        n=$((n+1)); ((n<=10)) || rm -f -- "$f"
    done < <(find -P "$dir" -mindepth 1 -maxdepth 1 -type f -name 'summary-*.json' -printf '%T@ %p\0' | sort -zrn)
    ok "已导出白名单诊断摘要：$file（root私有；最多保留10份）"
    ui_note '未写入域名/IP/节点凭据/用户名/原始日志；分享前仍请检查。错误计数不是唯一故障数，也不能单独证明断流原因。'
}
s3_panel_action() {
    local action=${1:-} value
    case "$action" in
        install-shared) install_wizard;; # UI dispatch uses install shared, not this path.
        adopt-acme) ask value '已有可信acme.sh程序的绝对路径' ''; adopt_acme "$value";;
        repair-apt-policy) repair_apt_policy;;
        native-import) smart_file_pick value '选择单个InboundObject JSON文件' json; native_import "$value";;
        node-overview) s3_node_overview;; node-batch) s3_node_batch;;
        xray-log) s3_xray_log;; proxy-log) advanced_edit nginx.proxy_access_log;;
        log-tuning) s3_log_tuning;; error-log) s3_error_log;;
        perf-recommend) s3_performance_recommend;; profile-plan) performance_profile '' --plan;;
        web-bench) s3_web_bench;;
        schedule-show) s3_schedule_show;; schedule-start|schedule-stop|schedule-enable|schedule-disable) service_control timer "${action#schedule-}";;
        diagnostics-summary) s3_diagnostics summary;; diagnostics-export) s3_diagnostics export;;
        cleanup-scan) s3_cleanup_command scan;; cleanup-run) s3_cleanup_command run;;
        log-preflight) logs_show preflight 120;; rebuild-plan) rebuild_command --plan;;
        tree) s3_menu_tree;; search) ask value '搜索本地功能关键词' ''; s3_menu_search "$value";;
        help-uninstall|help-shared|help-performance) s3_help "${action#help-}";;
        *) die '未知面板动作。';;
    esac
}
s4_previous_menu_dispatch() {
    local route=$1
    case "$route" in
        s3-install-shared) menu_run install shared;; s3-install-isolated) menu_run install isolated;;
        s3-*) menu_run panel-action "${route#s3-}";;
        *) s3_prev_menu_dispatch "$@";;
    esac
}
s3_help() {
    case "${1:-performance}" in
        shared) cat <<'TEXT'
共享模式只生成本项目HTTP片段，不接管其他网站或系统全局设置。
nginx -t 检查；nginx -s reload 或 systemctl reload nginx 平滑重载；没有nginx --reload。
修改全局Worker/connections使用 shared-global 独立授权；本地资源预设跳过全局容量。
重载作用于整个共享实例。只更新管理代码不重载，不代表运行进程自动加载新配置。
TEXT
        ;;
        uninstall) cat <<'TEXT'
使用 uninstall plan / uninstall wizard 区分项目配置、程序和数据；共享组件默认保留。
共享detach不会删除Xray直连节点，也不是完整卸载。存在外部站点时不能停止/卸载共享Nginx。
阶段4提供独立卸载向导、依赖预览、外部备份和部分失败恢复；未知外部依赖不会被强制覆盖。
配置、网站正文、证书、程序与云主机镜像是不同资源；不能用一次rm递归代替归属检查。
TEXT
        ;;
        performance) cat <<'TEXT'
建议从eco或balanced开始；throughput增加内存/空闲池，须对照测速，不保证提速。
不开常驻监控，不周期扫描网络，不自动调BBR/MTU，不开启公网管理API。
访问日志默认关闭；启用时使用有界缓冲和抽样。轮转只留尾部，不是完整审计归档。
菜单等待输入时不采样；R重新读取。状态区标注配置值/本机观测，未知不会显示为关闭。
共享和独立都沿用阶段2的候选检查、无差异跳过、按变更范围恢复。
TEXT
        ;;
        *) die '帮助主题无效。';;
    esac
}
s4_previous_usage() {
    s3_prev_usage "$@"
    cat <<'HELP'

阶段3：16模块面板（旧CLI保留，主菜单数字按新分类重排）：
  menu [分组] / preview [分组|all]     主菜单及只读预览
  panel tree / panel search 关键词    本地目录和功能检索
  node overview                      传统/原生节点统一总览
  node batch-all enable|disable 1,3   统一序号合并提交；旧batch仍只选传统节点
  performance recommend              可见物理/cgroup资源建议，不修改
  performance profile eco --plan     预设字段差异及服务计划，不应用
  performance benchmark [域名] [1-3] 网站小请求分阶段检查，不关闭TLS验证
  diagnostics summary|export         白名单摘要/导出，不包含原始日志或凭据
  cleanup scan                       只预览过期白名单候选及大小
  cleanup run [类别]                  确认后清理temp/diagnostics/history/code/all
  service nginx|xray enable|disable   只设置自启，不立即启停
  service timer start|stop|enable|disable 只管理本工具维护定时器
交互：R刷新、D折叠说明、N/P翻页、/关键词搜索、H主页、0上级、:q退出。
共享模式不可用动作显示原因；卸载使用阶段4独立向导，不直接递归删除项目根目录。
HELP
}

# -----------------------------------------------------------------------------
# Stage 4: plan -> confirmed external backup -> scoped detach -> optional removal.
# No package purge/autoremove, no shell eval of plans, no recursive /etc cleanup.
# Uninstall receipts are deliberately outside ROOT; software/data removal is not
# an ACID transaction. APT failures retain a resumable, explicit partial result.
# -----------------------------------------------------------------------------
S4_STORE='/var/backups/vpskit-uninstall'
S4_DPKG_STATUS='/var/lib/dpkg/status'
S4_PROC='/proc'
S4_PASSWD='/etc/passwd'
S4_SCAN_ROOTS=(/etc/systemd/system /run/systemd/system /usr/lib/systemd/system /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly /var/spool/cron/crontabs)
S4_SCAN_FILES=(/etc/crontab /etc/rc.local)
S4_PRIVATE_UNITS=(vpskit-maintain.timer vpskit-maintain.service vpskit-xray.service vpskit-nginx.service)
S4_SCOPE=config
S4_REMOVE=''
S4_DELETE=''
S4_PLAN=''
S4_RECEIPT=''

s4_has() { [[ ",$1," == *",$2,"* ]]; }
s4_path() {
    [[ $1 == /* && $1 != / && $1 != *[[:cntrl:]]* && $1 != *'/../'* && $1 != *'/./'* && $1 != */ && $(realpath -ms -- "$1") == "$1" && $(realpath -m -- "${1%/*}") == "${1%/*}" ]]
}
s4_owned_root() {
    s4_path "$ROOT" && [[ ! -L $ROOT && -d $ROOT && $(stat -c %u "$ROOT") == 0 &&
      -f $ROOT/.vpskit-owned && ! -L $ROOT/.vpskit-owned && $(cat "$ROOT/.vpskit-owned") == VPSKIT_V1 ]]
}
s4_tree_safe() {
    # Deleting a link itself is only allowed for the known CLI entry. Inside a
    # tree, preserve relative certificate links, never traverse an outside tree.
    local sp=$1 mounts mp item resolved listing
    s4_path "$sp" || return 1
    [[ ! -e $sp && ! -L $sp ]] && return 0
    if [[ -L $sp ]]; then
        [[ $sp == "$ENTRY" && $(readlink "$sp") == "$ROOT/vpskit.sh" ]] && return 0
        return 1
    fi
    [[ $(stat -c %u "$sp") == 0 ]] || return 1
    mounts=$(findmnt -rn -o TARGET) || return 1
    while IFS= read -r mp; do
        [[ $mp != "$sp" && $mp != "$sp/"* ]] || return 1
    done <<< "$mounts"
    if [[ ! -d $sp ]]; then
        [[ -f $sp && $(stat -c %h "$sp") == 1 ]] || return 1
        return 0
    fi
    listing=$(mktemp "$WORK/s4-tree.XXXXXXXX") || return 1
    find -P "$sp" -xdev -print0 > "$listing" || return 1
    while IFS= read -r -d '' item; do
        [[ $item != *[[:cntrl:]]* ]] || return 1
        if [[ -L $item ]]; then
            resolved=$(realpath -m -- "$item") || return 1
            [[ $resolved == "$sp/"* ]] || return 1
        elif [[ -f $item ]]; then
            [[ $(stat -c %h "$item") == 1 ]] || return 1
        elif [[ ! -d $item ]]; then return 1
        fi
    done < "$listing"
    rm -f -- "$listing"
    return 0
}
s4_stamp() (
    # Content + permissions/owner, but NOT access/mtime. Output is path-independent
    # so cp -a backups can be checked against the original. No compression/daemon.
    local sp=$1 f listing
    [[ -e $sp || -L $sp ]] || { printf 'absent\n'; exit 0; }
    if [[ -L $sp ]]; then printf 'link:%s\n' "$(readlink "$sp")"; exit 0; fi
    if [[ -f $sp ]]; then printf 'file:%s:%s\n' "$(stat -c '%a:%u:%g' "$sp")" "$(runtime_hash_file "$sp")"; exit 0; fi
    [[ -d $sp ]] || exit 1
    listing=$(mktemp "$WORK/s4-stamp.XXXXXXXX") || exit 1
    trap 'rm -f -- "$listing"' EXIT
    cd "$sp" || exit 1
    find -P . -xdev -mindepth 1 -print0 | LC_ALL=C sort -z > "$listing" || exit 1
    {
        stat -c 'root:%a:%u:%g' .
        while IFS= read -r -d '' f; do
            printf '%s\t' "$f"; stat -c '%F:%a:%u:%g' -- "$f"
            if [[ -L $f ]]; then readlink -- "$f"
            elif [[ -f $f ]]; then sha256sum -- "$f"; fi
        done < "$listing"
    } | sha256sum | awk '{print "tree:"$1}'
)
s4_note() { # severity / dependency kind / source path / explanation (no raw text)
    jq -nc --arg level "$1" --arg kind "$2" --arg path "$3" --arg message "$4" \
      '{level:$level,kind:$kind,path:$path,message:$message}' >> "$S4_NOTES"
}
s4_plan_options() {
    S4_SCOPE=config; S4_REMOVE=''; S4_DELETE=''
    local arg key value v; local -a vals=()
    for arg in "$@"; do
        case "$arg" in
            --scope=*) S4_SCOPE=${arg#*=};;
            --remove-shared=*) S4_REMOVE=${arg#*=};;
            --delete-data=*) S4_DELETE=${arg#*=};;
            *) die 'uninstall: --scope=config|project --remove-shared=nginx,acme --delete-data=config,web,certs,accounts,logs,history|all。';;
        esac
    done
    choice "$S4_SCOPE" 'config project component' || die '卸载范围只能为config/project/component。'
    for key in S4_REMOVE S4_DELETE; do
        value=${!key}; [[ -n $value ]] || continue
        [[ $value != ,* && $value != *, && $value != *,,* ]] || die '卸载列表格式错误。'
        if [[ $key == S4_DELETE && $value == all ]]; then value=config,web,certs,accounts,logs,history; fi
        IFS=, read -r -a vals <<< "$value"
        for v in "${vals[@]}"; do
            if [[ $key == S4_REMOVE ]]; then choice "$v" 'nginx acme'; else choice "$v" 'config web certs accounts logs history'; fi || die '不支持的卸载项目。'
        done
        printf -v "$key" '%s' "$(printf '%s\n' "${vals[@]}" | LC_ALL=C sort -u | paste -sd, -)"
    done
    [[ $S4_SCOPE != config || ( -z $S4_REMOVE && -z $S4_DELETE ) ]] || die '仅撤配置不允许同时删除程序或数据；请选择project范围。'
    if [[ $S4_SCOPE == component ]]; then
        choice "$S4_REMOVE" 'nginx acme' && [[ -z $S4_DELETE ]] || die 'component仅允许单独移除nginx或acme，不删除项目数据。'
    fi
}
s4_known_target() {
    local sp=$1 u
    case "$sp" in
        "$SHARED_INCLUDE"|"$SHARED_ACME_ENTRY"|"$SHARED_ACME_HOME"|"$ENTRY"|\
        "$ROOT/vpskit.sh"|"$ROOT/bin/xray"|"$ROOT/nginx"|"$ROOT/config"|\
        "$ROOT/config/nginx.conf"|"$ROOT/config/xray.json"|"$ROOT/config/.runtime-applied.json"|\
        "$ROOT/acme"|"$ROOT/acme/acme.sh"|"$ROOT/acme/dnsapi"|"$ROOT/acme/deploy"|"$ROOT/acme/notify"|\
        "$ROOT/data/state.json"|"$ROOT/data/installation.json"|"$ROOT/.uninstalled.json"|"$ROOT/.uninstall-pending.json"|\
        "$ROOT/www"|"$ROOT/certs"|"$ROOT/logs"|"$ROOT/backup"|"$ROOT/rebuild-backups") return 0;;
    esac
    for u in "${S4_PRIVATE_UNITS[@]}"; do [[ $sp != "$SYSTEMD/$u" ]] || return 0; done
    return 1
}
s4_target() {
    s4_known_target "$1" && s4_path "$1" || return 1
    jq -nc --arg path "$1" --arg kind "$2" '{path:$path,kind:$kind}' >> "$S4_TARGETS"
}
s4_collect_targets() {
    local u cat
    if [[ $S4_SCOPE == component ]]; then
        if [[ $S4_REMOVE == acme ]]; then s4_target "$SHARED_ACME_HOME" shared-acme; s4_target "$SHARED_ACME_ENTRY" shared-acme; fi
        return 0
    fi
    if [[ $MODE == shared ]]; then s4_target "$SHARED_INCLUDE" runtime; fi
    if s4_has "$S4_DELETE" config; then
        s4_target "$ROOT/config" config
        s4_target "$STATE" config; s4_target "$(install_record_path)" config
    else
        s4_target "$ROOT/config/nginx.conf" runtime
        s4_target "$ROOT/config/xray.json" runtime
        s4_target "$ROOT/config/.runtime-applied.json" runtime
    fi
    if [[ $S4_SCOPE == project ]]; then
        for u in "${S4_PRIVATE_UNITS[@]}"; do s4_target "$SYSTEMD/$u" unit; done
        s4_target "$ROOT/vpskit.sh" program; s4_target "$ENTRY" entry
        s4_target "$ROOT/bin/xray" program; s4_target "$ROOT/nginx" program
        if ! s4_has "$S4_DELETE" accounts; then
            for cat in acme.sh dnsapi deploy notify; do s4_target "$ROOT/acme/$cat" program; done
        fi
    fi
    for cat in web certs accounts logs history; do
        s4_has "$S4_DELETE" "$cat" || continue
        case "$cat" in
            web) s4_target "$ROOT/www" web;; certs) s4_target "$ROOT/certs" certs;;
            accounts) s4_target "$ROOT/acme" accounts;; logs) s4_target "$ROOT/logs" logs;;
            history) s4_target "$ROOT/backup" history; s4_target "$ROOT/rebuild-backups" history;;
        esac
    done
    if s4_has "$S4_REMOVE" acme; then s4_target "$SHARED_ACME_HOME" shared-acme; s4_target "$SHARED_ACME_ENTRY" shared-acme; fi
}
s4_unit_snapshot() {
    local unit=$1 out active enabled load fragment drops
    out=$(timeout 5 systemctl show "$unit" -p LoadState -p ActiveState -p UnitFileState -p FragmentPath -p DropInPaths) || return 1
    load=$(sed -n 's/^LoadState=//p' <<< "$out"); active=$(sed -n 's/^ActiveState=//p' <<< "$out")
    enabled=$(sed -n 's/^UnitFileState=//p' <<< "$out"); fragment=$(sed -n 's/^FragmentPath=//p' <<< "$out"); drops=$(sed -n 's/^DropInPaths=//p' <<< "$out")
    [[ -n $load && -n $active ]] || return 1
    jq -nc --arg unit "$unit" --arg load "$load" --arg active "$active" --arg enabled "$enabled" --arg fragment "$fragment" --arg drops "$drops" \
      '{unit:$unit,load:$load,active:$active,enabled:$enabled,fragment:$fragment,dropins:$drops}'
}
s4_collect_units() {
    local u out file
    : > "$S4_UNITS"
    for u in "${S4_PRIVATE_UNITS[@]}" nginx.service; do
        file="$SYSTEMD/$u"
        if ! out=$(s4_unit_snapshot "$u"); then s4_note block service "$u" '无法可靠读取服务状态；未按已停止继续。'; continue; fi
        printf '%s\n' "$out" >> "$S4_UNITS"
        [[ $u != nginx.service ]] || continue
        if [[ -e $file || -L $file ]]; then
            if [[ ! -f $file || -L $file ]] || ! grep -Fq '# VPSKIT_OWNED' "$file"; then s4_note block service "$file" '同名项目服务归属不明。'; fi
            if grep -Eq '^[[:space:]]*(Also|Alias)=' "$file"; then s4_note block service "$file" '服务含额外Also/Alias，可能停用外部服务，需人工处理。'; fi
        elif [[ $(jq -r .load <<< "$out") != not-found ]]; then s4_note block service "$u" '同名服务未由本项目目录提供。'
        fi
        if [[ -n $(jq -r .dropins <<< "$out") ]]; then s4_note block service "$u" '项目服务存在外部drop-in；不自动删除或忽略。'; fi
        case "$(jq -r .enabled <<< "$out")" in enabled|disabled|static|'') ;;
            *) s4_note block service "$u" '项目服务使用masked/linked/runtime等非标准启用状态，先由管理员核对。';; esac
        local frag; frag=$(jq -r .fragment <<< "$out")
        [[ -z $frag || $frag == "$file" ]] || s4_note block service "$u" '加载的服务文件不在本工具服务路径。'
    done
}
s4_nginx_remaining() {
    local candidate=$1
    S2_MAIN_OVERRIDE=''; S2_OWN_OVERRIDE=$candidate
    S2_SHADOW=$(mktemp -d "$WORK/nginx-uninstall-shadow.XXXXXXXX") || return 1
    S2_INPUT_MANIFEST="$S2_SHADOW/inputs.jsonl"; : > "$S2_INPUT_MANIFEST"
    S2_GRAPH_DEST=(); S2_GRAPH_BUSY=(); S2_GRAPH_COUNT=0; S2_GRAPH_BYTES=0; S2_OWN_SEEN=0
    s2_graph_clone "$SHARED_MAIN" || return 1
    if [[ -f $SHARED_INCLUDE && $S2_OWN_SEEN == 0 ]]; then return 1; fi
    S2_SHADOW_MAIN=${S2_GRAPH_DEST[$SHARED_MAIN]}
    if ! "$SHARED_NGINX" -T -c "$S2_SHADOW_MAIN" > "$S2_SHADOW/dump" 2> "$S2_SHADOW/errors"; then
        tail -n 12 "$S2_SHADOW/errors" >&2; return 1
    fi
    if grep -Eq 'conflicting server name|duplicate' "$S2_SHADOW/errors"; then return 1; fi
    s2_inputs_unchanged
}
s4_scan_nginx() {
    local file rows first last context name end args scope matches empty="$WORK/s4-empty.conf"
    # Also inspect a system Nginx outside isolated mode if it exists. Never stop it.
    [[ -f $SHARED_MAIN && -x $SHARED_NGINX ]] || {
        if [[ $MODE == shared ]]; then s4_note block nginx "$SHARED_MAIN" '共享Nginx或主配置缺失，先修复或手工迁移配置。'; fi
        return 0
    }
    printf '# VPSKIT_OWNED uninstall candidate\n' > "$empty"
    if [[ -f $SHARED_INCLUDE ]]; then (shared_guard_file) || { s4_note block nginx "$SHARED_INCLUDE" '受管片段已被外部修改/没有登记。'; return 0; }; fi
    if ! s4_nginx_remaining "$empty"; then s4_note block nginx "$SHARED_MAIN" '撤下项目片段后的完整候选验证失败（含外部依赖）。'; return 0; fi
    cp "$S2_INPUT_MANIFEST" "$WORK/s4-nginx-inputs.jsonl"
    if [[ -f $SHARED_INCLUDE ]] && jq -se --arg p "$SHARED_INCLUDE" 'any(.[];.kind=="glob" and .path==$p)' "$S2_INPUT_MANIFEST" >/dev/null; then
        s4_note block nginx "$SHARED_INCLUDE" '主配置直接include此文件；需管理员改为通配包含后再撤下。'
    fi
    while IFS= read -r file; do
        [[ $file != "$SHARED_INCLUDE" ]] || continue
        [[ -f $file ]] || { s4_note block scan "$file" '配置图文件不可读。'; continue; }
        rows="$WORK/s4-tokens"; s2_nginx_tokens "$file" > "$rows" || { s4_note block scan "$file" '无法解析外部Nginx配置。'; continue; }
        while IFS=$'\t' read -r first last context name end args; do
            if [[ $name == server && $end == '{' ]]; then
                if s4_has "$S4_REMOVE" nginx; then scope=block; else scope=info; fi
                s4_note "$scope" external-site "$file" '发现外部server；只撤项目配置时保留；删除共享Nginx前需迁移。'
            fi
            if [[ $args == *"$ROOT"* && $name != include ]]; then
                scope=warn
                if [[ $S4_SCOPE == project ]]; then scope=block; fi
                s4_note "$scope" project-reference "$file" '外部Nginx指令引用本项目路径；不显示指令值。'
            fi
        done < "$rows"
    done < <(jq -r 'select(.kind=="file")|.path' "$S2_INPUT_MANIFEST" | LC_ALL=C sort -u)
}
s4_scan_file() {
    local sf=$1 level hit=false unit base
    [[ -f $sf && -r $sf ]] || { s4_note block scan "$sf" '依赖扫描文件不可读。'; return; }
    [[ $(stat -Lc %s "$sf") -le 1048576 ]] || { s4_note block scan "$sf" '依赖文件超过1MiB扫描上限，未认定没有引用。'; return; }
    base=${sf##*/}
    for unit in "${S4_PRIVATE_UNITS[@]}"; do
        if [[ $sf == "$SYSTEMD/$unit" ]]; then return; fi
    done
    # Project-owned enable symlinks and vendor nginx unit are expected references.
    if [[ -L $sf ]]; then
        local dest; dest=$(readlink -f "$sf" || true)
        for unit in "${S4_PRIVATE_UNITS[@]}"; do [[ $dest != "$SYSTEMD/$unit" ]] || return; done
    fi
    if grep -Fq -- "$ROOT" "$sf"; then s4_note block external-job "$sf" '外部调度/服务引用VPSKit；先停用或迁移，不能仅删除本项目服务。'; fi
    if s4_has "$S4_REMOVE" acme && grep -Eq 'acme\.sh' "$sf"; then s4_note block acme-reference "$sf" '外部ACME任务或hook；程序共享关系需人工核对。'; fi
    if s4_has "$S4_REMOVE" nginx; then
        case "$base" in nginx.service|nginx|nginx.conf) return;; esac
        if grep -Eq '(^|[^[:alnum:]_])(nginx|nginx\.service)([^[:alnum:]_]|$)' "$sf"; then s4_note block nginx-reference "$sf" '外部任务引用Nginx或其reload hook。'; fi
    fi
}
s4_scan_jobs() {
    local dir sf count=0 listing="$WORK/s4-scan-files"
    : > "$listing"
    for dir in "${S4_SCAN_ROOTS[@]}"; do
        [[ -e $dir ]] || continue
        if [[ ! -d $dir || ! -r $dir || ! -x $dir ]]; then s4_note block scan "$dir" '无法遍历外部调度目录。'; continue; fi
        if ! timeout 8 find -P "$dir" -xdev -maxdepth 5 \( -type f -o -type l \) -print0 >> "$listing"; then s4_note block scan "$dir" '调度目录扫描超时或失败。'; fi
    done
    for sf in "${S4_SCAN_FILES[@]}"; do [[ ! -e $sf ]] || printf '%s\0' "$sf" >> "$listing"; done
    while IFS= read -r -d '' sf; do
        count=$((count+1)); if ((count>4096)); then s4_note block scan '' '外部任务文件超过4096个；扫描不完整。'; break; fi
        s4_scan_file "$sf"
    done < "$listing"
    if s4_has "$S4_REMOVE" acme; then
        local name pass uid gid gecos home shell
        [[ -r $S4_PASSWD ]] || { s4_note block scan "$S4_PASSWD" '不能核对用户ACME目录。'; return; }
        while IFS=: read -r name pass uid gid gecos home shell; do
            [[ $home == /* && -d $home/.acme.sh ]] || continue
            s4_note block acme-home "$home/.acme.sh" '发现外部ACME用户目录；不读取Token，不能证明不依赖共享程序。'
        done < "$S4_PASSWD"
        if [[ -d $SHARED_ACME_HOME ]]; then
            while IFS= read -r -d '' sf; do
                case ${sf##*/} in acme.sh|dnsapi|deploy|notify|.vpskit-code) ;;
                    *) s4_note block acme-home "$sf" '共享程序目录含额外资料，可能是账户/证书；拒绝整目录删除。';;
                esac
            done < <(find -P "$SHARED_ACME_HOME" -mindepth 1 -maxdepth 1 -print0)
        fi
    fi
}
s4_apt_plan() {
    local out=$1 owner pkg action extra tmp="$WORK/s4-apt.raw"; local -a req=() removed=()
    : > "$out"
    owner=$(dpkg-query -S "$SHARED_NGINX" 2>/dev/null | sed -n 's/: \/.*$//p' | head -n1) || return 1
    [[ $owner =~ ^nginx(-core|-full|-light|-extras)?(:[a-z0-9]+)?$ ]] || return 1
    req+=("$owner")
    if [[ $owner != nginx && $(dpkg-query -W -f='${db:Status-Status}' nginx 2>/dev/null || true) == installed ]]; then req+=(nginx); fi
    LC_ALL=C apt-get -s -o APT::Get::AutomaticRemove=false remove -- "${req[@]}" > "$tmp" 2>&1 || return 1
    while read -r action pkg extra; do
        case "$action" in
            Remv)
                [[ $pkg =~ ^(nginx(-common|-core|-full|-light|-extras)?|libnginx-mod-[a-z0-9-]+)(:[a-z0-9]+)?$ ]] || { warn "APT计划还会删除外部软件包：$pkg；拒绝。"; return 1; }
                removed+=("$pkg");;
            Inst|Purg) warn 'APT计划包含安装/清除配置，不属于本次remove范围。'; return 1;;
        esac
    done < "$tmp"
    ((${#removed[@]})) || return 1
    jq -n --argjson requested "$(printf '%s\n' "${req[@]}" | jq -Rsc 'split("\n")[:-1]')" \
      --argjson removed "$(printf '%s\n' "${removed[@]}" | LC_ALL=C sort -u | jq -Rsc 'split("\n")[:-1]')" \
      --arg status "$(runtime_hash_file "$S4_DPKG_STATUS")" '{requested:$requested,removed:$removed,status_sha256:$status}' > "$out"
}
s4_build_plan() {
    local dest=$1 path kind stamp bytes rows="$WORK/s4-target-rows.jsonl" out
    local S4_NOTES="$WORK/s4-notes.jsonl" S4_TARGETS="$WORK/s4-targets.jsonl" S4_UNITS="$WORK/s4-units.jsonl"
    : > "$S4_NOTES"; : > "$S4_TARGETS"; : > "$rows"; rm -f "$WORK/s4-nginx-inputs.jsonl"
    s4_owned_root || { warn '安装目录归属不明。'; return 1; }
    [[ ! -e $ROOT/backup/transaction && ! -L $ROOT/backup/transaction ]] || s4_note block transaction "$ROOT/backup/transaction" '存在未完成事务，先恢复；卸载不是清事务的方法。'
    [[ ! -e $ROOT/.uninstalled.json ]] || s4_note block lifecycle "$ROOT/.uninstalled.json" '已有卸载收据；先status/resume/restore，不能覆盖原收据。'
    [[ ! -e $ROOT/.uninstall-pending.json && ! -L $ROOT/.uninstall-pending.json ]] || s4_note block lifecycle "$ROOT/.uninstall-pending.json" '存在未完成卸载，不能覆盖原收据。'
    state_basic "$STATE" || s4_note block state "$STATE" '状态文件损坏，需先恢复配置。'
    [[ $MODE == shared || -z $S4_REMOVE ]] || s4_note block mode '' '独立模式不接管系统共享程序。'
    if [[ $S4_SCOPE == component ]]; then
        if [[ $S4_REMOVE == nginx && -f $SHARED_INCLUDE ]]; then s4_note block dependency "$SHARED_INCLUDE" '单组件移除前先撤下VPSKit片段；本操作不会替你停用Xray。'; fi
        if [[ $S4_REMOVE == acme ]] && jq -e 'any(.sites[];.issued and (.certificate_source // "acme")!="manual")' "$STATE" >/dev/null; then
            s4_note block dependency "$STATE" '仍有项目自动续期证书；先迁移续期责任，不删除账户。'
        fi
    fi
    s4_collect_targets
    s4_collect_units
    s4_scan_nginx
    s4_scan_jobs
    local package_plan='null'
    if s4_has "$S4_REMOVE" nginx; then
        if s4_apt_plan "$WORK/s4-packages.json"; then package_plan=$(cat "$WORK/s4-packages.json")
        else s4_note block packages "$SHARED_NGINX" '无法生成限于Nginx家族的APT移除计划。'; fi
        if [[ -f $INSTALL_RECORD && $(jq -r '.components.nginx.origin // "external"' "$INSTALL_RECORD") != vpskit ]]; then
            s4_note warn external-component "$SHARED_NGINX" '此Nginx由外部安装；删除需要额外系统级口令。'
        fi
    fi
    if s4_has "$S4_REMOVE" acme; then
        if [[ $ACME != "$SHARED_ACME_HOME/acme.sh" || ! -f $SHARED_ACME_HOME/.vpskit-code ]] ||
           [[ $(cat "$SHARED_ACME_HOME/.vpskit-code" 2>/dev/null) != VPSKIT_ACME_CODE_V1 ]] ||
           [[ ! -f $SHARED_ACME_ENTRY || -L $SHARED_ACME_ENTRY ]] || ! grep -Fxq '# VPSKIT_SHARED_ACME_ENTRY_V1' "$SHARED_ACME_ENTRY"; then
            s4_note block ownership "$SHARED_ACME_HOME" '外部或被替换的ACME程序不自动删除，只能撤下VPSKit引用。'
        fi
    fi
    # Parent targets subsume children. Fixed whitelist remains the only removal scope.
    jq -sc 'unique_by(.path) | . as $all | map(. as $x | select(any($all[]; . as $p | $p.path != $x.path and ($x.path|startswith($p.path+"/")))|not))' "$S4_TARGETS" > "$WORK/s4-targets-final.json"
    while IFS=$'\t' read -r path kind; do
        if ! s4_tree_safe "$path"; then s4_note block filesystem "$path" '路径、挂载、特殊文件或链接不安全，未列为可删除。'; fi
        if [[ $path == "$ENTRY" && -e $path && ! -L $path ]]; then
            if ! grep -Fq '# VPSKIT_SINGLE_FILE' "$path"; then s4_note block ownership "$path" '全局入口不是本工具脚本/链接。'; fi
        fi
        bytes=0
        if [[ -e $path || -L $path ]]; then bytes=$(du -sk -- "$path" 2>/dev/null | awk '{print $1*1024}'); fi
        bytes=${bytes:-0}; stamp=$(s4_stamp "$path") || { stamp=unreadable; s4_note block scan "$path" '不能读取目标摘要。'; }
        jq -nc --arg path "$path" --arg kind "$kind" --arg before "$stamp" --argjson bytes "$bytes" '{path:$path,kind:$kind,before:$before,bytes:$bytes}' >> "$rows"
    done < <(jq -r '.[]|[.path,.kind]|@tsv' "$WORK/s4-targets-final.json")
    for path in "$ROOT/data/firewall.json" "$ROOT/data/firewall-v2.json" "$ROOT/data/bbr-v2.json" "$ROOT/data/swap-v2.json" "$ROOT/data/swap.json" "$ROOT/swap"; do
        [[ ! -e $path ]] || s4_note info retained-system "$path" '系统规则/BBR/Swap及归属记录保留；需要移除时先到对应功能独立确认。'
    done
    s4_note warn coverage '' '依赖扫描仅覆盖Nginx引用、常见系统任务与账户目录；不能证明容器/CI/外部程序没有依赖。'
    if [[ $S4_SCOPE != component ]]; then s4_note warn renewals '' '项目维护与续期将停用；保留证书不等于仍会自动续期。没有吊销证书或删除CA账户。'; fi
    jq -n --arg version "$VERSION" --arg mode "$MODE" --arg root "$ROOT" --arg scope "$S4_SCOPE" \
      --arg remove "$S4_REMOVE" --arg delete "$S4_DELETE" --arg state "$(s4_stamp "$STATE")" --arg record "$(s4_stamp "$(install_record_path)")" \
      --slurpfile rows "$rows" --slurpfile notes "$S4_NOTES" --slurpfile units "$S4_UNITS" --argjson packages "$package_plan" \
      '{schema:1,version:$version,root:$root,mode:$mode,scope:$scope,remove_shared:$remove,delete_data:$delete,state_stamp:$state,installation_stamp:$record,
        targets:$rows,notes:($notes|unique_by([.level,.kind,.path,.message])),units:$units,packages:$packages,
        preserve:["system nginx configuration and external sites","external ACME accounts and schedules","SSH/firewall/BBR/Swap and ownership records","cloud snapshots","external uninstall backup"],
        blocked:any($notes[];.level=="block"),backup_scope:"selected targets + state/installation + project unit files; website/certificate/account contents backed up when selected for deletion"}' > "$dest"
}
s4_show_plan() {
    local plan=$1
    ui_title '卸载计划（尚未停服务或删除）'
    jq -r '"模式："+.mode+"  范围："+.scope,
      "共享程序删除："+(if .remove_shared=="" then "不删除" else .remove_shared end),
      "项目数据删除："+(if .delete_data=="" then "全部保留" else .delete_data end),
      "目标：",(.targets[]|"  ["+.kind+"] "+.path+"  "+((.bytes/1024|floor)|tostring)+" KiB"),
      "检查：",(.notes[]|"  ["+.level+"] "+.kind+" "+.path+" — "+.message),
      (if .packages==null then empty else "APT将移除："+(.packages.removed|join(", ")) end),
      (if .blocked then "结论：存在阻止项；不执行。" else "结论：可进入明确确认；不保证检测到全部外部依赖。" end)' "$plan"
    ui_note "备份保存到 $S4_STORE/；不自动清理该目录。仅撤配置会停用全部本项目节点/续期，不只是网站。"
}
s4_store_safe() {
    s4_path "$S4_STORE" && [[ $S4_STORE != "$ROOT" && $S4_STORE != "$ROOT/"* && ! -L $S4_STORE ]] || return 1
    local p=$S4_STORE mode
    while [[ $p != / ]]; do
        if [[ -e $p ]]; then
            [[ -d $p && ! -L $p && $(stat -c %u "$p") == 0 ]] || return 1
            mode=$(stat -c %a "$p")
            # The global sticky /tmp is allowed in disposable tests, but a receipt
            # and every directory below it must be root-private.
            [[ $p == /tmp && $mode == 1777 ]] || (( (8#$mode & 0022)==0 )) || return 1
        fi
        p=${p%/*}; [[ -n $p ]] || p=/
    done
}
s4_capture() {
    local dir=$1 path=$2 kind=$3 key before
    s4_known_target "$path" && s4_tree_safe "$path" || return 1
    key=$(printf '%s' "$path" | sha256sum | cut -d' ' -f1)
    grep -Fq '"key":"'"$key"'"' "$dir/files.jsonl" && return 0
    before=$(s4_stamp "$path") || return 1
    if [[ $before != absent ]]; then cp -a --reflink=auto -- "$path" "$dir/blobs/$key" || return 1; fi
    [[ $(s4_stamp "$dir/blobs/$key") == "$before" ]] || return 1
    jq -nc --arg key "$key" --arg path "$path" --arg kind "$kind" --arg before "$before" '{key:$key,path:$path,kind:$kind,before:$before}' >> "$dir/files.jsonl"
}
s4_backup() {
    local plan=$1 path kind bytes free id dir u
    s4_store_safe || { warn '卸载备份目录不安全。'; return 1; }
    mkdir -p -m 700 "$S4_STORE" || return 1; chmod 700 "$S4_STORE"
    bytes=$(jq '[.targets[].bytes]|add // 0' "$plan")
    free=$(df -Pk "$S4_STORE" | awk 'NR==2{printf "%.0f",$4*1024}')
    [[ $free =~ ^[0-9]+$ ]] && ((free>bytes+16777216)) || { warn '备份空间不足（保守预留16MiB）；未停用。'; return 1; }
    id="$(date -u +%Y%m%dT%H%M%SZ)-$(randhex 4)"; dir="$S4_STORE/$id"
    mkdir -m 700 "$dir" "$dir/blobs" "$dir/progress" || return 1
    S4_RECEIPT=$dir
    LOGFILE="$dir/operation.log"
    printf 'VPSKIT_UNINSTALL_V1\n' > "$dir/.owned"
    cp -- "$plan" "$dir/plan.json"
    : > "$dir/files.jsonl"; : > "$dir/intents.jsonl"; : > "$dir/actions.jsonl"
    for path in "$STATE" "$(install_record_path)" "$ROOT/.uninstalled.json" "$ROOT/.uninstall-pending.json"; do s4_capture "$dir" "$path" metadata || return 1; done
    for u in "${S4_PRIVATE_UNITS[@]}"; do s4_capture "$dir" "$SYSTEMD/$u" unit || return 1; done
    while IFS=$'\t' read -r path kind; do s4_capture "$dir" "$path" "$kind" || return 1; done < <(jq -r '.targets[]|[.path,.kind]|@tsv' "$plan")
    install -m 700 "$SELF" "$dir/manager.sh" || return 1
    (cd "$dir"; sha256sum plan.json files.jsonl manager.sh > SHA256SUMS) || return 1
    jq -n --arg id "$id" --arg t "$(date -u +%FT%TZ)" --arg version "$VERSION" '{schema:1,id:$id,version:$version,created:$t,status:"prepared",phase:"backup",irreversible:false,packages_removed:false}' > "$dir/status.json"
    # Receipt ancestors are private; do NOT chmod the copied blobs recursively:
    # their original modes/owners are part of the restore manifest.
    chmod 700 "$dir" "$dir/blobs" "$dir/progress"
    chmod 600 "$dir"/*.json "$dir"/*.jsonl "$dir/.owned" "$dir/SHA256SUMS"
    s4_receipt_verify "$dir" || return 1
    ok "卸载前备份已校验：$dir（含凭据/私钥，root私有，项目删除不会清除此备份）"
}
s4_receipt_verify() {
    local dir=$1 row key path stamp
    s4_store_safe && [[ $dir == "$S4_STORE/"* && ${dir##*/} =~ ^[0-9]{8}T[0-9]{6}Z-[a-f0-9]{8}$ ]] && s4_path "$dir" || return 1
    [[ -d $dir && ! -L $dir && -f $dir/.owned && $(cat "$dir/.owned") == VPSKIT_UNINSTALL_V1 && $(stat -c %u "$dir") == 0 ]] || return 1
    # Never follow a substituted manifest/metadata file.
    for path in .owned plan.json files.jsonl manager.sh SHA256SUMS status.json intents.jsonl actions.jsonl; do [[ -f $dir/$path && ! -L $dir/$path ]] || return 1; done
    (cd "$dir"; sha256sum -c --strict SHA256SUMS >/dev/null) || return 1
    jq -e --arg r "$ROOT" '.schema==1 and .root==$r and (.scope=="project" or .scope=="config" or .scope=="component")' "$dir/plan.json" >/dev/null || return 1
    while IFS=$'\t' read -r key path stamp; do
        [[ $key =~ ^[a-f0-9]{64}$ ]] && s4_known_target "$path" && s4_path "$path" || return 1
        [[ $(s4_stamp "$dir/blobs/$key") == "$stamp" ]] || return 1
    done < <(jq -r '[.key,.path,.before]|@tsv' "$dir/files.jsonl")
    return 0
}
s4_status_set() {
    local dir=$1; shift; local temp="$dir/.status.next"
    jq "$@" "$dir/status.json" > "$temp" && chmod 600 "$temp" && mv -f "$temp" "$dir/status.json"
}
s4_event() { jq -nc --arg at "$(date -u +%FT%TZ)" --arg action "$2" --arg target "$3" '{time:$at,action:$action,target:$target}' >> "$1/actions.jsonl"; }
s4_intent() {
    local dir=$1 path=$2 after=$3 row current last
    row=$(jq -sc --arg p "$path" '[.[]|select(.path==$p)]|first // empty' "$dir/files.jsonl")
    [[ -n $row ]] || return 1
    current=$(s4_stamp "$path") || return 1
    last=$(jq -sr --arg p "$path" '[.[]|select(.path==$p)]|last.after // empty' "$dir/intents.jsonl")
    [[ $current == "$(jq -r .before <<< "$row")" || ( -n $last && $current == "$last" ) ]] || {
        warn "卸载期间外部内容变化：$path；未覆盖。"; return 1; }
    jq -c --arg after "$after" '.+{after:$after}' <<< "$row" >> "$dir/intents.jsonl"
}
s4_write() {
    local dir=$1 src=$2 target=$3 temp
    chmod 600 "$src"; chown 0:0 "$src"
    s4_intent "$dir" "$target" "$(s4_stamp "$src")" || return 1
    mkdir -p -- "${target%/*}" || return 1
    temp=$(mktemp "${target%/*}/.uninstall.XXXXXXXX") || return 1
    cp -a "$src" "$temp" && mv -f -- "$temp" "$target"
}
s4_remove_path() {
    local dir=$1 target=$2
    [[ -e $target || -L $target ]] || return 0
    s4_known_target "$target" && s4_tree_safe "$target" || return 1
    s4_intent "$dir" "$target" absent || return 1
    rm -rf --one-file-system -- "$target" || return 1
    s4_event "$dir" removed "$target"
}
s4_service() {
    local dir=$1 action=$2 unit=$3 result
    s4_event "$dir" "service:$action" "$unit" || return 1
    systemctl "$action" "$unit" || return 1
    if [[ $action == stop ]]; then
        result=$(timeout 5 systemctl show "$unit" -p ActiveState --value) || return 1
        [[ $result == inactive || $result == failed ]] || { warn "$unit 未停止，取消后续删除。"; return 1; }
    fi
}
s4_detach() {
    local dir=$1 row u load active enabled temp old='' candidate="$WORK/s4-detach.conf"
    s4_status_set "$dir" '.status="running"|.phase="detaching"' || return 1
    # Validate shared configuration before stopping any production service.
    if [[ $MODE == shared && -f $SHARED_INCLUDE ]]; then
        shared_guard_file || return 1
        printf '# VPSKIT_OWNED uninstall\n' > "$candidate"
        s2_shared_validate "$candidate" && s2_inputs_unchanged || return 1
    fi
    while IFS= read -r row; do
        u=$(jq -r .unit <<< "$row"); load=$(jq -r .load <<< "$row")
        [[ $u != nginx.service && $load != not-found ]] || continue
        active=$(jq -r .active <<< "$row"); enabled=$(jq -r .enabled <<< "$row")
        if [[ $enabled == enabled ]]; then s4_service "$dir" disable "$u" || return 1; fi
        if [[ $active == active || $active == activating || $active == reloading || $active == deactivating ]]; then s4_service "$dir" stop "$u" || return 1; fi
    done < <(jq -c '.units[]' "$dir/plan.json")
    if [[ $MODE == shared && -f $SHARED_INCLUDE ]]; then
        s2_inputs_unchanged && shared_guard_file || return 1
        s4_remove_path "$dir" "$SHARED_INCLUDE" || return 1
        "$SHARED_NGINX" -t -c "$SHARED_MAIN" || return 1
        if systemctl is-active --quiet nginx.service; then
            old=$(worker_generation "$(nginx_master_pid)")
            s4_service "$dir" reload nginx.service && shared_verify_runtime "$old" || return 1
        fi
    fi
    # Delete only generated runtime configs during the reversible stage.
    for u in nginx.conf xray.json .runtime-applied.json; do
        if jq -e --arg p "$ROOT/config/$u" 'any(.targets[];.path==$p)' "$dir/plan.json" >/dev/null; then
            s4_remove_path "$dir" "$ROOT/config/$u" || return 1
        fi
    done
    temp="$WORK/s4-lifecycle.json"
    if ! s4_has "$S4_DELETE" config; then
        jq --arg receipt "${dir##*/}" '.lifecycle={status:"uninstalled",receipt:$receipt} | .components.nginx=false | .components.xray=false | .components.acme=false | .preferences.service_enabled={nginx:false,xray:false,timer:false} | .preferences.maintenance_running=false' "$STATE" > "$temp" || return 1
        s4_write "$dir" "$temp" "$STATE" || return 1
        if [[ -f $INSTALL_RECORD ]]; then
            jq --arg receipt "${dir##*/}" '.lifecycle={status:"uninstalled",receipt:$receipt} | .owned_files={}' "$INSTALL_RECORD" > "$temp" || return 1
            s4_write "$dir" "$temp" "$INSTALL_RECORD" || return 1
        fi
    fi
    jq -n --arg receipt "${dir##*/}" --arg mode "$MODE" '{schema:1,receipt:$receipt,mode:$mode,status:"uninstalled"}' > "$temp" || return 1
    s4_write "$dir" "$temp" "$ROOT/.uninstalled.json" || return 1
    touch "$dir/progress/detached"
    s4_status_set "$dir" '.phase="detached"' || return 1
}
s4_busy_targets() {
    local plan=$1 proc fd dest target kind pid
    # Check observed references immediately before removing binaries/data. The
    # manager's own cwd/script is excluded; no process is killed to clear a path.
    while IFS=$'\t' read -r target kind; do
        case "$kind" in program|web|certs|accounts|shared-acme|logs) ;; *) continue;; esac
        [[ -e $target ]] || continue
        for proc in "$S4_PROC"/[0-9]*; do
            [[ -d $proc ]] || continue; pid=${proc##*/}
            [[ $pid != "$BASHPID" && $pid != "$$" && $pid != "$PPID" ]] || continue
            for fd in "$proc/exe" "$proc/cwd" "$proc"/fd/*; do
                [[ -L $fd ]] || continue
                dest=$(readlink "$fd" 2>/dev/null || true); dest=${dest% (deleted)}
                if [[ $dest == "$target" || $dest == "$target/"* ]]; then
                    warn "PID $pid 仍引用 $target；不强杀外部进程。等待旧连接退出后可resume。"; return 1
                fi
            done
        done
    done < <(jq -r '.targets[]|[.path,.kind]|@tsv' "$plan")
    return 0
}
s4_remove_packages() {
    local dir=$1 plan="$dir/plan.json" check="$WORK/s4-recheck-packages.json" pkg before after
    local -a requested=(); local present=no
    s4_has "$S4_REMOVE" nginx || return 0
    [[ ! -f $dir/progress/packages ]] || return 0
    mapfile -t requested < <(jq -r '.packages.requested[]' "$plan")
    ((${#requested[@]})) || return 1
    for pkg in "${requested[@]}"; do
        [[ $(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null || true) != installed ]] || present=yes
    done
    if [[ $present == no ]]; then touch "$dir/progress/packages"; s4_status_set "$dir" '.packages_removed=true'; return; fi
    s4_apt_plan "$check" || return 1
    # No newly-installed reverse dependency may be silently removed on resume.
    jq -e --slurpfile old "$plan" 'all(.removed[]; . as $p | $old[0].packages.removed | index($p)!=null)' "$check" >/dev/null || return 1
    shared_external_sites_check || { warn '出现外部网站；拒绝移除共享Nginx。'; return 1; }
    s4_status_set "$dir" '.irreversible=true|.phase="packages"' || return 1
    if systemctl is-active --quiet nginx.service; then s4_service "$dir" stop nginx.service || return 1; fi
    # No purge, autoremove, unauthenticated or essential-package removal flags.
    [[ $(runtime_hash_file "$S4_DPKG_STATUS") == "$(jq -r .status_sha256 "$check")" ]] || { warn '停止服务期间软件包数据库改变，未执行APT删除；收据保留。'; return 1; }
    s4_event "$dir" apt-remove "${requested[*]}"
    DEBIAN_FRONTEND=noninteractive LC_ALL=C apt-get -y -o APT::Get::AutomaticRemove=false remove -- "${requested[@]}" > "$dir/apt-remove.log" 2>&1 || { warn "APT删除失败，已保留$dir/apt-remove.log；不会自动重装或继续删数据。"; return 1; }
    for pkg in "${requested[@]}"; do [[ $(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null || true) != installed ]] || return 1; done
    touch "$dir/progress/packages"; s4_status_set "$dir" '.packages_removed=true'
}
s4_finish_removal() {
    local dir=$1 path kind
    if [[ $S4_SCOPE == project || $S4_SCOPE == component ]]; then
        s4_status_set "$dir" '.irreversible=true|.phase="programs-and-data"' || return 1
        s4_remove_packages "$dir" || return 1
        s4_busy_targets "$dir/plan.json" || return 1
        while IFS=$'\t' read -r path kind; do
            [[ $path != "$SHARED_INCLUDE" ]] || continue
            # Retained state was deliberately rewritten after its backup. Deleting
            # config metadata is allowed only in the originally confirmed plan.
            s4_remove_path "$dir" "$path" || return 1
        done < <(jq -r '.targets[]|[.path,.kind]|@tsv' "$dir/plan.json")
        systemctl daemon-reload || return 1
        if [[ $S4_SCOPE == component ]]; then
            local component_temp="$WORK/s4-component-state.json"
            jq --arg c "$S4_REMOVE" '.components[$c]=false' "$STATE" > "$component_temp" || return 1
            s4_write "$dir" "$component_temp" "$STATE" || return 1
            if [[ -f $INSTALL_RECORD ]]; then
                jq --arg c "$S4_REMOVE" '.components[$c].removed=true' "$INSTALL_RECORD" > "$component_temp" || return 1
                s4_write "$dir" "$component_temp" "$INSTALL_RECORD" || return 1
            fi
        fi
    fi
    s4_audit "$dir" > "$dir/audit.txt" || { s4_status_set "$dir" '.status="partial"|.phase="audit"'; return 1; }
    s4_remove_path "$dir" "$ROOT/.uninstall-pending.json" || return 1
    s4_status_set "$dir" '.status="complete"|.phase="verified"' || return 1
    cat "$dir/audit.txt"
    ok "卸载已完成所选范围；备份/收据：$dir"
    info "恢复使用下载的完整脚本：bash ./vpskit.sh uninstall restore ${dir##*/}；共享APT程序若已删除，需先人工补装。"
}
s4_restore_local() {
    local dir=$1 intent path key before after current row unit active enabled kind tmp old_generation
    s4_receipt_verify "$dir" || { warn '收据/备份校验失败。'; return 1; }
    # APT cannot be rolled back by copying a few files. Explicitly require package
    # availability before restoring service references; never reinstall silently.
    if [[ $(jq -r .mode "$dir/plan.json") == shared ]] && s4_has "$(jq -r .remove_shared "$dir/plan.json")" nginx; then
        [[ -x $SHARED_NGINX ]] || { warn '共享Nginx软件包已删除，先由管理员补装nginx，再restore。'; return 1; }
        local restored_package
        while IFS= read -r restored_package; do
            [[ $(dpkg-query -W -f='${db:Status-Status}' "$restored_package" 2>/dev/null || true) == installed ]] || {
                warn "先人工补装原软件包 $restored_package，再恢复项目文件；不会静默APT安装。"; return 1; }
        done < <(jq -r '.packages.removed[]' "$dir/plan.json")
    fi
    # Check ALL intent paths before changing any; do not overwrite third-party edits.
    while IFS= read -r intent; do
        path=$(jq -r .path <<< "$intent"); before=$(jq -r .before <<< "$intent"); after=$(jq -r .after <<< "$intent")
        current=$(s4_stamp "$path") || return 1
        [[ $current == "$before" || $current == "$after" ]] || { warn "恢复冲突：$path 已有其他变化；保留现场。"; return 1; }
    done < <(jq -sc 'group_by(.path)|map(last)|.[]' "$dir/intents.jsonl")
    # Restore in reverse intent order so children/marker cannot escape parent checks.
    while IFS= read -r intent; do
        path=$(jq -r .path <<< "$intent"); key=$(jq -r .key <<< "$intent"); before=$(jq -r .before <<< "$intent")
        current=$(s4_stamp "$path") || return 1
        [[ $current != "$before" ]] || continue
        s4_known_target "$path" && s4_tree_safe "$path" || return 1
        if [[ $before == absent ]]; then rm -rf --one-file-system -- "$path" || return 1
        else
            mkdir -p -- "${path%/*}" || return 1
            if [[ -d $dir/blobs/$key && ! -L $dir/blobs/$key ]]; then
                [[ ! -e $path ]] || return 1
                cp -a -- "$dir/blobs/$key" "$path" || return 1
            else
                tmp=$(mktemp "${path%/*}/.restore.XXXXXXXX") || return 1
                rm -f -- "$tmp"; cp -a -- "$dir/blobs/$key" "$tmp" && mv -Tf -- "$tmp" "$path" || return 1
            fi
        fi
    done < <(jq -sc 'reverse|unique_by(.path)|.[]' "$dir/intents.jsonl")
    mode_load
    if [[ $MODE == shared && -f $SHARED_INCLUDE ]]; then "$SHARED_NGINX" -t -c "$SHARED_MAIN" || return 1
    elif [[ $MODE == isolated && -f $ROOT/config/nginx.conf ]]; then nginx_cmd -t -p "$ROOT/" -c "$ROOT/config/nginx.conf" || return 1; fi
    if [[ -f $ROOT/config/xray.json && -x $XRAY ]]; then "$XRAY" run -test -config "$ROOT/config/xray.json" || return 1; fi
    systemctl daemon-reload || return 1
    # Only services actually touched by this uninstall are reconciled.
    while IFS= read -r row; do
        unit=$(jq -r .unit <<< "$row"); active=$(jq -r .active <<< "$row"); enabled=$(jq -r .enabled <<< "$row")
        jq -se --arg u "$unit" 'any(.[];.target==$u and (.action|startswith("service:")))' "$dir/actions.jsonl" >/dev/null || continue
        if [[ $unit == nginx.service ]]; then
            if [[ $active == active ]]; then
                old_generation=''
                if systemctl is-active --quiet "$unit"; then
                    old_generation=$(worker_generation "$(nginx_master_pid)")
                    systemctl reload "$unit" || return 1
                else systemctl start "$unit" || return 1; fi
                if [[ $(jq -r .scope "$dir/plan.json") != component && -f $SHARED_INCLUDE ]]; then
                    shared_verify_runtime "$old_generation" || return 1
                fi
            fi
        else
            if [[ $enabled == enabled ]]; then systemctl enable "$unit" >/dev/null || return 1; fi
            if [[ $active == active ]]; then
                systemctl start "$unit" && systemctl is-active --quiet "$unit" || return 1
            fi
        fi
    done < <(jq -c '.units|sort_by(if .unit=="vpskit-xray.service" then 0 elif (.unit=="nginx.service" or .unit=="vpskit-nginx.service") then 1 elif .unit=="vpskit-maintain.service" then 2 else 3 end)|.[]' "$dir/plan.json")
    s4_status_set "$dir" '.status="restored"|.phase="local-restored"' || return 1
    ok '本次删除的项目文件及涉及的服务已按收据恢复；没有恢复外部网站/CA事件或APT依赖。'
}
s4_on_exit() {
    local rc=$1 dir=$2
    trap - EXIT ERR INT TERM
    set +e
    if ((rc!=0)) && [[ -n $dir && -f $dir/status.json ]]; then
        if [[ $(jq -r .irreversible "$dir/status.json") == false ]]; then
            warn '卸载尚未进入程序/数据删除阶段，尝试仅恢复本次操作。'
            if s4_restore_local "$dir"; then s4_status_set "$dir" '.status="rolled-back"'
            else s4_status_set "$dir" '.status="partial"'; warn '恢复冲突/失败，收据保留；不要清理备份。'; fi
        else
            s4_status_set "$dir" '.status="partial"'
            warn "卸载部分完成；未继续删除未完成项目。用 uninstall status/resume/restore ${dir##*/} 查看和处理。"
        fi
    fi
    exit "$rc"
}
s4_confirm_plan() {
    local plan=$1 token
    local message='已确认上述范围；将断开本项目节点、停用续期；先做root私有备份再执行'
    [[ $(jq -r .scope "$plan") != component ]] || message='已确认单个共享程序移除；不主动停用Xray；相关网站或续期调用可能受影响'
    confirm "$message" || return 1
    if [[ $(jq -r .scope "$plan") == project ]]; then
        ask token '输入 REMOVE VPSKIT 确认移除管理代码/私有程序' ''
        [[ $token == 'REMOVE VPSKIT' ]] || return 1
    fi
    if [[ -n $(jq -r .delete_data "$plan") ]]; then
        ask token '输入 DELETE VPSKIT DATA 确认删除所选项目数据（外部卸载备份保留）' ''
        [[ $token == 'DELETE VPSKIT DATA' ]] || return 1
    fi
    if s4_has "$(jq -r .remove_shared "$plan")" nginx; then
        ask token '输入 REMOVE SHARED NGINX 确认移除系统Nginx软件包' ''
        [[ $token == 'REMOVE SHARED NGINX' ]] || return 1
    fi
    if s4_has "$(jq -r .remove_shared "$plan")" acme; then
        ask token '输入 REMOVE SHARED ACME 确认共享程序不再被其他应用使用' ''
        [[ $token == 'REMOVE SHARED ACME' ]] || return 1
    fi
}
s4_apply_plan() (
    trap - EXIT ERR INT TERM
    set -Eeuo pipefail
    local plan=$1 fresh="$WORK/s4-fresh-plan.json" hash_before hash_after S4_RECEIPT=''
    [[ $(jq -r .blocked "$plan") == false ]] || { warn '卸载存在阻止项；未执行。'; exit 1; }
    s4_confirm_plan "$plan" || { info '卸载已取消。'; exit 0; }
    # Rebuild dependencies and content hashes after human confirmation.
    s4_build_plan "$fresh" || exit 1
    hash_before=$(jq -Sc 'del(.targets[].bytes) | .targets |= map(if .kind=="logs" then .before="volatile" else . end)' "$plan" | sha256sum)
    hash_after=$(jq -Sc 'del(.targets[].bytes) | .targets |= map(if .kind=="logs" then .before="volatile" else . end)' "$fresh" | sha256sum)
    [[ $hash_before == "$hash_after" ]] || { warn '确认期间状态/依赖/文件改变；请重新预览。'; exit 1; }
    s4_backup "$plan" || exit 1
    trap 's4_on_exit "$?" "$S4_RECEIPT"' EXIT
    trap 'exit 130' INT; trap 'exit 143' TERM
    jq -n --arg receipt "${S4_RECEIPT##*/}" '{schema:1,receipt:$receipt,status:"pending"}' > "$WORK/s4-pending.json"
    s4_write "$S4_RECEIPT" "$WORK/s4-pending.json" "$ROOT/.uninstall-pending.json" || exit 1
    if [[ $S4_SCOPE == component ]]; then touch "$S4_RECEIPT/progress/detached"
    else s4_detach "$S4_RECEIPT" || exit 1; fi
    s4_finish_removal "$S4_RECEIPT" || exit 1
)
s4_select_receipt() {
    local destvar=$1 selected=${2:-} path id row i=0; local -a ids=() options=()
    s4_store_safe || die '收据目录不安全。'
    if [[ -z $selected ]]; then
        [[ -d $S4_STORE ]] || die '尚无卸载收据。'
        while IFS= read -r path; do
            id=${path##*/}; [[ $id =~ ^[0-9]{8}T[0-9]{6}Z-[a-f0-9]{8}$ && ! -L $path && -f $path/status.json ]] || continue
            ids+=("$id"); options+=("$id|$id — $(jq -r '.status+" / "+.phase' "$path/status.json")")
        done < <(find -P "$S4_STORE" -mindepth 1 -maxdepth 1 -type d -print | LC_ALL=C sort -r)
        ((${#ids[@]})) || die '尚无可识别收据。'
        select_value selected '按序号选择卸载收据' "${ids[0]}" "${options[@]}"
    fi
    [[ $selected =~ ^[0-9]{8}T[0-9]{6}Z-[a-f0-9]{8}$ ]] || die '请使用收据ID，不接受任意目录。'
    printf -v "$destvar" '%s' "$S4_STORE/$selected"
}
s4_audit() {
    local dir=${1:-} plan path kind u status failures=0
    ui_title '卸载残留与保留项核对（只读）'
    if [[ -n $dir ]]; then
        plan="$dir/plan.json"
        while IFS=$'\t' read -r path kind; do
            if [[ -e $path || -L $path ]]; then printf '  [待处理] %s\n' "$path"; failures=$((failures+1)); fi
        done < <(jq -r '.targets[]|[.path,.kind]|@tsv' "$plan")
    fi
    local audit_scope=project
    [[ -z $dir ]] || audit_scope=$(jq -r .scope "$dir/plan.json")
    for u in "${S4_PRIVATE_UNITS[@]}"; do
        [[ $audit_scope != component ]] || continue
        status=$(timeout 5 systemctl show "$u" -p ActiveState --value 2>/dev/null || printf unknown)
        printf '  服务 %s：%s\n' "$u" "${status:-unknown}"
        case "$status" in active|activating|reloading|deactivating|unknown|'') failures=$((failures+1));; esac
    done
    if [[ -n $dir ]] && s4_has "$(jq -r .remove_shared "$dir/plan.json")" nginx; then
        local pkg
        while IFS= read -r pkg; do
            if [[ $(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null || true) == installed ]]; then printf '  [待处理软件包] %s\n' "$pkg"; failures=$((failures+1)); fi
        done < <(jq -r '.packages.removed[]' "$dir/plan.json")
    fi
    printf '  共享Nginx：%s；共享ACME：%s（保留程序不代表项目仍部署）\n' \
      "$( [[ -x $SHARED_NGINX ]] && printf 存在 || printf 未发现 )" "$( [[ -x $SHARED_ACME_HOME/acme.sh ]] && printf 存在 || printf 未发现 )"
    for path in data www certs acme logs backup rebuild-backups swap; do
        [[ ! -e $ROOT/$path ]] || printf '  [保留] %s/%s\n' "$ROOT" "$path"
    done
    printf '  [始终保留] SSH、系统日志、外部站点/账户、云快照、系统网络规则和Swap归属记录；外部备份 %s\n' "$S4_STORE"
    ((failures==0))
}
s4_wizard() {
    local v data='' shared='' cat
    S4_SCOPE=config; S4_REMOVE=''; S4_DELETE=''
    select_value S4_SCOPE '选择卸载范围' config \
      'config|只停用/撤下本项目配置；保留程序、网站、证书和数据' \
      'project|移除项目管理代码/私有程序；共享程序与数据分别选择'
    if [[ $S4_SCOPE == project ]]; then
        if [[ $MODE == shared ]]; then
            select_value v '共享Nginx程序' keep 'keep|保留，其他应用继续使用（默认）' 'remove|检查依赖后删除软件包，不purge配置'
            [[ $v != remove ]] || shared=nginx
            select_value v '共享ACME程序' keep 'keep|保留程序与所有外部账户（默认）' 'remove|只删除本工具安装的共享程序，需无已发现依赖'
            [[ $v != remove ]] || shared+="${shared:+,}acme"
        fi
        select_value v '项目数据保留方式' keep 'keep|全部保留（默认）' 'select|逐项编号选择删除' 'all|删除六类项目数据，独立卸载备份仍保留'
        if [[ $v == all ]]; then data=all
        elif [[ $v == select ]]; then
            for cat in config web certs accounts logs history; do
                select_value v "数据 $cat" keep 'keep|保留' 'remove|删除，先备份到项目外'
                [[ $v != remove ]] || data+="${data:+,}$cat"
            done
        fi
    fi
    local -a opts=("--scope=$S4_SCOPE")
    [[ -z $shared ]] || opts+=("--remove-shared=$shared")
    [[ -z $data ]] || opts+=("--delete-data=$data")
    s4_plan_options "${opts[@]}"
    s4_build_plan "$WORK/uninstall-plan.json" || return 1
    s4_show_plan "$WORK/uninstall-plan.json"
    s4_apply_plan "$WORK/uninstall-plan.json"
}
s4_resume_guard() {
    local dir=$1 path before after current row f
    local S4_NOTES="$WORK/s4-resume-notes.jsonl"
    : > "$S4_NOTES"
    while IFS= read -r row; do
        path=$(jq -r .path <<< "$row"); before=$(jq -r .before <<< "$row")
        after=$(jq -sr --arg p "$path" '[.[]|select(.path==$p)]|last.after // empty' "$dir/intents.jsonl")
        current=$(s4_stamp "$path") || return 1
        [[ $current == "$before" || ( -n $after && $current == "$after" ) ]] || { warn "继续卸载冲突：$path；不猜测如何删除。"; return 1; }
    done < "$dir/files.jsonl"
    # Package deletion may already have completed before a crash.
    if [[ -x $SHARED_NGINX && -f $SHARED_MAIN ]]; then s4_scan_nginx; fi
    s4_scan_jobs
    if jq -se 'any(.[];.level=="block")' "$S4_NOTES" >/dev/null; then
        jq -r 'select(.level=="block")|.path+" — "+.message' "$S4_NOTES" >&2; return 1
    fi
    return 0
}
shared_remove_component() {
    choice "${1:-}" 'nginx acme' || die '共享移除仅支持nginx/acme。'
    s4_command apply --scope=component "--remove-shared=$1"
}
s4_prepare_install() {
    local dir=$1 path kind marker="$ROOT/.uninstalled.json" unit status token
    s4_receipt_verify "$dir" || die '卸载收据校验失败。'
    [[ $(jq -r .status "$dir/status.json") == complete && $(jq -r .scope "$dir/plan.json") == project ]] || die '仅已完成的项目删除可准备全新安装。'
    for kind in config web certs accounts logs history; do
        s4_has "$(jq -r .delete_data "$dir/plan.json")" "$kind" || die '仍有刻意保留的数据；请按收据restore，不把旧数据当成全新安装。'
    done
    [[ -f $marker && ! -L $marker && $(jq -r .receipt "$marker") == "${dir##*/}" && ! -e $ROOT/.uninstall-pending.json ]] || die '卸载标记不匹配或仍在进行。'
    while IFS= read -r path; do
        [[ ! -e $path && ! -L $path ]] || die "卸载目标又出现：$path；拒绝重置安装入口。"
    done < <(jq -r '.targets[].path' "$dir/plan.json")
    for unit in "${S4_PRIVATE_UNITS[@]}"; do
        status=$(timeout 5 systemctl show "$unit" -p ActiveState --value) || die '服务状态查询失败。'
        [[ $status == inactive || $status == failed ]] || die "项目服务尚未停用：$unit"
    done
    ask token '输入 NEW VPSKIT INSTALL 解除已完成卸载标记；独立备份和系统规则仍保留' ''
    [[ $token == 'NEW VPSKIT INSTALL' ]] || { info '未解除卸载标记。'; return 0; }
    s4_status_set "$dir" '.reinstall_released=true' || return 1
    rm -f -- "$marker" || return 1
    ok '可以使用下载的完整脚本 install shared / install isolated 进行新安装；旧节点不会自动复活。'
    info '系统防火墙/BBR/Swap归属记录及卸载备份仍保留；不是整机恢复出厂设置。'
}
s4_command() {
    local action=${1:-wizard} dir plan="$WORK/uninstall-plan.json" token
    shift || true
    case "$action" in status|audit|restore|resume|prepare-install) (($#<=1)) || die '收据命令最多接受一个ID；不能用新选项扩大原删除计划。';; esac
    case "$action" in
        wizard) (($#==0)) || die 'wizard不接受额外参数。'; s4_wizard;;
        plan|apply)
            s4_plan_options "$@"
            s4_build_plan "$plan" || return 1; s4_show_plan "$plan"
            [[ $action != apply ]] || s4_apply_plan "$plan";;
        status)
            s4_select_receipt dir "${1:-}"
            [[ -f $dir/status.json && ! -L $dir/status.json ]] || die '收据不存在。'
            jq . "$dir/status.json"; s4_show_plan "$dir/plan.json"
            info "备份：$dir；不含系统软件包本体/外部网站/云快照。";;
        audit) if [[ -n ${1:-} ]]; then s4_select_receipt dir "$1"; s4_audit "$dir"; else s4_audit; fi;;
        prepare-install)
            s4_select_receipt dir "${1:-}"; s4_prepare_install "$dir";;
        restore)
            s4_select_receipt dir "${1:-}"
            s4_receipt_verify "$dir" || die '备份校验失败。'
            confirm '恢复本次卸载中被修改/删除的项目文件和涉及服务；不重装APT，不覆盖后来修改，不撤销CA事件' || return 0
            s4_restore_local "$dir" || die "恢复失败或有冲突，备份保留：$dir";;
        resume)
            s4_select_receipt dir "${1:-}"
            s4_receipt_verify "$dir" || die '收据/备份校验失败。'
            choice "$(jq -r .status "$dir/status.json")" 'partial running prepared' || die '该收据不是未完成卸载。'
            S4_SCOPE=$(jq -r .scope "$dir/plan.json"); S4_REMOVE=$(jq -r .remove_shared "$dir/plan.json"); S4_DELETE=$(jq -r .delete_data "$dir/plan.json")
            s4_resume_guard "$dir" || die '当前依赖或目标发生变化；未继续卸载。'
            s4_show_plan "$dir/plan.json"
            s4_confirm_plan "$dir/plan.json" || return 0
            (
                trap - EXIT ERR INT TERM
                trap 's4_on_exit "$?" "$dir"' EXIT; trap 'exit 130' INT; trap 'exit 143' TERM
                s4_resume_guard "$dir" || exit 1
                if [[ ! -f $dir/progress/detached ]]; then
                    if [[ $S4_SCOPE == component ]]; then touch "$dir/progress/detached"; else s4_detach "$dir" || exit 1; fi
                fi
                s4_finish_removal "$dir" || exit 1
            );;
        keep) s4_command apply --scope=config;;
        all) s4_wizard;;
        nginx|xray|acme) uninstall_component "$action";;
        *) die 'uninstall: wizard/plan/apply/status/audit/restore/resume/prepare-install；旧keep/all改为安全流程。';;
    esac
}
s4_lifecycle_guard() {
    local command=$1 action=${2:-}
    [[ -e $ROOT/.uninstalled.json || -L $ROOT/.uninstalled.json || -e $ROOT/.uninstall-pending.json || -L $ROOT/.uninstall-pending.json ]] || return 0
    case "$command:$action" in
        uninstall:*|version:*|help:*|--help:*|-h:*|selftest:*|preview:*|dashboard:*|status:*|paths:*|logs:*|mode:show|components:show|update:manager|panel:*|menu:*|diagnostics:*|panel-action:help-*) return 0;;
    esac
    die '项目存在卸载收据/未完成卸载；未自动重新生成配置。先 uninstall status / uninstall restore；重新空安装前先另行保留需要的数据。'
}

s4_management_layout() {
    root_check
    s4_owned_root || {
        case "${action:-}" in status|restore|resume|audit) ;;
            *) die '需要可确认归属的现有部署；没有创建空state。';; esac
    }
    [[ ! -L $ROOT && ! -L $ROOT/run && ! -L $ROOT/run/manage.lock ]] || die '管理锁目录存在链接。'
    mkdir -p -m 700 "$ROOT/run"
    exec {LOCK_FD}> "$ROOT/run/manage.lock"
    flock -w 10 "$LOCK_FD" || die '另一个VPSKit管理操作仍在进行。'
    WORK=$(mktemp -d /run/vpskit-uninstall-work.XXXXXXXX)
    chmod 700 "$WORK"
    LOGFILE=''
}
s5_previous_menu_catalog() {
    s4_previous_menu_catalog | awk -F'|' '$1!="uninstall" && $1!="sharedremove"'
    cat <<'VPSKIT_STAGE4_MENU'
uninstall|1|卸载范围与依赖预览|只列出目标、共享引用、软件包影响和保留项|不停止服务，不删除文件，不创建正式备份|read|s4-plan
uninstall|2|分步卸载向导|编号选择仅撤配置或删除项目，再选择共享程序和数据|默认保留共享程序和数据；删除前外部备份与口令确认|danger|s4-wizard
uninstall|3|仅停用并撤下项目配置|停止本项目节点和续期，保留程序/数据/共享网站|不只撤网站；使用卸载收据restore重新启用|warn|s4-config
uninstall|4|卸载收据与状态|按编号查看完整/部分失败的执行记录|root私有，可能含路径，不含终端明文密钥|read|s4-status
uninstall|5|继续未完成卸载|沿用原确认范围，不扩大删除对象|重新核对；失败保留备份，不强杀外部进程|danger|s4-resume
uninstall|6|按收据恢复项目|恢复本次被改动文件与服务，拒绝覆盖后续编辑|APT软件包需先补装；不回滚CA、外部服务或云资源|warn|s4-restore
uninstall|7|卸载残留核对|区分待处理目标和刻意保留的数据/系统记录|只读；不自动清日志、证书或云快照|read|s4-audit
uninstall|8|仅撤共享网站片段|继续保留Xray直连节点和其他项目服务|不是完整停用；候选检查后reload共享Nginx|danger|provider-detach
uninstall|9|共享组件移除|进入检查严格的单组件入口|未知外部依赖不会被强制删除|nav|menu:sharedremove
uninstall|10|独立单组件移除|保留原单组件流程和依赖校验|完整项目卸载请使用本页向导|nav|menu:isolatedremove
uninstall|11|系统资源保留与清理|网络、BBR、防火墙和Swap需单独确认|卸载默认保留，避免断开SSH或删除活跃Swap|nav|menu:network
uninstall|13|准备全新安装|完整删除六类数据后解除卸载标记|需NEW VPSKIT INSTALL；不删除独立备份或系统规则|warn|s4-prepare-install
uninstall|12|卸载操作说明|解释备份、删除、恢复与无法保证的外部依赖|不提供强制清空/etc或APT autoremove|read|s3-help-uninstall
uninstall|0|返回上一级|不修改配置|已提交的配置保留|back|back
sharedremove|1|共享组件归属|查看安装来源及程序路径|只读，程序共享不等于公开私钥|read|provider-show
sharedremove|2|共享卸载完整向导|先撤项目再选择共享Nginx/ACME|发现外部依赖时阻止；程序与数据独立确认|danger|s4-wizard
sharedremove|3|仅撤项目网站配置|不删除系统程序和其他网站|项目Xray直连节点仍可能运行|danger|provider-detach
sharedremove|0|返回上一级|不修改配置|已提交的配置保留|back|back
VPSKIT_STAGE4_MENU
}
s5_previous_menu_dispatch() {
    case "$1" in
        s4-plan) menu_run uninstall plan;;
        s4-wizard) menu_run uninstall wizard;;
        s4-config) menu_run uninstall apply --scope=config;;
        s4-status) menu_run uninstall status;;
        s4-resume) menu_run uninstall resume;;
        s4-restore) menu_run uninstall restore;;
        s4-audit) menu_run uninstall audit;;
        s4-prepare-install) menu_run uninstall prepare-install;;
        *) s4_previous_menu_dispatch "$@";;
    esac
}
s5_previous_usage() {
    s4_previous_usage "$@"
    cat <<'VPSKIT_STAGE4_HELP'

阶段4：共享卸载与执行记录（默认不删共享程序/网站/证书）：
  uninstall                           打开卸载面板
  uninstall wizard                    编号向导；每类删除分别确认
  uninstall plan [选项]                只预览，不改变服务/配置
  uninstall apply [选项]               备份→停用/撤配置→可选删除→残留核对
    --scope=config|project            默认config；project包含管理代码/私有程序
    --remove-shared=nginx,acme         可选；只用于project；逐组件口令
    --delete-data=config,web,certs,accounts,logs,history  可选，支持all
  uninstall status [ID]                查看外部卸载收据，省略ID按编号选择
  uninstall resume [ID]                继续原范围，不能扩大选择
  uninstall restore [ID]               冲突检查后恢复；APT不自动重装
  uninstall audit [ID]                 核对待处理项及保留项，不自动删除
  uninstall prepare-install [ID]       完整删除六类数据成功后，明确解除标记以便全新安装
备份默认：/var/backups/vpskit-uninstall/，root私有，不随项目卸载自动删除。
卸载后的apply/节点修改被阻止，需明确按收据restore；只更新代码不触发卸载。
SSH/防火墙/BBR/Swap、外部账户/站点、系统日志和云快照默认保留。
APT使用remove不purge、不autoremove；扫描是有限覆盖，不能证明外部依赖不存在。
VPSKIT_STAGE4_HELP
}

# -----------------------------------------------------------------------------
# 2.0.4: small, deterministic input helpers. Existing CLI arguments remain valid.
# No new daemon, public IP discovery request, token echo, or implicit key rotation.
# -----------------------------------------------------------------------------
smart_choice_label() {
    case "$1" in
        true) printf '开启 / 是';; false) printf '关闭 / 否';;
        template) printf '模板静态网站';; custom) printf '自有静态文件';;
        proxy) printf '本机HTTP反向代理';; redirect) printf 'HTTPS跳转';;
        direct) printf '直连源站';; cloudflare) printf 'Cloudflare橙云回源';;
        http) printf 'HTTP / HTTP-01（按本菜单用途）';;
        dns_cf) printf 'Cloudflare DNS-01';; dns_dp) printf 'DNSPod DNS-01';;
        welcome) printf '欢迎页';; notes) printf '技术笔记模板';; blog) printf '博客模板';;
        A) printf '方案A：REALITY直连';; B) printf '方案B：网站TLS + XHTTP';;
        tcp) printf TCP;; udp) printf UDP;; both) printf 'TCP + UDP';;
        off) printf '关闭';; observe) printf '观察模式';; enforce) printf '强制验证';;
        ai) printf 'AI爬虫规则';; common) printf '常见爬虫规则';; all) printf '全部（请核对本菜单影响范围）';;
        bots) printf '爬虫策略';; rate) printf '每秒请求速率';; burst) printf '突发请求配额';;
        connections) printf '连接数限制';; kbps) printf '传输速率限制';; static_ttl) printf '静态缓存时间';;
        gzip) printf '文本压缩';; origin) printf '回源来源限制';; aop) printf '回源客户端证书验证';;
        *) printf '%s' "$1";;
    esac
}
ask_valid() {
    local svd=$1 svt=$2 svdef=$3 svcheck=$4 svv svout
    local -a svopts=()
    shift 4
    case "$svcheck" in
        choice)
            for svv in $1; do svopts+=("$svv|$(smart_choice_label "$svv") [$svv]"); done
            select_value svout "$svt" "$svdef" "${svopts[@]}"
            printf -v "$svd" '%s' "$svout";;
        valid_bool)
            select_value svout "$svt" "${svdef:-false}" 'false|关闭 / 否' 'true|开启 / 是'
            printf -v "$svd" '%s' "$svout";;
        *) s5_legacy_ask_valid "$svd" "$svt" "$svdef" "$svcheck" "$@";;
    esac
}
smart_host_select() {
    local shdest=$1 shtitle=$2 shdefault=${3:-} shraw='' shhost shchosen
    local -a shopts=(); local -A shseen=()
    [[ -z $shdefault ]] || shraw+="$shdefault"$'\n'
    if [[ -s $STATE ]]; then
        shraw+=$(jq -r '[.host, (.nodes // [])[].host, (.native_nodes // [])[].host] | .[] | select(type=="string" and length>0)' "$STATE") || return 1
    fi
    while IFS= read -r shhost; do
        valid_host "$shhost" || continue
        [[ -z ${shseen[$shhost]+x} ]] || continue
        shseen[$shhost]=1
        shopts+=("$shhost|$shhost（已保存；直连用途请确认不是橙云/NAT内网地址）")
    done <<< "$shraw"
    if ((${#shopts[@]})); then
        shopts+=('manual|输入一个新的IP或域名')
        select_value shchosen "$shtitle" "$shdefault" "${shopts[@]}"
    else shchosen=manual; fi
    if [[ $shchosen == manual ]]; then
        s5_legacy_ask_valid shchosen "$shtitle（首次需填写真实地址，不自动猜公网IP）" "$shdefault" valid_host
    fi
    printf -v "$shdest" '%s' "$shchosen"
}
smart_sni_select() {
    local ssdest=$1 ssvalue ssdefault=www.microsoft.com ssrow
    local -a ssoptions=(); local -A ssseen=()
    while IFS= read -r ssrow; do
        valid_domain "$ssrow" || continue
        [[ -z ${ssseen[$ssrow]+x} ]] || continue
        ssseen[$ssrow]=1; ssoptions+=("$ssrow|$ssrow（现有REALITY目标，不保证当前可达）")
    done < <(jq -r '(.nodes // [])[] | .sni // empty | select(length>0)' "$STATE")
    if ((${#ssoptions[@]})); then ssdefault=${ssoptions[0]%%|*};
    else ssoptions+=("$ssdefault|$ssdefault（示例目标；TLS1.3及可达性需验证）"); fi
    ssoptions+=('manual|指定其他目标域名')
    select_value ssvalue 'REALITY目标/SNI；不自动探测第三方目标' "$ssdefault" "${ssoptions[@]}"
    [[ $ssvalue != manual ]] || s5_legacy_ask_valid ssvalue '目标域名' "$ssdefault" valid_domain
    printf -v "$ssdest" '%s' "$ssvalue"
}
node_set_credential() {
    local id n p m value action candidate="$WORK/credential.next.json"
    node_select id "${1:-}"
    n=$(jq -c --arg id "$id" '.nodes[]|select(.id==$id)' "$STATE") || return 1
    p=$(jq -r .protocol <<< "$n"); m=$(jq -r '.method // ""' <<< "$n")
    select_value action '凭据设置（不会显示已有凭据；新增节点仍默认自动生成）' keep \
        'keep|保留当前UUID/密码：不修改，不重启' \
        'generate|生成新的随机UUID/密码：需同步所有客户端' \
        'manual|手动填写新的UUID/密码（不回显）'
    [[ $action != keep ]] || { info '保留原凭据，没有创建事务。'; return 0; }
    if [[ $action == generate ]]; then value=$(node_credential "$p" "$m")
    else
        secret value '新UUID/密码；直接回车取消修改并保留原值'
        [[ -n $value ]] || { info '保留原凭据。'; return 0; }
    fi
    [[ $value != "$(jq -r .credential <<< "$n")" ]] || { info '凭据未变，不操作服务。'; return 0; }
    jq --arg id "$id" --arg c "$value" '(.nodes[]|select(.id==$id)).credential=$c' "$STATE" > "$candidate" || return 1
    (validate_state "$candidate" no) || { warn '新凭据未通过校验，原配置未改。请重新选择自动生成或重新填写。'; return 1; }
    confirm "更新 $id 凭据并应用；需要同步客户端，Xray可能重启" || return 0
    begin_tx "node-credential:$id"; install -m 600 "$candidate" "$STATE"; apply_config; commit_tx
}

# Port inventory is sampled ONCE per chooser, not jq + ss for every candidate.
# Reserve disabled nodes too; conservatively keep TCP and UDP numbers distinct.
declare -A SMART_RESERVED=()
SMART_SOCKET_TEXT=''
smart_port_snapshot() {
    local spr sptext spstate='' spssh
    SMART_RESERVED=(); SMART_SOCKET_TEXT=''
    need ss
    sptext=$(ss -H -antu 2>/dev/null) || { warn '无法读取套接字；不把查询失败当成空闲。'; return 1; }
    SMART_SOCKET_TEXT=$sptext
    if [[ -e $STATE ]]; then
        spstate=$(jq -er 'select(type=="object" and (.nodes|type=="array")) |
          [(.nodes // [])[].port, (.native_nodes // [])[].inbound.port] | .[]?' "$STATE" 2>/dev/null) || {
            # jq -e returns 4 when the valid array is empty; verify structure separately.
            jq -e 'type=="object" and (.nodes|type=="array") and ((.native_nodes // [])|type=="array")' "$STATE" >/dev/null 2>&1 || {
                warn '状态文件不能解析，未猜测可分配端口。'; return 1; }
        }
    fi
    while IFS= read -r spr; do
        valid_port "$spr" || { [[ -z $spr ]] && continue; warn '配置中存在非数值/异常端口。'; return 1; }
        SMART_RESERVED[$spr]='配置保留（包含停用节点）'
    done <<< "$spstate"
    while IFS= read -r spr; do
        valid_port "$spr" || continue
        SMART_RESERVED[$spr]='本机已有TCP/UDP绑定'
    done < <(awk '$1=="tcp" || $1=="udp" {n=split($5,a,":");if(a[n]~/^[0-9]+$/)print a[n]}' <<< "$sptext")
    spssh=$(ssh_ports) || return 1
    while IFS= read -r spr; do valid_port "$spr" && SMART_RESERVED[$spr]='SSH保护端口'; done <<< "$spssh"
    SMART_RESERVED[22]='SSH'; SMART_RESERVED[80]='HTTP共享入口'; SMART_RESERVED[443]='HTTPS共享入口'
    return 0
}
smart_next_port() {
    local snp=${1:-8443}
    valid_port "$snp" || return 1
    while ((snp<=65535)); do
        if [[ -z ${SMART_RESERVED[$snp]+x} ]]; then printf '%s\n' "$snp"; return 0; fi
        snp=$((snp+1))
    done
    return 1
}
unused_port() {
    smart_port_snapshot || return 1
    smart_next_port "${1:-20000}" || { warn '可选端口范围已耗尽。'; return 1; }
}
smart_port_select() {
    local spdest=$1 sptitle=$2 spstart=${3:-8443} spkeep=${4:-} sppick spnext spi
    local -a spopts=()
    while :; do
        smart_port_snapshot || return 1
        spopts=()
        if [[ -n $spkeep ]]; then spopts+=("$spkeep|保留当前 $spkeep（不改变端口）"); fi
        spnext=$spstart
        for ((spi=0;spi<3;spi++)); do
            spnext=$(smart_next_port "$spnext") || break
            spopts+=("$spnext|$spnext（本次采样未占用；TCP/UDP与配置均已排除）")
            spnext=$((spnext+1)); ((spnext<=65535)) || break
        done
        spopts+=('manual|手工指定端口，再次检测冲突')
        select_value sppick "$sptitle（输入左侧序号，不用输入端口长数字）" "${spkeep:-${spopts[0]%%|*}}" "${spopts[@]}"
        if [[ $sppick == manual ]]; then s5_legacy_ask_valid sppick '指定监听端口' "$spstart" valid_port; fi
        if [[ -n $spkeep && $sppick == "$spkeep" ]]; then printf -v "$spdest" '%s' "$sppick"; return; fi
        # Re-sample after user input; final configuration/start checks still apply.
        smart_port_snapshot || return 1
        if [[ -z ${SMART_RESERVED[$sppick]+x} ]]; then printf -v "$spdest" '%s' "$sppick"; return 0; fi
        warn "端口 $sppick：${SMART_RESERVED[$sppick]}；不会杀占用进程，请重新选择。"
        ss -H -lntup "sport = :$sppick" >&2 || true
    done
}
fw_choose_zone() {
    local fzdest=$1 fzbackend=$2 fzvalue='' fzitem fzactive fzdefault fzall
    local -a fzopts=()
    if [[ $fzbackend == firewalld ]]; then
        fzactive=$(firewall-cmd --get-active-zones) || return 1
        fzall=$(firewall-cmd --get-zones) || return 1
        fzdefault=$(firewall-cmd --get-default-zone) || return 1
        printf '当前活动zone与接口/来源：\n%s\n' "$fzactive" >&2
        for fzitem in $fzall; do
            [[ $fzitem =~ ^[a-zA-Z0-9_-]+$ ]] || return 1
            if grep -qxF "$fzitem" <<< "$fzactive"; then fzopts+=("$fzitem|$fzitem（活动；请核对上方接口/来源）")
            else fzopts+=("$fzitem|$fzitem（未在活动列表列出）"); fi
        done
        select_value fzvalue '选择防火墙zone（默认zone不一定就是公网接口zone）' "$fzdefault" "${fzopts[@]}"
    fi
    printf -v "$fzdest" '%s' "$fzvalue"
}
firewall_required() {
    state_basic "$STATE" 2>/dev/null || return 0
    firewall_required_state "$STATE"
}
smart_firewall_choose() {
    local sfcdest=$1 sfcport sfcproto sfcrules sfcpick sfckey
    local -a sfcopts=(); local -A sfcseen=()
    sfcrules=''
    if state_basic "$STATE" 2>/dev/null; then sfcrules=$(firewall_required_state "$STATE") || return 1; fi
    while read -r sfcport sfcproto; do
        valid_port "$sfcport" && choice "$sfcproto" 'tcp udp' || continue
        sfckey="$sfcport/$sfcproto"; [[ -z ${sfcseen[$sfckey]+x} ]] || continue
        sfcseen[$sfckey]=1; sfcopts+=("$sfckey|$sfckey（项目公网入口；不是代理回环后端）")
    done <<< "$sfcrules"
    sfcopts+=('manual|手工指定其他端口与TCP/UDP')
    select_value sfcpick '选择需要处理的端口（编号）' '' "${sfcopts[@]}"
    printf -v "$sfcdest" '%s' "$sfcpick"
}
firewall_change() {
    local action=$1 port=${2:-} proto=${3:-} chosen
    if [[ -z $port ]]; then
        smart_firewall_choose chosen || return 1
        if [[ $chosen != manual ]]; then port=${chosen%/*}; proto=${chosen##*/}; fi
    fi
    [[ -n $port ]] || s5_legacy_ask_valid port '端口（禁止SSH）' '' valid_port
    [[ -n $proto ]] || select_value proto '传输协议' tcp 'tcp|TCP' 'udp|UDP' 'both|TCP和UDP'
    valid_port "$port" || return 1
    printf '\n端口当前的进程监听（不是防火墙放行状态；没有输出表示未发现监听）：\n'
    ss -H -lntup "sport = :$port" || return 1
    s5_legacy_firewall_change "$action" "$port" "$proto"
}
smart_after_node() {
    local sanhow=check
    recovery_firewall check || true
    [[ -n $TTY_FD ]] || return 0
    select_value sanhow '节点已保存：是否同时核对并补齐本机防火墙？' check \
      'check|暂不修改规则（默认）；已有规则、云安全组需自行核对' \
      'sync|编号选择zone并确认：补齐项目公网入口，跳过SSH和回环后端'
    [[ $sanhow != sync ]] || recovery_firewall sync
}
smart_ports_command() {
    case "${1:-show}" in
        show|audit)
            printf '本机TCP/UDP监听及进程（不代表公网可达）：\n'
            ss -H -lntup || return 1
            if state_basic "$STATE" 2>/dev/null; then recovery_firewall check; fi
            ui_note '进程占用、保存的节点端口、防火墙规则、云安全组是四层信息；没有放行不等于端口可分配。';;
        suggest)
            smart_port_snapshot || return 1
            local sp=${2:-8443} si
            valid_port "$sp" || die '起始端口无效。'
            for ((si=0;si<5;si++)); do sp=$(smart_next_port "$sp") || break; printf '%d. %s\n' "$((si+1))" "$sp"; sp=$((sp+1)); ((sp<=65535)) || break; done;;
        *) die 'ports: show/audit/suggest [起始端口]。';;
    esac
}
# Emergency path is deliberately entered BEFORE mode_load / state validation.
# Force means ignoring damaged project metadata, not following symlinks, erasing
# /etc/nginx, deleting SSH, bypassing kernel errors or killing all nginx processes.
SMART_EMERGENCY_STORE='/var/backups/vpskit-emergency'
SMART_EMERGENCY_LOCK='/run/lock/vpskit-emergency.lock'
SMART_EMERGENCY_PROC='/proc'
SMART_POLICY='/usr/sbin/policy-rc.d'
SMART_EMERGENCY_UNITS=(vpskit-maintain.timer vpskit-maintain.service vpskit-xray.service vpskit-nginx.service)
declare -a SMART_PURGE_PATHS=()
smart_emergency_path_safe() {
    local sep=$1 sem
    [[ $sep == /* && $sep != / && $sep != *[[:cntrl:]]* && $(realpath -ms "$sep") == "$sep" &&
       $(realpath -m "${sep%/*}") == "${sep%/*}" ]] || return 1
    # A final symlink can be unlinked, but no symlink parent is traversed.
    while IFS= read -r sem; do
        [[ $sem != "$sep" && $sem != "$sep/"* ]] || { warn "含挂载点，不自动卸载/递归清理：$sem"; return 1; }
    done <<< "$SMART_MOUNTS"
    return 0
}
smart_emergency_collect() {
    local sec p f u
    SMART_PURGE_PATHS=()
    [[ ! -L $ROOT && ( ! -e $ROOT || -d $ROOT ) ]] || { warn '项目根目录是链接或非目录；不进行强制递归删除。'; return 1; }
    smart_emergency_path_safe "$ROOT" || return 1
    if [[ -d $ROOT ]]; then
        [[ $(stat -c %u "$ROOT") == 0 ]] || { warn '项目根目录不属于root；请先确认位置。'; return 1; }
        while IFS= read -r -d '' p; do
            case "${p##*/}" in data|run|swap|.vpskit-owned) continue;; esac
            SMART_PURGE_PATHS+=("$p")
        done < <(find -P "$ROOT" -mindepth 1 -maxdepth 1 -print0)
        # Keep optional system resources AND their ownership records, never erase
        # an active swap file or SSH/firewall rollback provenance as 'garbage'.
        for sec in data run; do
            if [[ -L $ROOT/$sec ]]; then SMART_PURGE_PATHS+=("$ROOT/$sec"); continue; fi
            [[ ! -e $ROOT/$sec || -d $ROOT/$sec ]] || { SMART_PURGE_PATHS+=("$ROOT/$sec"); continue; }
            [[ -d $ROOT/$sec ]] || continue
            while IFS= read -r -d '' p; do
                f=${p##*/}
                if [[ $sec == data ]]; then
                    case "$f" in firewall.json|firewall-v2.json|bbr-v2.json|swap-v2.json|swap.json) continue;; esac
                else [[ $f != manage.lock ]] || continue; fi
                SMART_PURGE_PATHS+=("$p")
            done < <(find -P "$ROOT/$sec" -mindepth 1 -maxdepth 1 -print0)
        done
    fi
    for u in "${SMART_EMERGENCY_UNITS[@]}"; do
        for p in "$SYSTEMD/$u" "$SYSTEMD/$u.d" "$RUNTIME_UNIT_DIR/$u" "$RUNTIME_UNIT_DIR/$u.d"; do
            [[ ! -e $p && ! -L $p ]] || SMART_PURGE_PATHS+=("$p")
        done
    done
    if [[ -e $ENTRY || -L $ENTRY ]]; then
        if [[ -L $ENTRY && $(readlink "$ENTRY") == "$ROOT/vpskit.sh" ]] ||
           { [[ -f $ENTRY && ! -L $ENTRY ]] && grep -Fq '# VPSKIT_SINGLE_FILE' "$ENTRY"; }; then
            SMART_PURGE_PATHS+=("$ENTRY")
        else warn "保留不属于VPSKit的入口：$ENTRY"; SMART_RETAINED_ENTRY=yes; fi
    fi
    if [[ -e $SHARED_INCLUDE || -L $SHARED_INCLUDE ]]; then SMART_PURGE_PATHS+=("$SHARED_INCLUDE"); fi
    for p in "${SMART_PURGE_PATHS[@]}"; do smart_emergency_path_safe "$p" || return 1; done
    return 0
}
smart_emergency_live_unit() {
    local seunit=$1 sestate
    sestate=$(systemctl show -p ActiveState --value "$seunit" 2>/dev/null) || return 2
    case "$sestate" in inactive|failed|'') return 1;; *) return 0;; esac
}
smart_emergency_stop_unit() {
    local seunit=$1 sestate load tries
    load=$(systemctl show -p LoadState --value "$seunit" 2>/dev/null) || { warn "无法查询服务：$seunit"; return 1; }
    [[ $load != not-found && -n $load ]] || return 0
    # No unrelated unit names accepted, even in emergency mode.
    case "$seunit" in vpskit-maintain.timer|vpskit-maintain.service|vpskit-xray.service|vpskit-nginx.service|nginx.service) ;; *) return 1;; esac
    systemctl disable "$seunit" >/dev/null 2>&1 || warn "无法取消 $seunit 自启，将核对残留。"
    if ! timeout 20 systemctl stop "$seunit"; then warn "$seunit 未正常停止，强制终止其服务组（不是全部同名进程）。"; fi
    if smart_emergency_live_unit "$seunit"; then
        systemctl kill --signal=KILL "$seunit" || return 1
        timeout 5 systemctl stop "$seunit" >/dev/null 2>&1 || true
    fi
    for ((tries=0;tries<20;tries++)); do
        sestate=$(systemctl show -p ActiveState --value "$seunit" 2>/dev/null) || return 1
        case "$sestate" in inactive|failed|'') systemctl reset-failed "$seunit" >/dev/null 2>&1 || true; return 0;; esac
        sleep .1
    done
    warn "$seunit 仍未停止；未删除它使用的项目资料。"; return 1
}
smart_emergency_private_pids() {
    local spdir spexe
    for spdir in "$SMART_EMERGENCY_PROC"/[0-9]*; do
        [[ -d $spdir ]] || continue
        spexe=$(readlink "$spdir/exe" 2>/dev/null) || continue
        spexe=${spexe% (deleted)}
        case "$spexe" in "$ROOT/bin/xray"|"$ROOT/nginx/usr/sbin/nginx") printf '%s\n' "${spdir##*/}";; esac
    done
}
smart_emergency_stop_private() {
    local sep sebirth senow tries
    # Kill orphaned private binaries only; do not match process names or command
    # strings (which can contain this project's path as unrelated arguments).
    while IFS= read -r sep; do
        [[ $sep =~ ^[1-9][0-9]*$ && $sep != 1 && $sep != $$ && $sep != "$BASHPID" ]] || return 1
        sebirth=$(proc_start_ticks "$sep") || return 1
        kill -TERM "$sep" 2>/dev/null || true
        for ((tries=0;tries<20;tries++)); do [[ ! -e /proc/$sep ]] && break; sleep .1; done
        senow=$(proc_start_ticks "$sep" 2>/dev/null || true)
        if [[ -n $senow && $senow == "$sebirth" ]]; then kill -KILL "$sep" || return 1; fi
    done < <(smart_emergency_private_pids)
    for ((tries=0;tries<20;tries++)); do
        [[ -n $(smart_emergency_private_pids) ]] || return 0
        sleep .1
    done
    warn '仍有私有Xray/Nginx进程（可能处于不可中断状态），未继续删除。'; return 1
}
smart_emergency_archive() {
    local ser=$1 p rel list source_files=0
    list="$ser/backup-paths.nul"
    : > "$list"
    for p in "${SMART_PURGE_PATHS[@]}"; do
        [[ -e $p || -L $p ]] || continue
        case "$p" in "$ROOT/logs"|"$ROOT/logs/"*|"$ROOT/tmp"|"$ROOT/tmp/"*|"$ROOT/run"|"$ROOT/run/"*|"$ROOT/backup"|"$ROOT/rebuild-backups") continue;; esac
        printf '%s\0' "${p#/}" >> "$list"; source_files=$((source_files+1))
    done
    # Default archive covers selected current config/code/web/certs/accounts,
    # not old archives, temporary data, live logs or system swap.
    if ((source_files)); then
        tar --one-file-system -cpf "$ser/current.tar" -C / --null --verbatim-files-from -T "$list" || {
            warn '备份读取/空间/并发写入错误；没有停止服务。可修复后重试，或明确使用--no-backup承担丢失风险。'; return 1; }
        tar -tf "$ser/current.tar" >/dev/null || return 1
        (cd "$ser"; sha256sum current.tar > SHA256SUMS; sha256sum -c SHA256SUMS >/dev/null) || return 1
    fi
    return 0
}
smart_emergency_detach_shared() {
    local ser=$1 stop=$2 existed=no out live_rc=0
    out="$ser/shared-check.log"
    if [[ -e $SHARED_INCLUDE || -L $SHARED_INCLUDE ]]; then
        existed=yes; cp -a -- "$SHARED_INCLUDE" "$ser/project-include.before" || return 1
    fi
    if [[ $stop == yes ]]; then
        smart_emergency_stop_unit nginx.service || return 1
        [[ $existed != yes ]] || rm -f -- "$SHARED_INCLUDE" || return 1
        return 0
    fi
    [[ $existed != yes ]] || rm -f -- "$SHARED_INCLUDE" || return 1
    if [[ -x $SHARED_NGINX && -f $SHARED_MAIN ]]; then
        # Validate remaining external sites after excluding this (possibly broken)
        # fragment. We do not require the OLD configuration to parse successfully.
        if ! "$SHARED_NGINX" -T -c "$SHARED_MAIN" > "$out" 2>&1 ||
           grep -F "$ROOT/" "$out" | grep -Ev '^[[:space:]]*#' >/dev/null; then
            if [[ $existed == yes ]]; then cp -a -- "$ser/project-include.before" "$SHARED_INCLUDE" || return 1; fi
            warn "外部Nginx配置仍有错误或引用 $ROOT；已还原项目片段，未清空项目。"
            warn '确需中断所有共享网站后强清，可重新使用 --stop-shared；这不是跳过检查后继续运行错误配置。'
            return 1
        fi
        if systemctl is-active --quiet nginx.service; then
            if ! systemctl reload nginx.service; then
                [[ $existed != yes ]] || cp -a -- "$ser/project-include.before" "$SHARED_INCLUDE"
                warn '共享重载失败，保留项目数据；请恢复服务，或明确选择--stop-shared。'; return 1
            fi
        fi
    else
        # Missing fragment/main does not prove the already-loaded shared master
        # has no references to the project. Unknown service state is not stopped.
        if smart_emergency_live_unit nginx.service; then live_rc=0; else live_rc=$?; fi
        if ((live_rc!=1)); then
            [[ $existed != yes ]] || cp -a -- "$ser/project-include.before" "$SHARED_INCLUDE" || return 1
            warn '共享服务仍运行或无法查询，且没有完整程序/主配置可验证；未删项目资料。'
            warn '确认中断共享网站时使用--stop-shared；无法查询/停止服务时仍需修复系统管理器。'
            return 1
        fi
    fi
    return 0
}
smart_emergency_show() {
    printf '\n强力清理计划（不读取损坏的state/installation/历史快照）\n'
    printf '项目根目录：%s\n' "$ROOT"
    printf '固定私有服务：%s\n' "${SMART_EMERGENCY_UNITS[*]}"
    printf '将删除：项目配置/节点/UUID/网站/证书/私有程序/旧事务；不是保留配置重装。\n'
    local sp; for sp in "${SMART_PURGE_PATHS[@]}"; do printf '  - %s\n' "$sp"; done
    printf '共享组件删除：%s；停止共享Nginx：%s；备份：%s\n' "${SMART_REMOVE:-无}" "$SMART_STOP_SHARED" "$SMART_BACKUP"
    printf '保留：SSH、防火墙/BBR/Swap与归属记录、外部站点配置/账户、系统日志、云快照、项目外备份。\n'
    [[ $SMART_STOP_SHARED != yes ]] || warn '已选择停止共享Nginx：该服务器其他共享网站也将中断。'
    [[ -z $SMART_REMOVE ]] || warn '已选择删除共享程序：忽略外部使用者阻止，但仍不删除外部配置/账户或非Nginx软件包。'
    [[ ${SMART_RETAINED_ENTRY:-no} != yes ]] || warn '全局入口不属于本工具，将保留并在结果中报告。'
}
smart_emergency_delete() {
    local sp
    for sp in "${SMART_PURGE_PATHS[@]}"; do
        [[ -e $sp || -L $sp ]] || continue
        smart_emergency_path_safe "$sp" || return 1
        if [[ -d $sp && ! -L $sp ]]; then rm -rf --one-file-system -- "$sp" || return 1
        else rm -f -- "$sp" || return 1; fi
        [[ ! -e $sp && ! -L $sp ]] || { warn "删除未完成：$sp"; return 1; }
    done
    return 0
}
smart_emergency_apt_remove() {
    local ser=$1 check="$WORK/packages-recheck.json"
    local -a req=()
    s4_apt_plan "$check" || return 1
    jq -e --slurpfile old "$ser/packages.json" '.requested==$old[0].requested and .removed==$old[0].removed and .status_sha256==$old[0].status_sha256' "$check" >/dev/null || {
        warn 'APT影响范围已改变，停止删除软件包。'; return 1; }
    mapfile -t req < <(jq -r '.requested[]' "$check")
    ((${#req[@]})) || return 1
    DEBIAN_FRONTEND=noninteractive LC_ALL=C apt-get -y -o APT::Get::AutomaticRemove=false remove -- "${req[@]}" > "$ser/apt-remove.log" 2>&1 || return 1
    local pkg
    for pkg in "${req[@]}"; do [[ $(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null || true) != installed ]] || return 1; done
}
smart_install_after_clean() { exec bash "$1" install "$2"; }
smart_emergency_entry() (
    trap - EXIT ERR INT TERM
    set -Eeuo pipefail
    root_check
    local cmd=${1:-} kind=${2:-} reinstall='' execute=no arg token receipt='' oldlock='' gate='' changed=no partial=no sp u
    local WORK='' LOGFILE='' SMART_MOUNTS='' SMART_REMOVE='' SMART_STOP_SHARED=no SMART_BACKUP=yes SMART_RETAINED_ENTRY=no
    # Treat custom test seams only as internal variables, never environment args.
    case "$cmd" in
        emergency) shift; case "${1:-plan}" in plan) shift || true;; clean) execute=yes; shift;; *) die 'emergency plan|clean [--stop-shared] [--remove-shared=nginx,acme] [--no-backup]。';; esac;;
        uninstall) shift 2; execute=yes;;
        reinstall) shift; reinstall=${1:-shared}; (($#==0)) || shift; execute=yes;;
        install) shift; reinstall=${1:-shared}; (($#==0)) || shift; execute=yes;;
        *) return 1;;
    esac
    [[ -z $reinstall ]] || choice "$reinstall" 'shared isolated wizard' || die '重装模式为shared/isolated。'
    for arg in "$@"; do
        case "$arg" in
            --plan) execute=no;; --apply|--clean) execute=yes;; --stop-shared) SMART_STOP_SHARED=yes;;
            --no-backup) SMART_BACKUP=no;; --remove-shared=*) SMART_REMOVE=${arg#*=};;
            *) die "未知强制清理参数：$arg";;
        esac
    done
    choice "${SMART_REMOVE:-none}" 'none nginx acme nginx,acme acme,nginx' || die '共享删除仅支持nginx/acme；不接受任意路径或软件包名。'
    [[ ,$SMART_REMOVE, != *,nginx,* ]] || SMART_STOP_SHARED=yes
    for sp in flock findmnt realpath stat find ss tar sha256sum systemctl jq openssl; do need "$sp"; done
    [[ $SELF != /dev/fd/* && $SELF != /proc/* ]] || die '请下载为完整文件，不支持进程替换。'
    SELF=$(realpath -e -- "$SELF") || return 1
    [[ -f $SELF && ! -L $SELF ]] || die '强清/重装需要完整普通脚本文件。'
    if { exec {TTY_FD}<>/dev/tty; } 2>/dev/null; then :; else TTY_FD=''; fi
    if [[ $reinstall == wizard ]]; then select_value reinstall '全新安装模式（旧凭据会删除）' shared 'shared|系统共享' 'isolated|独立隔离'; fi
    [[ ! -L $SMART_EMERGENCY_LOCK && $(realpath -m "${SMART_EMERGENCY_LOCK%/*}") == "${SMART_EMERGENCY_LOCK%/*}" ]] || die '强清锁路径异常。'
    exec {gate}> "$SMART_EMERGENCY_LOCK"; flock -n "$gate" || die '另一个强清任务正在执行。'
    SMART_MOUNTS=$(findmnt -rn -o TARGET) || die '无法核对挂载点。'
    smart_emergency_collect || die '路径或挂载不安全；不会把强制解释为清空外部磁盘。'
    if [[ -d $ROOT/run && ! -L $ROOT/run ]]; then
        [[ ! -L $ROOT/run/manage.lock && ( ! -e $ROOT/run/manage.lock || -f $ROOT/run/manage.lock ) ]] || die '项目锁路径异常。'
        exec {oldlock}> "$ROOT/run/manage.lock"; flock -n "$oldlock" || die '另一个正常管理任务仍在运行；强清不删除其锁或竞争写入。'
    fi
    WORK=$(mktemp -d /run/vpskit-emergency.XXXXXXXX)
    trap 'rc=$?; trap - EXIT ERR INT TERM; set +e; if [[ -n $receipt && $changed == yes ]]; then printf "partial\n" > "$receipt/status"; printf "强清未完成；查看 %s；未报告为成功，不能直接假设可重装。\n" "$receipt" >&2; fi; [[ -z $WORK ]] || rm -rf -- "$WORK"; exit "$rc"' EXIT
    trap 'exit 130' INT; trap 'exit 143' TERM
    if [[ ,$SMART_REMOVE, == *,nginx,* ]]; then
        s4_apt_plan "$WORK/packages.json" || die 'APT不能生成仅含Nginx家族的移除计划；不以--force删除外部/系统关键包。'
        jq '{requested,removed}' "$WORK/packages.json"
    fi
    if [[ ,$SMART_REMOVE, == *,acme,* ]]; then
        for sp in "$SHARED_ACME_HOME" "$SHARED_ACME_ENTRY"; do smart_emergency_path_safe "$sp" || die '共享ACME路径不安全。'; done
        SMART_PURGE_PATHS+=("$SHARED_ACME_HOME" "$SHARED_ACME_ENTRY")
    fi
    smart_emergency_show
    [[ $execute == yes ]] || { info '仅预览。没有停止服务、删除文件或建立正式备份。'; return 0; }
    [[ -z $reinstall ]] || warn "清理成功后全新安装$reinstall；旧UUID/密码不会自动恢复，客户端需要重新配置。"
    ask token "输入项目路径 $ROOT 确认永久删除该项目的运行数据（而非仅更新）" ''
    [[ $token == "$ROOT" ]] || { info '未确认，取消。'; return 0; }
    if [[ $SMART_STOP_SHARED == yes ]]; then ask token '输入 STOP SHARED NGINX 确认其他网站也会中断' ''; [[ $token == 'STOP SHARED NGINX' ]] || return 0; fi
    if [[ -n $SMART_REMOVE ]]; then ask token '输入 REMOVE SHARED 确认删除选中的共享程序并接受外部依赖影响' ''; [[ $token == 'REMOVE SHARED' ]] || return 0; fi
    if [[ $SMART_BACKUP == no ]]; then ask token '输入 NO BACKUP 确认不备份当前配置/私钥/网站，数据可能无法恢复' ''; [[ $token == 'NO BACKUP' ]] || return 0; fi
    # Receipt location is root-owned and not inside the deletion scope.
    [[ $SMART_EMERGENCY_STORE != "$ROOT" && $SMART_EMERGENCY_STORE != "$ROOT/"* ]] || die '应急备份目录不能位于项目内。'
    s4_path "$SMART_EMERGENCY_STORE" && [[ ! -L $SMART_EMERGENCY_STORE ]] || die '应急备份路径异常。'
    mkdir -p -m 700 "$SMART_EMERGENCY_STORE"; [[ $(stat -c %u "$SMART_EMERGENCY_STORE") == 0 ]] || die '备份目录必须属于root。'; chmod 700 "$SMART_EMERGENCY_STORE"
    receipt="$SMART_EMERGENCY_STORE/$(date -u +%Y%m%dT%H%M%SZ)-$(randhex 4)"
    mkdir -m 700 "$receipt"
    smart_emergency_show > "$receipt/plan.txt"
    install -m 700 "$SELF" "$receipt/manager.sh"
    printf 'prepared\n' > "$receipt/status"
    [[ ! -f $WORK/packages.json ]] || cp "$WORK/packages.json" "$receipt/packages.json"
    if [[ $SMART_BACKUP == yes ]]; then smart_emergency_archive "$receipt" || return 1; else printf 'EXPLICIT_NO_BACKUP\n' > "$receipt/NO_BACKUP"; fi
    # From here failures are partial; a complete archive is not automatic service rollback.
    changed=yes; printf 'running\n' > "$receipt/status"
    printf 'detach-shared\n' > "$receipt/phase"
    smart_emergency_detach_shared "$receipt" "$SMART_STOP_SHARED" || return 1
    printf 'stop-private\n' > "$receipt/phase"
    for u in "${SMART_EMERGENCY_UNITS[@]}"; do smart_emergency_stop_unit "$u" || return 1; done
    smart_emergency_stop_private || return 1
    # Refresh mount inventory immediately before deletion; no unmounting or chattr.
    SMART_MOUNTS=$(findmnt -rn -o TARGET) || return 1
    for sp in "${SMART_PURGE_PATHS[@]}"; do smart_emergency_path_safe "$sp" || return 1; done
    if [[ ,$SMART_REMOVE, == *,nginx,* ]]; then smart_emergency_apt_remove "$receipt" || { warn "APT失败，详情：$receipt/apt-remove.log"; return 1; }; fi
    printf 'delete-project\n' > "$receipt/phase"
    smart_emergency_delete || return 1
    # Remove exact standard project enable-links left by a damaged/missing unit.
    for sp in "$SYSTEMD/multi-user.target.wants" "$SYSTEMD/timers.target.wants"; do
        [[ ! -d $sp || ( ! -L $sp && $(realpath -m "$sp") == "$sp" ) ]] || return 1
        [[ -d $sp ]] || continue
        for u in "${SMART_EMERGENCY_UNITS[@]}"; do
            [[ ! -L $sp/$u ]] || rm -f -- "$sp/$u" || return 1
        done
    done
    # An exact package-start inhibition leftover is removable; never replace a
    # foreign policy-rc.d merely to make installation work.
    if [[ -f $SMART_POLICY && ! -L $SMART_POLICY ]] &&
       [[ $(sha256sum "$SMART_POLICY" | cut -d' ' -f1) == "$(printf '#!/bin/sh\n# VPSKIT_TEMP_APT_POLICY\nexit 101\n' | sha256sum | cut -d' ' -f1)" ]]; then
        cp -a "$SMART_POLICY" "$receipt/policy-rc.d.before"; rm -f -- "$SMART_POLICY"
    fi
    systemctl daemon-reload || return 1
    for u in "${SMART_EMERGENCY_UNITS[@]}"; do
        if smart_emergency_live_unit "$u"; then warn "$u 仍在运行"; return 1; fi
        # A query error is not 'stopped'.
        systemctl show -p ActiveState --value "$u" >/dev/null 2>&1 || return 1
    done
    [[ -z $(smart_emergency_private_pids) ]] || return 1
    # Tiny ownership marker, resource records and the lock may intentionally remain.
    if [[ -d $ROOT ]]; then
        [[ ! -L $ROOT/.vpskit-owned ]] || rm -f -- "$ROOT/.vpskit-owned"
        printf 'VPSKIT_V1\n' > "$ROOT/.vpskit-owned"; chmod 700 "$ROOT"
    fi
    printf 'complete\n' > "$receipt/status"; changed=no
    ok "项目强清范围已完成，结果和独立备份：$receipt"
    info '系统Swap/BBR/防火墙及归属记录、外部Nginx配置/ACME账户/系统日志保留；不是整机恢复出厂。'
    [[ $SMART_RETAINED_ENTRY != yes ]] || { warn '外部同名命令入口保留；请先改名该入口再安装。'; partial=yes; }
    if [[ -n $reinstall ]]; then
        [[ $partial != yes ]] || return 1
        [[ -z $oldlock ]] || exec {oldlock}>&-
        exec {gate}>&-
        rm -rf -- "$WORK"; WORK=''
        trap - EXIT ERR INT TERM
        smart_install_after_clean "$receipt/manager.sh" "$reinstall"
    fi
)

menu_catalog() {
    s5_previous_menu_catalog
    cat <<'SMART_MENU'
providers|10|清理残留后全新安装|编号选择安装模式；先独立备份并强清项目，再安装|旧节点/UUID会删除；共享程序默认保留；失败不假报成功|danger|smart-reinstall
uninstall|14|强力卸载：忽略损坏登记|独立清理入口，不要求旧state/模式/事务校验通过|先预览和确认项目路径；默认外部备份；不删除外部项目|danger|smart-emergency
firewall|7|端口占用与防火墙核对|合并查看TCP/UDP进程监听和项目规则状态|只读；本机监听不等于公网可达|read|smart-ports
network|9|智能端口推荐|一次采样，排除传统/原生/停用/SSH及占用端口|只推荐，不抢占进程，不自动开放端口|read|smart-suggest
SMART_MENU
}
menu_dispatch() {
    case "$1" in
        smart-emergency) menu_run emergency clean;;
        smart-reinstall) menu_run reinstall wizard --clean;;
        smart-ports) menu_run ports show;; smart-suggest) menu_run ports suggest;;
        *) s5_previous_menu_dispatch "$@";;
    esac
}
usage() {
    s5_previous_usage "$@"
    cat <<'SMART_HELP'

2.0.4 操作简化与应急清理：
  ports show | ports suggest [8443]         本机端口/规则核对，或可用端口建议
  uninstall force --plan                  强清预览；损坏的state/installation也可用
  uninstall force [--apply]               确认项目路径后强清，仅本项目，默认独立备份
  emergency plan | emergency clean        同上独立入口，不依赖正常模式/事务解析
    --stop-shared                         明确停止共享Nginx（所有共享网站中断）
    --remove-shared=nginx,acme             显式删除共享程序，须额外确认外部依赖影响
    --no-backup                           仅应急：须NO BACKUP确认不可恢复风险
  reinstall shared|isolated --clean        强清完成后从空配置安装；旧UUID/密码不保留
  install shared|isolated --clean          同上（普通install仍保留已有配置）
默认备份：/var/backups/vpskit-emergency/，含当前配置/程序/证书/账户/网站；旧历史、日志、临时和Swap不备份。
强制不绕过：路径/挂载安全、运行管理锁、SSH/Swap保护、APT非Nginx包边界、停止失败/磁盘错误。
不会用rm清空/etc/nginx，不自动复活旧凭据。未完成报告partial；只有成功才继续重装。
普通向导的枚举改为编号；编辑凭据默认保留，新增仍独立随机生成。危险词确认有意保留。
SMART_HELP
}
# Existing secrets are never shown or copied between users. Reuse means let ACME
# read its private saved configuration, not eval/source its contents in the manager.
dns_credentials() {
    local provider=$1 dcaction=input dcfound=no
    case "$provider" in
        dns_cf) grep -Rq '^SAVED_CF_Token=' "$ROOT/acme/config" 2>/dev/null && dcfound=yes;;
        dns_dp) grep -Rq '^SAVED_DP_Id=' "$ROOT/acme/config" 2>/dev/null && dcfound=yes;;
        *) return 0;;
    esac
    if [[ $dcfound == yes ]]; then
        select_value dcaction 'DNS API凭据' reuse 'reuse|复用ACME已保存凭据（不显示，不重新输入）' 'input|更换凭据（不回显）'
        [[ $dcaction != reuse ]] || return 0
    fi
    s5_legacy_dns_credentials "$provider"
}
SMART_UPLOAD_DIRS=(/root /root/vpskit-new /root/vpskit-fix)
smart_file_pick() {
    local sfdest=$1 sftitle=$2 sfkind=$3 sfextra=${4:-} sfp sfd sfchosen
    local -a sfdirs=("${SMART_UPLOAD_DIRS[@]}") sfopts=()
    local -A sfseen=()
    [[ -z $sfextra ]] || sfdirs=("$sfextra" "${sfdirs[@]}")
    for sfd in "${sfdirs[@]}"; do
        [[ -d $sfd && ! -L $sfd ]] || continue
        while IFS= read -r -d '' sfp; do
            [[ $sfp != *[[:cntrl:]]* && $sfp != *'|'* && -z ${sfseen[$sfp]+x} ]] || continue
            case "$sfkind:$sfp" in
                cert:*.pem|cert:*.crt|cert:*.cer|key:*.key|key:*.pem|json:*.json) ;;
                *) continue;;
            esac
            sfseen[$sfp]=1; sfopts+=("$sfp|$sfp")
            ((${#sfopts[@]}<30)) || break
        done < <(find -P "$sfd" -maxdepth 1 -type f -print0 | sort -z)
        ((${#sfopts[@]}<30)) || break
    done
    if ((${#sfopts[@]})); then
        sfopts+=('manual|输入其他绝对路径')
        select_value sfchosen "$sftitle（最多列出30项；不会读取文件内容）" '' "${sfopts[@]}"
    else sfchosen=manual; fi
    [[ $sfchosen != manual ]] || ask sfchosen "$sftitle：绝对路径" ''
    [[ $sfchosen == /* && -f $sfchosen && ! -L $sfchosen && $sfchosen != *[[:cntrl:]]* ]] || { warn '文件不存在或是链接；未保存。'; return 1; }
    printf -v "$sfdest" '%s' "$sfchosen"
}
cert_import_interactive() {
    local d cert key source
    site_select d
    source=$(realpath -m "$ROOT/certs/$d/current")
    # A known current revision is offered, but pair matching is still mandatory.
    smart_file_pick cert '选择完整证书链文件' cert "$source" || return 1
    smart_file_pick key '选择私钥文件（不显示内容）' key "$source" || return 1
    cert_import "$d" "$cert" "$key"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
