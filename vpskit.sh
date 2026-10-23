#!/usr/bin/env bash
# VPSKIT_SINGLE_FILE
# VPSKIT_FEATURE_LEVEL=3
# VPSKIT_STATE_SCHEMA=1
# VPSKit 1.7.1-panel — full colored menu edition; independent enhanced release.
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
VERSION='1.7.1-panel'
FEATURE_LEVEL=3
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

info() { log INFO "$@"; }
warn() { log WARN "$@"; }
ok() { log OK "$@"; }
die() { log ERROR "$@"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "缺少命令 $1。"; }
root_check() { (( EUID == 0 )) || die '请使用 sudo bash ./vpskit.sh 或 sudo vpskit。'; }
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
        ws-plain) warn '此模式没有外层TLS，仅用于明确需要的可信部署；不建议暴露到不可信网络。'
            ask_valid path 'WebSocket路径（至少8位，保留前导/）' "/$(randhex 12)" valid_path;;
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
service_action() {
    local name=$1 action=$2
    choice "$name" 'nginx xray' && choice "$action" 'start stop restart' || die '服务操作无效。'
    ensure_component "$name"
    [[ -f $SYSTEMD/vpskit-$name.service ]] && grep -Fq '# VPSKIT_OWNED' "$SYSTEMD/vpskit-$name.service" || die '服务文件不属于VPSKit。'
    confirm "对vpskit-$name执行$action；可能中断现有连接" || return 0
    systemctl "$action" "vpskit-$name.service"
    if [[ $action != stop ]]; then systemctl is-active --quiet "vpskit-$name.service" || die '服务未运行。'; fi
}
uninstall_keep_data() {
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
menu_catalog() {
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
services|1|启动 Nginx|仅控制 vpskit-nginx 服务|已安装对应组件；停止或重启会中断相关连接|write|service:nginx:start
services|2|停止 Nginx|仅控制 vpskit-nginx 服务|已安装对应组件；停止或重启会中断相关连接|warn|service:nginx:stop
services|3|重启 Nginx|仅控制 vpskit-nginx 服务|已安装对应组件；停止或重启会中断相关连接|warn|service:nginx:restart
services|4|验证并重载 Nginx|仅控制 vpskit-nginx 服务|已安装对应组件；停止或重启会中断相关连接|write|service:nginx:reload
services|5|启动 Xray|仅控制 vpskit-xray 服务|已安装对应组件；停止或重启会中断相关连接|write|service:xray:start
services|6|停止 Xray|仅控制 vpskit-xray 服务|已安装对应组件；停止或重启会中断相关连接|warn|service:xray:stop
services|7|重启 Xray|仅控制 vpskit-xray 服务|已安装对应组件；停止或重启会中断相关连接|warn|service:xray:restart
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
nginxparams|14|网站访问日志开关|开启或关闭缓冲访问日志|true/false；会记录IP与路径并占用磁盘|write|param:access_log
nginxparams|15|Worker 优雅退出期限|reload后旧Worker最多等待的时间|0–3600 秒；0不强制截止，非0可能断开长连接|write|param:worker_shutdown_timeout
nginxparams|16|网站上游连接池|每Worker保留的应用上游空闲连接数|0–128；0关闭；并非最大上游连接总数|write|param:upstream_keepalive
history|1|列出历史快照|显示快照时间、备注和版本|只读；快照含敏感凭据，不要公开|read|history-list
history|2|立即创建快照|保存当前配置、证书及ACME资料|当前state.json须有效；不备份网站内容|write|history-save
history|3|恢复配置与证书|从历史恢复配置及证书，验证后应用|现有程序必须满足依赖；可能重启服务|warn|history-full
history|4|仅恢复高级参数|取回旧的Nginx/Xray参数|保留当前节点、证书和网站；状态文件须有效|warn|history-advanced
history|5|回滚最近事务|恢复上一次操作前配置，可能含组件程序|将重启之前运行的服务；需有最近事务备份|warn|rollback
history|6|恢复中断事务|处理掉线或失败留下的未完成事务|检测到残留事务时优先执行此项|warn|repair
history|7|只恢复状态配置|使用历史节点/网站设置及当前证书重新生成|当前证书及组件必须满足历史配置要求|warn|history-state
history|8|查看当前部署进度|核对现有历史参数和向导完成情况|只读；不会重置部署|read|wizard-status
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
menu_title() {
    case "$1" in
        main) printf '主面板';; install) printf '部署与安装';; nodes) printf '节点与用户';;
        websites) printf '网站与证书';; optimize) printf '网络与网站优化';; update) printf '组件更新';;
        status) printf '状态、日志与维护';; services) printf '服务控制';; uninstall) printf '卸载管理';;
        help) printf '方案说明与帮助';; firewall) printf '防火墙端口管理';; swap) printf 'Swap 虚拟内存';;
        edge) printf '方案 B 防护与流量';; advanced) printf '高级配置 · Nginx / Xray';;
        nginxparams) printf 'Nginx 参数设置';; history) printf '历史配置和恢复';;
        *) return 1;;
    esac
}
panel_summary() {
    if ! command -v jq >/dev/null 2>&1; then
        ui_note '尚未安装 jq：可先进入部署菜单；不会覆盖现有状态文件。'; return
    fi
    if [[ -f $STATE ]] && state_basic "$STATE" 2>/dev/null; then
        printf '  已载入配置：方案 %s%s%s  节点 %s%s%s（启用 %s）  网站 %s%s%s\n' \
          "$CYAN" "$(get '.scheme // "A"')" "$RESET" "$CYAN" "$(get '.nodes|length')" "$RESET" \
          "$(get '[.nodes[]|select(.enabled)]|length')" "$CYAN" "$(get '.sites|length')" "$RESET"
        printf '  Worker：%s%s%s  数量：%s%s%s  每 Worker 连接：%s%s%s\n' \
          "$CYAN" "$(get '.advanced.nginx.resolved_user // "应用配置时自动检测"')" "$RESET" \
          "$CYAN" "$(ng_value workers)" "$RESET" "$CYAN" "$(ng_value connections)" "$RESET"
        ui_note '保留节点、网站、证书和高级参数；再次打开不会重置。'
    elif [[ -e $STATE ]]; then ui_status '配置文件' '损坏'; ui_note '请选择 14 恢复；不会创建空配置覆盖它。'
    else ui_note '尚未初始化；请选择 1 新装，已有部署请先检查 14 历史恢复。'; fi
    if [[ -d $ROOT/backup/transaction ]]; then ui_status '待处理事务' '请先选择 14 → 6 恢复中断事务'; fi
}
menu_render() {
    local group=$1 row_group number title desc req risk route c badge current
    local heading; heading=$(menu_title "$group") || return 1
    ui_title "VPSKit $VERSION  |  $heading"
    [[ $group != main ]] || panel_summary
    ui_note '蓝色=选项  绿色=只读/正常  黄色=注意  红色=危险  灰色=说明'
    while IFS='|' read -r row_group number title desc req risk route; do
        [[ $row_group == "$group" ]] || continue
        c=$BLUE; badge='设置'
        case "$risk" in read) c=$GREEN; badge='只读';; nav) c=$BLUE; badge='菜单';;
            write) c=$BLUE; badge='修改';; warn) c=$YELLOW; badge='注意';;
            danger) c=$RED; badge='危险';; sensitive) c=$YELLOW; badge='敏感';;
            back) c=$DIM; badge='返回';; esac
        current=''
        if [[ $group == nginxparams ]] && command -v jq >/dev/null && state_basic "$STATE" 2>/dev/null; then
            [[ $route != param:* ]] || current="（当前：$(ng_value "${route#param:}")）"
        fi
        printf '  %s%2s.%s %s%s%s %s[%s]%s %s%s%s\n' "$BLUE" "$number" "$RESET" "$c" "$title" "$RESET" "$c" "$badge" "$RESET" "$CYAN" "$current" "$RESET"
        printf '      %s用途：%s  |  要求：%s%s\n' "$DIM" "$desc" "$req" "$RESET"
    done < <(menu_catalog)
    ui_note '输入序号；0 返回；操作中 :q 取消后回到面板。危险操作默认不执行。'
}
menu_preview() {
    local group=${1:-main} g
    if [[ $group == all ]]; then
        while IFS= read -r g; do menu_render "$g"; done < <(menu_catalog | cut -d'|' -f1 | awk '!seen[$0]++')
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
menu_dispatch() {
    local route=$1 name action
    case "$route" in
        menu:*) menu_group "${route#menu:}";;
        param:*) menu_run advanced edit "nginx.${route#param:}";;
        service:*) name=${route#service:}; action=${name#*:}; name=${name%%:*}; menu_run service "$name" "$action";;
        install-wizard) menu_run install;; install-nginx) menu_run install nginx;; install-xray) menu_run install xray;; install-acme) menu_run install acme;;
        wizard-configure) menu_run wizard configure;; wizard-status) menu_run wizard status;;
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
        rollback) menu_run rollback;; repair) menu_run repair;; back) return;;
        *) die "面板路由不存在：$route";;
    esac
}
menu_group() {
    local group=${1:-main} option route
    menu_title "$group" >/dev/null || die '未知菜单。'
    while :; do
        menu_render "$group"
        ask option '请选择序号' 0
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
    ask_valid host '以后新增节点默认连接的公网IP或域名' "$(get '.host // ""')" valid_host
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
cert_import_interactive() {
    local d cert key
    site_select d
    ask cert '完整证书链 PEM 文件绝对路径' ''
    ask key '私钥 PEM 文件绝对路径（不会打印内容）' ''
    [[ $cert == /* && $key == /* ]] || die '请提供绝对路径。'
    cert_import "$d" "$cert" "$key"
}
site_edit_existing() { local d; site_select d "${1:-}"; site_configure "$d"; }
node_set_credential() {
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
    ask_valid value '监听：0.0.0.0=IPv4；::=IPv6/双栈；127.0.0.1或::1=仅本机' "$(jq -r '.listen // "0.0.0.0"' <<< "$n")" choice '0.0.0.0 :: 127.0.0.1 ::1'
    if [[ $value == *:* ]]; then [[ -s /proc/net/if_inet6 ]] || die '系统未提供可用IPv6接口。'; fi
    entry=$(jq -r .entry <<< "$n")
    confirm "同步修改整个共享入口 $entry 的监听地址为 $value" || return 0
    begin_tx "node-listen:$id"
    json_update --arg e "$entry" --arg l "$value" '(.nodes[]|select(.entry==$e)).listen=$l'
    apply_config; commit_tx
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
service_control() {
    local name=$1 action=$2
    # Accept both the 1.6 order (action name) and 1.7 order (name action).
    if choice "$name" 'start stop restart reload'; then local tmp=$name; name=$action; action=$tmp; fi
    if [[ $name == nginx && $action == reload ]]; then
        ensure_component nginx
        [[ -f $SYSTEMD/vpskit-nginx.service && ! -L $SYSTEMD/vpskit-nginx.service ]] && grep -Fq '# VPSKIT_OWNED' "$SYSTEMD/vpskit-nginx.service" || die '服务归属不匹配。'
        nginx_cmd -t -p "$ROOT/" -c "$ROOT/config/nginx.conf"
        confirm '配置检查成功，重载本工具Nginx（不重新生成配置）' || return 0
        systemctl reload vpskit-nginx.service
        verify_nginx_runtime ''
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
fw_choose_zone() {
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
    fw_guard_port "$port" "$proto"
    choice "$backend" 'ufw firewalld' && choice "$proto" 'tcp udp' && choice "$action" 'allow deny' || die '防火墙规则字段错误。'
    [[ $backend != firewalld || $zone =~ ^[a-zA-Z0-9_-]+$ ]] || die 'zone字段无效。'
    fw_records_init; f=$(fw_record_file); id=$(fw_id "$backend" "$zone" "$port" "$proto"); tag="VPSKIT-$id"
    old=$(jq -r --arg id "$id" '.rules[]|select(.id==$id)|.action' "$f")
    if [[ $backend == ufw ]]; then
        status=$(ufw status numbered)
        # Avoid UFW silently re-labelling an existing unowned rule on the same port.
        existing=$(awk -v p="$port/$proto" -v tag="$tag" 'index($0,p) && index($0,"# "tag)==0 {print}' <<< "$status")
        [[ -z $existing ]] || die "检测到 $port/$proto 的外部UFW规则；为避免更改归属，请先人工核对规则顺序。"
    fi
    record_update "$f" --arg id "$id" --arg b "$backend" --arg z "$zone" --argjson p "$port" --arg pr "$proto" --arg a "$action" --arg old "${old:-}" '
      .rules=([.rules[]|select(.id!=$id)]+[{id:$id,backend:$b,zone:$z,port:$p,proto:$pr,action:$a,previous_action:$old,stage:"pending"}])'
    # Both possible actions are removed for crash recovery; only exact tagged/recorded rules.
    if [[ $backend == ufw ]]; then fw_ufw_remove_tag "$tag"
    else
        fw_remove_rule "$backend" "$zone" "$port" "$proto" allow "$id"
        fw_remove_rule "$backend" "$zone" "$port" "$proto" deny "$id"
    fi
    if [[ $backend == ufw ]]; then
        ufw insert 1 "$action" in proto "$proto" to any port "$port" comment "$tag"
        ufw status numbered | grep -Fq "# $tag" || die 'UFW未返回预期规则标识；保留pending记录。'
    else
        for family in ipv4 ipv6; do
            rule=$(fw_rich_rule "$family" "$port" "$proto" "$action" "$id")
            firewall-cmd --zone="$zone" --add-rich-rule="$rule"
            firewall-cmd --permanent --zone="$zone" --add-rich-rule="$rule"
            firewall-cmd --zone="$zone" --query-rich-rule="$rule" >/dev/null
            firewall-cmd --permanent --zone="$zone" --query-rich-rule="$rule" >/dev/null
        done
    fi
    record_update "$f" --arg id "$id" '(.rules[]|select(.id==$id)).stage="applied"'
    ok "$backend $zone：$port/$proto → $action（需外网及云安全组验收）"
}
firewall_required() {
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
firewall_change() {
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
uninstall_component() {
    local name=$1
    choice "$name" 'nginx xray acme' || die '组件无效。'; ensure_component "$name"
    case "$name" in
        nginx) [[ $(get '.sites|length') == 0 ]] && ! jq -e '.nodes[]|select(.mode=="ws" or .mode=="xhttp")' "$STATE" >/dev/null || die '仍有网站/网关节点依赖Nginx，请先移除这些绑定。';;
        acme) ! jq -e '.sites[]|select(.issued and (.certificate_source // "acme")!="manual")' "$STATE" >/dev/null || die '仍有自动续期证书依赖ACME；先移除网站或明确改为手动证书。';;
    esac
    warn '单组件卸载保留其他组件与网站文件；Xray卸载会删除全部节点。'
    confirm "卸载 $name，并按剩余配置重新应用" || return 0
    begin_tx "uninstall:$name" components
    json_update --arg n "$name" '.components[$n]=false | del(.versions[$n]) | if $n=="xray" then .nodes=[] else . end'
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
uninstall_all() {
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
        printf '[%s] [%s] %s\n' "$(date -u '+%FT%TZ')" "$level" "$*" >> "$LOGFILE"
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
    local key=${1:-} value workers connections nofile description=''
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
            value=$(ng_value worker_user);;
        xray.nofile)
            ui_note '用途：Xray进程文件描述符上限；要求2048～1048576且不超过内核nr_open；应用会按需重启Xray。'
            value=$(xray_nofile);;
        nginx.*)
            description=$(menu_catalog | awk -F'|' -v k="param:${key#nginx.}" '$7==k{print "用途："$4"；要求："$5}')
            [[ -n $description ]] || die '该参数请通过 advanced set 修改，或从高级面板选择有效选项。'
            ui_note "$description"; value=$(ng_value "${key#nginx.}");;
        *) die '未知高级参数。';;
    esac
    ask value "设置 $key（true/false用于开关；:q取消）" "$value"
    advanced_set "$key" "$value"
}
paths_show() {
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
    case "$name" in nginx) file=nginx.log;; xray) file=xray.log;; manager) file=manage.log;; service) file=nginx-service.log;; access) file=access.log;; *) die '日志类型：nginx/xray/manager/service/access/cert。';; esac
    [[ -f $ROOT/logs/$file && ! -L $ROOT/logs/$file ]] || { info '日志文件尚不存在；访问日志需在高级配置中先开启。'; return; }
    tail -n "$lines" "$ROOT/logs/$file"
}
usage() {
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
VPSKit 1.7.1-panel 完整单文件管理器（独立增强版，非上游官方发布）
用法：sudo bash ./vpskit.sh [选项] [命令] / sudo vpskit [选项] [命令]
不带命令进入彩色管理面板；每项均显示用途、要求和风险类别。
选项：--no-color / --color=auto|always|never（位于命令之前）

version | help [workflow|colors] | selftest | preview [面板|all]  只读，无需root
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
history restore [快照ID] [full|state|advanced] | rollback | repair
update manager [/新版.sh|HTTPS地址] [独立确认的SHA256]  仅替换代码
update nginx|xray|acme [Xray版本] | update all           单独更新组件
optimize status|bbr|restore|mtu [目标] | performance gzip [true|false]
edge status|show [域名] | edge edit | edge refresh | edge guide | edge traffic
edge profile|bots|limits|cache|origin|aop|probe|reset [域名]
edge set 域名 bots|rate|burst|connections|kbps|static_ttl|gzip|origin|aop 值
service nginx|xray start|stop|restart | service nginx reload
logs [nginx|xray|manager|service|access|cert] [行数]
firewall status | firewall open|close [端口] [tcp|udp|both]
firewall sync | firewall cleanup           支持已启用的UFW或firewalld
swap status | swap enable | swap custom [MiB] | swap remove
maintenance                               证书、日志、官方Cloudflare资料维护
uninstall [keep|xray|nginx|acme|all]         停用保留/分组件/完整删除

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
    case "$command" in
        version|--version|-V) printf '%s\n' "$VERSION"; return;;
        help|--help|-h) usage "$action"; return;;
        explain) explain; return;;
        edge) if [[ $action == guide ]]; then edge_guide; return; fi;;
        selftest) selftest; return;;
        preview) menu_preview "${2:-main}"; return;;
        _service) service_runner "$action"; return;;
        menu|install|wizard|apply|status|doctor|paths|node|site|cert|advanced|history|rollback|repair|update|edge|performance|optimize|service|logs|firewall|swap|maintenance|uninstall|network-check) ;;
        *) die '未知命令；使用help查看。';;
    esac
    system_check
    [[ -f $SELF && $SELF != /dev/fd/* && $SELF != /proc/* ]] || die '请先下载完整脚本为本地普通文件，再运行sudo bash ./vpskit.sh。'
    SELF=$(realpath -- "$SELF")
    if { exec {TTY_FD}<>/dev/tty; } 2>/dev/null; then :; else TTY_FD=''; fi
    if [[ $command == menu ]]; then main_menu; return; fi
    if [[ -z $action ]]; then
        case "$command" in
            node) menu_group nodes; return;; site|cert) menu_group websites; return;;
            advanced|history|update|edge|firewall|swap|optimize) menu_group "$command"; return;;
        esac
    fi
    safe_layout
    trap cleanup EXIT
    trap 'error_trap "$?" "$LINENO"' ERR
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [[ $command == install ]]; then install_dependencies; fi
    need jq; need openssl
    if [[ $command == update && $action == manager ]]; then
        update_manager "${3:-}" "${4:-}"; return
    fi
    case "$command" in
        repair) repair_transaction; return;; rollback) rollback_last; return;;
        history)
            case "$action" in list) history_list;; save) history_save "${3:-manual}";; restore) history_restore "${3:-}" "${4:-full}";; *) die 'history: list/save/restore。';; esac
            return;;
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
    case "$command" in
        install) if [[ -z $action ]]; then install_wizard; else install_component "$action" "${3:-$XRAY_DEFAULT_VERSION}"; fi;;
        wizard) [[ $action == configure ]] || die 'wizard: configure/status。'; wizard_configure;;
        apply) apply_existing;; doctor) doctor;; network-check) network_check;;
        node)
            case "$action" in
                list) node_list;; add) node_add;; share) node_share "${3:-}";; export) node_export "${3:-}";; client) node_client "${3:-}";;
                edit|credential) node_set_credential "${3:-}";; listen) node_set_listen "${3:-}";; address) node_change host "${3:-}" "${4:-}";;
                enable|disable|delete|rotate|rename|port|host) node_change "$action" "${3:-}" "${4:-}";;
                *) die 'node: list/add/share/edit/listen/enable/disable/delete/rotate/rename/port/host/export/client。';;
            esac;;
        site) case "$action" in list) site_list;; add) site_configure "${3:-}";; edit) site_edit_existing "${3:-}";; remove) site_remove "${3:-}";; *) die 'site: list/add/edit/remove。';; esac;;
        cert)
            case "$action" in
                issue) cert_issue "${3:-}";; settings) cert_settings "${3:-}";; status) cert_status;; renew) cert_renew;;
                import) if (($#==2)); then cert_import_interactive; else (($#==5)) || die 'cert import需要域名、证书路径、私钥路径。'; cert_import "$3" "$4" "$5"; fi;;
                *) die 'cert: issue/settings/status/renew/import。';;
            esac;;
        advanced) case "$action" in show) advanced_show;; users) worker_users;; edit) advanced_edit "${3:-}";; defaults) advanced_defaults;; set) shift 2; advanced_set "$@";; *) die 'advanced: show/users/edit/set/defaults。';; esac;;
        update) if [[ $action == all ]]; then update_all; else component_update "$action" "${3:-}"; fi;;
        edge)
            case "$action" in
                status) edge_status_all;; show) if [[ -n ${3:-} ]]; then edge_show "$3"; else edge_status_all; fi;;
                edit) edge_edit;; refresh) edge_refresh;; guide) edge_guide;; traffic) edge_traffic;; probe) edge_probe "${3:-}";;
                profile|bots|limits|cache|origin|aop|reset) edge_action "$action" "${3:-}";;
                set) (($#==5)) || die 'edge set需要域名、键、值。'; edge_set "$3" "$4" "$5";;
                *) die 'edge: status/edit/refresh/guide/traffic/probe/profile/bots/limits/cache/origin/aop/reset/set。';;
            esac;;
        performance) [[ $action == gzip ]] || die 'performance: gzip。'; performance_gzip "${3:-}";;
        service) service_control "$action" "${3:-}";;
        maintenance) cert_renew; rotate_logs; edge_maintenance;;
        uninstall) case "${action:-keep}" in keep) uninstall_keep_data;; all) uninstall_all;; nginx|xray|acme) uninstall_component "$action";; *) die 'uninstall: keep/xray/nginx/acme/all。';; esac;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
