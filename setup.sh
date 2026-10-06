#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/modules/system.sh"
. "$SCRIPT_DIR/modules/docker.sh"
. "$SCRIPT_DIR/modules/ssh.sh"
. "$SCRIPT_DIR/modules/security.sh"
. "$SCRIPT_DIR/modules/tools.sh"
. "$SCRIPT_DIR/modules/tailscale.sh"
. "$SCRIPT_DIR/modules/services.sh"
. "$SCRIPT_DIR/modules/host.sh"
. "$SCRIPT_DIR/modules/time.sh"
. "$SCRIPT_DIR/modules/swap.sh"
. "$SCRIPT_DIR/modules/maintenance.sh"

services_selected() {
  [[ "$INSTALL_SYNCTHING" == yes || "$INSTALL_NGINX" == yes || "$INSTALL_MIHOMO" == yes ]]
}

usage() {
  cat <<'EOF'
用法：bash setup.sh <命令> [--config 文件] [--confirm-key-login]

  plan         显示配置和计划，不修改系统
  doctor       在目标主机检查安装前提、软件包状态与磁盘空间，不修改系统
  health       查看资源、网卡、时间同步、失败服务及维护定时器，不修改系统
  init         初始化账户、公钥、时区、防火墙和选中的软件
  docker       单独安装 Docker（使用配置中的明确用户名）
  tools        安装配置中选中的常用工具和额外软件包
  security     配置内核安全参数、日志上限和选中的自动安全更新
  tailscale    安装 Tailscale；首次账号登录随后执行 tailscale up
  services     安装配置中选中的服务（Syncthing/Nginx/Mihomo）
  host         单独设置选中的主机名、字符集和时间同步
  maintenance  安装维护工具，配置选中的性能历史记录、TRIM 和 Swap
  harden       新管理员公钥登录验证后，关闭 root/密码登录
  confirm-ssh  在加固后的新 SSH 连接中确认，取消 5 分钟自动回退
  check        检查账户、SSH、防火墙和选中的服务

默认配置：项目根目录中的 config.conf。
先复制 configs/vps.example.conf 或 configs/homelab.example.conf 并填写公钥路径。
EOF
}

show_plan() {
  printf '目标：Debian 12/13（systemd）\n配置：%s\n管理员：%s\n公钥：%s\n时区：%s\n' \
    "$CONFIG_FILE" "$ADMIN_USER" "${SSH_PUBLIC_KEY_FILE:-未设置}" "$TIMEZONE"
  printf '免密 sudo：%s\n系统升级：%s\nDocker：%s\nFail2Ban：%s\n加入 docker 组：%s\n' \
    "$PASSWORDLESS_SUDO" "$UPGRADE_PACKAGES" "$INSTALL_DOCKER" "$INSTALL_FAIL2BAN" "$DOCKER_ADD_ADMIN_TO_GROUP"
  printf '额外 TCP 端口：%s\n额外 UDP 端口：%s\n' "${ALLOW_TCP_PORTS:-无}" "${ALLOW_UDP_PORTS:-无}"
  printf '系统加固：%s\n自动安全更新：%s\n常用工具：%s\n额外软件包：%s\nTailscale：%s\n' \
    "$INSTALL_SECURITY_HARDENING" "$ENABLE_UNATTENDED_UPGRADES" "$INSTALL_COMMON_TOOLS" "${EXTRA_PACKAGES:-无}" "$INSTALL_TAILSCALE"
  printf '终端复用工具：%s（随常用工具安装；Zellij 固定版本 %s）\n' "$TERMINAL_MULTIPLEXER" "$ZELLIJ_VERSION"
  printf 'Syncthing：%s；Nginx：%s；Mihomo：%s；服务局域网：%s\n' \
    "$INSTALL_SYNCTHING" "$INSTALL_NGINX" "$INSTALL_MIHOMO" "${SERVICE_LAN_CIDR:-未放行}"
  printf '主机名：%s；默认 LANG：%s；时间同步：%s；NTP 上游：%s；Swap：%s MiB\n' \
    "${SERVER_HOSTNAME:-保留}" "${SYSTEM_LOCALE:-保留}" "$ENABLE_TIME_SYNC" "${NTP_SERVERS:-保留现有或发行版默认}" "$SWAP_SIZE_MB"
  printf '性能诊断工具：%s；性能历史：%s（%s 天）；定期 TRIM：%s；备份工具：%s；硬件诊断工具：%s\n' \
    "$INSTALL_MONITORING_TOOLS" "$ENABLE_SYSSTAT_HISTORY" "$SYSSTAT_HISTORY_DAYS" "$ENABLE_FSTRIM" "$INSTALL_BACKUP_TOOLS" "$INSTALL_HARDWARE_TOOLS"
  printf '保留现有 APT 源；放行实际 SSH 端口；init 后单独验证并加固 SSH。\n'
  if [[ -n "$SSH_PUBLIC_KEY_FILE" ]]; then
    load_public_keys
    printf '已验证 %s 条公钥。\n' "${#PUBLIC_KEYS[@]}"
  fi
}

