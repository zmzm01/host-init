#!/usr/bin/env bash

require_admin_connection() {
  [[ "${SUDO_USER:-}" == "$ADMIN_USER" ]] || die "请从 $ADMIN_USER 的 SSH 会话通过 sudo 执行此操作。"
  [[ -n "${SSH_CONNECTION:-}" ]] || die '缺少 SSH_CONNECTION；请使用 sudo --preserve-env=SSH_CONNECTION。'
  local extra
  read -r CLIENT_ADDRESS CLIENT_PORT SERVER_ADDRESS SERVER_PORT extra <<< "$SSH_CONNECTION"
  [[ -z "$extra" && "$CLIENT_ADDRESS" =~ ^[[:xdigit:]:.]+$ && "$SERVER_ADDRESS" =~ ^[[:xdigit:]:.]+$ ]] || die 'SSH_CONNECTION 格式不正确。'
  valid_port "$CLIENT_PORT" && valid_port "$SERVER_PORT" || die 'SSH_CONNECTION 的端口无效。'
  inspect_admin
  [[ -s "$ADMIN_HOME/.ssh/authorized_keys" ]] || die '管理员的公钥尚未安装。'
}

ssh_effective_config() {
  sshd -T -C "user=$1,addr=$CLIENT_ADDRESS,host=$CLIENT_ADDRESS,laddr=$SERVER_ADDRESS,lport=$SERVER_PORT"
}

ssh_connection_token() {
  python3 - "$SSH_CONNECTION" <<'PY'
import ipaddress
import sys

def normalize(value):
    address = ipaddress.ip_address(value.strip('[]'))
    return str(getattr(address, 'ipv4_mapped', None) or address)

client, client_port, server, server_port = sys.argv[1].split()
print(normalize(client), int(client_port), normalize(server), int(server_port))
PY
}

snapshot_ssh_connections() {
  ss -H -tn state established > "$WORK_DIR/established-connections"
  python3 - "$WORK_DIR/established-connections" <<'PY'
import ipaddress
import pathlib
import sys

def endpoint(value):
    host, port = value.rsplit(':', 1)
    address = ipaddress.ip_address(host.strip('[]'))
    return str(getattr(address, 'ipv4_mapped', None) or address), int(port)

for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    fields = line.split()
    server, server_port = endpoint(fields[-2])
    client, client_port = endpoint(fields[-1])
    print(client, client_port, server, server_port)
PY
}

assert_hardened_config() {
  local global admin root setting
  local settings=('permitrootlogin no' 'pubkeyauthentication yes' 'passwordauthentication no'
    'kbdinteractiveauthentication no' 'authenticationmethods publickey')
  if [[ "${INSTALL_SECURITY_HARDENING:-no}" == yes ]]; then
    settings+=('logingracetime 30' 'maxauthtries 3' 'x11forwarding no' 'permitemptypasswords no'
      'permituserenvironment no' 'clientaliveinterval 300' 'clientalivecountmax 2')
  fi
  global=$(sshd -T) || return 1
  admin=$(ssh_effective_config "$ADMIN_USER") || return 1
  root=$(ssh_effective_config root) || return 1
  for setting in "${settings[@]}"; do
    grep -Fxq "$setting" <<< "$global" || return 1
    grep -Fxq "$setting" <<< "$admin" || return 1
  done
  grep -Fxq 'permitrootlogin no' <<< "$root"
}

write_ssh_rollback_script() {
  local script
  script=$(root_path /var/lib/vps-init/ssh-rollback.sh)
  # Root-owned, self-contained recovery does not depend on the uploaded checkout/config.
  write_managed_file "$script" 0700 <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ ! -L /run/lock/vps-init.lock && -f /run/lock/vps-init.lock ]] || exit 1
exec 9>>/run/lock/vps-init.lock
flock 9
pending=/var/lib/vps-init/ssh-pending
target=/etc/ssh/sshd_config.d/00-00-vps-init.conf
[[ -d "$pending" ]] || exit 0
if [[ -f "$pending/previous.conf" ]]; then
  install -m 0644 "$pending/previous.conf" "$target"
else
  rm -f -- "$target"
fi
/usr/sbin/sshd -t
systemctl reload ssh.service
systemctl stop vps-init-ssh-rollback.timer
rm -rf -- "$pending"
logger -t vps-init 'SSH 加固未确认，已自动恢复之前的配置。'
SH
}

restore_pending_ssh() {
  local pending target
  pending=$(root_path /var/lib/vps-init/ssh-pending)
  target=$(root_path /etc/ssh/sshd_config.d/00-00-vps-init.conf)
  if [[ -f "$pending/previous.conf" ]]; then
    install -m 0644 -- "$pending/previous.conf" "$target"
  else
    rm -f -- "$target"
  fi
  sshd -t
  systemctl reload ssh.service
  systemctl stop vps-init-ssh-rollback.timer vps-init-ssh-rollback.service
  rm -rf -- "$pending"
}

