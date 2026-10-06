#!/usr/bin/env bash

COMMON_PACKAGES=(vim-tiny nano htop git wget rsync jq unzip zip zstd tree
  lsof bind9-dnsutils iputils-ping mtr-tiny netcat-openbsd ncdu ripgrep fd-find bash-completion)

# Pin both the release and official GitHub archive digests; never execute latest blindly.
ZELLIJ_VERSION=0.45.1

zellij_asset() {
  local architecture
  architecture=$(dpkg --print-architecture)
  case "$architecture" in
    amd64)
      ZELLIJ_ASSET=zellij-x86_64-unknown-linux-musl.tar.gz
      ZELLIJ_SHA256=40bcc2e03f5d5ae8e054e39f676081fe12ab70871506996ba595834c3718eefc ;;
    arm64)
      ZELLIJ_ASSET=zellij-aarch64-unknown-linux-musl.tar.gz
      ZELLIJ_SHA256=05f0802afadd53f8db9514e7cae53c9ae8432fed1b35b8294aa816ee3044a16b ;;
    *) die "Zellij 预编译安装支持 amd64/arm64；当前是 $architecture，可选择 tmux 或 none。" ;;
  esac
}

tools_preflight() {
  [[ "$INSTALL_COMMON_TOOLS" == yes && "$TERMINAL_MULTIPLEXER" == zellij ]] || return 0
  zellij_asset
  local target mode
  target=$(root_path /usr/local/bin/zellij)
  [[ ! -L "$target" && ( ! -e "$target" || -f "$target" ) ]] || die 'Zellij 安装目标必须是普通文件，不能是符号链接。'
  if [[ -f "$target" ]]; then
    [[ "$(stat -c %u "$target")" == "$EUID" && "$(stat -c %h "$target")" == 1 ]] || die '已有 Zellij 必须由特权账户所有，且不能有硬链接。'
    mode=$(stat -c %a "$target")
    (( (8#$mode & 0022) == 0 )) || die '已有 Zellij 不能允许其他账户写入。'
  fi
}

validate_zellij_binary() {
  chmod 0755 -- "$1"
  [[ "$("$1" --version)" == "zellij $ZELLIJ_VERSION" ]] || die "Zellij 二进制版本与固定版本 $ZELLIJ_VERSION 不符。"
}

install_zellij() {
  step "安装 Zellij $ZELLIJ_VERSION 官方预编译版"
  tools_preflight
  local archive binary target
  target=$(root_path /usr/local/bin/zellij)
  if [[ -x "$target" ]] && [[ "$("$target" --version 2>/dev/null)" == "zellij $ZELLIJ_VERSION" ]]; then
    log '已安装所选 Zellij 版本，保留程序及现有用户配置。'
    return 0
  fi
  apt_install ca-certificates curl tar gzip
  archive="$WORK_DIR/$ZELLIJ_ASSET"
  binary="$WORK_DIR/zellij"
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --retry 3 --connect-timeout 10 --max-time 120 \
    "https://github.com/zellij-org/zellij/releases/download/v$ZELLIJ_VERSION/$ZELLIJ_ASSET" -o "$archive"
  printf '%s  %s\n' "$ZELLIJ_SHA256" "$archive" | sha256sum --check --status || die 'Zellij 下载校验失败，未修改已有程序。'
  # Read only the binary member to stdout; never extract archive paths into the filesystem.
  tar --extract --gzip --file "$archive" --to-stdout -- zellij > "$binary"
  write_managed_file "$target" 0755 validate_zellij_binary < "$binary"
  log 'Zellij 已安装到 /usr/local/bin/zellij；以管理员账户运行 zellij，不自动修改 Shell 启动文件。'
}

install_optional_tool_packages() {
  local package output status
  local available=()
  output="$WORK_DIR/tool-package-plan.log"
  for package in "$@"; do
    status=0
    LC_ALL=C apt-get -o DPkg::Lock::Timeout=120 --no-remove --simulate install "$package" > "$output" 2>&1 || status=$?
    if ((status == 0)); then
      available+=("$package")
    else
      cat "$output"
      if ((status == 100)) && grep -Eq '^E: (Unable to locate package |Package .* has no installation candidate)' "$output"; then
        warn "跳过常用工具 $package：当前软件源中找不到可安装的软件包。"
      else
        die "常用工具 $package 的 APT 预检查失败（退出码 $status）；请查看上方错误。"
      fi
    fi
  done
  if ((${#available[@]} > 0)); then apt_install "${available[@]}"; fi
}

install_common_tools() {
  step '安装常用编辑、诊断和文件管理工具'
  tools_preflight
  local packages=()
  [[ "$INSTALL_COMMON_TOOLS" == no ]] || packages+=("${COMMON_PACKAGES[@]}")
  [[ "$INSTALL_COMMON_TOOLS" == no || "$TERMINAL_MULTIPLEXER" != tmux ]] || packages+=(tmux)
  packages+=("${EXTRA_PACKAGE_LIST[@]}")
  if ((${#packages[@]} > 0)); then install_optional_tool_packages "${packages[@]}"; fi
  if [[ "$INSTALL_COMMON_TOOLS" == yes && "$TERMINAL_MULTIPLEXER" == zellij ]]; then install_zellij; fi
}

check_common_tools() {
  step '检查常用工具安装状态'
  local packages=() package status query_status
  [[ "$INSTALL_COMMON_TOOLS" == no ]] || packages+=("${COMMON_PACKAGES[@]}")
  [[ "$INSTALL_COMMON_TOOLS" == no || "$TERMINAL_MULTIPLEXER" != tmux ]] || packages+=(tmux)
  packages+=("${EXTRA_PACKAGE_LIST[@]}")
  for package in "${packages[@]}"; do
    query_status=0
    status=$(dpkg-query -W -f='${Status}' "$package" 2>&1) || query_status=$?
    log "软件包 $package：${status:-无状态输出}（查询退出码 $query_status）"
    if [[ "$query_status" == 0 && "$status" == 'install ok installed' ]]; then
      continue
    elif [[ "$query_status" == 1 || ( "$query_status" == 0 && ( "$status" == 'unknown ok not-installed' || "$status" == 'deinstall ok config-files' || "$status" == 'deinstall ok not-installed' || "$status" == 'purge ok not-installed' ) ) ]]; then
      warn "常用工具尚未安装：$package；保留后续安装步骤，修复包名或软件源后重跑 tools。"
    else
      die "常用工具软件包状态异常：$package；请查看日志中的软件包状态和 APT 输出。"
    fi
  done
  if [[ "$INSTALL_COMMON_TOOLS" == yes && "$TERMINAL_MULTIPLEXER" == zellij ]]; then
    tools_preflight
    local target
    target=$(root_path /usr/local/bin/zellij)
    [[ -f "$target" && ! -L "$target" && -x "$target" ]] || die 'Zellij 尚未安装到 /usr/local/bin/zellij。'
    [[ "$("$target" --version)" == "zellij $ZELLIJ_VERSION" ]] || die 'Zellij 版本与本项目固定版本不一致，请重跑 tools。'
  fi
}
