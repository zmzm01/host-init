#!/usr/bin/env bash

COMMON_PACKAGES=(vim-tiny nano tmux htop git wget rsync jq unzip zip zstd tree
  lsof dnsutils iputils-ping mtr-tiny netcat-openbsd ncdu ripgrep fd-find bash-completion)

install_common_tools() {
  step '安装常用编辑、诊断和文件管理工具'
  local packages=()
  [[ "$INSTALL_COMMON_TOOLS" == no ]] || packages+=("${COMMON_PACKAGES[@]}")
  packages+=("${EXTRA_PACKAGE_LIST[@]}")
  ((${#packages[@]} > 0)) || return 0
  apt_install "${packages[@]}"
}

check_common_tools() {
  local packages=() package status
  [[ "$INSTALL_COMMON_TOOLS" == no ]] || packages+=("${COMMON_PACKAGES[@]}")
  packages+=("${EXTRA_PACKAGE_LIST[@]}")
  for package in "${packages[@]}"; do
    status=$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)
    [[ "$status" == 'install ok installed' ]] || die "常用工具尚未安装：$package"
  done
}
