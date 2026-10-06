#!/usr/bin/env bash

# Avoid routing, forwarding, rp_filter and IPv6-disable settings: Docker/Tailscale need them.
SECURITY_SYSCTL_SETTINGS=(
  kernel.kptr_restrict=2 kernel.dmesg_restrict=1
  fs.protected_hardlinks=1 fs.protected_symlinks=1
  net.ipv4.tcp_syncookies=1
  net.ipv4.conf.all.accept_redirects=0 net.ipv4.conf.default.accept_redirects=0
  net.ipv4.conf.all.send_redirects=0 net.ipv4.conf.default.send_redirects=0
  net.ipv6.conf.all.accept_redirects=0 net.ipv6.conf.default.accept_redirects=0
)

security_sysctl_settings() {
  printf '%s\n' "${SECURITY_SYSCTL_SETTINGS[@]}"
  # all/default do not disable IPv4 redirects on already existing host interfaces.
  # Slash notation preserves dots in interface names (e.g. enp3s0.200).
  local family parameter path interface base
  for family in ipv4 ipv6; do
    base=$(root_path "/proc/sys/net/$family/conf")
    for parameter in accept_redirects send_redirects; do
      [[ "$family:$parameter" != ipv6:send_redirects ]] || continue
      for path in "$base"/*/"$parameter"; do
        [[ -e "$path" ]] || continue
        interface=${path%/*}; interface=${interface##*/}
        [[ "$interface" != all && "$interface" != default ]] || continue
        printf 'net/%s/conf/%s/%s=0\n' "$family" "$interface" "$parameter"
      done
    done
  done
}

kernel_parameter_path() {
  local key=$1
  [[ "$key" == */* ]] || key=${key//./\/}
  root_path "/proc/sys/$key"
}

configure_kernel_security() {
  step '限制内核信息泄露并关闭 ICMP 重定向'
  local target item key value previous changed old_value
  target=$(root_path /etc/sysctl.d/90-vps-init-security.conf)
  : > "$WORK_DIR/sysctl-before"
  : > "$WORK_DIR/sysctl-security"
  security_sysctl_settings > "$WORK_DIR/sysctl-settings"
  while IFS= read -r item; do
    key=${item%%=*}; value=${item#*=}
    [[ -e "$(kernel_parameter_path "$key")" ]] || continue
    old_value=$(sysctl -n "$key")
    printf '%s = %s\n' "$key" "$old_value" >> "$WORK_DIR/sysctl-before"
    printf '%s = %s\n' "$key" "$value" >> "$WORK_DIR/sysctl-security"
  done < "$WORK_DIR/sysctl-settings"
  [[ -s "$WORK_DIR/sysctl-security" ]] || die '无法读取支持的内核参数。'
  write_managed_file "$target" 0644 < "$WORK_DIR/sysctl-security"
  previous=$FILE_PREVIOUS; changed=$FILE_CHANGED
  if ! sysctl -p "$target"; then
    [[ "$changed" == no ]] || restore_file "$target" "$previous" 0644
    sysctl -p "$WORK_DIR/sysctl-before" || true
    die '内核参数应用失败，已恢复本次文件修改并尝试恢复运行时值。'
  fi
}

configure_journal_limits() {
  step '持久保存系统日志并限制磁盘占用'
  local target previous changed
  target=$(root_path /etc/systemd/journald.conf.d/90-vps-init.conf)
  write_managed_file "$target" 0644 <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=200M
RuntimeMaxUse=50M
MaxRetentionSec=1month
EOF
  previous=$FILE_PREVIOUS; changed=$FILE_CHANGED
  if [[ "$changed" == yes ]]; then
    if ! systemctl restart systemd-journald.service; then
      restore_file "$target" "$previous" 0644
      systemctl restart systemd-journald.service || true
      die '日志服务启动失败，已恢复本次配置。'
    fi
  fi
  systemctl is-active --quiet systemd-journald.service
  journalctl --flush
}

validate_apt_config() { apt-config -c "$1" dump >/dev/null; }

configure_security_updates() {
  step '启用每日 Debian 安全更新，禁止自动重启'
  apt_install unattended-upgrades
  local target
  target=$(root_path /etc/apt/apt.conf.d/99-vps-init-security)
  write_managed_file "$target" 0644 validate_apt_config <<EOF
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=$VERSION_CODENAME-security,label=Debian-Security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "false";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
}

configure_security() {
  configure_kernel_security
  configure_journal_limits
  ufw logging low
}

check_security() {
  local item key value
  if [[ "$INSTALL_SECURITY_HARDENING" == yes ]]; then
    security_sysctl_settings > "$WORK_DIR/sysctl-check-settings"
    while IFS= read -r item; do
      key=${item%%=*}; value=${item#*=}
      [[ -e "$(kernel_parameter_path "$key")" ]] || continue
      [[ "$(sysctl -n "$key")" == "$value" ]] || die "内核安全参数没有生效：$key"
    done < "$WORK_DIR/sysctl-check-settings"
    systemctl is-active --quiet systemd-journald.service
    [[ -f "$(root_path /etc/systemd/journald.conf.d/90-vps-init.conf)" ]] || die '日志上限配置尚未安装。'
  fi
  if [[ "$ENABLE_UNATTENDED_UPGRADES" == yes ]]; then
    systemctl is-active --quiet apt-daily-upgrade.timer
    [[ -f "$(root_path /etc/apt/apt.conf.d/99-vps-init-security)" ]] || die '自动安全更新尚未配置。'
  fi
}
