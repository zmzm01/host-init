#!/usr/bin/env bash

locale_config_file() {
  local legacy canonical target
  legacy=$(root_path /etc/default/locale)
  canonical=$(root_path /etc/locale.conf)
  if [[ -L "$legacy" ]]; then
    # Debian 13 keeps this compatibility link; never follow arbitrary links.
    case "$(readlink "$legacy")" in
      ../locale.conf|/etc/locale.conf) target=$canonical ;;
      *) die "字符集配置链接目标异常：$legacy" ;;
    esac
  elif [[ -e "$legacy" ]]; then
    target=$legacy
  elif [[ -e "$canonical" || -L "$canonical" || "${VERSION_ID:-}" == 13 ]]; then
    target=$canonical
  else
    target=$legacy
  fi
  [[ ! -L "$target" && ( ! -e "$target" || -f "$target" ) ]] || die "字符集配置不是普通文件：$target"
  printf '%s\n' "$target"
}

host_preflight() {
  if [[ -n "$SERVER_HOSTNAME" ]]; then
    local target
    for target in /etc/hostname /etc/hosts /etc/cloud/cloud.cfg.d/99-vps-init-hostname.cfg; do
      target=$(root_path "$target")
      [[ ! -L "$target" && ( ! -e "$target" || -f "$target" ) ]] || die "主机名配置不是普通文件：$target"
    done
  fi
  if [[ -n "$SYSTEM_LOCALE" ]]; then
    local locale_file
    locale_file=$(locale_config_file)
    [[ "$(LC_ALL=C.UTF-8 locale charmap)" == UTF-8 ]] || die '系统缺少 C.UTF-8 locale。'
  fi
}

hostname_hosts_config() {
  python3 - "$1" "$SERVER_HOSTNAME" <<'PY'
import pathlib
import sys

path, name = sys.argv[1:]
file = pathlib.Path(path)
lines = file.read_text().splitlines() if file.exists() else []
if any(name in line.split('#', 1)[0].split()[1:] for line in lines):
    print('\n'.join(lines))
    raise SystemExit(0)
for index, line in enumerate(lines):
    entry, mark, comment = line.partition('#')
    if entry.split()[:1] == ['127.0.1.1']:
        lines[index] = entry.rstrip() + ' ' + name + (' #' + comment if mark else '')
        break
else:
    lines.append('127.0.1.1\t' + name)
print('\n'.join(lines))
PY
}

configure_hostname() {
  [[ -n "$SERVER_HOSTNAME" ]] || return 0
  step "设置主机名 $SERVER_HOSTNAME，保留现有 hosts 别名"
  local host_file hosts_file cloud_file old_runtime
  local host_previous hosts_previous cloud_previous='' host_changed hosts_changed cloud_changed=no
  host_file=$(root_path /etc/hostname); hosts_file=$(root_path /etc/hosts)
  cloud_file=$(root_path /etc/cloud/cloud.cfg.d/99-vps-init-hostname.cfg)
  old_runtime=$(uname -n)
  hostname_hosts_config "$hosts_file" > "$WORK_DIR/hosts"
  write_managed_file "$hosts_file" 0644 < "$WORK_DIR/hosts"
  hosts_previous=$FILE_PREVIOUS; hosts_changed=$FILE_CHANGED
  write_managed_file "$host_file" 0644 <<< "$SERVER_HOSTNAME"
  host_previous=$FILE_PREVIOUS; host_changed=$FILE_CHANGED
  if [[ -f "$(root_path /etc/cloud/cloud.cfg)" ]]; then
    write_managed_file "$cloud_file" 0644 <<< 'preserve_hostname: true'
    cloud_previous=$FILE_PREVIOUS; cloud_changed=$FILE_CHANGED
  fi
  if ! hostnamectl --static --transient set-hostname "$SERVER_HOSTNAME"; then
    [[ "$host_changed" == no ]] || restore_file "$host_file" "$host_previous" 0644
    [[ "$hosts_changed" == no ]] || restore_file "$hosts_file" "$hosts_previous" 0644
    [[ "$cloud_changed" == no ]] || restore_file "$cloud_file" "$cloud_previous" 0644
    hostnamectl --transient set-hostname "$old_runtime" || true
    die '主机名设置失败，已恢复本次文件修改并尝试恢复运行时名称。'
  fi
}

configure_host() {
  local locale_file=''
  if [[ -n "$SYSTEM_LOCALE" ]]; then
    locale_file=$(locale_config_file)
  fi
  configure_hostname
  if [[ -n "$SYSTEM_LOCALE" ]]; then
    step '设置默认 LANG 为 C.UTF-8，保留其他 locale 分类'
    update_config_assignment "$locale_file" LANG '"C.UTF-8"'
    log '字符集配置在新的登录会话中生效。'
  fi
}

check_host() {
  [[ -z "$SERVER_HOSTNAME" || "$(hostnamectl --static)" == "$SERVER_HOSTNAME" ]] || die '静态主机名与配置不一致。'
  if [[ -n "$SYSTEM_LOCALE" ]]; then
    local locale_file
    locale_file=$(locale_config_file)
    grep -Fxq 'LANG="C.UTF-8"' "$locale_file" || die '默认 LANG 尚未配置。'
  fi
}
