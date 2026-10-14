#!/usr/bin/env bash
# K8S 单机执行安装器 v2.1 — 2026-10-10
# 每台 Linux 机器各执行一次；不包含 SSH 编排。请用 bash，不要用 sh。
# 适用范围：RHEL 9，x86_64/aarch64，systemd + cgroup v2，IPv4，单控制平面。
# 自动路径：containerd + kubeadm + kubelet + kubectl + Flannel（VXLAN）。
# 这是实验环境安装脚本，不是发行版升级器、集群升级器或生产环境安全基线。
#
# 首次使用先看：bash k8s-setup.sh --help
# master: sudo bash k8s-setup.sh master --name master --ip 192.168.194.141
# worker: sudo bash k8s-setup.sh worker --name node1 --ip 192.168.194.142 \
#           --join-file ./k8s-worker-join.json
#
# 自动修改内容：hostname/hosts、Swap、SELinux、firewalld（可选保留）、软件源、
# 内核模块/参数、containerd、kubelet、集群初始化或加入。修改前备份配置。
# 默认 FIREWALL_MODE=disable、SELinux=permissive；请先看配置样例中的说明。
# 不修改网卡地址/默认路由、不 yum update、不自动重启、不 kubeadm reset。
# 已初始化的 master 只核对并继续 CNI/导出；不覆盖已有 etcd 或重新 init。
#
# 依据：
# https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
# https://kubernetes.io/docs/setup/production-environment/container-runtimes/
# https://kubernetes.io/docs/reference/config-api/kubeadm-config.v1beta4/
# https://docs.docker.com/engine/install/rhel/
# https://github.com/flannel-io/flannel#deploying-flannel-with-kubectl

set -Eeuo pipefail

# ===== 默认值：配置文件可覆盖；不把密码、token 或网卡参数写死在脚本中 =====
K8S_VERSION=1.37.1
# K8S_VERSION 固定本机组件的 RPM 版本；新建集群时也作为控制平面版本。
# 已有集群/加入文件另存控制平面版本，不能把 1.37.0 的服务端当成 1.37.1 RPM 的目标版本。
CONTROL_PLANE_VERSION=
CONTAINERD_VERSION=2.4.1
MIRROR=aliyun
IMAGE_REPOSITORY=registry.aliyuncs.com/google_containers
K8S_BASEURL=
K8S_GPGKEY=
CONTAINERD_BASEURL=
CONTAINERD_GPGKEY=
BASEOS_URL=
APPSTREAM_URL=
RHEL_GPGKEY=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release
OS_REPO_IDS=
POD_CIDR=10.244.0.0/16
SERVICE_CIDR=10.96.0.0/12
KUBE_PROXY_MODE=iptables
FIREWALL_MODE=disable
FLANNEL_VERSION=v0.28.10
FLANNEL_SHA256=393bdbce53eb50c8eb97dd513b218518b7d6e7985dc7b889be956e112a711084
FLANNEL_URL=
# 可选：在企业镜像仓库中同步 ghcr.io/flannel-io/* 的同名镜像后替换此前缀。
FLANNEL_IMAGE_PREFIX=
WAIT_SECONDS=600
JOIN_TTL_HOURS=24

STAGE=help
NODE_NAME=
NODE_IP=
MASTER_NAME=
MASTER_IP=
JOIN_FILE=
OUTPUT_FILE=./k8s-worker-join.json
CONFIG_FILE=
CLI_NAME=
CLI_IP=
PLAN_ROLE=master
JOIN_TOKEN=
CA_HASH=
JOIN_EXPIRES=
CRI_SOCKET=unix:///run/containerd/containerd.sock
WORK_DIR=
BACKUP_DIR=
NODE_NIC=
NODE_NETWORK=
RHEL_MAJOR=
HOST_ARCH=
PYTHON=
LIVE_VERSION=
LIVE_POD=
LIVE_SERVICE=
LIVE_IMAGE_REPOSITORY=
LIVE_PROXY_MODE=
DNF_OS_ARGS=()

# ===== 输出样式：模块用分隔栏，具体检查项用小标题 =====
# 仅交互终端启用颜色；重定向到日志、TERM=dumb 或 NO_COLOR=1 时输出纯文本。
UI_RULE='======================================================================'
UI_ACCENT=
UI_BOLD=
UI_RESET=
init_output() {
    UI_ACCENT=; UI_BOLD=; UI_RESET=
    if [[ -t 1 && "${TERM:-dumb}" != dumb && -z "${NO_COLOR:-}" ]]; then
        UI_ACCENT=$'\033[1;36m'
        UI_BOLD=$'\033[1m'
        UI_RESET=$'\033[0m'
    fi
}
section() {
    printf '\n%s%s%s\n' "$UI_ACCENT" "$UI_RULE" "$UI_RESET"
    printf '%s  %s%s\n' "$UI_BOLD" "$*" "$UI_RESET"
    printf '%s%s%s\n' "$UI_ACCENT" "$UI_RULE" "$UI_RESET"
}
item() { printf '\n%s  > %s%s\n' "$UI_BOLD" "$*" "$UI_RESET"; }
log() { printf '\n%s[k8s]%s %s\n' "$UI_ACCENT" "$UI_RESET" "$*"; }
die() { printf '\n[停止] %s\n' "$*" >&2; exit 1; }
on_error() {
    # 不打印 BASH_COMMAND，避免错误日志泄漏加入凭据。
    printf '\n[失败] 行号 %s，退出码 %s。后续步骤已停止。\n' "$1" "$2" >&2
    [[ -z "$BACKUP_DIR" ]] || printf '配置备份：%s\n' "$BACKUP_DIR" >&2
    printf '排查：sudo bash k8s-setup.sh check；不要直接 reset 或重复 init。\n' >&2
}
cleanup() {
    # 只清理本次 mktemp 创建的临时目录，绝不删除 Kubernetes/etcd 数据。
    if [[ "$WORK_DIR" == /tmp/k8s-setup.* && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}

usage() {
    cat <<'HELP'
K8S 安装器 ：每台机器独立执行，同一份脚本可部署 master 或任意数量的 worker。

用法：sudo bash k8s-setup.sh <命令> [选项]
  master      新机器：准备环境 → 初始化 → Flannel → 验证 → 导出加入文件。
              已有 master：先核对参数；只继续网络插件/验证，不重装或重新初始化。
  worker      读取加入文件 → 准备环境 → kubeadm join → 等待本节点 Ready。
  prepare     只安装基础环境和组件；适合制作“kubeadm init 之前”的关机模板。
  cni         已有 master 上部署/继续 Flannel；自动读取真实集群网段。
  join-info   已有 master 上检查健康状态并导出新的加入文件；默认有效期 24 小时。
  check       只读检查；不会安装、刷新软件包缓存或生成 token。
  plan        仅显示参数和将执行的流程；不会安装或检查实际网络连通性。

选项：
  --name NAME       本机 Kubernetes 节点名，例如 master / node1 / worker-a。
  --ip IPv4         本机已配置好的 IPv4；不是“让脚本设置成这个 IP”。
  --config FILE     可选 KEY=value 配置；默认不自动读取任何配置文件。
  --join-file FILE  worker 必填；master 导出的 JSON 数据文件，不是 shell 脚本。
  --output FILE     master / join-info 导出位置；默认 ./k8s-worker-join.json。
  --role ROLE       仅 plan 使用：master（默认）或 worker。
  --help            显示说明；无参数也只显示说明。

输出样式：模块以分隔栏显示；check 分为 6 个编号模块，并标注各检查项。
终端自动启用彩色标题；保存到日志时使用纯文本。NO_COLOR=1 可手动关闭颜色。

示例（各自在对应虚拟机执行）：
  sudo bash k8s-setup.sh master --name master --ip 192.168.194.141 --config ./k8s-setup.conf
  sudo bash k8s-setup.sh worker --name node1 --ip 192.168.194.142 --join-file ./k8s-worker-join.json
  sudo bash k8s-setup.sh worker --name node2 --ip 192.168.194.143 --join-file ./k8s-worker-join.json
  sudo bash k8s-setup.sh join-info --output ./k8s-worker-join.json
  sudo bash k8s-setup.sh check

前置条件：独立的主机名/MAC/虚拟机 UUID、持久固定 IP、节点互通、可用的 RHEL
BaseOS/AppStream 源，以及 RPM/容器镜像下载通道。RHEL 订阅或安装光盘须自行准备。
只支持一个 master；不自动部署高可用、负载均衡、Cilium、离线镜像仓库。
worker 不运行 kubeadm init 或 kubectl apply Flannel。
join-info/cni 允许同一小版本内的补丁差异（如控制平面 1.37.0、组件 1.37.1）。
加入文件分别保存控制平面版本和 worker 组件版本；master/worker 都请使用新版脚本。
已有集群缺少 podSubnet、Flannel 网段错配时会停止，需先诊断，不能靠加 node 修复。
HELP
}

parse_args() {
    STAGE=${1:-help}
    [[ $# == 0 ]] || shift
    case "$STAGE" in help|-h|--help) STAGE=help; return;; esac
    case "$STAGE" in master|worker|prepare|cni|join-info|check|plan) ;; *) die "未知命令：$STAGE";; esac
    while (( $# )); do
        [[ "$1" != --help ]] || { STAGE=help; return; }
        [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "选项 $1 缺少值。"
        case "$1" in
            --name) CLI_NAME=$2;; --ip) CLI_IP=$2;; --config) CONFIG_FILE=$2;;
            --join-file) JOIN_FILE=$2;; --output) OUTPUT_FILE=$2;; --role) PLAN_ROLE=$2;;
            *) die "未知选项：$1";;
        esac
        shift 2
    done
}