harden_ssh() {
  require_admin_connection
  [[ "$CONFIRM_KEY_LOGIN" == yes ]] || die '请先用仅公钥认证的新连接验证登录，再加 --confirm-key-login。'
  assert_no_pending_ssh
  command -v systemd-run >/dev/null || die '缺少 systemd-run，无法安排 SSH 自动回退。'
  step '应用 SSH 加固，并安排 5 分钟自动回退'
  local target pending candidate
  target=$(root_path /etc/ssh/sshd_config.d/00-00-vps-init.conf)
  pending=$(root_path /var/lib/vps-init/ssh-pending)
  [[ ! -L "$target" && ! -L "$(dirname -- "$target")" ]] || die 'SSH 配置目录或文件是符号链接。'
  candidate="$WORK_DIR/ssh.conf"
  cat > "$candidate" <<'EOF'
# Managed by host-init/setup.sh. Validated with sshd -t and sshd -T.
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthenticationMethods publickey
EOF
  if [[ "${INSTALL_SECURITY_HARDENING:-no}" == yes ]]; then
    cat >> "$candidate" <<'EOF'
LoginGraceTime 30
MaxAuthTries 3
X11Forwarding no
PermitEmptyPasswords no
PermitUserEnvironment no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
  fi
  if [[ -f "$target" ]] && cmp -s "$candidate" "$target" && assert_hardened_config; then
    log 'SSH 已加固，配置无需修改。'
    return 0
  fi
  # Reject confirmation from any connection already established before the change,
  # including another old terminal, not only the session running harden.
  snapshot_ssh_connections > "$WORK_DIR/ssh-existing"
  grep -Fxq "$(ssh_connection_token)" "$WORK_DIR/ssh-existing" || die '无法核对当前 SSH TCP 连接，未修改 SSH 配置。'
  install -d -m 0700 -- "$(root_path /var/lib/vps-init)"
  write_ssh_rollback_script
  install -d -m 0700 -- "$pending"
  [[ ! -f "$target" ]] || cp -a -- "$target" "$pending/previous.conf"
  printf '%s\n' "$SSH_CONNECTION" > "$pending/original-connection"
  cp -- "$WORK_DIR/ssh-existing" "$pending/existing-connections"
  printf '%s\n' "$ADMIN_USER" > "$pending/admin-user"
  # Schedule recovery before installing or reloading the potentially blocking config.
  if ! systemd-run --quiet --collect --unit=vps-init-ssh-rollback --on-active=300s \
    --timer-property=AccuracySec=1s --property=Type=oneshot \
    /bin/bash "$(root_path /var/lib/vps-init/ssh-rollback.sh)"; then
    rm -rf -- "$pending"
    die '无法安排自动回退，SSH 配置未修改。'
  fi
  systemctl is-active --quiet vps-init-ssh-rollback.timer
  write_managed_file "$target" 0644 < "$candidate"
  if ! sshd -t || ! assert_hardened_config; then
    restore_pending_ssh
    die 'SSH 配置无效或被已有配置覆盖，已恢复。请检查 Include 顺序和 Match 规则。'
  fi
  if ! systemctl reload ssh.service; then
    restore_pending_ssh
    die 'SSH 重载失败，已恢复之前的配置。'
  fi
  log 'SSH 加固已应用；请保持当前连接，在 5 分钟内打开新的公钥连接。'
  log '在新连接执行：sudo --preserve-env=SSH_CONNECTION bash setup.sh confirm-ssh --config config.conf'
  log '未确认会自动回退；确认前请勿重启服务器。'
}

confirm_ssh() {
  require_admin_connection
  local pending
  pending=$(root_path /var/lib/vps-init/ssh-pending)
  [[ -d "$pending" ]] || die '没有待确认的 SSH 修改；可能已自动回退。'
  [[ "$(cat "$pending/admin-user")" == "$ADMIN_USER" ]] || die '确认账户与加固账户不一致。'
  [[ "$(cat "$pending/original-connection")" != "$SSH_CONNECTION" ]] || die '请打开新的 SSH 连接后确认，不能用加固前的旧连接。'
  if grep -Fxq "$(ssh_connection_token)" "$pending/existing-connections"; then
    die '该连接在加固前已经存在，请打开真正的新 SSH 连接后确认。'
  fi
  sshd -t
  assert_hardened_config || die 'SSH 生效配置与加固策略不一致，保留自动回退。'
  step '确认新 SSH 连接并取消自动回退'
  # The shared lock serializes this operation against a rollback already in progress.
  systemctl stop vps-init-ssh-rollback.timer vps-init-ssh-rollback.service
  rm -rf -- "$pending"
  log '新连接已确认，SSH 加固完成。'
}
