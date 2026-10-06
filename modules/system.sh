#!/usr/bin/env bash

inspect_admin() {
  local entry uid gid gecos shell status
  if entry=$(getent passwd "$ADMIN_USER"); then
    IFS=: read -r _ _ uid gid gecos ADMIN_HOME shell <<< "$entry"
    ((uid >= 1000 && uid != 65534)) || die '拒绝把系统账户设为管理员。'
    [[ "$ADMIN_HOME" == /* && "$ADMIN_HOME" != / && -d "$ADMIN_HOME" ]] || die '已有管理员的主目录无效。'
    case "$shell" in */nologin|*/false) die '已有管理员账户不允许登录。' ;; esac
    if [[ "$PASSWORDLESS_SUDO" == no ]]; then
      status=$(passwd -S "$ADMIN_USER")
      [[ "$(awk '{print $2}' <<< "$status")" == P ]] || die 'PASSWORDLESS_SUDO=no 时，已有管理员必须先设置密码。'
    fi
  else
    ADMIN_HOME="$(root_path "/home/$ADMIN_USER")"
    if [[ "$PASSWORDLESS_SUDO" == no && ! -t 0 ]]; then
      die '新用户需要交互设置 sudo 密码；请在终端运行，或设置 PASSWORDLESS_SUDO=yes。'
    fi
  fi
  [[ ! -L "$ADMIN_HOME" && ! -L "$ADMIN_HOME/.ssh" && ! -L "$ADMIN_HOME/.ssh/authorized_keys" ]] || die '拒绝操作带有符号链接的管理员主目录或 SSH 文件。'
}

prepare_packages() {
  step '更新软件包索引并安装基础工具'
  apt_update
  apt_install adduser sudo ca-certificates curl gnupg python3 openssh-client iproute2 procps ufw tzdata util-linux
  if [[ "$UPGRADE_PACKAGES" == yes ]]; then
    step '升级已安装的软件包'
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get -o DPkg::Lock::Timeout=120 -o Acquire::Retries=3 \
      -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade -y
  fi
  timedatectl set-timezone "$TIMEZONE"
}

validate_sudo_file() { visudo -cf "$1"; }

configure_admin() {
  step "配置管理员 $ADMIN_USER 和 SSH 公钥"
  if ! getent passwd "$ADMIN_USER" >/dev/null; then
    adduser --disabled-password --gecos '' "$ADMIN_USER"
    if [[ "$PASSWORDLESS_SUDO" == no ]]; then
      passwd "$ADMIN_USER"
    fi
  fi
  inspect_admin
  usermod -aG sudo "$ADMIN_USER"
  # StrictModes rejects group/other writable homes.
  chmod go-w -- "$ADMIN_HOME"
  install -d -m 0700 -o "$ADMIN_USER" -g "$(id -gn "$ADMIN_USER")" -- "$ADMIN_HOME/.ssh"
  local authorized key kind material rest sudo_file previous changed
  authorized="$ADMIN_HOME/.ssh/authorized_keys"
  [[ ! -e "$authorized" || -f "$authorized" ]] || die 'authorized_keys 不是普通文件。'
  if [[ -f "$authorized" ]]; then
    backup_file "$authorized"
  else
    install -m 0600 -o "$ADMIN_USER" -g "$(id -gn "$ADMIN_USER")" /dev/null "$authorized"
  fi
  for key in "${PUBLIC_KEYS[@]}"; do
    read -r kind material rest <<< "$key"
    # Compare key material, so changing a comment does not append another copy.
    if ! awk -v key="$material" '{for (i=1; i<=NF; i++) if ($i == key) found=1} END {exit !found}' "$authorized"; then
      printf '\n%s\n' "$key" >> "$authorized"
    fi
  done
  chown "$ADMIN_USER:$(id -gn "$ADMIN_USER")" "$authorized"
  chmod 0600 "$authorized"
  sudo_file=$(root_path /etc/sudoers.d/90-vps-init)
  if [[ "$PASSWORDLESS_SUDO" == yes ]]; then
    write_managed_file "$sudo_file" 0440 validate_sudo_file <<< "$ADMIN_USER ALL=(ALL:ALL) NOPASSWD: ALL"
  else
    write_managed_file "$sudo_file" 0440 validate_sudo_file <<< "$ADMIN_USER ALL=(ALL:ALL) ALL"
  fi
  previous=$FILE_PREVIOUS; changed=$FILE_CHANGED
  if ! visudo -c; then
    [[ "$changed" == no ]] || restore_file "$sudo_file" "$previous" 0440
    die 'sudo 配置检查失败，已恢复本次修改。'
  fi
  if [[ "$PASSWORDLESS_SUDO" == yes ]]; then
    sudo -u "$ADMIN_USER" sudo -n /usr/bin/true
  fi
}

configure_firewall() {
  step '配置主机防火墙并保留实际 SSH 端口'
  local port
  for port in "${SSH_PORTS[@]}"; do
    ufw allow "$port/tcp" comment 'vps-init SSH'
  done
  for port in "${TCP_PORTS[@]}"; do ufw allow "$port/tcp"; done
  for port in "${UDP_PORTS[@]}"; do ufw allow "$port/udp"; done
  ufw default deny incoming
  ufw default allow outgoing
  ufw --force enable
  ufw status verbose
}

configure_fail2ban() {
  step '配置 Fail2Ban，通过 systemd journal 读取 SSH 日志'
  apt_install fail2ban python3-systemd
  local target ports previous changed
  target=$(root_path /etc/fail2ban/jail.d/90-vps-init.local)
  ports=$(IFS=,; printf '%s' "${SSH_PORTS[*]}")
  write_managed_file "$target" 0644 <<EOF
[sshd]
enabled = true
backend = systemd
port = $ports
maxretry = 5
bantime = 1h
findtime = 10m
EOF
  previous=$FILE_PREVIOUS; changed=$FILE_CHANGED
  if ! fail2ban-client -t; then
    [[ "$changed" == no ]] || restore_file "$target" "$previous" 0644
    die 'Fail2Ban 配置检查失败，已恢复本次修改。'
  fi
  systemctl enable fail2ban.service
  if [[ "$changed" == yes ]]; then
    if ! systemctl restart fail2ban.service; then
      restore_file "$target" "$previous" 0644
      fail2ban-client -t && systemctl restart fail2ban.service || true
      die 'Fail2Ban 启动失败，已恢复本次配置并尝试恢复服务。'
    fi
  else
    systemctl start fail2ban.service
  fi
  # Give a newly started daemon time to create its socket.
  local attempt
  for attempt in {1..10}; do
    if fail2ban-client status sshd; then return 0; fi
    sleep 1
  done
  if [[ "$changed" == yes ]]; then
    restore_file "$target" "$previous" 0644
    fail2ban-client -t && systemctl restart fail2ban.service || true
    die 'Fail2Ban 的 sshd jail 没有成功启动，已恢复本次配置并尝试恢复服务。'
  fi
  die 'Fail2Ban 的 sshd jail 没有成功启动，请检查原有配置与日志。'
}

check_system() {
  step '检查管理员、SSH 和主机防火墙'
  getent passwd "$ADMIN_USER" >/dev/null || die '管理员账户不存在。'
  inspect_admin
  [[ -s "$ADMIN_HOME/.ssh/authorized_keys" ]] || die '管理员缺少 authorized_keys。'
  visudo -c
  if [[ "$PASSWORDLESS_SUDO" == yes ]]; then sudo -u "$ADMIN_USER" sudo -n /usr/bin/true; fi
  sshd -t
  sshd -T | awk '$1 ~ /^(port|permitrootlogin|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|authenticationmethods)$/ {print}'
  systemctl is-active --quiet ssh.service
  local firewall
  firewall=$(LC_ALL=C ufw status verbose)
  printf '%s\n' "$firewall"
  grep -q '^Status: active' <<< "$firewall" || die 'UFW 尚未启用。'
  if [[ "$INSTALL_FAIL2BAN" == yes ]]; then
    systemctl is-active --quiet fail2ban.service
    fail2ban-client status sshd
  fi
}