preflight_init() {
  local mode=${1:-init}
  assert_no_pending_ssh
  check_package_state
  load_public_keys
  inspect_admin
  read_ssh_ports
  host_preflight
  time_preflight
  swap_preflight
  tools_preflight
  [[ "$INSTALL_DOCKER" == no ]] || docker_preflight
  [[ "$INSTALL_TAILSCALE" == no ]] || tailscale_preflight
  if services_selected; then services_preflight "$mode"; fi
}

main() {
  local command=${1:-help} config="$SCRIPT_DIR/config.conf"
  CONFIRM_KEY_LOGIN=no
  (($# == 0)) || shift
  case "$command" in help|-h|--help) usage; return 0 ;; esac
  case "$command" in plan|doctor|health|init|docker|tools|security|tailscale|services|host|maintenance|harden|confirm-ssh|check) ;; *) usage; die "未知命令：$command" ;; esac
  while (($# > 0)); do
    case "$1" in
      --config) (($# >= 2)) || die '--config 后需要文件路径。'; config=$2; shift 2 ;;
      --confirm-key-login) CONFIRM_KEY_LOGIN=yes; shift ;;
      -h|--help) usage; return 0 ;;
      *) die "未知参数：$1" ;;
    esac
  done
  [[ "$CONFIRM_KEY_LOGIN" == no || "$command" == harden ]] || die '--confirm-key-login 仅用于 harden。'
  load_config "$config"
  if [[ "$command" == plan ]]; then show_plan; return 0; fi
  require_target
  if [[ "$command" == health ]]; then health_report; return 0; fi
  if [[ "$command" == doctor ]]; then
    step '检查安装前提'
    preflight_init doctor
    printf '实际 SSH 端口：%s\n' "${SSH_PORTS[*]}"
    df -h -- / /var /tmp
    log '安装前检查通过；未更新软件源或安装软件，下载连通性在安装时验证。'
    return 0
  fi
  case "$command" in docker|tools|security|tailscale|services|host|maintenance) check_package_state ;; esac
  case "$command" in
    init) preflight_init ;;
    docker)
      docker_preflight
      if [[ "$DOCKER_ADD_ADMIN_TO_GROUP" == yes ]]; then
        getent passwd "$ADMIN_USER" >/dev/null || die '请先创建配置中的管理员账户。'
      fi ;;
    tailscale) tailscale_preflight ;;
    tools) tools_preflight ;;
    services) services_preflight services ;;
    host) host_preflight; time_preflight ;;
    maintenance) swap_preflight ;;
  esac
  RUN_COMMAND=$command
  begin_run
  case "$command" in
    init)
      assert_no_pending_ssh
      [[ "$INSTALL_DOCKER" == no ]] || migrate_legacy_docker_source
      prepare_packages
      configure_swap
      install_common_tools
      configure_host
      configure_time_sync
      configure_admin
      configure_firewall
      [[ "$INSTALL_FAIL2BAN" == no ]] || configure_fail2ban
      [[ "$INSTALL_DOCKER" == no ]] || install_docker
      [[ "$INSTALL_TAILSCALE" == no ]] || install_tailscale
      if services_selected; then install_services; fi
      configure_maintenance
      # Network daemons may create interfaces or reset networking sysctls during startup.
      [[ "$INSTALL_SECURITY_HARDENING" == no ]] || configure_security
      [[ "$ENABLE_UNATTENDED_UPGRADES" == no ]] || configure_security_updates
      check_system
      check_common_tools
      check_security
      check_host
      check_maintenance
      check_swap
      log '基础初始化完成。请用新管理员公钥登录并验证 sudo，然后执行 harden。' ;;
    docker) assert_no_pending_ssh; install_docker ;;
    tools) assert_no_pending_ssh; apt_update; install_common_tools; check_common_tools ;;
    security)
      assert_no_pending_ssh
      apt_update
      apt_install procps ufw
      configure_security
      [[ "$ENABLE_UNATTENDED_UPGRADES" == no ]] || configure_security_updates ;;
    tailscale) assert_no_pending_ssh; install_tailscale ;;
    services)
      assert_no_pending_ssh
      apt_update
      apt_install adduser ufw
      install_services ;;
    host)
      assert_no_pending_ssh
      apt_update
      apt_install python3
      configure_host
      configure_time_sync
      check_host ;;
    maintenance)
      assert_no_pending_ssh
      apt_update
      apt_install python3 util-linux
      configure_swap
      configure_maintenance
      check_maintenance
      check_swap ;;
    harden) harden_ssh ;;
    confirm-ssh) confirm_ssh ;;
    check)
      check_system
      [[ "$INSTALL_DOCKER" == no ]] || check_docker
      check_security
      check_common_tools
      check_host
      check_time_sync
      check_maintenance
      check_swap
      [[ "$INSTALL_TAILSCALE" == no ]] || check_tailscale
      if services_selected; then check_services; fi
      log '检查通过。' ;;
  esac
  log "本次备份目录：$BACKUP_DIR"
}

main "$@"
