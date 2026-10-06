#!/usr/bin/env bash

time_preflight() {
  TIME_SYNC_SERVICE=''
  [[ "$ENABLE_TIME_SYNC" == yes ]] || return 0
  local package unit status found=()
  for package in chrony ntpsec openntpd systemd-timesyncd; do
    status=$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)
    [[ "$status" == 'install ok installed' ]] || continue
    case "$package" in
      chrony) unit=chrony.service ;;
      ntpsec) unit=ntpsec.service ;;
      openntpd) unit=openntpd.service ;;
      systemd-timesyncd) unit=systemd-timesyncd.service ;;
    esac
    found+=("$unit")
  done
  ((${#found[@]} <= 1)) || die '检测到多套时间服务，请先整合，或设置 ENABLE_TIME_SYNC=no。'
  if ((${#found[@]} == 1)); then
    TIME_SYNC_SERVICE=${found[0]}
  elif [[ "$(timedatectl show --property=NTP --value)" == yes ]]; then
    die '检测到未识别的已有时间服务；请保留其配置并设置 ENABLE_TIME_SYNC=no。'
  else
    TIME_SYNC_SERVICE=systemd-timesyncd.service
  fi
  [[ -z "$NTP_SERVERS" || "$TIME_SYNC_SERVICE" == systemd-timesyncd.service ]] || die '已有 Chrony/NTP 服务时请在其原配置中设置上游；NTP_SERVERS 仅用于 systemd-timesyncd。'
}

configure_time_sync() {
  [[ "$ENABLE_TIME_SYNC" == yes ]] || return 0
  step '启用时间同步，沿用已安装的 NTP 服务'
  time_preflight
  if [[ "$TIME_SYNC_SERVICE" == systemd-timesyncd.service ]]; then
    apt_install systemd-timesyncd
    if [[ -n "$NTP_SERVERS" ]]; then
      local target previous changed
      target=$(root_path /etc/systemd/timesyncd.conf.d/90-vps-init.conf)
      write_managed_file "$target" 0644 <<EOF
[Time]
NTP=
NTP=$NTP_SERVERS
EOF
      previous=$FILE_PREVIOUS; changed=$FILE_CHANGED
      if [[ "$changed" == yes ]] && ! systemctl restart "$TIME_SYNC_SERVICE"; then
        restore_file "$target" "$previous" 0644
        systemctl restart "$TIME_SYNC_SERVICE" || true
        die '时间同步服务启动失败，已恢复本次上游配置。'
      fi
    fi
  fi
  systemctl enable --now "$TIME_SYNC_SERVICE"
  check_time_sync
}

check_time_sync() {
  [[ "$ENABLE_TIME_SYNC" == yes ]] || return 0
  time_preflight
  systemctl is-active --quiet "$TIME_SYNC_SERVICE"
  if [[ "$(timedatectl show --property=NTPSynchronized --value)" == yes ]]; then
    log "时间已同步（$TIME_SYNC_SERVICE）。"
  else
    log "时间服务已运行（$TIME_SYNC_SERVICE），尚未同步；请检查上游及 UDP 123 出站，稍后用 health 查看。"
  fi
}
