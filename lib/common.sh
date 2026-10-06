#!/usr/bin/env bash

# Libraries are sourced by setup.sh; no installation happens when sourced.
ROOT_PREFIX=''
CURRENT_STEP=准备
WORK_DIR=''
BACKUP_DIR=''
FILE_CHANGED=no
FILE_PREVIOUS=''
SWAP_CANDIDATE=''

root_path() { printf '%s%s' "$ROOT_PREFIX" "$1"; }
log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }
step() { CURRENT_STEP=$1; log "$1"; }
sshd() { /usr/sbin/sshd "$@"; }

trim() {
  local value=$1
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  printf '%s' "$value"
}

load_config() {
  ADMIN_USER=ops
  SSH_PUBLIC_KEY_FILE=''
  TIMEZONE=UTC
  SERVER_HOSTNAME=''
  SYSTEM_LOCALE=''
  ENABLE_TIME_SYNC=yes
  NTP_SERVERS=''
  SWAP_SIZE_MB=0
  INSTALL_MONITORING_TOOLS=yes
  ENABLE_SYSSTAT_HISTORY=yes
  SYSSTAT_HISTORY_DAYS=7
  ENABLE_FSTRIM=no
  INSTALL_BACKUP_TOOLS=no
  INSTALL_HARDWARE_TOOLS=no
  PASSWORDLESS_SUDO=yes
  UPGRADE_PACKAGES=no
  INSTALL_DOCKER=yes
  INSTALL_FAIL2BAN=yes
  DOCKER_ADD_ADMIN_TO_GROUP=no
  INSTALL_SECURITY_HARDENING=yes
  ENABLE_UNATTENDED_UPGRADES=yes
  INSTALL_COMMON_TOOLS=yes
  EXTRA_PACKAGES=''
  INSTALL_TAILSCALE=yes
  TAILSCALE_UDP_PORT=''
  INSTALL_SYNCTHING=no
  SYNCTHING_USER=''
  INSTALL_NGINX=no
  INSTALL_MIHOMO=no
  SERVICE_LAN_CIDR=''
  MIHOMO_DIR=/opt/mihomo
  ALLOW_TCP_PORTS=''
  ALLOW_UDP_PORTS=''
  local file=$1 line key value number=0 config_dir
  local -A seen=()
  [[ -f "$file" ]] || die "配置文件不存在：$file；请先从 configs/ 复制配置示例。"
  CONFIG_FILE=$(realpath -- "$file")
  config_dir=$(dirname -- "$CONFIG_FILE")
  # Parse literal KEY=value pairs. Never source/eval a user-supplied config as root.
  while IFS= read -r line || [[ -n "$line" ]]; do
    number=$((number + 1))
    line=$(trim "${line%$'\r'}")
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == *=* ]] || die "配置第 $number 行必须是 KEY=value。"
    key=$(trim "${line%%=*}")
    value=$(trim "${line#*=}")
    case "$key" in
      ADMIN_USER|SSH_PUBLIC_KEY_FILE|TIMEZONE|SERVER_HOSTNAME|SYSTEM_LOCALE|ENABLE_TIME_SYNC|NTP_SERVERS|SWAP_SIZE_MB|INSTALL_MONITORING_TOOLS|ENABLE_SYSSTAT_HISTORY|SYSSTAT_HISTORY_DAYS|ENABLE_FSTRIM|INSTALL_BACKUP_TOOLS|INSTALL_HARDWARE_TOOLS|PASSWORDLESS_SUDO|UPGRADE_PACKAGES|INSTALL_DOCKER|INSTALL_FAIL2BAN|DOCKER_ADD_ADMIN_TO_GROUP|ALLOW_TCP_PORTS|ALLOW_UDP_PORTS|INSTALL_SECURITY_HARDENING|ENABLE_UNATTENDED_UPGRADES|INSTALL_COMMON_TOOLS|EXTRA_PACKAGES|INSTALL_TAILSCALE|TAILSCALE_UDP_PORT|INSTALL_SYNCTHING|INSTALL_NGINX|INSTALL_MIHOMO|SYNCTHING_USER|SERVICE_LAN_CIDR|MIHOMO_DIR)
        [[ -z "${seen[$key]+defined}" ]] || die "配置第 $number 行重复定义 $key（首次在第 ${seen[$key]} 行）。"
        printf -v "$key" '%s' "$value"; seen[$key]=$number ;;
      *) die "配置第 $number 行包含未知选项：$key" ;;
    esac
  done < "$file"
  if [[ -n "$SSH_PUBLIC_KEY_FILE" && "$SSH_PUBLIC_KEY_FILE" != /* ]]; then
    SSH_PUBLIC_KEY_FILE=$(realpath -m -- "$config_dir/$SSH_PUBLIC_KEY_FILE")
  fi
  [[ -n "$SYNCTHING_USER" ]] || SYNCTHING_USER=$ADMIN_USER
  validate_config
}

validate_config() {
  [[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$ADMIN_USER" != root ]] || die 'ADMIN_USER 必须是普通用户名，不能是 root。'
  [[ "$SYNCTHING_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$SYNCTHING_USER" != root ]] || die 'SYNCTHING_USER 必须是非 root 用户名。'
  local name port package server
  for name in PASSWORDLESS_SUDO UPGRADE_PACKAGES INSTALL_DOCKER INSTALL_FAIL2BAN DOCKER_ADD_ADMIN_TO_GROUP INSTALL_SECURITY_HARDENING ENABLE_UNATTENDED_UPGRADES INSTALL_COMMON_TOOLS INSTALL_TAILSCALE INSTALL_SYNCTHING INSTALL_NGINX INSTALL_MIHOMO ENABLE_TIME_SYNC INSTALL_MONITORING_TOOLS ENABLE_SYSSTAT_HISTORY ENABLE_FSTRIM INSTALL_BACKUP_TOOLS INSTALL_HARDWARE_TOOLS; do
    [[ "${!name}" == yes || "${!name}" == no ]] || die "$name 只能填 yes 或 no。"
  done
  [[ "$TIMEZONE" =~ ^[A-Za-z0-9_+/-]+$ && "$TIMEZONE" != *..* && "$TIMEZONE" != /* ]] || die 'TIMEZONE 格式不正确。'
  [[ -f "$(root_path "/usr/share/zoneinfo/$TIMEZONE")" ]] || die "未知时区：$TIMEZONE"
  [[ -z "$SERVER_HOSTNAME" || ( "$SERVER_HOSTNAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ && "$SERVER_HOSTNAME" != localhost ) ]] || die 'SERVER_HOSTNAME 请填 1–63 位小写字母、数字和连字符组成的单段主机名，不能是 localhost。'
  [[ -z "$SYSTEM_LOCALE" || "$SYSTEM_LOCALE" == C.UTF-8 ]] || die 'SYSTEM_LOCALE 目前支持留空或 C.UTF-8；其他语言请自行生成并配置 locale。'
  NTP_SERVER_LIST=()
  read -r -a NTP_SERVER_LIST <<< "$NTP_SERVERS"
  for server in "${NTP_SERVER_LIST[@]}"; do
    valid_ntp_server "$server" || die "NTP_SERVERS 只接受 DNS 主机名、IPv4 或纯 IPv6 地址（不含端口）：$server"
  done
  [[ "$ENABLE_TIME_SYNC" == yes || -z "$NTP_SERVERS" ]] || die '设置 NTP_SERVERS 时必须启用 ENABLE_TIME_SYNC。'
  [[ "$SWAP_SIZE_MB" =~ ^(0|[1-9][0-9]{0,4})$ ]] && ((SWAP_SIZE_MB == 0 || (SWAP_SIZE_MB >= 128 && SWAP_SIZE_MB <= 32768))) || die 'SWAP_SIZE_MB 为 0（跳过）或 128–32768 的整数 MiB。'
  [[ "$SYSSTAT_HISTORY_DAYS" =~ ^[1-9][0-9]{0,2}$ ]] && ((SYSSTAT_HISTORY_DAYS <= 365)) || die 'SYSSTAT_HISTORY_DAYS 必须是 1–365 的整数。'
  TCP_PORTS=(); UDP_PORTS=()
  read -r -a TCP_PORTS <<< "$ALLOW_TCP_PORTS"
  read -r -a UDP_PORTS <<< "$ALLOW_UDP_PORTS"
  for port in "${TCP_PORTS[@]}" "${UDP_PORTS[@]}"; do
    valid_port "$port" || die "端口必须是 1–65535 的整数：$port"
  done
  [[ -z "$TAILSCALE_UDP_PORT" ]] || valid_port "$TAILSCALE_UDP_PORT" || die 'TAILSCALE_UDP_PORT 必须为空或合法端口。'
  EXTRA_PACKAGE_LIST=()
  read -r -a EXTRA_PACKAGE_LIST <<< "$EXTRA_PACKAGES"
  for package in "${EXTRA_PACKAGE_LIST[@]}"; do
    [[ "$package" =~ ^[a-z0-9][a-z0-9+.-]*$ ]] || die "EXTRA_PACKAGES 只接受普通 Debian 包名：$package"
  done
  [[ -z "$SERVICE_LAN_CIDR" ]] || valid_private_cidr "$SERVICE_LAN_CIDR" || die 'SERVICE_LAN_CIDR 只接受 RFC1918 IPv4 私有网段，如 192.168.1.0/24。'
  [[ "$MIHOMO_DIR" =~ ^/opt/[A-Za-z0-9_/-]+$ && "$MIHOMO_DIR" != *..* ]] || die 'MIHOMO_DIR 必须是 /opt 下不含空格的目录。'
}

valid_ntp_server() {
  local server=$1 part left right
  local parts=()
  if [[ "$server" == *:* ]]; then
    [[ "$server" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    if [[ "$server" == *::* ]]; then
      left=${server%%::*}; right=${server#*::}
      [[ "$left" != :* && "$left" != *: && "$right" != :* && "$right" != *: && "$right" != *::* ]] || return 1
      server="${left}${left:+${right:+:}}${right}"
      [[ -z "$server" ]] || IFS=: read -r -a parts <<< "$server"
      ((${#parts[@]} < 8)) || return 1
    else
      [[ "$server" != :* && "$server" != *: ]] || return 1
      IFS=: read -r -a parts <<< "$server"
      ((${#parts[@]} == 8)) || return 1
    fi
    for part in "${parts[@]}"; do [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1; done
    return 0
  fi
  if [[ "$server" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    IFS=. read -r -a parts <<< "$server"
    for part in "${parts[@]}"; do
      [[ "$part" =~ ^(0|[1-9][0-9]{0,2})$ ]] && ((10#$part <= 255)) || return 1
    done
    return 0
  fi
  [[ ${#server} -le 253 ]] || return 1
  server=${server%.}
  [[ -n "$server" && "$server" != *..* && "$server" != .* ]] || return 1
  IFS=. read -r -a parts <<< "$server"
  for part in "${parts[@]}"; do
    [[ "$part" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
  done
}

valid_private_cidr() {
  [[ "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
  local a b c d prefix part
  IFS=./ read -r a b c d prefix <<< "$1"
  for part in "$a" "$b" "$c" "$d"; do ((10#$part <= 255)) || return 1; done
  ((10#$prefix <= 32)) || return 1
  (( (10#$a == 10 && 10#$prefix >= 8) ||
     (10#$a == 172 && 10#$b >= 16 && 10#$b <= 31 && 10#$prefix >= 12) ||
     (10#$a == 192 && 10#$b == 168 && 10#$prefix >= 16) ))
}

valid_port() {
  [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

load_public_keys() {
  [[ -n "$SSH_PUBLIC_KEY_FILE" && -f "$SSH_PUBLIC_KEY_FILE" ]] || die '请设置 SSH_PUBLIC_KEY_FILE，指向上传的 SSH 公钥文件。'
  command -v ssh-keygen >/dev/null || die '缺少 ssh-keygen，请先安装 openssh-client。'
  PUBLIC_KEYS=()
  local key kind material rest
  while IFS= read -r key || [[ -n "$key" ]]; do
    key=$(trim "${key%$'\r'}")
    [[ -z "$key" || "$key" == \#* ]] && continue
    read -r kind material rest <<< "$key"
    case "$kind" in
      ssh-ed25519|ssh-rsa|ecdsa-sha2-*|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) ;;
      *) die '公钥文件只能包含普通 SSH 公钥；不要上传私钥或 authorized_keys 限制选项。' ;;
    esac
    ssh-keygen -lf /dev/stdin <<< "$key" >/dev/null 2>&1 || die 'SSH 公钥无效。'
    PUBLIC_KEYS+=("$key")
  done < "$SSH_PUBLIC_KEY_FILE"
  ((${#PUBLIC_KEYS[@]} > 0)) || die 'SSH 公钥文件为空。'
}

require_target() {
  ((EUID == 0)) || die '此操作需要 root；请使用 sudo bash setup.sh。'
  local os_file
  os_file=$(root_path /etc/os-release)
  [[ -r "$os_file" ]] || die '找不到 /etc/os-release。'
  # This file is part of the operating system, not the user's configuration.
  . "$os_file"
  [[ "${ID:-}" == debian ]] || die '目前只支持 Debian 12 和 Debian 13。'
  case "${VERSION_ID:-}:${VERSION_CODENAME:-}" in
    12:bookworm|13:trixie) ;;
    *) die '目前只支持 Debian 12/bookworm 和 Debian 13/trixie。' ;;
  esac
  command -v systemctl >/dev/null || die '需要 systemd。'
  [[ -d "$(root_path /run/systemd/system)" ]] || die '需要运行中的 systemd；普通容器不适用。'
  systemctl is-active --quiet ssh.service || die '需要运行中的 ssh.service。'
  sshd -t
}

read_ssh_ports() {
  local output port client client_port server server_port extra listeners=''
  output=$(sshd -T)
  SSH_PORTS=()
  while read -r port; do
    [[ -z "$port" ]] && continue
    valid_port "$port" || die "SSH 配置包含无效端口：$port"
    SSH_PORTS+=("$port")
  done < <(awk '$1 == "port" {print $2}' <<< "$output")
  # Include live sshd listeners even when the service passes a command-line port.
  if command -v ss >/dev/null; then
    listeners=$(ss -H -ltnp)
    while read -r port; do
      [[ -z "$port" ]] && continue
      valid_port "$port" || die '无法解析 sshd 的实际监听端口。'
      SSH_PORTS+=("$port")
    done < <(awk '/users:\(\("sshd"/ {port=$4; sub(/^.*:/, "", port); print port}' <<< "$listeners")
  fi
  # Preserve the port of this actual SSH connection as well (e.g. socket activation).
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    read -r client client_port server server_port extra <<< "$SSH_CONNECTION"
    [[ -z "$extra" ]] && valid_port "$server_port" || die 'SSH_CONNECTION 格式不正确。'
    SSH_PORTS+=("$server_port")
  elif [[ -z "$listeners" || "$listeners" != *'"sshd"'* ]]; then
    die '无法验证当前 SSH 监听端口；请在 SSH 会话中使用 sudo --preserve-env=SSH_CONNECTION。'
  fi
  ((${#SSH_PORTS[@]} > 0)) || die '无法读取 SSH 监听端口。'
  mapfile -t SSH_PORTS < <(printf '%s\n' "${SSH_PORTS[@]}" | sort -nu)
}

begin_run() {
  local run_id log_dir lock_file lock_dir lock_candidate mode
  run_id="$(date '+%Y%m%d-%H%M%S')-$$"
  log_dir=$(root_path /var/log/vps-init)
  lock_file=$(root_path /run/lock/vps-init.lock)
  lock_dir=$(dirname -- "$lock_file")
  [[ ! -L "$lock_dir" && ! -L "$lock_file" ]] || die '运行锁目录或文件不能是符号链接。'
  [[ -d "$lock_dir" ]] || install -d -m 0755 -- "$lock_dir"
  [[ "$(stat -c %u "$lock_dir")" == "$EUID" ]] || die '运行锁目录必须由当前特权账户所有。'
  mode=$(stat -c %a "$lock_dir")
  (( (8#$mode & 0022) == 0 || (8#$mode & 01000) != 0 )) || die '可共享写入的运行锁目录需要 sticky bit 保护。'
  # Link a private inode atomically; never open an attacker-created file during creation.
  if [[ ! -e "$lock_file" ]]; then
    lock_candidate=$(mktemp "$lock_dir/.vps-init-lock.XXXXXX")
    if ! ln -T -- "$lock_candidate" "$lock_file"; then
      rm -- "$lock_candidate"
      die '无法安全创建运行锁，可能有其他进程正在初始化。'
    fi
    rm -- "$lock_candidate"
  fi
  [[ ! -L "$lock_file" && -f "$lock_file" && "$(stat -c %u "$lock_file")" == "$EUID" ]] || die '运行锁必须是特权账户所有的普通文件。'
  [[ "$(stat -c %h "$lock_file")" == 1 ]] || die '运行锁不能与其他文件共享硬链接。'
  chmod 0600 -- "$lock_file"
  exec 9>>"$lock_file"
  flock -n 9 || die '另一个初始化或 SSH 回退操作正在运行。'
  install -d -m 0700 -- "$log_dir"
  LOG_FILE="$log_dir/$run_id.log"
  install -m 0600 /dev/null "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  BACKUP_DIR="$(root_path /var/backups/vps-init)/$run_id"
  install -d -m 0700 -- "$BACKUP_DIR"
  WORK_DIR=$(mktemp -d)
  trap 'on_error "$?" "$LINENO"' ERR
  trap cleanup EXIT
  log "日志：$LOG_FILE"
}

on_error() {
  local status=$1 line=$2
  trap - ERR
  printf '执行失败：步骤「%s」，第 %s 行，退出码 %s。\n日志：%s\n' "$CURRENT_STEP" "$line" "$status" "${LOG_FILE:-未创建}" >&2
  exit "$status"
}

cleanup() {
  [[ -z "$SWAP_CANDIDATE" ]] || rm -f -- "$SWAP_CANDIDATE"
  [[ -z "$WORK_DIR" ]] || rm -rf -- "$WORK_DIR"
}

backup_file() {
  local target=$1 destination
  destination="$BACKUP_DIR${target#"$ROOT_PREFIX"}"
  install -d -m 0700 -- "$(dirname -- "$destination")"
  [[ -e "$destination" ]] || cp -a -- "$target" "$destination"
  FILE_PREVIOUS=$destination
}

# Atomic replacement, only if content differs. Optional validator runs on the candidate.
write_managed_file() {
  local target=$1 mode=$2 validator=${3:-} candidate
  [[ ! -L "$target" ]] || die "拒绝覆盖符号链接：$target"
  [[ ! -e "$target" || -f "$target" ]] || die "目标不是普通文件：$target"
  local parent
  parent=$(dirname -- "$target")
  [[ -d "$parent" ]] || install -d -m 0755 -- "$parent"
  candidate=$(mktemp "$WORK_DIR/config.XXXXXX")
  cat > "$candidate"
  [[ -z "$validator" ]] || "$validator" "$candidate"
  FILE_CHANGED=no; FILE_PREVIOUS=''
  if [[ -f "$target" ]] && cmp -s -- "$candidate" "$target"; then
    chmod "$mode" "$target"
    return 0
  fi
  [[ ! -e "$target" ]] || backup_file "$target"
  # Stage on the destination filesystem so the final rename is atomic.
  local staged
  staged=$(mktemp "$(dirname -- "$target")/.vps-init.XXXXXX")
  install -m "$mode" -- "$candidate" "$staged"
  mv -f -- "$staged" "$target"
  FILE_CHANGED=yes
}

restore_file() {
  local target=$1 previous=$2 mode=$3
  if [[ -n "$previous" ]]; then
    install -m "$mode" -- "$previous" "$target"
  else
    rm -f -- "$target"
  fi
}

apt_update() {
  # Partial index downloads must not silently fall back to stale package lists.
  apt-get -o DPkg::Lock::Timeout=120 -o Acquire::Retries=3 --error-on=any update
}

apt_install() {
  DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get -o DPkg::Lock::Timeout=120 -o Acquire::Retries=3 \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
    --no-remove install -y "$@"
}

# Change one simple assignment in a package config; preserve other settings/comments.
update_config_assignment() {
  local target=$1 key=$2 value=$3
  [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die '内部配置键格式错误。'
  python3 - "$target" "$key" "$value" > "$WORK_DIR/assignment.conf" <<'PY'
import pathlib
import re
import sys

path, key, value = sys.argv[1:]
file = pathlib.Path(path)
lines = file.read_text().splitlines() if file.exists() else []
pattern = re.compile(r'^\s*(?:export\s+)?' + re.escape(key) + r'\s*=')
output = []
written = False
for line in lines:
    if pattern.match(line):
        if not written:
            output.append(f'{key}={value}')
            written = True
    else:
        output.append(line)
if not written:
    output.append(f'{key}={value}')
print('\n'.join(output))
PY
  write_managed_file "$target" 0644 < "$WORK_DIR/assignment.conf"
}

write_apt_repository() {
  local key_file=$1 repo_file=$2 key_candidate=$3 target
  local key_previous key_changed repo_previous repo_changed
  for target in "$key_file" "$repo_file"; do
    [[ ! -L "$target" && ( ! -e "$target" || -f "$target" ) ]] || die "软件源或密钥不是普通文件：$target"
  done
  write_managed_file "$key_file" 0644 < "$key_candidate"
  key_previous=$FILE_PREVIOUS; key_changed=$FILE_CHANGED
  write_managed_file "$repo_file" 0644
  repo_previous=$FILE_PREVIOUS; repo_changed=$FILE_CHANGED
  if ! apt_update; then
    [[ "$repo_changed" == no ]] || restore_file "$repo_file" "$repo_previous" 0644
    [[ "$key_changed" == no ]] || restore_file "$key_file" "$key_previous" 0644
    die '软件源索引更新失败，已恢复本次软件源和密钥修改；请检查网络及现有 APT 源后重跑。'
  fi
}

check_package_state() {
  local audit
  audit=$(LC_ALL=C dpkg --audit) || die '无法检查软件包状态。'
  if [[ -n "$audit" ]]; then
    printf '%s\n' "$audit" >&2
    die '存在未完成或损坏的软件包状态，请先修复 dpkg 后重跑。'
  fi
}

assert_no_pending_ssh() {
  [[ ! -d "$(root_path /var/lib/vps-init/ssh-pending)" ]] || die 'SSH 加固正在等待确认，请先用新连接执行 confirm-ssh，或等待自动回退。'
}
