#!/usr/bin/env bash

services_preflight() {
  if [[ "$INSTALL_SYNCTHING" == yes ]]; then
    local entry uid
    if entry=$(getent passwd "$SYNCTHING_USER"); then
      IFS=: read -r _ _ uid _ <<< "$entry"
      ((uid > 0)) || die '拒绝以 UID 0 运行 Syncthing。'
    elif [[ "$SYNCTHING_USER" != syncthing ]]; then
      [[ ( "$1" == init || "$1" == doctor ) && "$SYNCTHING_USER" == "$ADMIN_USER" ]] || die '请先创建配置指定的 Syncthing 账户。'
    fi
  fi
  if [[ "$INSTALL_MIHOMO" == yes ]]; then
    local dir binary mode
    dir=$(root_path "$MIHOMO_DIR"); binary="$dir/mihomo"
    [[ -d "$dir/config" && -f "$dir/config/config.yaml" && -x "$binary" ]] || die '请先准备 MIHOMO_DIR/mihomo 和 config/config.yaml。'
    [[ ! -L "$dir" && ! -L "$binary" && ! -L "$dir/config" && ! -L "$dir/config/config.yaml" ]] || die 'Mihomo 目录、二进制及配置文件不能是符号链接。'
    [[ "$(stat -c %u "$binary")" == 0 && "$(stat -c %u "$dir")" == 0 ]] || die 'Mihomo 二进制及其目录必须由 root 所有。'
    mode=$(stat -c %a "$binary")
    (( (8#$mode & 06022) == 0 )) || die 'Mihomo 二进制不能有 setuid/setgid 或组/其他用户写权限。'
    mode=$(stat -c %a "$dir")
    (( (8#$mode & 0022) == 0 )) || die 'Mihomo 目录不能由组/其他用户写入。'
    # doctor only inspects files; third-party config tests can create caches/downloads.
    [[ "$1" == doctor ]] || "$binary" -t -d "$dir/config"
  fi
}

configure_syncthing() {
  step "为 $SYNCTHING_USER 安装 Syncthing"
  apt_install syncthing
  local entry uid
  if ! entry=$(getent passwd "$SYNCTHING_USER"); then
    [[ "$SYNCTHING_USER" == syncthing ]] || die 'Syncthing 使用的账户不存在。'
    adduser --system --group --home "$(root_path /var/lib/syncthing)" syncthing
    entry=$(getent passwd syncthing)
  fi
  IFS=: read -r _ _ uid _ <<< "$entry"
  ((uid > 0)) || die '拒绝以 UID 0 运行 Syncthing。'
  systemctl enable --now "syncthing@$SYNCTHING_USER.service"
  systemctl is-active --quiet "syncthing@$SYNCTHING_USER.service"
  if [[ -n "$SERVICE_LAN_CIDR" ]]; then
    ufw allow from "$SERVICE_LAN_CIDR" to any port 22000 proto tcp
    ufw allow from "$SERVICE_LAN_CIDR" to any port 22000 proto udp
    ufw allow from "$SERVICE_LAN_CIDR" to any port 21027 proto udp
  fi
  log 'Syncthing GUI 首次默认监听本机；通过 SSH 隧道访问 8384，不自动放行 GUI 端口。'
}

configure_nginx() {
  step '安装 Debian 软件源的 Nginx'
  apt_install nginx
  nginx -t
  systemctl enable --now nginx.service
  systemctl is-active --quiet nginx.service
  if [[ -n "$SERVICE_LAN_CIDR" ]]; then
    ufw allow from "$SERVICE_LAN_CIDR" to any port 80 proto tcp
    ufw allow from "$SERVICE_LAN_CIDR" to any port 443 proto tcp
  fi
}

validate_mihomo_unit() {
  cp -- "$1" "$WORK_DIR/mihomo.service"
  systemd-analyze verify "$WORK_DIR/mihomo.service"
}

configure_mihomo() {
  step '使用受限系统账户运行已准备好的 Mihomo'
  local dir target previous changed entry uid
  dir=$(root_path "$MIHOMO_DIR")
  target=$(root_path /etc/systemd/system/mihomo.service)
  if entry=$(getent passwd mihomo); then
    IFS=: read -r _ _ uid _ <<< "$entry"
    ((uid > 0 && uid < 1000)) || die '已有 mihomo 账户不是专用系统账户。'
  else
    adduser --system --group --no-create-home --home "$dir" mihomo
  fi
  chown -R mihomo:mihomo -- "$dir/config"
  chmod 0700 -- "$dir/config"
  chmod 0600 -- "$dir/config/config.yaml"
  runuser -u mihomo -- "$dir/mihomo" -t -d "$dir/config"
  # The old script created this exact symlink; preserve it in the backup before migration.
  if [[ -L "$target" ]]; then
    [[ "$(readlink -- "$target")" == "$dir/mihomo.service" ]] || die '已有 Mihomo 服务是未知符号链接，请先手动整合。'
    backup_file "$target"
    cp -L -- "$target" "$WORK_DIR/legacy-mihomo.service"
    rm -- "$target"
    install -m 0644 -- "$WORK_DIR/legacy-mihomo.service" "$target"
  fi
  write_managed_file "$target" 0644 validate_mihomo_unit <<EOF
[Unit]
Description=Mihomo proxy service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=mihomo
Group=mihomo
ExecStart=$dir/mihomo -d $dir/config
Restart=on-failure
RestartSec=5s
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=$dir/config
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
  previous=$FILE_PREVIOUS; changed=$FILE_CHANGED
  systemctl daemon-reload
  systemctl enable mihomo.service
  if [[ "$changed" == yes ]]; then
    if ! systemctl restart mihomo.service; then
      restore_file "$target" "$previous" 0644
      systemctl daemon-reload
      systemctl restart mihomo.service || true
      die 'Mihomo 服务启动失败，已恢复本次服务文件。'
    fi
  else
    systemctl start mihomo.service
  fi
  systemctl is-active --quiet mihomo.service
}

install_services() {
  [[ "$INSTALL_MIHOMO" == no ]] || configure_mihomo
  [[ "$INSTALL_SYNCTHING" == no ]] || configure_syncthing
  [[ "$INSTALL_NGINX" == no ]] || configure_nginx
  check_services
}

check_services() {
  [[ "$INSTALL_MIHOMO" == no ]] || systemctl is-active --quiet mihomo.service
  [[ "$INSTALL_SYNCTHING" == no ]] || systemctl is-active --quiet "syncthing@$SYNCTHING_USER.service"
  if [[ "$INSTALL_NGINX" == yes ]]; then
    nginx -t
    systemctl is-active --quiet nginx.service
  fi
}
