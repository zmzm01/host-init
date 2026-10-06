#!/usr/bin/env bash

MONITORING_PACKAGES=(sysstat iotop-c iftop nethogs needrestart)
HARDWARE_PACKAGES=(smartmontools nvme-cli lm-sensors)

install_maintenance_tools() {
  local packages=()
  [[ "$INSTALL_MONITORING_TOOLS" == no ]] || packages+=("${MONITORING_PACKAGES[@]}")
  [[ "$INSTALL_HARDWARE_TOOLS" == no ]] || packages+=("${HARDWARE_PACKAGES[@]}")
  [[ "$INSTALL_BACKUP_TOOLS" == no ]] || packages+=(restic)
  ((${#packages[@]} > 0)) || return 0
  step '安装性能诊断、磁盘健康和选中的备份工具'
  apt_install "${packages[@]}"
}

configure_sysstat() {
  [[ "$ENABLE_SYSSTAT_HISTORY" == yes ]] || return 0
  step "启用性能历史记录，保留 $SYSSTAT_HISTORY_DAYS 天"
  apt_install sysstat
  update_config_assignment "$(root_path /etc/default/sysstat)" ENABLED '"true"'
  update_config_assignment "$(root_path /etc/sysstat/sysstat)" HISTORY "$SYSSTAT_HISTORY_DAYS"
  systemctl enable --now sysstat.service sysstat-collect.timer sysstat-summary.timer
  # Debian 13 has a separate rotation timer; Debian 12 rotates during summary.
  local state
  state=$(systemctl show --property=LoadState --value sysstat-rotate.timer)
  if [[ "$state" != not-found && -n "$state" ]]; then
    systemctl enable --now sysstat-rotate.timer
  fi
}

configure_trim() {
  [[ "$ENABLE_FSTRIM" == yes ]] || return 0
  step '启用发行版的定期 TRIM 定时器'
  apt_install util-linux
  systemctl enable --now fstrim.timer
  log '保留发行版的 TRIM 周期；可用 lsblk -D 查看设备支持情况。'
}

configure_maintenance() {
  install_maintenance_tools
  configure_sysstat
  configure_trim
}

check_maintenance() {
  local packages=() package status unit
  [[ "$INSTALL_MONITORING_TOOLS" == no ]] || packages+=("${MONITORING_PACKAGES[@]}")
  [[ "$INSTALL_HARDWARE_TOOLS" == no ]] || packages+=("${HARDWARE_PACKAGES[@]}")
  [[ "$INSTALL_BACKUP_TOOLS" == no ]] || packages+=(restic)
  for package in "${packages[@]}"; do
    status=$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)
    [[ "$status" == 'install ok installed' ]] || die "维护工具尚未安装：$package"
  done
  if [[ "$ENABLE_SYSSTAT_HISTORY" == yes ]]; then
    for unit in sysstat-collect.timer sysstat-summary.timer; do
      systemctl is-active --quiet "$unit"
    done
    grep -Fxq 'ENABLED="true"' "$(root_path /etc/default/sysstat)" || die 'sysstat 采集尚未启用。'
    grep -Fxq "HISTORY=$SYSSTAT_HISTORY_DAYS" "$(root_path /etc/sysstat/sysstat)" || die 'sysstat 保留天数与配置不符。'
  fi
  [[ "$ENABLE_FSTRIM" == no ]] || systemctl is-active --quiet fstrim.timer
}

health_report() {
  step '查看主机运行状态（不修改系统）'
  printf '主机：%s；内核：%s\n' "$(uname -n)" "$(uname -r)"
  uptime
  free -h
  df -h -- / /var /tmp
  df -i -- / /var /tmp
  swapon --show
  lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS
  ip -brief address
  printf '\n时间同步：\n'
  timedatectl show --property=Timezone --property=NTP --property=NTPSynchronized
  printf '\n失败的 systemd 单元：\n'
  systemctl --failed --no-legend --plain --no-pager
  printf '\n维护定时器：\n'
  systemctl list-timers --all --no-pager 'apt-daily*' 'sysstat*' 'fstrim*'
  if [[ -f "$(root_path /var/run/reboot-required)" ]]; then
    log '系统已标记需要重启，请安排维护窗口。'
  else
    log '没有 reboot-required 标记；这不代表所有服务和内核均已更新，可用 sudo needrestart -r l 检查。'
  fi
}