config_key_allowed() {
    case "$1" in
        K8S_VERSION|CONTAINERD_VERSION|MIRROR|IMAGE_REPOSITORY|K8S_BASEURL|K8S_GPGKEY|CONTAINERD_BASEURL|CONTAINERD_GPGKEY|BASEOS_URL|APPSTREAM_URL|RHEL_GPGKEY|OS_REPO_IDS|POD_CIDR|SERVICE_CIDR|KUBE_PROXY_MODE|FIREWALL_MODE|FLANNEL_VERSION|FLANNEL_SHA256|FLANNEL_URL|FLANNEL_IMAGE_PREFIX|WAIT_SECONDS|JOIN_TTL_HOURS) return 0;;
        *) return 1;;
    esac
}
read_config() {
    local line key value number=0
    [[ -n "$CONFIG_FILE" ]] || return 0
    [[ -f "$CONFIG_FILE" && -r "$CONFIG_FILE" ]] || die "无法读取配置：$CONFIG_FILE"
    # 按数据读取，不 source / eval。文件中不需要引号，不支持行末注释或 shell 展开。
    while IFS= read -r line || [[ -n "$line" ]]; do
        number=$((number + 1)); line=${line%$'\r'}
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" =~ ^([A-Z_][A-Z_0-9]*)=(.*)$ ]] || die "配置第 $number 行不是 KEY=value。"
        key=${BASH_REMATCH[1]}; value=${BASH_REMATCH[2]}
        config_key_allowed "$key" || die "配置中不支持：$key"
        [[ ! "$value" =~ [[:space:]] ]] || die "$key 的值不能带空格、引号或行末注释。"
        printf -v "$key" '%s' "$value"
    done < "$CONFIG_FILE"
}

need_python() {
    [[ -z "$PYTHON" ]] || return 0
    if command -v python3 >/dev/null; then PYTHON=python3
    elif [[ -x /usr/libexec/platform-python ]]; then PYTHON=/usr/libexec/platform-python
    else die "缺少 Python 3。请先用可用的 RHEL 源安装 python3，再运行脚本。"; fi
}

