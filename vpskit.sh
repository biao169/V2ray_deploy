#!/usr/bin/env bash
# VPSKIT_SINGLE_FILE
# VPSKIT_FEATURE_LEVEL=2
# VPSKIT_STATE_SCHEMA=1
# VPSKit 1.7.0-enhanced — complete, standalone manager; not an upstream release.
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
VERSION='1.7.0-enhanced'
FEATURE_LEVEL=2
ROOT='/opt/vpskit'
STATE="$ROOT/data/state.json"
ENTRY='/usr/local/bin/vpskit'
SYSTEMD='/etc/systemd/system'
XRAY="$ROOT/bin/xray"
NGINX="$ROOT/nginx/usr/sbin/nginx"
ACME="$ROOT/acme/acme.sh"
SELF_URL='https://raw.githubusercontent.com/biao169/V2ray_deploy/main/vpskit.sh'
XRAY_DEFAULT_VERSION='v26.3.27'
SELF="${BASH_SOURCE[0]}"
WORK='' LOCK_FD='' TTY_FD='' TX=0 LOGFILE='' BOOTSTRAP_DIR=''
HISTORY_KEEP=20
UNITS=(vpskit-xray.service vpskit-nginx.service vpskit-maintain.service vpskit-maintain.timer)

log() {
    local level=$1; shift
    printf '[%s] %s\n' "$level" "$*" >&2
    if [[ -n $LOGFILE && -d ${LOGFILE%/*} ]]; then
        printf '[%s] [%s] %s\n' "$(date -u '+%FT%TZ')" "$level" "$*" >> "$LOGFILE"
    fi
}
info() { log INFO "$@"; }
warn() { log WARN "$@"; }
ok() { log OK "$@"; }
die() { log ERROR "$@"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "缺少命令 $1。"; }
root_check() { (( EUID == 0 )) || die '请使用 sudo bash ./vpskit.sh 或 sudo vpskit。'; }
ask() {
    local ap_dest=$1 ap_label=$2 ap_default=${3:-} ap_reply
    [[ -n $TTY_FD ]] || die '此操作需要交互终端；输入 :q 可取消。'
    printf '%s' "$ap_label" >&2
    [[ -z $ap_default ]] || printf ' [%s]' "$ap_default" >&2
    printf ': ' >&2
    IFS= read -r -u "$TTY_FD" ap_reply || die '输入已关闭。'
    [[ $ap_reply != :q ]] || exit 130
    printf -v "$ap_dest" '%s' "${ap_reply:-$ap_default}"
}
secret() {
    local sp_dest=$1 sp_label=$2 sp_reply
    [[ -n $TTY_FD ]] || die '凭据输入需要终端。'
    printf '%s（不回显；:q取消）: ' "$sp_label" >&2
    IFS= read -r -s -u "$TTY_FD" sp_reply || die '输入已关闭。'
    printf '\n' >&2
    [[ $sp_reply != :q ]] || exit 130
    printf -v "$sp_dest" '%s' "$sp_reply"
}
confirm() { local cp_answer; ask cp_answer "$1；输入 yes 确认" no; [[ $cp_answer == yes ]]; }
ask_valid() {
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
{"worker_user":"auto","workers":1,"connections":1024,"nofile":8192,"keepalive":30,"keepalive_requests":1000,"ssl_cache":4,"ssl_timeout":10,"http2":true,"client_header_timeout":15,"client_body_timeout":60,"send_timeout":60,"proxy_connect_timeout":10,"proxy_read_timeout":3600,"proxy_send_timeout":3600,"site_proxy_timeout":60,"client_max_body_mb":16,"access_log":false,"worker_shutdown_timeout":0,"upstream_keepalive":8}
JSON
}
nginx_settings() { jq -c --argjson d "$(nginx_defaults)" '$d * (.advanced.nginx // {})' "${1:-$STATE}"; }
ng_value() { nginx_settings | jq -r --arg k "$1" '.[$k]'; }
xray_nofile() { jq -r '.advanced.xray.nofile // 8192' "$STATE"; }
init_state() {
    if [[ -e $STATE ]]; then state_basic "$STATE" || die "配置损坏，未覆盖。请使用 history list / history restore 恢复：$STATE"; return; fi
    if [[ -e $ROOT/config/nginx.conf || -e $ROOT/config/xray.json || -d $ROOT/backup/history ]] && [[ ${ALLOW_NEW_STATE:-0} != 1 ]]; then
        die '发现部署资料但state.json缺失；拒绝创建空配置，请从历史恢复。'
    fi
    jq -n --arg v "$VERSION" '{schema:1,manager:$v,scheme:"A",host:"",performance:{gzip:false},components:{xray:false,nginx:false,acme:false},versions:{},nodes:[],sites:[],preferences:{},wizard:{selected:false}}' > "$STATE"
    chmod 600 "$STATE"
}
migrate_state() {
    # Defaults are merged, not substituted with jq // (which would lose false).
    json_update --argjson d "$(nginx_defaults)" --arg v "$VERSION" '
      .advanced=((.advanced // {}) + {version:1}) |
      .advanced.nginx=($d * (.advanced.nginx // {})) |
      .advanced.xray=({nofile:8192} * (.advanced.xray // {})) |
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
      (.upstream_keepalive|i(0;128)) and (.worker_user|type=="string") and
      ((.resolved_user // "")|type=="string")' <<< "$n" >/dev/null || die '高级配置类型/范围错误，或nofile小于connections+1024。'
    local user; user=$(jq -r .worker_user <<< "$n")
    [[ $user == auto ]] || valid_user_name "$user" || die 'Worker账户名称不合法。'
    [[ $user != root ]] || die '禁止设置root Worker。'
    jq -e '(.advanced.xray.nofile // 8192) as $n | ($n|type=="number") and $n==($n|floor) and $n>=2048 and $n<=1048576' "$cfg" >/dev/null || die 'Xray文件描述符上限无效。'
    nr=$(cat /proc/sys/fs/nr_open 2>/dev/null || printf 1048576)
    (( $(jq -r .nofile <<< "$n") <= nr && $(jq -r '.advanced.xray.nofile // 8192' "$cfg") <= nr )) || die "nofile超过当前内核nr_open=$nr；未自动改变内核。"
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
resolve_worker() {
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
    # Group traversal only at the root. All secret directories stay root:root 0700.
    # This deliberately avoids an ACL dependency and never creates OS accounts.
    chown "0:$group" "$ROOT"; chmod 0710 "$ROOT"
    for path in data config certs acme backup tmp bin nginx logs; do
        [[ -d $ROOT/$path && ! -L $ROOT/$path ]] || die "异常私有目录 $path"
        chown 0:0 "$ROOT/$path"; chmod 0700 "$ROOT/$path"
    done
    [[ ! -L $ROOT/www && ! -L $ROOT/run ]] || die '网站/运行目录不能为符号链接。'
    # Do not follow symlinks, hard links or mounted subtrees during permission repair.
    if [[ -n $(find -P "$ROOT/www" -xdev \( -type l -o \( -type f -links +1 \) \) -print -quit) ]]; then
        die '网站目录含符号链接或硬链接；请改为实际文件，避免权限修复影响目录外资料。'
    fi
    if findmnt -rn -o TARGET 2>/dev/null | grep -Fq "$ROOT/www/"; then die '网站目录内有子挂载，拒绝递归调整权限。'; fi
    find -P "$ROOT/www" -xdev -type d -exec chown "0:$group" {} + -exec chmod 2750 {} +
    find -P "$ROOT/www" -xdev -type f -exec chown "0:$group" {} + -exec chmod 0640 {} +
    chown "0:$group" "$ROOT/run"; chmod 0710 "$ROOT/run"
    mkdir -p "$ROOT/run/nginx"
    chown "0:$group" "$ROOT/run/nginx"; chmod 0710 "$ROOT/run/nginx"
    for path in client proxy fastcgi uwsgi scgi; do
        [[ ! -L $ROOT/run/nginx/$path ]] || die 'Nginx临时目录不能为链接。'
        mkdir -p "$ROOT/run/nginx/$path"
        chown "$user:$group" "$ROOT/run/nginx/$path"; chmod 0700 "$ROOT/run/nginx/$path"
    done
    if command -v runuser >/dev/null; then
        runuser -u "$user" -- test -x "$ROOT/www" || die 'Worker无法访问网站目录。'
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
    for p in data config certs acme backup tmp logs bin nginx; do chown 0:0 "$ROOT/$p"; chmod 700 "$ROOT/$p"; done
    [[ ! -L $STATE && ! -L $ROOT/run/manage.lock ]] || die '状态文件/锁文件不能为链接。'
    exec {LOCK_FD}> "$ROOT/run/manage.lock"
    flock -w 10 "$LOCK_FD" || die '另一个VPSKit操作正在运行。'
    WORK=$(mktemp -d "$ROOT/tmp/job.XXXXXXXX")
    LOGFILE="$ROOT/logs/manage.log"
}
cleanup() {
    local rc=$?
    trap - EXIT ERR INT TERM
    set +e
    if ((TX)); then
        warn '操作失败或中断，开始恢复事务前状态。'
        if restore_transaction "$ROOT/backup/transaction"; then rm -rf -- "$ROOT/backup/transaction"; else warn '自动恢复失败，保留事务；运行 vpskit repair。'; rc=1; fi
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
# History snapshots contain configuration, certificates and ACME account data,
# never binaries, the manager source, website contents, firewall rules or swap.
snapshot_copy() {
    local dest=$1 reason=$2 p
    mkdir -p "$dest"
    [[ ! -f $STATE ]] || cp -a "$STATE" "$dest/state.json"
    for p in config certs; do cp -a "$ROOT/$p" "$dest/$p"; done
    mkdir -p "$dest/acme"
    for p in config certstore; do [[ ! -d $ROOT/acme/$p ]] || cp -a "$ROOT/acme/$p" "$dest/acme/$p"; done
    jq -n --arg v "$VERSION" --arg r "$reason" --arg t "$(date -u '+%FT%TZ')" '{snapshot_schema:1,manager:$v,created:$t,reason:$r,includes:["state","config","certs","acme/config","acme/certstore"],excludes:["website files","binaries","manager code","firewall","swap"]}' > "$dest/meta.json"
    (cd "$dest"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 -r sha256sum > SHA256SUMS)
    chmod 700 "$dest"
}
history_prune() {
    local f count=0
    while IFS= read -r f; do
        count=$((count+1)); ((count<=HISTORY_KEEP)) && continue
        [[ $f =~ ^[0-9]{8}T[0-9]{6}Z-[a-f0-9]{8}$ ]] || continue
        rm -rf -- "$ROOT/backup/history/$f"
    done < <(find "$ROOT/backup/history" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r)
}
history_save() {
    local reason=${1:-manual} id dest
    state_basic "$STATE" || die '当前状态无效，不能创建正常历史快照。'
    mkdir -p "$ROOT/backup/history"
    id="$(date -u '+%Y%m%dT%H%M%SZ')-$(randhex 4)"
    dest="$ROOT/backup/history/.pending-$id"
    snapshot_copy "$dest" "$reason"
    mv -- "$dest" "$ROOT/backup/history/$id"
    history_prune
    info "历史快照：$id（含凭据/私钥，仅root可读；保留最近$HISTORY_KEEP份）"
}
history_list() {
    local dir
    [[ -d $ROOT/backup/history ]] || { printf '暂无历史快照。\n'; return; }
    while IFS= read -r dir; do
        [[ -f $dir/meta.json ]] || continue
        printf '%s  ' "${dir##*/}"
        jq -r '[.created,.reason,.manager]|@tsv' "$dir/meta.json"
    done < <(find "$ROOT/backup/history" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | sort -r)
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
    printf 'ready\n' > "$dir/ready"
    TX=1
    if state_basic "$STATE"; then history_save "before:$reason"; fi
}
restore_transaction() {
    local dir=$1 p u mode gid failed=0 worker
    if [[ -f $dir/state.json && -d $dir/tree ]]; then legacy_restore_transaction "$dir"; return; fi
    [[ -f $dir/ready && -d $dir/snapshot ]] || return 1
    systemctl stop vpskit-xray.service vpskit-nginx.service >/dev/null 2>&1 || true
    for p in config certs; do
        [[ -d $dir/snapshot/$p ]] || return 1
        rm -rf -- "$ROOT/$p"; cp -a "$dir/snapshot/$p" "$ROOT/$p" || failed=1
    done
    for p in config certstore; do
        rm -rf -- "$ROOT/acme/$p"
        [[ ! -d $dir/snapshot/acme/$p ]] || cp -a "$dir/snapshot/acme/$p" "$ROOT/acme/$p" || failed=1
    done
    if [[ -d $dir/programs ]]; then
        for p in bin nginx acme; do
            rm -rf -- "$ROOT/$p"; cp -a "$dir/programs/$p" "$ROOT/$p" || failed=1
        done
    fi
    if [[ -f $dir/snapshot/state.json ]]; then cp -a "$dir/snapshot/state.json" "$STATE" || failed=1
    else rm -f "$STATE"; fi
    for u in "${UNITS[@]}"; do
        if [[ -f $dir/units/$u ]]; then cp -a "$dir/units/$u" "$SYSTEMD/$u" || failed=1
        elif [[ -f $SYSTEMD/$u ]] && grep -Fq '# VPSKIT_OWNED' "$SYSTEMD/$u"; then
            systemctl disable --now "$u" >/dev/null 2>&1 || true; rm -f "$SYSTEMD/$u"
        fi
    done
    read -r mode gid < "$dir/root-permissions"
    chown "0:$gid" "$ROOT" || failed=1; chmod "$mode" "$ROOT" || failed=1
    # Permissions must match the restored worker, not the failed new selection.
    worker=$(sed -n 's/^user \([a-z_][a-z0-9_-]*\).*/\1/p' "$ROOT/config/nginx.conf" 2>/dev/null | head -1 || true)
    if [[ -n $worker && $worker != root ]]; then worker_permissions "$worker" || failed=1; fi
    systemctl daemon-reload || failed=1
    for u in "${UNITS[@]}"; do
        if [[ -f $dir/enabled ]] && grep -Fxq "$u" "$dir/enabled"; then systemctl enable "$u" >/dev/null 2>&1 || failed=1
        else systemctl disable "$u" >/dev/null 2>&1 || true; fi
    done
    if [[ -f $dir/active ]]; then
        while IFS= read -r u; do systemctl start "$u" || failed=1; done < "$dir/active"
    fi
    ((failed==0))
}
commit_tx() {
    ((TX==1)) || die '没有待提交事务。'
    rm -rf -- "$ROOT/backup/last"
    mv -- "$ROOT/backup/transaction" "$ROOT/backup/last"
    TX=0
    ok '配置已验证并提交；操作前历史和最近事务均可恢复。'
}
repair_transaction() {
    if [[ -d $ROOT/backup/transaction ]]; then
        if [[ ! -f $ROOT/backup/transaction/ready ]]; then
            rm -rf -- "$ROOT/backup/transaction"; ok '已清理未完成备份；正式配置未被该事务修改。'
        else
            restore_transaction "$ROOT/backup/transaction" || die '恢复失败，事务已保留。'
            rm -rf -- "$ROOT/backup/transaction"; ok '已恢复未完成事务。'
        fi
    else ok '没有未完成事务。'; fi
}

component_ready() {
    local f
    case "$1" in xray) f=$XRAY;; nginx) f=$NGINX;; acme) f=$ACME;; *) return 1;; esac
    [[ $(get ".components.$1 // false") == true && -x $f && ! -L $f ]]
}
ensure_component() { component_ready "$1" || die "组件 $1 未安装或缺失，请运行 vpskit install $1。"; }
latest_release() {
    fetch "https://api.github.com/repos/$1/releases/latest" "$2"
    jq -er '.tag_name|select(test("^[A-Za-z0-9._-]+$"))' "$2"
}
install_xray_binary() {
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
install_nginx_binary() {
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
install_acme_binary() {
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
validate_state() {
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
    jq -e '[.nodes|group_by(.entry)[]|(map(del(.id,.credential,.enabled))|unique|length)==1]|all' "$cfg" >/dev/null || die '同入口用户的传输参数不一致。'
    jq -e '[.nodes|group_by(.entry)[]|.[0].port]|length==(unique|length)' "$cfg" >/dev/null || die '不同入口使用了重复端口。'
    jq -e '[.nodes[]|select(.mode=="ws" or .mode=="xhttp")]|group_by([.domain,.path])|map(map(.entry)|unique|length==1)|all' "$cfg" >/dev/null || die '不同入口使用了同一网站代理路径。'
    # A WS exact path must not fall under another XHTTP prefix.
    jq -e '.nodes as $a | [ $a[]|select(.mode=="xhttp") as $x | $a[]|select(.entry!=$x.entry and .domain==$x.domain and (.mode=="xhttp" or .mode=="ws")) | (.path|startswith($x.path+"/")) ] | any | not' "$cfg" >/dev/null || die 'XHTTP路径前缀冲突。'
}
render_xray() {
    jq --arg root "$ROOT" '
      {log:{access:"none",error:($root+"/logs/xray.log"),loglevel:"warning"},
       inbounds:([.nodes[]|select(.enabled)]|group_by(.entry)|map(. as $g|.[0] as $n|
        {tag:$n.entry,listen:(if ($n.mode=="ws" or $n.mode=="xhttp") then "127.0.0.1" else $n.listen end),port:$n.port,protocol:$n.protocol,
         settings:(if $n.protocol=="vless" then {decryption:"none",clients:($g|map({id:.credential,email:.id,flow:(if .mode=="reality" then "xtls-rprx-vision" else "" end)}))}
          elif $n.protocol=="vmess" then {clients:($g|map({id:.credential,email:.id})),disableInsecureEncryption:true}
          elif $n.protocol=="trojan" then {clients:($g|map({password:.credential,email:.id}))}
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
    cat <<'NGINX'
            gzip on;
            gzip_vary on;
            gzip_comp_level 2;
            gzip_min_length 1024;
            gzip_types text/plain text/css application/javascript application/json image/svg+xml application/xml;
NGINX
}
render_nginx() {
    local dest=$1 a user group version build h2 modern=false ipv6=false site domain kind upstream issued settings zone rate conn cidr policy ttl gzip node path port aop probe
    a=$(nginx_settings); user=$(resolve_worker); group=$(id -gn "$user")
    build=$("$NGINX" -V 2>&1); version=$("$NGINX" -v 2>&1 | sed -n 's@.*nginx/\([0-9.]*\).*@\1@p')
    h2=$(jq -r .http2 <<< "$a")
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
worker_processes $(jq -r .workers <<< "$a");
worker_rlimit_nofile $(jq -r .nofile <<< "$a");
pid $ROOT/run/nginx.pid;
error_log $ROOT/logs/nginx.log warn;
EOF
        if (( $(jq -r .worker_shutdown_timeout <<< "$a") > 0 )); then printf 'worker_shutdown_timeout %ss;\n' "$(jq -r .worker_shutdown_timeout <<< "$a")"; fi
        cat <<EOF
 events { worker_connections $(jq -r .connections <<< "$a"); }
http {
    types { text/html html htm; text/css css; application/javascript js mjs; application/json json; image/png png; image/jpeg jpg jpeg; image/gif gif; image/webp webp; image/avif avif; image/svg+xml svg; image/x-icon ico; text/plain txt; font/woff woff; font/woff2 woff2; font/ttf ttf; application/pdf pdf; video/mp4 mp4; application/xml xml; }
    default_type application/octet-stream;
    server_tokens off;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout $(jq -r .keepalive <<< "$a")s;
    keepalive_requests $(jq -r .keepalive_requests <<< "$a");
    client_header_timeout $(jq -r .client_header_timeout <<< "$a")s;
    client_body_timeout $(jq -r .client_body_timeout <<< "$a")s;
    send_timeout $(jq -r .send_timeout <<< "$a")s;
    reset_timedout_connection on;
    client_max_body_size $(jq -r .client_max_body_mb <<< "$a")m;
    client_body_temp_path $ROOT/run/nginx/client;
    proxy_temp_path $ROOT/run/nginx/proxy;
    fastcgi_temp_path $ROOT/run/nginx/fastcgi;
    uwsgi_temp_path $ROOT/run/nginx/uwsgi;
    scgi_temp_path $ROOT/run/nginx/scgi;
    ssl_session_cache shared:VPSKITSSL$(jq -r .ssl_cache <<< "$a"):$(jq -r .ssl_cache <<< "$a")m;
    ssl_session_timeout $(jq -r .ssl_timeout <<< "$a")m;
    ssl_protocols $(nginx_tls_protocols);
EOF
        if [[ $(jq -r .access_log <<< "$a") == true ]]; then printf '    access_log %s/logs/access.log combined buffer=32k flush=5s;\n' "$ROOT"; else printf '    access_log off;\n'; fi
        cat <<'NGINX'
    map $http_upgrade $vpskit_is_ws { default 0; ~*^websocket$ 1; }
    map $http_upgrade $vpskit_connection { default upgrade; '' ''; }
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
                if (( $(jq -r .upstream_keepalive <<< "$a")>0 )); then printf ' keepalive %s;' "$(jq -r .upstream_keepalive <<< "$a")"; fi
                printf ' }\n'
            fi
        done < <(jq -c '.sites[]' "$STATE")
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
                        printf '            proxy_http_version 1.1;\n            proxy_set_header Connection "";\n            proxy_set_header Host $host;\n            client_max_body_size 0;\n'
                    else
                        printf '        location = %s {\n' "$path"
                        edge_origin_guard "$settings"
                        printf '            if ($vpskit_is_ws = 0) { return 404; }\n            if ($request_method != GET) { return 404; }\n            proxy_http_version 1.1;\n            proxy_set_header Upgrade $http_upgrade;\n            proxy_set_header Connection "upgrade";\n            proxy_set_header Host $host;\n'
                    fi
                    cat <<EOF
            proxy_pass http://127.0.0.1:$port;
            proxy_buffering off;
            proxy_request_buffering off;
            proxy_cache off;
            gzip off;
            add_header Cache-Control "no-store" always;
            proxy_connect_timeout $(jq -r .proxy_connect_timeout <<< "$a")s;
            proxy_read_timeout $(jq -r .proxy_read_timeout <<< "$a")s;
            proxy_send_timeout $(jq -r .proxy_send_timeout <<< "$a")s;
            client_body_timeout $(jq -r .proxy_send_timeout <<< "$a")s;
            send_timeout $(jq -r .proxy_read_timeout <<< "$a")s;
        }
EOF
                done < <(jq -c --arg d "$domain" '[.nodes[]|select(.enabled and (.mode=="ws" or .mode=="xhttp") and .domain==$d)]|unique_by(.entry)[]' "$STATE")
            fi
            if [[ $kind == template || $kind == custom ]]; then
                if ((ttl>0)); then
                    printf '        location ~* \\.(css|js|png|jpe?g|gif|svg|webp|avif|ico|woff2?|ttf)$ {\n'
                    edge_web_guard "$settings" "$domain"
                    printf '            try_files $uri =404;\n            expires %ss;\n' "$ttl"; static_gzip "$gzip"; printf '        }\n'
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
            proxy_set_header Connection \$vpskit_connection;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$remote_addr;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_hide_header X-Powered-By;
            proxy_connect_timeout $(jq -r .proxy_connect_timeout <<< "$a")s;
            proxy_read_timeout $(jq -r .site_proxy_timeout <<< "$a")s;
            proxy_send_timeout $(jq -r .site_proxy_timeout <<< "$a")s;
EOF
            else printf '            try_files $uri $uri/ =404;\n'; static_gzip "$gzip"; fi
            printf '        }\n    }\n'
        done < <(jq -c '.sites[]' "$STATE")
        printf '}\n'
    } > "$dest"
}

render_units() {
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
LimitNOFILE=$nglimit
LimitCORE=0
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ReadWritePaths=$ROOT/logs $ROOT/run
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
# CHOWN/DAC_OVERRIDE: temp paths; KILL: signal workers after setuid.
# These are master capabilities; a normal setuid worker drops its capabilities.
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_SETUID CAP_SETGID CAP_CHOWN CAP_DAC_OVERRIDE CAP_FOWNER CAP_KILL
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
UMask=0077
EOF
    cat > "$dir/vpskit-maintain.timer" <<'EOF'
# VPSKIT_OWNED
[Unit]
Description=VPSKit scheduled certificate and log maintenance
[Timer]
OnCalendar=daily
RandomizedDelaySec=3600
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
master_workers() {
    local pid=$1
    [[ $pid =~ ^[1-9][0-9]*$ ]] || return 0
    ps --ppid "$pid" -o pid=,uid=,args= 2>/dev/null | awk '$3=="nginx:" && $4=="worker" && $5=="process" && NF==5 {print $1" "$2}' || true
}
verify_nginx_runtime() {
    local old=${1:-} master=${2:-} desired uid pid actual_uid fd found=0 tries caps
    desired=$(resolve_worker); uid=$(id -u "$desired")
    for ((tries=0; tries<50; tries++)); do
        if [[ -z ${2:-} ]]; then master=$(systemctl show -p MainPID --value vpskit-nginx.service); fi
        [[ $master =~ ^[1-9][0-9]*$ && -r /proc/$master/status ]] || { sleep 0.1; continue; }
        found=0
        while read -r pid actual_uid; do
            [[ -n $pid ]] || continue
            [[ " $old " != *" $pid "* ]] || continue
            ((actual_uid == uid && actual_uid != 0)) || die '发现新Nginx Worker身份不符合预期。'
            fd=$(awk '/^Max open files/{print $4}' "/proc/$pid/limits")
            [[ $fd == unlimited ]] || ((fd >= $(ng_value nofile))) || die 'Worker实际文件描述符上限未生效。'
            caps=$(awk '/^CapEff:/{print $2}' "/proc/$pid/status")
            [[ $caps =~ ^0+$ ]] || die 'Worker仍保留有效Linux capabilities，拒绝提交。'
            found=$((found+1))
        done < <(master_workers "$master")
        if ((found>0)); then
            local expected; expected=$(ng_value workers)
            if [[ $expected == auto ]] || ((found>=expected)); then return 0; fi
        fi
        sleep 0.1
    done
    die '未观察到符合用户/权限/文件数要求的新Worker；可能reload失败，正在触发回滚。'
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
check_listener_ports() {
    local port
    if [[ $(get '.components.nginx // false') == true ]]; then
        guard_port 80 vpskit-nginx.service
        if jq -e '.sites[]|select(.issued)' "$STATE" >/dev/null; then guard_port 443 vpskit-nginx.service; fi
    fi
    while IFS= read -r port; do guard_port "$port" vpskit-xray.service; done < <(jq -r '[.nodes[]|select(.enabled)]|unique_by(.entry)[].port' "$STATE")
}
code_candidate_check() {
    local file=$1 minimum=${2:-2}
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
apply_config() {
    local scope=${1:-all} force=${2:-none} xc="$WORK/xray.next.json" nc="$WORK/nginx.next.conf" u restart_ng=false restart_x=false old='' pid count
    ((TX==1)) || die '应用配置必须处于事务中。'
    migrate_state
    if [[ $(get '.components.nginx // false') == true ]]; then remember_worker; fi
    validate_state
    check_listener_ports
    if [[ $(get '.components.xray // false') == true && $scope == all ]]; then
        ensure_component xray; render_xray "$xc"
        "$XRAY" run -test -config "$xc"
        if ! cmp -s "$xc" "$ROOT/config/xray.json"; then restart_x=true; fi
    fi
    if [[ $(get '.components.nginx // false') == true ]]; then
        ensure_component nginx
        mkdir -p "$ROOT/www/acme/.well-known/acme-challenge"
        worker_permissions "$(resolve_worker)"
        render_nginx "$nc"
        nginx_cmd -t -p "$ROOT/" -c "$nc"
    fi
    render_units "$WORK/units"
    for u in "${UNITS[@]}"; do
        if [[ -e $SYSTEMD/$u ]]; then [[ ! -L $SYSTEMD/$u ]] && grep -Fq '# VPSKIT_OWNED' "$SYSTEMD/$u" || die "外部同名服务：$u"; fi
        if ! cmp -s "$WORK/units/$u" "$SYSTEMD/$u"; then
            [[ $u != vpskit-nginx.service ]] || restart_ng=true
            [[ $u != vpskit-xray.service ]] || restart_x=true
        fi
    done
    [[ $force != nginx ]] || restart_ng=true
    [[ $force != xray ]] || restart_x=true
    ensure_manager_installed
    [[ ! -f $xc ]] || install -m 600 "$xc" "$ROOT/config/xray.json"
    [[ ! -f $nc ]] || install -m 600 "$nc" "$ROOT/config/nginx.conf"
    for u in "${UNITS[@]}"; do install -m 644 "$WORK/units/$u" "$SYSTEMD/$u"; done
    systemctl daemon-reload
    if [[ $(get '.components.nginx // false') == true ]]; then
        systemctl enable vpskit-nginx.service >/dev/null
        if systemctl is-active --quiet vpskit-nginx.service; then
            if [[ $restart_ng == true ]]; then
                warn 'Nginx服务参数/用户/二进制改变，需要重启；现有连接会中断。'
                systemctl restart vpskit-nginx.service
            else
                pid=$(systemctl show -p MainPID --value vpskit-nginx.service)
                old=$(master_workers "$pid" | awk '{print $1}' | paste -sd ' ' -)
                systemctl reload vpskit-nginx.service
            fi
        else systemctl start vpskit-nginx.service; fi
        verify_nginx_runtime "$old"
    else
        systemctl disable --now vpskit-nginx.service >/dev/null 2>&1 || true
    fi
    if [[ $scope == all && $(get '.components.xray // false') == true ]]; then
        count=$(jq '[.nodes[]|select(.enabled)]|length' "$STATE")
        if ((count>0)); then
            systemctl enable vpskit-xray.service >/dev/null
            if [[ $restart_x == true ]] || ! systemctl is-active --quiet vpskit-xray.service; then
                warn 'Xray配置/服务参数改变，需要启动或重启；现有代理连接可能中断。'
                systemctl restart vpskit-xray.service
            fi
            sleep 0.5
            systemctl is-active --quiet vpskit-xray.service || die 'Xray启动失败。'
            while IFS= read -r pid; do [[ -n $(ss -H -lnt "sport = :$pid") ]] || die "Xray端口 $pid 未监听。"; done < <(jq -r '[.nodes[]|select(.enabled)]|unique_by(.entry)[].port' "$STATE")
        else systemctl disable --now vpskit-xray.service >/dev/null 2>&1 || true; fi
    fi
    if [[ $scope == all && $(get '.components.xray // false') != true ]]; then
        systemctl disable --now vpskit-xray.service >/dev/null 2>&1 || true
    fi
    systemctl enable --now vpskit-maintain.timer >/dev/null
}
install_component() {
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
history_restore() {
    local id=${1:-} scope=${2:-full} dir p candidate="$WORK/restored-state.json"
    if [[ -z $id ]]; then history_list; ask id '输入完整快照ID' ''; fi
    [[ $id =~ ^[0-9]{8}T[0-9]{6}Z-[a-f0-9]{8}$ ]] || die '快照ID格式错误。'
    choice "$scope" 'full state advanced' || die '恢复范围只能为full/state/advanced。'
    dir="$ROOT/backup/history/$id"; snapshot_verify "$dir"
    if [[ $scope == advanced ]]; then
        state_basic "$STATE" || die '高级参数恢复需要当前state.json有效；当前状态损坏时使用full。'
        jq --slurpfile h "$dir/state.json" '.advanced=($h[0].advanced // {})' "$STATE" > "$candidate"
    else cp "$dir/state.json" "$candidate"; fi
    validate_advanced "$candidate"
    for p in xray nginx acme; do
        if [[ $(jq -r ".components.$p // false" "$candidate") == true ]]; then
            case "$p" in xray) [[ -x $XRAY ]];; nginx) [[ -x $NGINX ]];; acme) [[ -x $ACME ]];; esac || die "快照需要$p，但当前二进制不存在；历史不包含程序，请先安装相应组件。"
        fi
    done
    warn "恢复范围=$scope。不会恢复/覆盖网站内容、管理代码、程序二进制、防火墙、Swap。full会恢复证书与ACME账户数据。"
    confirm "恢复快照 $id，必要时重新加载或重启相关服务" || return 0
    # Retain the chosen snapshot before begin_tx can prune the oldest history.
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
    # Program versions reflect currently installed programs, not historical binaries.
    if state_basic "$ROOT/backup/transaction/snapshot/state.json"; then
        json_update --slurpfile old "$ROOT/backup/transaction/snapshot/state.json" '.versions=($old[0].versions // .versions)'
    fi
    apply_config
    commit_tx
}
rollback_last() {
    local dir="$ROOT/backup/last" preserved="$WORK/last-copy"
    [[ -f $dir/ready ]] || die '没有可用的最近事务快照。'
    confirm '回滚最近一次事务（可能包括组件二进制），会重新启动之前运行的服务' || return 0
    cp -a "$dir" "$preserved"
    begin_tx rollback components
    restore_transaction "$preserved" || die '回滚失败。'
    commit_tx
}

advanced_show() {
    printf '\nNginx高级配置（默认值与已保存值合并显示）：\n'
    nginx_settings | jq .
    printf 'Xray LimitNOFILE=%s\n' "$(xray_nofile)"
    printf 'CPU逻辑核心=%s；内存=%s MiB\n' "$(getconf _NPROCESSORS_ONLN)" "$(awk '/MemTotal:/{printf "%d",$2/1024}' /proc/meminfo)"
    printf '连接数包含客户端和上游连接，不等于用户人数；auto按CPU数量启动Worker。\n'
    printf 'XHTTP启用时HTTP/2保持开启；纯网站可通过http2参数关闭。\n'
    if component_ready nginx; then
        printf '计划Worker用户：%s\n' "$(resolve_worker)"
        local master; master=$(systemctl show -p MainPID --value vpskit-nginx.service 2>/dev/null || true)
        printf '当前Worker PID / UID：\n'; master_workers "$master"
    fi
}
advanced_assign() {
    local file=$1 key=$2 value=$3 section=${2%%.*} field=${2#*.} type=num
    case "$key" in
        nginx.workers) valid_worker_count "$value" || die 'Worker数量需为auto或1～64。'; [[ $value != auto ]] || type=string;;
        nginx.worker_user) [[ $value == auto ]] || service_user_valid "$value" || die '必须选择已有的非特权、非登录服务账户。'; type=string;;
        nginx.http2|nginx.access_log) valid_bool "$value" || die '布尔值只能为true/false。'; type=bool;;
        nginx.connections|nginx.nofile|nginx.keepalive|nginx.keepalive_requests|nginx.ssl_cache|nginx.ssl_timeout|nginx.client_header_timeout|nginx.client_body_timeout|nginx.send_timeout|nginx.proxy_connect_timeout|nginx.proxy_read_timeout|nginx.proxy_send_timeout|nginx.site_proxy_timeout|nginx.client_max_body_mb|nginx.worker_shutdown_timeout|nginx.upstream_keepalive|xray.nofile)
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
advanced_set() {
    (( $#>=2 && $#%2==0 )) || die '用法：advanced set nginx.workers 2 nginx.connections 2048 nginx.nofile 16384'
    local candidate="$WORK/advanced.json" scope=web key value
    cp "$STATE" "$candidate"
    while (($#)); do
        key=$1; value=$2; shift 2
        advanced_assign "$candidate" "$key" "$value"
        [[ $key != xray.nofile ]] || scope=all
    done
    validate_advanced "$candidate"
    if [[ $(nginx_settings "$candidate" | jq -r .workers) == auto ]]; then warn 'auto并不按内存限制Worker数量；低内存VPS建议明确设置1或2。'; fi
    if component_ready nginx; then resolve_worker "$candidate" >/dev/null; fi
    confirm '保存这些高级配置并应用；修改文件数/账户时需要重启对应服务' || return 0
    begin_tx advanced
    install -m 600 "$candidate" "$STATE"
    if component_ready nginx || component_ready xray; then apply_config "$scope"
    else migrate_state; fi
    commit_tx
}
advanced_defaults() {
    confirm '只恢复Nginx/Xray高级默认参数，保留节点、网站和证书' || return 0
    begin_tx advanced-defaults
    json_update --argjson d "$(nginx_defaults)" '.advanced.nginx=$d | .advanced.xray={nofile:8192}'
    if component_ready nginx || component_ready xray; then apply_config; else migrate_state; fi
    commit_tx
}
advanced_edit() {
    local key=${1:-} value workers connections nofile
    if [[ -z $key || $key == capacity ]]; then
        ask_valid workers 'Worker数量（auto或1～64；小内存推荐1）' "$(ng_value workers)" valid_worker_count
        ask_valid connections '每个Worker连接上限（128～65535）' "$(ng_value connections)" number 128 65535
        ask_valid nofile 'Nginx文件数上限（必须至少为连接数+1024）' "$(ng_value nofile)" number 2048 1048576
        advanced_set nginx.workers "$workers" nginx.connections "$connections" nginx.nofile "$nofile"
        return
    fi
    if [[ $key == xray.nofile ]]; then value=$(xray_nofile); else value=$(ng_value "${key#nginx.}"); fi
    ask value "设置 $key（true/false用于开关；:q取消）" "$value"
    advanced_set "$key" "$value"
}
site_list() { jq -r '.sites|to_entries[]|[(.key+1),.value.domain,(.value.kind // "custom"),(.value.access // "direct"),(.value.issued|tostring)]|@tsv' "$STATE"; }
site_select() {
    local ss_dest=$1 ss_value=${2:-}
    if [[ -z $ss_value ]]; then
        [[ $(get '.sites|length') -gt 0 ]] || die '尚无网站，请先添加网站。'
        site_list >&2
        ask ss_value '网站域名或序号' "$(get '.preferences.domain // .sites[0].domain // ""')"
    fi
    if [[ $ss_value =~ ^[1-9][0-9]*$ ]]; then ss_value=$(jq -r --argjson i "$ss_value" '.sites[$i-1].domain // ""' "$STATE"); fi
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
    json_update --arg d "$domain" '.preferences.domain=$d'
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
site_remove() {
    local domain; site_select domain "${1:-}"
    if jq -e --arg d "$domain" '.nodes[]|select(.domain==$d)' "$STATE" >/dev/null; then die '仍有节点引用此网站，请先删除或迁移这些节点。'; fi
    confirm "移除 $domain 绑定和续期；保留网站内容和证书文件" || return 0
    begin_tx "site-remove:$domain"
    if component_ready acme && jq -e --arg d "$domain" '.sites[]|select(.domain==$d and .issued)' "$STATE" >/dev/null; then acme_run --remove -d "$domain" --ecc; fi
    json_update --arg d "$domain" '.sites |= map(select(.domain!=$d))'
    apply_config web; commit_tx
}
acme_run() { (umask 077; "$ACME" --home "$ROOT/acme" --config-home "$ROOT/acme/config" --cert-home "$ROOT/acme/certstore" --no-color "$@"); }
dns_credentials() {
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
deploy_certificate() {
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
        systemctl is-active --quiet vpskit-nginx.service || die 'HTTP-01需要本工具Nginx运行。'
        args+=(--webroot "$ROOT/www/acme")
        info '请确认公网80及/.well-known/acme-challenge/能到达本机；不自动修改防火墙。'
    else dns_credentials "$challenge"; args+=(--dns "$challenge"); fi
    begin_tx "cert-issue:$domain"
    mkdir -p "$ROOT/www/acme/.well-known/acme-challenge"
    migrate_state; remember_worker; worker_permissions "$(resolve_worker)"
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
cert_import() {
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
cert_renew() {
    component_ready acme || return 0
    local domain changed=false rc=0
    mkdir -p "$ROOT/www/acme/.well-known/acme-challenge"
    if component_ready nginx; then worker_permissions "$(resolve_worker)"; fi
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
rotate_logs() {
    local f
    for f in "$ROOT"/logs/*.log; do
        [[ -f $f && ! -L $f ]] || continue
        if (( $(stat -c %s "$f")>2097152 )); then cp -- "$f" "$f.1"; : > "$f"; fi
    done
}

# Node records retain the 1.6.0 schema. Public TLS transport uses 443;
# .port for WS/XHTTP is a distinct loopback listener, never the public port.
node_list() {
    printf '序号\t名称\t协议/模式\t入口\t后端/直连端口\t启用\n'
    jq -r '.nodes|to_entries[]|[(.key+1),.value.id,(.value.protocol+"/"+.value.mode),.value.entry,.value.port,.value.enabled]|@tsv' "$STATE"
}
node_select() {
    local ns_dest=$1 ns_value=${2:-}
    if [[ -z $ns_value ]]; then node_list >&2; ask ns_value '节点名称或序号' ''; fi
    if ! jq -e --arg id "$ns_value" '.nodes[]|select(.id==$id)' "$STATE" >/dev/null; then
        if [[ $ns_value =~ ^[1-9][0-9]{0,7}$ ]]; then ns_value=$(jq -r --argjson i "$ns_value" '.nodes[$i-1].id // ""' "$STATE"); fi
    fi
    valid_name "$ns_value" && jq -e --arg id "$ns_value" '.nodes[]|select(.id==$id)' "$STATE" >/dev/null || die '节点不存在。'
    printf -v "$ns_dest" '%s' "$ns_value"
}
unused_port() {
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
node_add() {
    local guided=${1:-no} id protocol mode host domain='' port path='' method='' credential listen='0.0.0.0'
    local target='' sni='' private='' public='' short='' keys http_version=h2 item scheme
    ensure_component xray
    ask_valid id '节点名称（字母、数字、下划线、短横线）' "node-$(randhex 3)" valid_name
    if jq -e --arg id "$id" '.nodes[]|select(.id==$id or .entry==$id)' "$STATE" >/dev/null; then die '节点名称/入口已存在。'; fi
    scheme=$(get '.scheme // "A"')
    if [[ $guided == yes ]]; then
        protocol=vless; if [[ $scheme == B ]]; then mode=xhttp; else mode=reality; fi
    else
        ask_valid protocol '协议：vless/vmess/trojan/shadowsocks' vless choice 'vless vmess trojan shadowsocks'
        case "$protocol" in
            vless) ask_valid mode '传输：reality/xhttp/ws/tls' reality choice 'reality xhttp ws tls';;
            vmess) ask_valid mode '传输：ws/tls/ws-plain（最后一个无外层TLS）' ws choice 'ws tls ws-plain';;
            trojan) ask_valid mode '传输：ws/tls' ws choice 'ws tls';;
            shadowsocks) mode=ss;;
        esac
    fi
    if [[ $mode == ws || $mode == xhttp || $mode == tls ]]; then
        site_select domain
        [[ $(jq -r --arg d "$domain" '.sites[]|select(.domain==$d)|.issued' "$STATE") == true ]] || die '所选网站尚未签发证书。'
        host=$domain
        if [[ $mode == tls ]]; then
            info '直接TLS使用独立公网端口；Cloudflare普通橙云不能代理任意TCP协议。'
            ask_valid host '直接连接地址（源站IP或未代理域名）' "$(get '.host // ""')" valid_host
        fi
    else ask_valid host '客户端连接的公网IP或域名' "$(get '.host // ""')" valid_host; fi
    case "$mode" in
        ws|xhttp)
            port=$(unused_port 20000); listen=127.0.0.1
            ask_valid path '代理路径（至少8位随机字符，保留前导/）' "/$(randhex 12)" valid_path
            if [[ $mode == xhttp && $guided != yes ]]; then
                ask_valid http_version '客户端HTTP版本：h2；h3仅限已配置Cloudflare的域名' h2 choice 'h2 h3'
            fi;;
        *) ask_valid port '公网监听端口（不使用22/80/443）' "$(unused_port 8443)" valid_port
           [[ $port != 22 && $port != 80 && $port != 443 ]] || die '该端口为保留端口。';;
    esac
    case "$mode" in
        reality)
            ask_valid sni 'REALITY目标域名/SNI（需TLS1.3，且本机能访问）' 'www.microsoft.com' valid_domain
            target="$sni:443"
            keys=$("$XRAY" x25519)
            private=$(awk -F': *' '/PrivateKey|Private key/{print $2;exit}' <<< "$keys")
            public=$(awk -F': *' '/PublicKey|Public key|Password/{print $2;exit}' <<< "$keys")
            [[ $private =~ ^[A-Za-z0-9_-]{43}$ && $public =~ ^[A-Za-z0-9_-]{43}$ ]] || die 'Xray x25519输出格式无法识别，未保存节点。'
            short=$(randhex 8);;
        ss) ask_valid method 'Shadowsocks算法' '2022-blake3-aes-128-gcm' choice 'aes-128-gcm aes-256-gcm chacha20-ietf-poly1305 2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305';;
        ws-plain) warn '此模式没有外层TLS，仅用于明确需要的可信部署；不建议暴露到不可信网络。';;
    esac
    credential=$(node_credential "$protocol" "$method")
    item=$(jq -n --arg id "$id" --arg p "$protocol" --arg m "$mode" --arg h "$host" --arg d "$domain" --argjson port "$port" --arg path "$path" --arg method "$method" --arg c "$credential" --arg l "$listen" --arg t "$target" --arg s "$sni" --arg pk "$private" --arg pub "$public" --arg sid "$short" --arg hv "$http_version" '{id:$id,entry:$id,protocol:$p,mode:$m,host:$h,domain:$d,port:$port,path:$path,method:$method,credential:$c,listen:$l,target:$t,sni:$s,privateKey:$pk,publicKey:$pub,shortId:$sid,http_version:$hv,enabled:true}')
    confirm "新增 $id ($protocol/$mode)，保留其他节点；Xray将按需重启" || return 0
    begin_tx "node-add:$id"
    json_update --argjson n "$item" --arg h "$host" '.nodes += [$n] | if (.host // "")=="" then .host=$h else . end'
    apply_config; commit_tx
    node_export "$id"
}
node_share() {
    local source id node protocol credential
    node_select source "${1:-}"
    node=$(jq -c --arg id "$source" '.nodes[]|select(.id==$id)' "$STATE"); protocol=$(jq -r .protocol <<< "$node")
    [[ $protocol != shadowsocks ]] || die '此实现不为Shadowsocks入口创建共享用户，请添加独立节点。'
    ask_valid id '新用户/节点名称' "user-$(randhex 3)" valid_name
    if jq -e --arg id "$id" '.nodes[]|select(.id==$id or .entry==$id)' "$STATE" >/dev/null; then die '名称已占用。'; fi
    credential=$(node_credential "$protocol")
    node=$(jq --arg id "$id" --arg c "$credential" '.id=$id|.credential=$c|.enabled=true' <<< "$node")
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
            [[ -n $value ]] || ask_valid value '新节点名称' '' valid_name
            valid_name "$value" || die '名称无效。'
            if jq -e --arg id "$value" '.nodes[]|select(.id==$id)' "$STATE" >/dev/null; then die '新名称已存在。'; fi;;
        port)
            [[ -n $value ]] || ask_valid value '新监听端口（整个共享入口一起更新）' "$(jq -r .port <<< "$node")" valid_port
            valid_port "$value" && [[ $value != 22 && $value != 80 && $value != 443 ]] || die '端口无效。';;
        host)
            [[ -n $value ]] || ask_valid value '新的客户端连接地址（整个共享入口）' "$(jq -r .host <<< "$node")" valid_host
            valid_host "$value" || die '连接地址无效。';;
        *) die '节点操作无效。';;
    esac
    confirm "对 $id 执行 $action；必要时重启Xray，当前连接可能中断" || return 0
    begin_tx "node-$action:$id"
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
    apply_config; commit_tx
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
edge_set() {
    local domain=$1 key=$2 value=$3 probe
    site_select domain "$domain"
    case "$key" in
        bots) choice "$value" 'off ai common all' || die 'bots: off/ai/common/all。';;
        aop) choice "$value" 'off observe enforce' || die 'aop: off/observe/enforce。';;
        gzip|origin) valid_bool "$value" || die '开关应为true/false。';;
        rate) number "$value" 0 100 || die 'rate:0～100。';;
        burst) number "$value" 1 200 || die 'burst:1～200。';;
        connections) number "$value" 0 200 || die 'connections:0～200。';;
        kbps) number "$value" 0 10240 || die 'kbps:0～10240。';;
        static_ttl) number "$value" 0 604800 || die 'static_ttl:0～604800。';;
        *) die '不支持的网站防护参数。';;
    esac
    if [[ $key == aop && $value == enforce ]]; then
        warn '强制AOP前必须在Cloudflare启用Authenticated Origin Pulls，并先用observe模式测试。误配会导致网站/节点525或403。'
    fi
    if [[ $key == origin && $value == true ]]; then warn '开启后此站点只接受已知Cloudflare网段，直连该站点会返回403。'; fi
    if [[ $key == aop && $value != off && ! -s $ROOT/config/edge/aop-ca.pem ]] || { cf_needed && ! cf_ready; }; then cf_fetch; fi
    confirm "设置 $domain：$key=$value" || return 0
    begin_tx "edge:$domain:$key"
    [[ ! -d $WORK/edge ]] || cf_install_assets
    probe=$(get '.edge.probe // ""'); [[ -n $probe ]] || json_update --arg p "$(randhex 16)" '.edge.probe=$p'
    case "$key" in
        bots|aop) json_update --arg d "$domain" --arg k "$key" --arg v "$value" '(.sites[]|select(.domain==$d)).protection[$k]=$v';;
        *) json_update --arg d "$domain" --arg k "$key" --argjson v "$value" '(.sites[]|select(.domain==$d)).protection[$k]=$v';;
    esac
    apply_config web; commit_tx
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
status_show() {
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
doctor() {
    status_show; state_basic "$STATE" || return 1
    validate_state
    local u pid
    u=$(resolve_worker); info "预期Worker账户：$u / UID $(id -u "$u")"
    if component_ready nginx; then
        nginx_cmd -t -p "$ROOT/" -c "$ROOT/config/nginx.conf"
        if systemctl is-active --quiet vpskit-nginx.service; then
            verify_nginx_runtime ''
        fi
        if runuser -u "$u" -- test -r "$STATE"; then die 'Worker能读state.json。'; fi
        if runuser -u "$u" -- test -x "$ROOT/certs"; then die 'Worker能遍历证书目录。'; fi
    fi
    if component_ready xray; then "$XRAY" run -test -config "$ROOT/config/xray.json"; fi
    printf '\n监听端口：\n'; ss -lntup
    printf '\n内存/Swap：\n'; free -h
    printf '\n当前拥塞控制：\n'; sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc 2>/dev/null || true
    ok '上述本机检查完成；不等于外网连通性、CDN回源或实际吞吐测试通过。'
}
paths_show() {
    cat <<EOF
管理代码：$ROOT/vpskit.sh
快捷命令：$ENTRY
持久配置：$STATE（包含凭据，禁止公开）
Nginx生成配置：$ROOT/config/nginx.conf
Xray生成配置：$ROOT/config/xray.json
网站文件：$ROOT/www/<domain>/
证书/私钥：$ROOT/certs/<domain>/current/
ACME账户与DNS凭据：$ROOT/acme/config/
历史快照：$ROOT/backup/history/（最近$HISTORY_KEEP份）
最近事务回滚：$ROOT/backup/last/
代码备份：$ROOT/backup/code/
服务文件：$SYSTEMD/vpskit-*.service / vpskit-maintain.timer
日志：$ROOT/logs/
不要直接编辑自动生成的Nginx/Xray配置；使用高级配置和节点/网站菜单。
EOF
}
logs_show() {
    local name=${1:-nginx} lines=${2:-100} file
    number "$lines" 1 2000 || die '日志行数应为1～2000。'
    case "$name" in nginx) file=nginx.log;; xray) file=xray.log;; manager) file=manage.log;; service) file=nginx-service.log;; access) file=access.log;; *) die '日志类型：nginx/xray/manager/service/access。';; esac
    [[ -f $ROOT/logs/$file && ! -L $ROOT/logs/$file ]] || { info '日志文件尚不存在。'; return; }
    warn '日志可能包含IP、路径或上游错误信息；分享前请脱敏。'
    tail -n "$lines" "$ROOT/logs/$file"
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
firewall_show() {
    printf '本工具不会自动启用/重置防火墙，不修改SSH规则。\n'
    if command -v ufw >/dev/null; then ufw status verbose; fi
    if command -v nft >/dev/null; then nft list ruleset; elif command -v iptables >/dev/null; then iptables -S; fi
    printf '\n本工具需要的公网端口（云厂商安全组仍需单独放行）：\n'
    if component_ready nginx; then printf '80/tcp 443/tcp\n'; fi
    jq -r '[.nodes[]|select(.enabled and .mode!="ws" and .mode!="xhttp")]|unique_by(.entry)[]|"\(.port)/tcp"+(if .mode=="ss" then " \(.port)/udp" else "" end)' "$STATE"
}
firewall_allow() {
    local port=${1:-} proto=${2:-tcp}
    need ufw
    [[ -n $port ]] || ask_valid port '要添加的UFW放行端口' '' valid_port
    valid_port "$port" && choice "$proto" 'tcp udp' || die '端口/协议无效。'
    confirm "仅添加UFW allow $port/$proto，不启用或重置UFW" || return 0
    ufw allow "$port/$proto" comment VPSKit
}
swap_show() { free -h; swapon --show; }
swap_create() {
    local size=${1:-} file=/var/lib/vpskit/swapfile available needed fstype
    [[ -n $size ]] || ask_valid size 'Swap容量MiB（256～8192）' 1024 number 256 8192
    number "$size" 256 8192 || die 'Swap容量超出范围。'
    [[ ! -e /var/lib/vpskit && ! -L /var/lib/vpskit ]] || {
        [[ -d /var/lib/vpskit && ! -L /var/lib/vpskit && -f /var/lib/vpskit/.owned ]] || die 'Swap目录被外部程序占用。'
    }
    [[ ! -e $file && ! -L $file ]] || die '已存在本工具Swap，不会反复创建或覆盖。'
    fstype=$(stat -f -c %T /var/lib)
    case "$fstype" in ext2/ext3|xfs) ;; *) die "当前文件系统${fstype}不在此简化Swap流程支持范围（ext4/XFS），请手工管理。";; esac
    available=$(df -Pk /var/lib | awk 'NR==2{print $4}'); needed=$((size*1024+262144))
    ((available>needed)) || die '磁盘空间不足（预留256MiB）。'
    [[ -f /etc/fstab && ! -L /etc/fstab ]] || die '/etc/fstab必须为普通文件。'
    confirm "创建${size}MiB Swap并添加一条带标识的fstab记录；不会变更已有Swap" || return 0
    mkdir -p /var/lib/vpskit; chmod 700 /var/lib/vpskit; printf VPSKIT_SWAP > /var/lib/vpskit/.owned
    if ! dd if=/dev/zero of="$file" bs=1M count="$size" status=none; then rm -f "$file"; die 'Swap文件分配失败。'; fi
    chmod 600 "$file"
    if ! mkswap "$file" || ! swapon "$file"; then rm -f "$file"; die 'Swap激活失败，已删除本次文件。'; fi
    mkdir -p "$ROOT/backup/system"; cp -a /etc/fstab "$ROOT/backup/system/fstab-before-swap-$(date +%s)"
    if ! grep -Fq "$file " /etc/fstab; then printf '%s none swap sw 0 0 # VPSKIT_SWAP\n' "$file" >> /etc/fstab; fi
    ok 'Swap已启用；现有Swap未修改。'
}
swap_remove() {
    local file=/var/lib/vpskit/swapfile
    [[ -f /var/lib/vpskit/.owned && $(cat /var/lib/vpskit/.owned) == VPSKIT_SWAP && ! -L /var/lib/vpskit && -f $file && ! -L $file ]] || die '没有可验证的本工具Swap。'
    confirm '关闭并删除本工具Swap；内存不足时swapoff可能失败，不处理其他Swap' || return 0
    if swapon --noheadings --raw --show=NAME | grep -Fxq "$file"; then swapoff "$file" || die 'swapoff失败，文件及启动配置保持不变。'; fi
    mkdir -p "$ROOT/backup/system"; cp -a /etc/fstab "$ROOT/backup/system/fstab-before-swap-remove-$(date +%s)"
    sed -i '\|^/var/lib/vpskit/swapfile .*# VPSKIT_SWAP$|d' /etc/fstab
    rm -f "$file" /var/lib/vpskit/.owned; rmdir /var/lib/vpskit || true
    ok '只删除了本工具Swap。'
}
uninstall_keep_data() {
    local u
    warn '卸载只停止/删除本工具服务与命令入口。配置、证书、网站、代码、备份、Swap和防火墙规则全部保留。'
    confirm '执行保留数据的卸载' || return 0
    for u in "${UNITS[@]}"; do
        if [[ -f $SYSTEMD/$u ]] && grep -Fq '# VPSKIT_OWNED' "$SYSTEMD/$u"; then systemctl disable --now "$u" || true; rm -f "$SYSTEMD/$u"; fi
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
usage() {
    cat <<'EOF'
VPSKit 1.7.0-enhanced 完整单文件管理器（非上游官方发布）
用法：sudo bash ./vpskit.sh [命令]  /  sudo vpskit [命令]
无参数进入面板。执行前建议先阅读随附README。

  version | help | selftest                 无需root，不改变系统
  install                                  新装或继续原部署（保留已填参数）
  install xray|nginx|acme [Xray版本]         单独补装，不重复安装已有组件
  apply                                    按现有state重新生成、检查并应用
  status | doctor | paths                  状态、检查、文件位置
  node list|add|share|export|client [名称]    节点、共享用户、客户端配置
  node enable|disable|delete|rotate 名称
  node rename|port|host 名称 [值]           改名、入口端口、连接地址
  site list|add|edit|remove [域名]           网站配置，不覆盖网站内容
  cert issue [域名] | cert status | cert renew
  cert import 域名 /证书路径 /私钥路径
  advanced show | advanced edit [键] | advanced defaults
  advanced set nginx.workers 2 nginx.connections 2048 nginx.nofile 8192
  advanced set nginx.worker_user auto
  advanced set xray.nofile 16384
  history list | history save [备注]
  history restore [快照ID] [full|state|advanced]
  rollback | repair                        最近事务回滚 / 恢复中断事务
  update manager [/新版脚本.sh|HTTPS地址] [独立确认的SHA256]
  update nginx|xray|acme [Xray版本]          组件更新，与代码更新分离
  edge show [域名] | edge edit | edge refresh
  edge set 域名 bots|rate|burst|connections|kbps|static_ttl|gzip|origin|aop 值
  performance gzip [true|false]
  service nginx|xray start|stop|restart
  logs [nginx|xray|manager|service|access] [行数]
  firewall status | firewall allow [端口] [tcp|udp]
  swap status | swap create [MiB] | swap remove
  maintenance                              定时证书/日志维护
  uninstall                                卸载服务，保留所有数据

示例：先 sudo bash ./vpskit.sh update manager ./vpskit.sh 仅换代码；
再 sudo vpskit apply 明确应用降权与参数，不把代码更新当成部署重做。
Xray默认版本固定为v26.3.27；update xray latest为显式选择最新版。
原版1.6.0远程文件不含增强标识，拒绝用它覆盖本版；可上传本版到自己的仓库。
端口/凭据/证书均保存在/opt/vpskit/data/state.json及私有目录。
EOF
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
menu_run() {
    local rc answer
    # Each command runs in a child with its own lock and errexit scope. Testing
    # a mutating function in `if fn` would disable Bash errexit inside that fn.
    set +e
    bash "$SELF" "$@"
    rc=$?
    set -e
    printf '\n操作退出码：%s\n' "$rc"
    ask answer '回车返回面板（:q退出）' ''
}
menu_group() {
    local group=$1 option key d id value
    case "$group" in
        nodes)
            printf '1.查看  2.新增  3.共享入口用户  4.启用  5.禁用  6.删除  7.轮换凭据  8.分享链接  9.XHTTP客户端JSON  0.返回\n'
            ask option '选择' 0
            case "$option" in 1) menu_run node list;; 2) menu_run node add;; 3) menu_run node share;; 4) menu_run node enable;; 5) menu_run node disable;; 6) menu_run node delete;; 7) menu_run node rotate;; 8) menu_run node export;; 9) menu_run node client;; esac;;
        websites)
            printf '1.网站列表  2.新增/编辑  3.移除绑定  4.签发证书  5.证书状态  6.续期检查  0.返回\n'
            ask option '选择' 0
            case "$option" in 1) menu_run site list;; 2) menu_run site add;; 3) menu_run site remove;; 4) menu_run cert issue;; 5) menu_run cert status;; 6) menu_run cert renew;; esac;;
        update)
            printf '1.Nginx组件  2.Xray组件  3.ACME组件  4.仅管理代码  0.返回\n'; ask option '选择' 0
            case "$option" in 1) menu_run update nginx;; 2) ask value 'Xray版本（v数字.数字.数字或latest）' "$XRAY_DEFAULT_VERSION"; menu_run update xray "$value";; 3) menu_run update acme;; 4) menu_run update manager;; esac;;
        advanced)
            printf '1.显示已保存/实际参数  2.Worker/连接数/文件数  3.选择已有服务账户  4.其他Nginx参数  5.Xray文件数  6.恢复高级默认值  0.返回\n'
            ask option '选择' 0
            case "$option" in
                1) menu_run advanced show;; 2) menu_run advanced edit capacity;; 3) menu_run advanced edit nginx.worker_user;;
                4) printf 'keepalive keepalive_requests ssl_cache ssl_timeout http2 client_header_timeout client_body_timeout send_timeout proxy_connect_timeout proxy_read_timeout proxy_send_timeout site_proxy_timeout client_max_body_mb access_log worker_shutdown_timeout upstream_keepalive\n'
                   ask key '参数名称（不含nginx.）' keepalive; menu_run advanced edit "nginx.$key";;
                5) menu_run advanced edit xray.nofile;; 6) menu_run advanced defaults;;
            esac;;
        history)
            printf '1.列出历史  2.立即创建快照  3.恢复配置及证书  4.只恢复高级参数  5.回滚最近事务  6.恢复中断事务  0.返回\n'; ask option '选择' 0
            case "$option" in 1) menu_run history list;; 2) menu_run history save manual;; 3) menu_run history restore;; 4) menu_run history restore '' advanced;; 5) menu_run rollback;; 6) menu_run repair;; esac;;
        status)
            printf '1.状态  2.完整本机检查  3.Nginx日志  4.Xray日志  5.按已保存配置应用  6.重启Nginx  0.返回\n'; ask option '选择' 0
            case "$option" in 1) menu_run status;; 2) menu_run doctor;; 3) menu_run logs nginx;; 4) menu_run logs xray;; 5) menu_run apply;; 6) menu_run service nginx restart;; esac;;
        firewall)
            printf '1.显示规则与所需端口  2.添加UFW放行规则  0.返回\n'; ask option '选择' 0
            case "$option" in 1) menu_run firewall status;; 2) menu_run firewall allow;; esac;;
        swap)
            printf '1.查看Swap  2.创建本工具Swap  3.移除本工具Swap  0.返回\n'; ask option '选择' 0
            case "$option" in 1) menu_run swap status;; 2) menu_run swap create;; 3) menu_run swap remove;; esac;;
        edge)
            printf '1.显示网站防护  2.编辑防护  3.更新Cloudflare官方IP与AOP CA  0.返回\n'; ask option '选择' 0
            case "$option" in 1) menu_run edge show;; 2) menu_run edge edit;; 3) menu_run edge refresh;; esac;;
    esac
}
main_menu() {
    local option
    while :; do
        printf '\nVPSKit %s 管理面板\n' "$VERSION"
        if [[ -f $STATE ]] && command -v jq >/dev/null && state_basic "$STATE"; then
            printf '已载入历史配置：%s个节点 / %s个网站；不会重置。\n' "$(get '.nodes|length')" "$(get '.sites|length')"
        elif [[ -e $STATE ]]; then printf '状态文件异常；请选择14恢复，不会覆盖。\n'
        else printf '尚未初始化；选择1部署，或先安装单独组件。\n'; fi
        cat <<'EOF'
 1. 部署与安装 / 继续历史部署
 2. 节点与用户
 3. 网站与证书
 4. 网站压缩设置
 5. 组件更新（与代码分离）
 6. 状态、日志与维护
 7. 卸载服务（保留数据）
 8. 方案说明与命令帮助
 9. 配置文件与目录
10. 防火墙端口管理
11. Swap虚拟内存
12. 网站防护与流量
13. 高级配置 · Nginx / Xray
14. 历史配置和恢复
15. 仅更新管理脚本
 0. 退出
EOF
        ask option '选择' 0
        case "$option" in
            0) return;;
            1) printf '1.向导/继续  2.只安装Nginx  3.只安装Xray  4.只安装ACME  0.返回\n'; ask option '选择' 1
               case "$option" in 1) menu_run install;; 2) menu_run install nginx;; 3) menu_run install xray;; 4) menu_run install acme;; esac;;
            2) menu_group nodes;; 3) menu_group websites;; 4) menu_run performance gzip;;
            5) menu_group update;; 6) menu_group status;; 7) menu_run uninstall;; 8) menu_run help;; 9) menu_run paths;;
            10) menu_group firewall;; 11) menu_group swap;; 12) menu_group edge;; 13) menu_group advanced;; 14) menu_group history;; 15) menu_run update manager;;
            *) printf '无效选项。\n';;
        esac
    done
}
main() {
    local command=${1:-menu} action=${2:-} rc
    case "$command" in version|--version|-V) printf '%s\n' "$VERSION"; return;; help|--help|-h) usage; return;; selftest) selftest; return;; esac
    if [[ $command == _service ]]; then service_runner "${2:-}"; return; fi
    system_check
    [[ -f $SELF && $SELF != /dev/fd/* && $SELF != /proc/* ]] || die '请先把完整脚本下载为本地普通文件，再执行 sudo bash ./vpskit.sh；不依赖在线旧脚本。'
    SELF=$(realpath -- "$SELF")
    # /dev/tty is optional for status/maintenance; mutations that need approval
    # refuse to invent approval when no terminal is attached.
    if { exec {TTY_FD}<>/dev/tty; } 2>/dev/null; then :; else TTY_FD=''; fi
    if [[ $command == menu ]]; then main_menu; return; fi
    safe_layout
    trap cleanup EXIT
    trap 'error_trap "$?" "$LINENO"' ERR
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [[ $command == install ]]; then install_dependencies; fi
    need jq; need openssl
    if [[ $command == update && $action == manager ]]; then
        # Never initialize, migrate, render or reload state on code-only update.
        update_manager "${3:-}" "${4:-}"; return
    fi
    if [[ $command == repair ]]; then repair_transaction; return; fi
    if [[ $command == rollback ]]; then rollback_last; return; fi
    if [[ $command == history ]]; then
        case "$action" in list) history_list;; save) history_save "${3:-manual}";; restore) history_restore "${3:-}" "${4:-full}";; *) die 'history: list/save/restore。';; esac
        return
    fi
    if [[ -d $ROOT/backup/transaction ]]; then die '检测到未完成事务；先运行repair再变更配置。'; fi
    if [[ $command == status ]]; then status_show; return; fi
    if [[ $command == paths ]]; then paths_show; return; fi
    if [[ $command == install ]]; then init_state
    else state_basic "$STATE" || die '没有可用state.json；新装请运行install，已有部署请从history恢复。'; fi
    case "$command" in
        install) if [[ -z $action ]]; then install_wizard; else install_component "$action" "${3:-$XRAY_DEFAULT_VERSION}"; fi;;
        apply) apply_existing;;
        doctor) doctor;;
        node)
            case "$action" in
                list) node_list;; add) node_add;; share) node_share "${3:-}";; export) node_export "${3:-}";; client) node_client "${3:-}";;
                enable|disable|delete|rotate|rename|port|host) node_change "$action" "${3:-}" "${4:-}";;
                *) die 'node: list/add/share/enable/disable/delete/rotate/rename/port/host/export/client。';;
            esac;;
        site) case "$action" in list) site_list;; add|edit) site_configure "${3:-}";; remove) site_remove "${3:-}";; *) die 'site: list/add/edit/remove。';; esac;;
        cert) case "$action" in issue) cert_issue "${3:-}";; status) cert_status;; renew) cert_renew;; import) (($#==5)) || die 'cert import需要域名、证书路径、私钥路径。'; cert_import "$3" "$4" "$5";; *) die 'cert: issue/status/renew/import。';; esac;;
        advanced)
            case "$action" in show) advanced_show;; edit) advanced_edit "${3:-}";; defaults) advanced_defaults;; set) shift 2; advanced_set "$@";; *) die 'advanced: show/edit/set/defaults。';; esac;;
        update)
            choice "$action" 'nginx xray acme' || die 'update: manager/nginx/xray/acme。'
            confirm "更新组件$action，保留配置；必要时重启相关服务" || return 0
            install_dependencies; install_component "$action" "${3:-$XRAY_DEFAULT_VERSION}" yes;;
        edge) case "$action" in show) edge_show "${3:-}";; edit) edge_edit;; refresh) edge_refresh;; set) (($#==5)) || die 'edge set需要域名、键、值。'; edge_set "$3" "$4" "$5";; *) die 'edge: show/edit/refresh/set。';; esac;;
        performance) [[ $action == gzip ]] || die 'performance仅支持gzip；不自动改动BBR或内核。'; performance_gzip "${3:-}";;
        service) service_action "$action" "${3:-}";;
        logs) logs_show "${2:-nginx}" "${3:-100}";;
        firewall) case "$action" in status) firewall_show;; allow) firewall_allow "${3:-}" "${4:-tcp}";; *) die 'firewall: status/allow。';; esac;;
        swap) case "$action" in status) swap_show;; create) swap_create "${3:-}";; remove) swap_remove;; *) die 'swap: status/create/remove。';; esac;;
        maintenance) cert_renew; rotate_logs;;
        uninstall) uninstall_keep_data;;
        *) die '未知命令；运行help查看。';;
    esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
