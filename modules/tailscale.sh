#!/usr/bin/env bash

tailscale_preflight() {
  local sources=() file
  shopt -s nullglob
  sources=("$(root_path /etc/apt/sources.list.d)"/*.list "$(root_path /etc/apt/sources.list.d)"/*.sources)
  shopt -u nullglob
  [[ ! -f "$(root_path /etc/apt/sources.list)" ]] || sources+=("$(root_path /etc/apt/sources.list)")
  for file in "${sources[@]}"; do
    grep -Eq '^[[:space:]]*[^#[:space:]].*pkgs\.tailscale\.com' "$file" || continue
    [[ "$file" == "$(root_path /etc/apt/sources.list.d/vps-init-tailscale.sources)" ]] || die "检测到已有 Tailscale 软件源：$file；请先整合或停用。"
  done
}

install_tailscale() {
  step '安装 Tailscale 官方稳定版并启动后台服务'
  apt_update
  apt_install ca-certificates curl gnupg python3
  local key_file repo_file
  key_file=$(root_path /etc/apt/keyrings/vps-init-tailscale.gpg)
  repo_file=$(root_path /etc/apt/sources.list.d/vps-init-tailscale.sources)
  curl --fail --silent --show-error --location --retry 3 --connect-timeout 10 --max-time 120 \
    "https://pkgs.tailscale.com/stable/debian/$VERSION_CODENAME.noarmor.gpg" -o "$WORK_DIR/tailscale.gpg"
  install -d -m 0700 "$WORK_DIR/gnupg"
  gpg --batch --homedir "$WORK_DIR/gnupg" --show-keys "$WORK_DIR/tailscale.gpg" >/dev/null
  write_apt_repository "$key_file" "$repo_file" "$WORK_DIR/tailscale.gpg" <<EOF
Types: deb
URIs: https://pkgs.tailscale.com/stable/debian
Suites: $VERSION_CODENAME
Components: main
Signed-By: /etc/apt/keyrings/vps-init-tailscale.gpg
EOF
  apt_install tailscale
  systemctl enable --now tailscaled.service
  if [[ -n "$TAILSCALE_UDP_PORT" ]]; then
    apt_install ufw
    ufw allow "$TAILSCALE_UDP_PORT/udp" comment 'Tailscale peer connections'
    log '已放行配置中的 UDP 端口；请确保它与 tailscaled 的实际端口一致。'
  fi
  check_tailscale
}

check_tailscale() {
  systemctl is-active --quiet tailscaled.service
  tailscale version
  local attempt state
  for attempt in {1..10}; do
    if tailscale status --json > "$WORK_DIR/tailscale-status.json"; then
      state=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("BackendState", "Unknown"))' "$WORK_DIR/tailscale-status.json")
      case "$state" in
        Running) log 'Tailscale 已连接；访问权限由 tailnet 策略控制。' ;;
        NeedsLogin|NeedsMachineAuth|Stopped) log "Tailscale 状态：$state；首次使用请执行 sudo tailscale up 并完成登录/设备批准。" ;;
        *) log "Tailscale 状态：$state；可用 tailscale status 和 tailscale netcheck 继续检查。" ;;
      esac
      return 0
    fi
    sleep 1
  done
  die '无法读取 tailscaled 状态，请检查 journalctl -u tailscaled。'
}