read_join_file() {
    [[ -f "$JOIN_FILE" && -r "$JOIN_FILE" ]] || die "worker 必须提供可读的 --join-file。"
    need_python
    local data key value
    # 严格限定 JSON 字段。禁止代码执行，且不把 token 打到终端；以原始 CA 公钥 hash 验证集群。
    data=$("$PYTHON" - "$JOIN_FILE" <<'PY'
import datetime, json, re, sys
try:
    raw = open(sys.argv[1], 'rb').read(32769)
    if len(raw) > 32768: raise ValueError('加入文件过大')
    obj = json.loads(raw.decode('utf-8-sig'))
    fields = ['masterName', 'masterIP', 'kubernetesVersion', 'containerdVersion',
              'imageRepository', 'podCIDR', 'serviceCIDR', 'proxyMode', 'token', 'caHash', 'expiresAt']
    if type(obj) is not dict or type(obj.get('schemaVersion')) is not int or obj['schemaVersion'] not in (1, 2):
        raise ValueError('不是本脚本 schemaVersion=1/2 的加入文件；请更新脚本或重新导出')
    # v1 中服务端/组件共用一个版本；v2 分开保存，同时兼容读取旧文件。
    extra = ['kubernetesPackageVersion'] if obj['schemaVersion'] == 2 else []
    if set(obj) != set(fields + extra + ['schemaVersion']): raise ValueError('加入文件字段不完整或含未知字段')
    for key in fields + extra:
        if type(obj[key]) is not str or not obj[key] or re.search(r'[\x00-\x20\x7f]', obj[key]):
            raise ValueError('字段格式错误：' + key)
    if not re.fullmatch(r'[a-z0-9]{6}\.[a-z0-9]{16}', obj['token']): raise ValueError('token 格式错误')
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', obj['caHash']): raise ValueError('CA hash 格式错误')
    expiry = datetime.datetime.strptime(obj['expiresAt'], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
    if expiry <= datetime.datetime.now(datetime.timezone.utc):
        raise ValueError('加入文件已过期；在 master 重新运行 join-info。请同时核对系统时间')
    variables = ['MASTER_NAME', 'MASTER_IP', 'CONTROL_PLANE_VERSION', 'CONTAINERD_VERSION',
                 'IMAGE_REPOSITORY', 'POD_CIDR', 'SERVICE_CIDR', 'KUBE_PROXY_MODE',
                 'JOIN_TOKEN', 'CA_HASH', 'JOIN_EXPIRES']
    for name, key in zip(variables, fields): print(name + '=' + obj[key])
    print('K8S_VERSION=' + obj.get('kubernetesPackageVersion', obj['kubernetesVersion']))
except (OSError, ValueError, TypeError) as e:
    sys.exit(str(e))
PY
    ) || die "加入文件校验失败。"
    while IFS='=' read -r key value; do printf -v "$key" '%s' "${value%$'\r'}"; done <<< "$data"
}

validate_settings() {
    local url
    [[ "$K8S_VERSION" =~ ^1\.(3[1-7])\.[0-9]+$ ]] || die "本版适配 Kubernetes 1.31—1.37，请填完整补丁版本，不带 v。"
    if [[ -n "$CONTROL_PLANE_VERSION" ]]; then
        [[ "$CONTROL_PLANE_VERSION" =~ ^1\.(3[1-7])\.[0-9]+$ ]] || die "无法识别控制平面版本：$CONTROL_PLANE_VERSION。"
        [[ "${K8S_VERSION%.*}" == "${CONTROL_PLANE_VERSION%.*}" ]] || die "控制平面 $CONTROL_PLANE_VERSION 与组件 $K8S_VERSION 不在同一小版本；本脚本只自动处理补丁差异，不执行升级或降级。"
    fi
    [[ "$CONTAINERD_VERSION" =~ ^2\.[0-9]+\.[0-9]+$ ]] || die "本版使用 containerd 2.x，请填完整版本。"
    [[ "$MIRROR" == aliyun || "$MIRROR" == official ]] || die "MIRROR 只能是 aliyun 或 official。"
    [[ "$FIREWALL_MODE" == disable || "$FIREWALL_MODE" == keep ]] || die "FIREWALL_MODE 只能是 disable 或 keep。"
    [[ "$KUBE_PROXY_MODE" == iptables || "$KUBE_PROXY_MODE" == ipvs ]] || die "KUBE_PROXY_MODE 只能是 iptables 或 ipvs。"
    [[ "$WAIT_SECONDS" =~ ^[1-9][0-9]{1,3}$ && "$WAIT_SECONDS" -ge 30 && "$WAIT_SECONDS" -le 3600 ]] || die "WAIT_SECONDS 范围为 30—3600。"
    [[ "$JOIN_TTL_HOURS" =~ ^[1-9][0-9]{0,2}$ && "$JOIN_TTL_HOURS" -le 168 ]] || die "JOIN_TTL_HOURS 范围为 1—168。"
    [[ "$FLANNEL_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && "$FLANNEL_SHA256" =~ ^[a-fA-F0-9]{64}$ ]] || die "Flannel 版本或 SHA256 格式错误。"
    [[ "$IMAGE_REPOSITORY" =~ ^[a-zA-Z0-9][a-zA-Z0-9._:/-]*$ && "$IMAGE_REPOSITORY" != *://* ]] || die "IMAGE_REPOSITORY 是镜像仓库前缀，不带 https://。"
    [[ -z "$FLANNEL_IMAGE_PREFIX" || "$FLANNEL_IMAGE_PREFIX" =~ ^[a-zA-Z0-9][a-zA-Z0-9._:/-]*$ && "$FLANNEL_IMAGE_PREFIX" != *://* ]] || die "FLANNEL_IMAGE_PREFIX 应为镜像仓库目录，不带 https://。"
    for url in "$K8S_BASEURL" "$K8S_GPGKEY" "$CONTAINERD_BASEURL" "$CONTAINERD_GPGKEY" "$BASEOS_URL" "$APPSTREAM_URL" "$RHEL_GPGKEY" "$FLANNEL_URL"; do
        [[ -z "$url" || "$url" =~ ^(https?://|file:///)[a-zA-Z0-9._~:/%+@=-]+$ ]] || die "下载地址必须是无空格的 http(s):// 或 file:/// URL。"
    done
    [[ -z "$OS_REPO_IDS" || "$OS_REPO_IDS" =~ ^[a-zA-Z0-9_.:,-]+$ ]] || die "OS_REPO_IDS 使用逗号分隔现有的 repo ID。"
    [[ -z "$BASEOS_URL" && -z "$APPSTREAM_URL" || -n "$BASEOS_URL" && -n "$APPSTREAM_URL" ]] || die "BASEOS_URL 和 APPSTREAM_URL 必须同时填写。"
    [[ -z "$BASEOS_URL" || -z "$OS_REPO_IDS" ]] || die "自定义 BaseOS/AppStream URL 与 OS_REPO_IDS 二选一。"
    [[ "$PLAN_ROLE" == master || "$PLAN_ROLE" == worker ]] || die "--role 只能为 master 或 worker。"
}

validate_identity() {
    need_python
    "$PYTHON" - "$NODE_NAME" "$NODE_IP" "$MASTER_NAME" "$MASTER_IP" "$POD_CIDR" "$SERVICE_CIDR" <<'PY'
import ipaddress as ip, re, sys
name, address, master, master_ip, pod, service = sys.argv[1:]
def valid_name(n):
    return len(n) <= 63 and bool(re.fullmatch(r'[a-z0-9](?:[a-z0-9-]*[a-z0-9])?', n)) and n != 'localhost'
try:
    if not valid_name(name): raise ValueError('请用 --name 指定合法节点名：小写字母/数字/连字符，最多 63 位')
    for value in [address] + ([master_ip] if master_ip else []):
        a = ip.IPv4Address(value)
        if a.is_loopback or a.is_multicast or a.is_unspecified or a.is_link_local:
            raise ValueError('需要可供节点互通的 IPv4 地址')
    if master and not valid_name(master): raise ValueError('加入文件 masterName 无效')
    p, s = ip.IPv4Network(pod), ip.IPv4Network(service)
    if not 8 <= p.prefixlen <= 24: raise ValueError('Pod 网段前缀必须在 /8—/24，默认给每节点分配 /24')
    if not 12 <= s.prefixlen <= 28: raise ValueError('Service 网段前缀必须在 /12—/28')
    if p.overlaps(s): raise ValueError('Pod CIDR 与 Service CIDR 不能重叠')
    for a in [address] + ([master_ip] if master_ip else []):
        if ip.ip_address(a) in p or ip.ip_address(a) in s: raise ValueError('节点 IP 不能位于 Pod/Service 网段内')
except ValueError as e: sys.exit(str(e))
PY
}

require_host() {
    [[ $EUID == 0 ]] || die "请用 sudo bash 或 root 执行安装命令。"
    [[ "$(uname -s)" == Linux && -r /etc/os-release ]] || die "安装必须在 Linux 虚拟机内部执行。"
    # /etc/os-release 是受 root 管理的系统文件；用户配置和加入文件不会 source。
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == rhel ]] || die "本版仅适配 RHEL，检测到 ${ID:-unknown}。"
    RHEL_MAJOR=${VERSION_ID%%.*}
    [[ "$RHEL_MAJOR" == 9 ]] || die "本版适配 RHEL 9；RHEL 8 的 cgroup 和 RHEL 10 的网络包需要单独适配，不直接套用。"
    HOST_ARCH=$(uname -m)
    [[ "$HOST_ARCH" == x86_64 || "$HOST_ARCH" == aarch64 ]] || die "本版支持 x86_64/aarch64。"
    [[ -d /run/systemd/system && -r /sys/fs/cgroup/cgroup.controllers ]] || die "需要 systemd 和 cgroup v2。"
    local tool
    for tool in dnf rpm ip findmnt awk flock systemctl; do command -v "$tool" >/dev/null || die "缺少系统工具：$tool"; done
    need_python
}

assert_root_mount() {
    [[ ",$(findmnt -n -o OPTIONS --target /)," == *,rw,* ]] || die "根分区不是 rw。请先修复只读挂载；脚本不强制 remount。"
    awk '!/^[[:space:]]*#/ && $2 == "/" { found=1 } END {exit !found}' /etc/fstab || die "fstab 缺少有效的根分区 / 记录，请检查是否被误注释。"
}

assert_local_network() {
    local data
    data=$(ip -j -4 address show | "$PYTHON" -c '
import ipaddress as ip, json, sys
target, pod, service = sys.argv[1:]
p, s = ip.ip_network(pod), ip.ip_network(service)
found = []
for dev in json.load(sys.stdin):
    for a in dev.get("addr_info", []):
        if a.get("family") != "inet": continue
        address = ip.ip_address(a["local"])
        net = ip.ip_network(a["local"] + "/" + str(a["prefixlen"]), strict=False)
        # 已有 CNI 虚拟网卡可位于 Pod 网段；物理/管理网络不能与 Pod/Service 冲突。
        if dev["ifname"].startswith(("cni", "flannel", "veth", "cali", "cilium", "lxc", "kube-ipvs0")): continue
        if not address.is_loopback and (p.overlaps(net) or s.overlaps(net)):
            sys.exit("宿主网络与 Pod/Service 网段重叠：" + str(net))
        if str(address) == target:
            if "UP" not in dev.get("flags", []): sys.exit("目标网卡未 UP")
            found.append((dev["ifname"], str(net)))
if len(found) != 1: sys.exit("--ip 必须是本机唯一的现有 IPv4 地址；请先在虚拟机控制台配置网络")
print(*found[0])
' "$NODE_IP" "$POD_CIDR" "$SERVICE_CIDR") || die "网卡/网段检查失败。"
    read -r NODE_NIC NODE_NETWORK <<< "$data"
    log "本机网络：$NODE_NIC / $NODE_IP（$NODE_NETWORK）；只核对，不修改网卡。"
    [[ "$(awk '/MemTotal/ {print $2}' /proc/meminfo)" -ge 1700000 ]] || die "至少为虚拟机分配 2 GiB 内存。"
    if [[ "$STAGE" == master ]]; then [[ "$(nproc)" -ge 2 ]] || die "master 至少需要 2 个 vCPU。"; fi
}

assert_fresh_node() {
    local path
    for path in /etc/kubernetes/admin.conf /etc/kubernetes/kubelet.conf /etc/kubernetes/bootstrap-kubelet.conf /var/lib/kubelet/config.yaml /var/lib/etcd/member; do
        [[ ! -e "$path" ]] || die "检测到已有集群数据 $path；不能作为空白节点安装，不会自动 reset。"
    done
    for path in /etc/kubernetes/manifests /etc/cni/net.d; do
        [[ ! -d "$path" || -z "$(find "$path" -mindepth 1 -maxdepth 1 -print -quit)" ]] || die "$path 非空；请使用 init 之前的模板或先诊断残留配置。"
    done
}

check_package_versions() {
    # 新安装/worker 仍然按目标 RPM 完整版本核对，避免 DNF 暗中升级或降级。
    local pkg actual wanted
    for pkg in kubeadm kubelet kubectl containerd.io; do
        if actual=$(rpm -q --qf '%{VERSION}' "$pkg" 2>/dev/null); then
            wanted=$K8S_VERSION; [[ "$pkg" != containerd.io ]] || wanted=$CONTAINERD_VERSION
            [[ "$actual" == "$wanted" ]] || die "$pkg 已安装 $actual，要求 $wanted；脚本不自动升级或降级。"
        fi
    done
}

check_existing_master_package_versions() {
    # 已有 master 不安装 RPM：兼容同一 major.minor 的补丁差异，不复用安装前的严格锁版检查。
    # 与 kubeadm 的版本预检一致，本脚本在此进一步限定所有组件与控制平面处于同一小版本。
    local pkg actual
    section "版本核对 | 控制平面与本机组件"
    printf '控制平面：%s\n' "$CONTROL_PLANE_VERSION"
    for pkg in kubeadm kubelet kubectl; do
        actual=$(rpm -q --qf '%{VERSION}' "$pkg" 2>/dev/null) || die "已有 master 缺少 $pkg；请先检查本机安装。"
        [[ "$actual" =~ ^1\.(3[1-7])\.[0-9]+$ && "${actual%.*}" == "${CONTROL_PLANE_VERSION%.*}" ]] || die "$pkg 已安装 $actual，控制平面为 $CONTROL_PLANE_VERSION；本脚本只自动处理同一小版本内的补丁差异。"
        printf '%s：%s\n' "$pkg" "$actual"
    done
    log "worker 组件安装版本：$K8S_VERSION（沿用本机 kubeadm）；containerd：$CONTAINERD_VERSION。"
}

begin_changes() {
    [[ -z "$WORK_DIR" ]] || return 0
    umask 077
    exec 200>/run/k8s-setup.lock
    flock -n 200 || die "已有一个安装器正在本机运行。"
    WORK_DIR=$(mktemp -d /tmp/k8s-setup.XXXXXXXX)
    BACKUP_DIR="/var/backups/k8s-setup-$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -p "$BACKUP_DIR"
    log "配置备份目录：$BACKUP_DIR"
}
backup_file() {
    local path=$1
    if [[ -e "$path" && ! -e "$BACKUP_DIR$path" ]]; then
        mkdir -p "$(dirname "$BACKUP_DIR$path")"
        cp -a -- "$path" "$BACKUP_DIR$path"
    elif [[ ! -e "$path" ]]; then printf '%s\n' "$path" >> "$BACKUP_DIR/new-files.txt"; fi
}
install_config() {
    local src=$1 dst=$2 mode=${3:-0644}
    backup_file "$dst"
    mkdir -p "$(dirname "$dst")"
    install -m "$mode" "$src" "$dst"
    if command -v restorecon >/dev/null; then restorecon "$dst"; fi
}

render_fstab() {
    # 按第三列“文件系统类型”为 swap 定位；不会误注释 /、/boot 或 /boot/efi。
    awk '!/^[[:space:]]*#/ && $3 == "swap" { print "# k8s-setup: " $0; next } { print }' "$1" > "$2"
}
render_hosts() {
    "$PYTHON" - "$1" "$2" "$NODE_NAME" "$NODE_IP" "$MASTER_NAME" "$MASTER_IP" <<'PY'
import sys
src, dst, node, addr, master, master_ip = sys.argv[1:]
mapping = {node: addr}
if master: mapping[master] = master_ip
out = []
for line in open(src, encoding='utf-8'):
    body, marker, comment = line.partition('#')
    fields = body.split()
    if len(fields) > 1 and set(fields[1:]) & set(mapping):
        aliases = [n for n in fields[1:] if n not in mapping]
        if aliases: out.append(fields[0] + ' ' + ' '.join(aliases) + (' #' + comment.rstrip('\n') if marker else '') + '\n')
        elif marker: out.append('#' + comment.rstrip('\n') + '\n')
    else: out.append(line if line.endswith('\n') else line + '\n')
for name, ip in mapping.items(): out.append(ip + ' ' + name + '\n')
open(dst, 'w', encoding='utf-8', newline='\n').writelines(out)
PY
}

render_containerd() {
    # 从“本机已安装版本”的 config default 生成，不依赖笔记里的行号或 pause 版本。
    # containerd 1.x 的 sandbox_image 与 2.x 的 pinned_images.sandbox 都可识别。
    awk -v pause="$3" '
      /^[[:space:]]*SystemdCgroup[[:space:]]*=/ {sub(/=.*/, "= true"); cgroup++}
      /^[[:space:]]*(sandbox_image|sandbox)[[:space:]]*=/ {sub(/=.*/, "= \"" pause "\""); image++}
      {print}
      END {if(cgroup != 1 || image != 1) {print "不认识 containerd 配置布局，停止替换" > "/dev/stderr"; exit 42}}
    ' "$1" > "$2"
}

resolve_urls() {
    local k8s_minor="v${K8S_VERSION%.*}" repo_root
    if [[ "$MIRROR" == aliyun ]]; then
        K8S_BASEURL=${K8S_BASEURL:-https://mirrors.aliyun.com/kubernetes-new/core/stable/$k8s_minor/rpm/}
        repo_root=https://mirrors.aliyun.com/docker-ce/linux/rhel
    else
        K8S_BASEURL=${K8S_BASEURL:-https://pkgs.k8s.io/core:/stable:/$k8s_minor/rpm/}
        repo_root=https://download.docker.com/linux/rhel
    fi
    K8S_GPGKEY=${K8S_GPGKEY:-${K8S_BASEURL%/}/repodata/repomd.xml.key}
    CONTAINERD_BASEURL=${CONTAINERD_BASEURL:-$repo_root/$RHEL_MAJOR/$HOST_ARCH/stable}
    CONTAINERD_GPGKEY=${CONTAINERD_GPGKEY:-$repo_root/gpg}
    FLANNEL_URL=${FLANNEL_URL:-https://github.com/flannel-io/flannel/releases/download/$FLANNEL_VERSION/kube-flannel.yml}
}

configure_repositories() {
    resolve_urls
    # 使用专用 repo ID 和文件；不移走用户已有源，不添加 CentOS 7 源。
    cat > "$WORK_DIR/repos" <<REPOS
[k8s-setup-kubernetes]
name=Kubernetes $K8S_VERSION managed by k8s-setup
baseurl=$K8S_BASEURL
enabled=0
gpgcheck=1
gpgkey=$K8S_GPGKEY
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni

[k8s-setup-containerd]
name=containerd for RHEL $RHEL_MAJOR $HOST_ARCH
baseurl=$CONTAINERD_BASEURL
enabled=0
gpgcheck=1
gpgkey=$CONTAINERD_GPGKEY
REPOS
    DNF_OS_ARGS=()
    if [[ -n "$BASEOS_URL" ]]; then
        cat >> "$WORK_DIR/repos" <<REPOS

[k8s-setup-baseos]
name=User supplied RHEL BaseOS
baseurl=$BASEOS_URL
enabled=0
gpgcheck=1
gpgkey=$RHEL_GPGKEY

[k8s-setup-appstream]
name=User supplied RHEL AppStream
baseurl=$APPSTREAM_URL
enabled=0
gpgcheck=1
gpgkey=$RHEL_GPGKEY
REPOS
        DNF_OS_ARGS=(--disablerepo='*' '--enablerepo=k8s-setup-baseos,k8s-setup-appstream' --disableplugin=subscription-manager)
    elif [[ -n "$OS_REPO_IDS" ]]; then
        DNF_OS_ARGS=(--disablerepo='*' "--enablerepo=$OS_REPO_IDS")
    fi
    install_config "$WORK_DIR/repos" /etc/yum.repos.d/k8s-setup.repo
}
dnf_os() { dnf --setopt=timeout=30 --setopt=retries=2 "${DNF_OS_ARGS[@]}" "$@"; }

prepare_node() {
    assert_fresh_node
    check_package_versions
    begin_changes
    section "准备环境 [1/5] | 软件源与组件安装"
    log "配置专用软件源并安装固定版本；软件包缺失或依赖冲突时停止。"
    configure_repositories
    # BaseOS/AppStream 不可用时，这一步会明确失败，不尝试替换成其他发行版。
    dnf_os -y install curl ca-certificates python3 openssl chrony conntrack-tools iproute \
        socat ethtool iptables bash-completion libseccomp
    dnf_os -y --enablerepo=k8s-setup-kubernetes,k8s-setup-containerd \
        --disableexcludes=k8s-setup-kubernetes install \
        "containerd.io-$CONTAINERD_VERSION" "kubeadm-$K8S_VERSION" \
        "kubelet-$K8S_VERSION" "kubectl-$K8S_VERSION" cri-tools kubernetes-cni
    if [[ "$KUBE_PROXY_MODE" == ipvs ]]; then dnf_os -y install ipvsadm ipset; fi
    check_package_versions

    section "准备环境 [2/5] | 节点身份、Swap 与 SELinux"
    backup_file /etc/hostname
    hostnamectl set-hostname "$NODE_NAME"
    render_hosts /etc/hosts "$WORK_DIR/hosts"
    install_config "$WORK_DIR/hosts" /etc/hosts
    render_fstab /etc/fstab "$WORK_DIR/fstab"
    findmnt --verify --verbose --tab-file "$WORK_DIR/fstab"
    install_config "$WORK_DIR/fstab" /etc/fstab
    systemctl daemon-reload
    swapoff -a
    [[ -z "$(swapon --noheadings --show)" ]] || die "Swap 仍在使用。"
    [[ -f /etc/selinux/config ]] || die "缺少 /etc/selinux/config。"
    awk 'BEGIN{done=0} /^SELINUX=/{print "SELINUX=permissive"; done=1; next} {print} END{if(!done)print "SELINUX=permissive"}' \
        /etc/selinux/config > "$WORK_DIR/selinux"
    install_config "$WORK_DIR/selinux" /etc/selinux/config
    if [[ "$(getenforce)" == Enforcing ]]; then setenforce 0; fi
    if [[ "$FIREWALL_MODE" == disable ]]; then
        if systemctl cat firewalld.service >/dev/null 2>&1; then
            systemctl is-enabled firewalld > "$BACKUP_DIR/firewalld-enabled.txt" 2>&1 || true
            systemctl is-active firewalld > "$BACKUP_DIR/firewalld-active.txt" 2>&1 || true
            systemctl disable --now firewalld
        fi
    else log "保留 firewalld；节点间 6443/TCP、10250/TCP、8472/UDP 等通信由你的现有策略保证。"; fi

    section "准备环境 [3/5] | 内核模块与网络参数"
    printf 'overlay\nbr_netfilter\nnf_conntrack\n' > "$WORK_DIR/modules"
    if [[ "$KUBE_PROXY_MODE" == ipvs ]]; then printf 'ip_vs\nip_vs_rr\nip_vs_wrr\nip_vs_sh\n' >> "$WORK_DIR/modules"; fi
    install_config "$WORK_DIR/modules" /etc/modules-load.d/k8s-setup.conf
    local module
    while IFS= read -r module; do modprobe "$module"; done < "$WORK_DIR/modules"
    cat > "$WORK_DIR/sysctl" <<'SYSCTL'
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
SYSCTL
    install_config "$WORK_DIR/sysctl" /etc/sysctl.d/99-zz-k8s-setup.conf
    # 写文件不等于修改当前内核值，必须显式加载。
    sysctl -p /etc/sysctl.d/99-zz-k8s-setup.conf

    section "准备环境 [4/5] | containerd 与 pause 镜像"
    local pause_image
    pause_image=$(kubeadm config images list --kubernetes-version "v${CONTROL_PLANE_VERSION:-$K8S_VERSION}" --image-repository "$IMAGE_REPOSITORY" | awk '/\/pause:/{print}')
    [[ "$pause_image" =~ ^[a-zA-Z0-9._:/-]+/pause:[a-zA-Z0-9._-]+$ ]] || die "无法从 kubeadm 确定 pause 镜像。"
    containerd config default > "$WORK_DIR/containerd-default.toml"
    render_containerd "$WORK_DIR/containerd-default.toml" "$WORK_DIR/containerd.toml" "$pause_image"
    containerd --config "$WORK_DIR/containerd.toml" config dump >/dev/null
    install_config "$WORK_DIR/containerd.toml" /etc/containerd/config.toml
    cat > "$WORK_DIR/crictl" <<CRICTL
runtime-endpoint: $CRI_SOCKET
image-endpoint: $CRI_SOCKET
timeout: 20
debug: false
CRICTL
    install_config "$WORK_DIR/crictl" /etc/crictl.yaml
    systemctl enable containerd
    systemctl restart containerd
    local ready=0 attempt
    for ((attempt=1; attempt<=15; attempt++)); do
        if crictl info 2>/dev/null | "$PYTHON" -c 'import json,sys; d=json.load(sys.stdin); sys.exit(not any(c["type"]=="RuntimeReady" and c["status"] is True for c in d.get("status",{}).get("conditions",[])))' 2>/dev/null; then ready=1; break; fi
        sleep 2
    done
    [[ "$ready" == 1 ]] || die "containerd CRI 没有就绪。检查 journalctl -u containerd。"
    # 预拉取能在 init/join 前暴露镜像网络问题；不关闭证书验证，不用 curl | sh。
    crictl pull "$pause_image"

    section "准备环境 [5/5] | 时间同步、kubelet 与命令补全"
    systemctl enable --now chronyd
    systemctl enable --now kubelet
    kubectl completion bash > "$WORK_DIR/kubectl-completion"
    install_config "$WORK_DIR/kubectl-completion" /etc/bash_completion.d/kubectl
    log "基础环境完成。init/join 之前 kubelet 缺少配置而短暂重启是正常阶段现象。"
    timedatectl show --property=NTPSynchronized
}

render_init_config() {
    cat > "$1" <<YAML
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "$NODE_IP"
  bindPort: 6443
nodeRegistration:
  name: "$NODE_NAME"
  criSocket: "$CRI_SOCKET"
  kubeletExtraArgs:
  - name: node-ip
    value: "$NODE_IP"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: "v$K8S_VERSION"
imageRepository: "$IMAGE_REPOSITORY"
controlPlaneEndpoint: "$NODE_IP:6443"
networking:
  dnsDomain: cluster.local
  podSubnet: "$POD_CIDR"
  serviceSubnet: "$SERVICE_CIDR"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
failSwapOn: true
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: "$KUBE_PROXY_MODE"
YAML
}

kctl() { kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout="${WAIT_SECONDS}s" "$@"; }

init_master() {
    section "控制平面 | kubeadm init"
    log "初始化新控制平面（默认保留控制平面污点，不把 master 当普通 worker）"
    render_init_config "$WORK_DIR/init.yaml"
    kubeadm config validate --config "$WORK_DIR/init.yaml"
    install_config "$WORK_DIR/init.yaml" /etc/kubernetes/k8s-setup-init.yaml 0600
    kubeadm config images pull --config "$WORK_DIR/init.yaml"
    kubeadm init --config "$WORK_DIR/init.yaml"
    # 仅配置 root 自己的 kubectl，worker 不复制 admin.conf。
    install_config /etc/kubernetes/admin.conf /root/.kube/config 0600
    kctl wait --for=jsonpath='{.spec.podCIDR}' "node/$NODE_NAME" --timeout="${WAIT_SECONDS}s"
}

cluster_scalar() {
    # kubeadm 自动生成的 ConfigMap YAML 使用简单标量；字段缺失/重复则拒绝猜测。
    awk -v key="$1:" '$1 == key {gsub(/["\047]/, "", $2); print $2; n++} END{if(n!=1)exit 1}' "$2"
}

read_live_cluster() {
    [[ -r /etc/kubernetes/admin.conf && -s /etc/kubernetes/manifests/kube-apiserver.yaml ]] || die "此命令必须在现有 kubeadm master 上运行。"
    command -v kubectl >/dev/null || die "缺少 kubectl。"
    kctl get --raw=/readyz >/dev/null
    kctl -n kube-system get cm kubeadm-config -o 'jsonpath={.data.ClusterConfiguration}' > "$WORK_DIR/live-cluster.yaml"
    LIVE_VERSION=$(cluster_scalar kubernetesVersion "$WORK_DIR/live-cluster.yaml") || die "无法读取集群版本。"
    LIVE_VERSION=${LIVE_VERSION#v}
    # ConfigMap 记录初始化/升级目标；再与实际 API Server 核对，避免把过期配置导出给 worker。
    local server_version
    server_version=$(kctl get --raw=/version | "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin)["gitVersion"].removeprefix("v"))') || die "无法读取 API Server 实际版本。"
    [[ "$server_version" == "$LIVE_VERSION" ]] || die "API Server 为 $server_version，kubeadm-config 为 $LIVE_VERSION；请先核对集群升级状态。"
    CONTROL_PLANE_VERSION=$LIVE_VERSION
    LIVE_POD=$(cluster_scalar podSubnet "$WORK_DIR/live-cluster.yaml") || die "集群缺少 podSubnet；这会导致 Flannel/CoreDNS 不就绪。请先诊断原集群，脚本不会重建它。"
    LIVE_SERVICE=$(cluster_scalar serviceSubnet "$WORK_DIR/live-cluster.yaml") || die "无法读取 Service 网段。"
    LIVE_IMAGE_REPOSITORY=$(cluster_scalar imageRepository "$WORK_DIR/live-cluster.yaml") || die "无法读取镜像仓库。"
    kctl -n kube-system get cm kube-proxy -o 'jsonpath={.data.config\.conf}' > "$WORK_DIR/live-proxy.yaml"
    LIVE_PROXY_MODE=$(cluster_scalar mode "$WORK_DIR/live-proxy.yaml") || die "无法读取 kube-proxy mode。"
    LIVE_PROXY_MODE=${LIVE_PROXY_MODE:-iptables}
    MASTER_NAME=$(hostname)
    MASTER_IP=$(kctl get node "$MASTER_NAME" -o 'jsonpath={.status.addresses[?(@.type=="InternalIP")].address}')
    [[ -n "$MASTER_IP" && "$MASTER_IP" != *' '* ]] || die "本版只处理 IPv4 单栈节点。"
    # 不向一个已有的多控制平面集群输出“单 master”加入参数。
    local control_count
    control_count=$(kctl get nodes -l node-role.kubernetes.io/control-plane -o name | wc -l)
    [[ "$control_count" == 1 ]] || die "检测到多个控制平面，本脚本只处理单控制平面拓扑。"
}

adopt_live_settings() {
    NODE_NAME=$MASTER_NAME; NODE_IP=$MASTER_IP
    CONTROL_PLANE_VERSION=$LIVE_VERSION
    # worker 跟随现有 kubeadm 的组件版本，不要求已安装的 1.37.1 降到服务端的 1.37.0。
    K8S_VERSION=$(rpm -q --qf '%{VERSION}' kubeadm 2>/dev/null) || die "已有 master 缺少 kubeadm，无法确定 worker 组件版本。"
    POD_CIDR=$LIVE_POD; SERVICE_CIDR=$LIVE_SERVICE
    IMAGE_REPOSITORY=$LIVE_IMAGE_REPOSITORY; KUBE_PROXY_MODE=$LIVE_PROXY_MODE
    CONTAINERD_VERSION=$(rpm -q --qf '%{VERSION}' containerd.io 2>/dev/null) || die "已有 master 缺少 containerd.io RPM。"
    validate_settings
    validate_identity
    assert_local_network
    check_existing_master_package_versions
}

assert_matching_master() {
    [[ "$NODE_NAME" == "$MASTER_NAME" && "$NODE_IP" == "$MASTER_IP" ]] || die "已有 master 的主机名/IP 与传入参数不符。"
    [[ "$K8S_VERSION" == "$LIVE_VERSION" && "$POD_CIDR" == "$LIVE_POD" && "$SERVICE_CIDR" == "$LIVE_SERVICE" && "$IMAGE_REPOSITORY" == "$LIVE_IMAGE_REPOSITORY" && "$KUBE_PROXY_MODE" == "$LIVE_PROXY_MODE" ]] || die "现有集群参数与配置不符。请先 check；已有 master 可用 cni/join-info 自动读取真实参数。本命令不会修改现有集群网段或版本。"
    check_package_versions
}

assert_flannel_compatible() {
    kctl get nodes -o json > "$WORK_DIR/nodes.json"
    "$PYTHON" - "$WORK_DIR/nodes.json" "$POD_CIDR" "$SERVICE_CIDR" <<'PY'
import ipaddress as ip, json, sys
p, s = ip.ip_network(sys.argv[2]), ip.ip_network(sys.argv[3])
if p.overlaps(s): sys.exit('现有集群 Pod/Service CIDR 重叠，停止部署 Flannel')
for n in json.load(open(sys.argv[1]))['items']:
    cidr = n.get('spec', {}).get('podCIDR')
    if not cidr: sys.exit(n['metadata']['name'] + ' 没有分配 Pod CIDR，请先诊断 controller-manager 配置')
    if not ip.ip_network(cidr).subnet_of(p): sys.exit('节点 Pod CIDR 不在集群 podSubnet 内')
PY
    kctl get daemonsets -A -o json > "$WORK_DIR/daemonsets.json"
    "$PYTHON" - "$WORK_DIR/daemonsets.json" <<'PY'
import json, sys
for d in json.load(open(sys.argv[1]))['items']:
    name = d['metadata']['name'].lower()
    namespace = d['metadata']['namespace']
    if any(x in name for x in ('cilium', 'calico', 'weave', 'kube-router', 'antrea')):
        sys.exit('检测到其他网络插件 ' + name + '；不允许直接叠加 Flannel')
    if 'flannel' in name and (name != 'kube-flannel-ds' or namespace != 'kube-flannel'):
        sys.exit('发现非本脚本布局的 Flannel：' + namespace + '/' + name + '；请先核对，避免重复部署')
PY
    # --ignore-not-found 只允许对象不存在；连接/RBAC 错误仍然失败，不掩盖网络故障。
    local existing
    existing=$(kctl -n kube-flannel get cm kube-flannel-cfg --ignore-not-found -o 'jsonpath={.data.net-conf\.json}')
    if [[ -n "$existing" ]]; then
        "$PYTHON" -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d.get("Network")==sys.argv[2] and d.get("Backend",{}).get("Type")=="vxlan" else "现有 Flannel Network/Backend 不一致，请先诊断；不会自动迁移网段")' "$existing" "$POD_CIDR"
    fi
}

render_flannel() {
    "$PYTHON" - "$1" "$2" "$POD_CIDR" "$FLANNEL_IMAGE_PREFIX" <<'PY'
import json, sys
src, dst, cidr, prefix = sys.argv[1:]
doc = json.load(open(src))
items = doc.get('items', [doc])
matches = [o for o in items if o.get('kind') == 'ConfigMap' and o.get('metadata', {}).get('name') == 'kube-flannel-cfg']
if len(matches) != 1: sys.exit('Flannel 清单结构不符合预期')
net = json.loads(matches[0]['data']['net-conf.json'])
net['Network'] = cidr
matches[0]['data']['net-conf.json'] = json.dumps(net, indent=2)
for o in items:
    if o.get('kind') != 'DaemonSet': continue
    spec = o['spec']['template']['spec']
    if prefix:
        for c in spec.get('initContainers', []) + spec.get('containers', []):
            roots = ['ghcr.io/flannel-io/', 'docker.io/flannel/']
            root = next((r for r in roots if c['image'].startswith(r)), None)
            if not root: sys.exit('Flannel 镜像路径发生变化，请核对清单')
            c['image'] = prefix.rstrip('/') + '/' + c['image'][len(root):]
    # 多网卡时 Flannel 按 Node.status.addresses 中的 InternalIP 找接口；该 IP 在 init/join 中指定。
    for c in spec.get('containers', []):
        if c.get('name') == 'kube-flannel' and '--iface-can-reach=' not in ' '.join(c.get('args', [])):
            c.setdefault('env', []).append({'name':'NODE_IP','valueFrom':{'fieldRef':{'fieldPath':'status.hostIP'}}})
            c.setdefault('args', []).append('--iface=$(NODE_IP)')
with open(dst, 'w') as f: json.dump(doc, f, indent=2)
PY
}

install_flannel() {
    section "集群网络 | Flannel"
    assert_flannel_compatible
    local existing
    existing=$(kctl -n kube-flannel get ds kube-flannel-ds --ignore-not-found -o name)
    if [[ -n "$existing" ]]; then
        log "已有网段匹配的 Flannel；保留其版本与清单，只等待就绪。若需升级请单独规划。"
    else
        log "下载固定版本 Flannel 并校验 SHA256；只在 master 向集群提交一次"
        resolve_urls
        curl --fail --location --connect-timeout 15 --max-time 180 --retry 2 "$FLANNEL_URL" -o "$WORK_DIR/flannel.yaml"
        printf '%s  %s\n' "$FLANNEL_SHA256" "$WORK_DIR/flannel.yaml" | sha256sum -c -
        kctl create --dry-run=client --validate=false -f "$WORK_DIR/flannel.yaml" -o json > "$WORK_DIR/flannel-original.json"
        render_flannel "$WORK_DIR/flannel-original.json" "$WORK_DIR/flannel.json"
        install_config "$WORK_DIR/flannel.json" /etc/kubernetes/k8s-setup-flannel.json 0600
        kctl apply -f "$WORK_DIR/flannel.json"
    fi
}

check_node_identities() {
    kctl get nodes -o json | "$PYTHON" -c '
import json,sys
nodes=json.load(sys.stdin)["items"]
for key in ("systemUUID", "machineID"):
    seen={}
    for n in nodes:
        val=n.get("status",{}).get("nodeInfo",{}).get(key, "").lower()
        if not val: continue
        if val in seen: sys.exit("克隆身份重复："+key+"，节点 "+seen[val]+" / "+n["metadata"]["name"])
        seen[val]=n["metadata"]["name"]
'
}

wait_master_ready() {
    section "就绪检查 | Flannel、CoreDNS 与 master"
    log "等待 Flannel、CoreDNS 与 master Ready（每项最多 $WAIT_SECONDS 秒）"
    kctl -n kube-flannel rollout status ds/kube-flannel-ds --timeout="${WAIT_SECONDS}s"
    kctl -n kube-system rollout status deployment/coredns --timeout="${WAIT_SECONDS}s"
    kctl wait --for=condition=Ready "node/$MASTER_NAME" --timeout="${WAIT_SECONDS}s"
    check_node_identities
}

ca_public_hash() {
    openssl x509 -in "$1" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256 | awk '{print "sha256:" $NF}'
}

export_join_info() {
    section "加入信息 | 导出 worker 加入文件"
    # 文件中只有短期 bootstrap token 和 CA hash，不包含 admin.conf 或私钥。
    # 文件过期只影响后续 join，不会使已经加入的 worker 下线。
    local parent token hash expiry
    parent=$(dirname "$OUTPUT_FILE")
    [[ -d "$parent" && ! -L "$OUTPUT_FILE" && ! -d "$OUTPUT_FILE" ]] || die "--output 父目录必须存在，目标不能为目录或符号链接。"
    log "导出控制平面版本 ${CONTROL_PLANE_VERSION:-$K8S_VERSION}；worker 组件版本 $K8S_VERSION。"
    token=$(kubeadm token create --ttl "${JOIN_TTL_HOURS}h")
    [[ "$token" =~ ^[a-z0-9]{6}\.[a-z0-9]{16}$ ]] || die "未能生成正确的加入 token。"
    hash=$(ca_public_hash /etc/kubernetes/pki/ca.crt)
    expiry=$(date -u -d "+${JOIN_TTL_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)
    # token 经标准输入传递给 Python，不写进子进程参数。
    printf '%s\n' "$token" | "$PYTHON" -c '
import json,sys
out,master,addr,control,k8s,runtime,repo,pod,svc,proxy,ca,expiry=sys.argv[1:]
d=dict(schemaVersion=2,masterName=master,masterIP=addr,kubernetesVersion=control,kubernetesPackageVersion=k8s,
       containerdVersion=runtime,imageRepository=repo,podCIDR=pod,serviceCIDR=svc,
       proxyMode=proxy,token=sys.stdin.read().strip(),caHash=ca,expiresAt=expiry)
with open(out,"w") as f: json.dump(d,f,indent=2); f.write("\n")
' "$WORK_DIR/worker-join.json" "$MASTER_NAME" "$MASTER_IP" "${CONTROL_PLANE_VERSION:-$K8S_VERSION}" "$K8S_VERSION" "$CONTAINERD_VERSION" \
        "$IMAGE_REPOSITORY" "$POD_CIDR" "$SERVICE_CIDR" "$KUBE_PROXY_MODE" "$hash" "$expiry"
    install -m 0600 "$WORK_DIR/worker-join.json" "$OUTPUT_FILE"
    if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then chown "$SUDO_UID:$SUDO_GID" "$OUTPUT_FILE"; fi
    log "加入文件：$(readlink -f "$OUTPUT_FILE")；有效至 $expiry（UTC）。请安全复制到各 worker。"
    log "worker 命令：sudo bash k8s-setup.sh worker --name <节点名> --ip <节点IP> --join-file ./k8s-worker-join.json"
}

assert_master_reachable() {
    "$PYTHON" - "$MASTER_IP" <<'PY'
import socket, sys
try:
    with socket.create_connection((sys.argv[1], 6443), timeout=8): pass
except OSError as e: sys.exit('无法连接 master:6443，请检查 IP/路由/防火墙/API Server：' + str(e))
PY
}

render_join_config() {
    # JSON 同样是合法 YAML；token 经 stdin 传入，避免出现在进程参数和 shell 历史中。
    printf '%s\n' "$JOIN_TOKEN" | "$PYTHON" -c '
import json,sys
out,name,ip,master,ca,cri=sys.argv[1:]
d={"apiVersion":"kubeadm.k8s.io/v1beta4","kind":"JoinConfiguration",
   "discovery":{"bootstrapToken":{"apiServerEndpoint":master+":6443","token":sys.stdin.read().strip(),"caCertHashes":[ca]}},
   "nodeRegistration":{"name":name,"criSocket":cri,"kubeletExtraArgs":[{"name":"node-ip","value":ip}]}}
with open(out,"w") as f: json.dump(d,f,indent=2)
' "$1" "$NODE_NAME" "$NODE_IP" "$MASTER_IP" "$CA_HASH" "$CRI_SOCKET"
}

wait_worker_ready() {
    section "就绪检查 | worker 节点"
    log "等待本机 Node Ready；网络插件由 master 上的 DaemonSet 自动下发"
    kubectl --kubeconfig=/etc/kubernetes/kubelet.conf --request-timeout="${WAIT_SECONDS}s" \
        wait --for=condition=Ready "node/$NODE_NAME" --timeout="${WAIT_SECONDS}s"
    kubectl --kubeconfig=/etc/kubernetes/kubelet.conf --request-timeout=30s get node "$NODE_NAME" -o wide
}

verify_existing_worker() {
    [[ ! -e /etc/kubernetes/admin.conf && ! -e /etc/kubernetes/manifests/kube-apiserver.yaml ]] || die "此机器是 master 的副本，不能直接当 worker；请用 init 之前的模板。"
    [[ "$(hostname)" == "$NODE_NAME" ]] || die "已有 worker 的主机名不符，不能直接改名后重新加入。"
    [[ -r /etc/kubernetes/pki/ca.crt ]] || die "已有 kubelet.conf 但没有 CA，属于部分失败状态，请先诊断。"
    [[ "$(ca_public_hash /etc/kubernetes/pki/ca.crt)" == "$CA_HASH" ]] || die "已有 worker 属于另一个集群。"
    check_package_versions
    local current_ip
    current_ip=$(kubectl --kubeconfig=/etc/kubernetes/kubelet.conf --request-timeout=30s get node "$NODE_NAME" -o 'jsonpath={.status.addresses[?(@.type=="InternalIP")].address}')
    [[ "$current_ip" == "$NODE_IP" ]] || die "已有 worker 的 InternalIP 不符；请先检查网络。"
    log "本机已经属于此集群；跳过安装和 join，只验证状态。"
    wait_worker_ready
}

show_plan() {
    section "部署预览 | $PLAN_ROLE"
    log "这是参数预览，不执行系统修改，也不代表前置条件已经通过。"
    printf '角色：%s\n本机：%s / %s\n控制平面版本：%s\nKubernetes 组件版本：%s\ncontainerd：%s\nPod CIDR：%s\nService CIDR：%s\nkube-proxy：%s\nRPM 镜像选择：%s\n控制平面镜像：%s\n防火墙：%s\nSELinux：permissive\n' \
        "$PLAN_ROLE" "${NODE_NAME:-待指定}" "${NODE_IP:-待指定}" "${CONTROL_PLANE_VERSION:-$K8S_VERSION}" "$K8S_VERSION" "$CONTAINERD_VERSION" "$POD_CIDR" "$SERVICE_CIDR" "$KUBE_PROXY_MODE" "$MIRROR" "$IMAGE_REPOSITORY" "$FIREWALL_MODE"
    if [[ "$PLAN_ROLE" == master ]]; then
        printf '流程：主机检查 → 配置备份 → 基础环境/组件 → init → Flannel → Ready → 导出加入文件\n'
    else printf '流程：校验加入文件 → 主机检查 → 配置备份 → 基础环境/组件 → join → Node Ready\n'; fi
    [[ -z "$BASEOS_URL" ]] || printf 'RHEL 源：自定义 BaseOS/AppStream URL\n'
    [[ -z "$OS_REPO_IDS" ]] || printf 'RHEL 源 ID：%s\n' "$OS_REPO_IDS"
}

check_status() {
    # 所有命令均只读；不调用 begin_changes、不生成 token、不执行 dnf。
    [[ "$(uname -s)" == Linux ]] || die "check 请在 Linux 虚拟机执行。"
    local swap_output service

    section "[1/6] 系统与网络"
    item "操作系统"
    cat /etc/redhat-release
    item "主机名"
    hostname
    item "IPv4 地址"
    ip -4 -br addr
    item "IPv4 路由"
    ip -4 route
    item "根分区挂载状态"
    findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS /

    section "[2/6] Swap、SELinux 与内核参数"
    item "Swap 使用情况"
    swap_output=$(swapon --show)
    if [[ -n "$swap_output" ]]; then printf '%s\n' "$swap_output"
    else printf '未启用 Swap（列表为空）\n'; fi
    item "SELinux 当前模式"
    getenforce || true
    item "IPv4 转发与网桥参数"
    sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables 2>/dev/null || true

    section "[3/6] 软件版本与服务状态"
    item "已安装的软件版本"
    rpm -q containerd.io kubeadm kubelet kubectl || true
    item "关键服务（服务名：当前状态）"
    for service in containerd kubelet chronyd; do
        printf '%-12s : ' "$service"
        systemctl is-active "$service" || true
    done
    item "启动失败的服务"
    systemctl --failed --no-pager || true
    item "时间同步"
    timedatectl show --property=NTPSynchronized || true

    section "[4/6] 本机身份（克隆后各节点应不同）"
    item "machine-id"
    cat /etc/machine-id
    item "虚拟机 product_uuid"
    cat /sys/class/dmi/id/product_uuid 2>/dev/null || true

    section "[5/6] Kubernetes 节点与 Pod 网段"
    if [[ -r /etc/kubernetes/admin.conf ]] && command -v kubectl >/dev/null; then
        item "节点状态"
        kctl --request-timeout=20s get nodes -o wide || true
        item "各节点的 Pod 网段与 UUID"
        kctl --request-timeout=20s get nodes -o 'custom-columns=NAME:.metadata.name,POD_CIDR:.spec.podCIDR,UUID:.status.nodeInfo.systemUUID' || true

        section "[6/6] Pod 与集群配置"
        item "所有命名空间的 Pod"
        kctl --request-timeout=20s get pods -A -o wide || true
        item "集群保存的 kubeadm 配置"
        kctl --request-timeout=20s -n kube-system get cm kubeadm-config -o 'jsonpath={.data.ClusterConfiguration}' || true
        printf '\n'
        item "集群节点身份重复检查"
        need_python
        if check_node_identities; then printf '未发现重复的 machineID / systemUUID\n'
        else printf '身份检查未通过，请查看上方错误。\n'; fi
    else
        log "跳过集群节点查询：需要可读的 /etc/kubernetes/admin.conf 和 kubectl。"
        section "[6/6] Pod 与集群配置"
        log "跳过集群查询；请在 master 上使用管理员权限执行 check。"
    fi

    section "检查结束 | 只读检查"
    log "以上为检查输出；出现错误请据此排查，不表示全部检查通过。"
}

main() {
    init_output
    parse_args "$@"
    if [[ "$STAGE" == help ]]; then usage; return; fi
    read_config
    NODE_NAME=$CLI_NAME; NODE_IP=$CLI_IP
    if [[ "$STAGE" == check ]]; then check_status; return; fi
    if [[ "$STAGE" == worker || "$STAGE" == plan && "$PLAN_ROLE" == worker && -n "$JOIN_FILE" ]]; then read_join_file; fi
    validate_settings
    if [[ "$STAGE" == plan ]]; then show_plan; return; fi
    section "主机预检 | $STAGE"
    require_host
    trap 'on_error "$LINENO" "$?"' ERR
    trap cleanup EXIT
    assert_root_mount
    if [[ "$STAGE" == cni || "$STAGE" == join-info ]]; then
        begin_changes
        read_live_cluster
        adopt_live_settings
        assert_flannel_compatible
        if [[ "$STAGE" == cni ]]; then install_flannel; fi
        wait_master_ready
        if [[ "$STAGE" == join-info ]]; then export_join_info; fi
        return
    fi
    [[ -n "$NODE_NAME" && -n "$NODE_IP" ]] || die "$STAGE 需要 --name 和 --ip。"
    if [[ "$STAGE" == master ]]; then MASTER_NAME=$NODE_NAME; MASTER_IP=$NODE_IP; fi
    validate_identity
    assert_local_network
    case "$STAGE" in
        prepare)
            prepare_node
            log "prepare 完成；若制作模板，请正常关机后克隆。此时还没有集群身份。"
            ;;
        master)
            if [[ -r /etc/kubernetes/admin.conf ]]; then
                begin_changes
                read_live_cluster
                assert_matching_master
                log "现有 master 参数一致；跳过基础配置和初始化，继续网络与验证。"
            else prepare_node; init_master; fi
            install_flannel
            wait_master_ready
            export_join_info
            kctl get nodes -o wide
            ;;
        worker)
            [[ "$NODE_NAME" != "$MASTER_NAME" && "$NODE_IP" != "$MASTER_IP" ]] || die "worker 的名称和 IP 都必须与 master 不同。"
            log "加入文件有效期至 $JOIN_EXPIRES（UTC）；版本和集群网段以加入文件为准。"
            assert_master_reachable
            if [[ -e /etc/kubernetes/kubelet.conf ]]; then verify_existing_worker; return; fi
            prepare_node
            render_join_config "$WORK_DIR/join.json"
            kubeadm config validate --config "$WORK_DIR/join.json"
            section "加入集群 | kubeadm join"
            log "worker 通过 join 加入；网络插件由集群统一下发。"
            kubeadm join --config "$WORK_DIR/join.json"
            JOIN_TOKEN=
            wait_worker_ready
            ;;
    esac
    log "本次操作完成。"
}

# 允许本地检查工具加载纯转换函数；直接运行时才进入安装流程。
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
