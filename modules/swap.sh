#!/usr/bin/env bash

swap_paths() { swapon --show --noheadings --raw --output NAME; }

swap_preflight() {
  SWAP_ACTION=skip
  ((SWAP_SIZE_MB > 0)) || return 0
  local target parent ancestor filesystem available existing unit_file
  target=$(root_path /var/lib/vps-init/swapfile)
  parent=$(dirname -- "$target")
  [[ ! -L "$parent" && ! -L "$target" ]] || die 'Swap 目录或文件不能是符号链接。'
  existing=$(swap_paths)
  if [[ ! -e "$target" && -n "$existing" ]]; then
    SWAP_ACTION=preserve
    log '已有启用的 Swap，保留现有配置，不额外创建。'
    return 0
  fi
  SWAP_UNIT=$(systemd-escape --path --suffix=swap "$target")
  unit_file=$(root_path "/etc/systemd/system/$SWAP_UNIT")
  [[ ! -L "$unit_file" && ( ! -e "$unit_file" || -f "$unit_file" ) ]] || die 'Swap 单元不是普通文件。'
  if [[ -f "$unit_file" ]]; then
    grep -Fxq 'Description=host-init managed swap file' "$unit_file" || die '已有同名 Swap 单元不由本项目管理，请先手动整合。'
  fi
  if [[ -e "$target" ]]; then
    [[ -f "$target" && "$(stat -c %u "$target")" == "$EUID" && "$(stat -c %h "$target")" == 1 ]] || die '托管 Swap 必须是特权账户所有、没有硬链接的普通文件。'
    [[ "$(stat -c %s "$target")" == "$((SWAP_SIZE_MB * 1024 * 1024))" ]] || die '已有托管 Swap 大小不同；不会自动停用或调整，请保留原大小或手动迁移。'
    [[ "$(blkid -p -s TYPE -o value "$target")" == swap ]] || die '已有同名文件不是有效 Swap，不会覆盖。'
    SWAP_ACTION=existing
    return 0
  fi
  ancestor=$parent
  while [[ ! -d "$ancestor" ]]; do ancestor=$(dirname -- "$ancestor"); done
  filesystem=$(findmnt --noheadings --output FSTYPE --target "$ancestor")
  case "$filesystem" in ext4|xfs) ;; *) die "Swap 自动创建仅支持 ext4/XFS；当前是 $filesystem，请按文件系统要求单独配置。" ;; esac
  available=$(df -Pm -- "$ancestor" | awk 'NR == 2 {print $4}')
  [[ "$available" =~ ^[0-9]+$ ]] && ((available >= SWAP_SIZE_MB + 256)) || die '磁盘空间不足：创建 Swap 后至少需要保留 256 MiB 可用空间。'
  SWAP_ACTION=create
}

validate_swap_unit() {
  cp -- "$1" "$WORK_DIR/$SWAP_UNIT"
  systemd-analyze verify "$WORK_DIR/$SWAP_UNIT"
}

configure_swap() {
  ((SWAP_SIZE_MB > 0)) || return 0
  step '按需配置 Swap，保留现有交换空间'
  swap_preflight
  [[ "$SWAP_ACTION" != preserve ]] || return 0
  local target parent candidate unit_file created=no previous changed active
  target=$(root_path /var/lib/vps-init/swapfile); parent=$(dirname -- "$target")
  SWAP_UNIT=$(systemd-escape --path --suffix=swap "$target")
  unit_file=$(root_path "/etc/systemd/system/$SWAP_UNIT")
  [[ ! -L "$unit_file" && ( ! -e "$unit_file" || -f "$unit_file" ) ]] || die 'Swap 单元不是普通文件。'
  if [[ "$SWAP_ACTION" == create ]]; then
    [[ -d "$parent" ]] || install -d -m 0700 -- "$parent"
    candidate=$(mktemp "$parent/.swap.XXXXXX")
    SWAP_CANDIDATE=$candidate
    if ! dd if=/dev/zero of="$candidate" bs=1M count="$SWAP_SIZE_MB" conv=fsync status=progress || ! mkswap "$candidate"; then
      rm -- "$candidate"
      SWAP_CANDIDATE=''
      die 'Swap 文件准备失败，已清理本次临时文件。'
    fi
    # Publish without replacing an existing path, even if another process created it.
    if ! ln -T -- "$candidate" "$target"; then
      rm -- "$candidate"
      SWAP_CANDIDATE=''
      die 'Swap 目标已存在，未覆盖；请重新检查。'
    fi
    rm -- "$candidate"
    SWAP_CANDIDATE=''
    created=yes
  fi
  chmod 0600 -- "$target"
  write_managed_file "$unit_file" 0644 validate_swap_unit <<EOF
[Unit]
Description=host-init managed swap file

[Swap]
What=$target
TimeoutSec=30s

[Install]
WantedBy=swap.target
EOF
  previous=$FILE_PREVIOUS; changed=$FILE_CHANGED
  systemctl daemon-reload
  if ! systemctl enable --now "$SWAP_UNIT"; then
    active=$(swap_paths)
    if ! grep -Fxq "$target" <<< "$active"; then
      systemctl disable "$SWAP_UNIT" || true
      [[ "$changed" == no ]] || restore_file "$unit_file" "$previous" 0644
      systemctl daemon-reload
      [[ "$created" == no ]] || rm -- "$target"
      die 'Swap 启用失败，已恢复本次单元修改并清理本次创建的未启用文件。'
    fi
    die 'Swap 单元操作失败；文件已在使用中，保留文件以避免影响运行中的系统。'
  fi
  check_swap
}

check_swap() {
  ((SWAP_SIZE_MB > 0)) || return 0
  local target active
  target=$(root_path /var/lib/vps-init/swapfile)
  active=$(swap_paths)
  [[ -n "$active" ]] || die '配置要求 Swap，但当前没有启用的交换空间。'
  if [[ -e "$target" ]]; then
    grep -Fxq "$target" <<< "$active" || die '托管 Swap 文件存在但未启用。'
  fi
}
