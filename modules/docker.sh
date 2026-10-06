#!/usr/bin/env bash

docker_preflight() {
  local pkg status file
  for pkg in docker.io docker-compose docker-doc docker-buildx podman-docker containerd runc; do
    status=$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)
    [[ "$status" != 'install ok installed' ]] || die "检测到冲突包 $pkg；请先确认现有服务及数据，再手动卸载。"
  done
  case "$(dpkg --print-architecture)" in
    amd64|arm64|armhf|ppc64el) ;;
    *) die '当前架构不在支持的 Docker 官方包架构列表内。' ;;
  esac
  # Only the old script's single-purpose docker.list is migrated automatically.
  LEGACY_DOCKER_LIST=''
  local sources=()
  shopt -s nullglob
  sources=("$(root_path /etc/apt/sources.list.d)"/*.list "$(root_path /etc/apt/sources.list.d)"/*.sources)
  shopt -u nullglob
  [[ ! -f "$(root_path /etc/apt/sources.list)" ]] || sources+=("$(root_path /etc/apt/sources.list)")
  for file in "${sources[@]}"; do
    grep -Eq '^[[:space:]]*[^#[:space:]].*download\.docker\.com/linux/(debian|ubuntu)' "$file" || continue
    [[ "$file" != "$(root_path /etc/apt/sources.list.d/vps-init-docker.sources)" ]] || continue
    if [[ "$file" == "$(root_path /etc/apt/sources.list.d/docker.list)" ]] && \
      awk 'NF && $1 !~ /^#/ && !($1 == "deb" && /https:\/\/download\.docker\.com\/linux\/debian/ && (/signed-by=\/usr\/share\/keyrings\/docker-archive-keyring.gpg/ || /signed-by=\/etc\/apt\/keyrings\/docker.asc/)) {bad=1} END {exit bad}' "$file"; then
      [[ ! -L "$file" ]] || die "旧 Docker 源是符号链接：$file"
      LEGACY_DOCKER_LIST=$file
    else
      die "检测到其他 Docker 软件源：$file。请手动整合或停用，避免重复源和 Signed-By 冲突。"
    fi
  done
}

validate_docker_config() { dockerd --validate --config-file "$1"; }

docker_log_config() {
  # Preserve registry mirrors and other existing daemon settings.
  python3 - "$1" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text()) if path.exists() else {}
if not isinstance(data, dict):
    raise ValueError('daemon.json must contain a JSON object')
if data.get('log-driver', 'json-file') == 'json-file':
    options = data.setdefault('log-opts', {})
    if not isinstance(options, dict):
        raise ValueError('log-opts must contain a JSON object')
    options.setdefault('max-size', '10m')
    options.setdefault('max-file', '3')
print(json.dumps(data, indent=2, sort_keys=True))
PY
}

migrate_legacy_docker_source() {
  # Migrate before apt update, which can otherwise fail on the old repository.
  if [[ -n "$LEGACY_DOCKER_LIST" ]]; then
    backup_file "$LEGACY_DOCKER_LIST"
    rm -- "$LEGACY_DOCKER_LIST"
    LEGACY_DOCKER_LIST=''
    log '已备份并迁移旧脚本的 Docker 软件源。'
  fi
}

install_docker() {
  step '安装 Docker 官方 Debian 软件包'
  migrate_legacy_docker_source
  apt_update
  apt_install ca-certificates curl gnupg python3
  local key_file repo_file daemon_file previous changed
  key_file=$(root_path /etc/apt/keyrings/vps-init-docker.asc)
  repo_file=$(root_path /etc/apt/sources.list.d/vps-init-docker.sources)
  curl --fail --silent --show-error --location --retry 3 --connect-timeout 10 --max-time 120 \
    https://download.docker.com/linux/debian/gpg -o "$WORK_DIR/docker.asc"
  install -d -m 0700 "$WORK_DIR/gnupg"
  gpg --batch --homedir "$WORK_DIR/gnupg" --show-keys "$WORK_DIR/docker.asc" >/dev/null
  write_apt_repository "$key_file" "$repo_file" "$WORK_DIR/docker.asc" <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $VERSION_CODENAME
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/vps-init-docker.asc
EOF
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  daemon_file=$(root_path /etc/docker/daemon.json)
  [[ ! -L "$daemon_file" ]] || die '拒绝覆盖作为符号链接的 daemon.json。'
  docker_log_config "$daemon_file" > "$WORK_DIR/daemon.json"
  write_managed_file "$daemon_file" 0644 validate_docker_config < "$WORK_DIR/daemon.json"
  previous=$FILE_PREVIOUS; changed=$FILE_CHANGED
  systemctl enable docker.service containerd.service
  if [[ "$changed" == yes ]]; then
    if ! systemctl restart docker.service; then
      restore_file "$daemon_file" "$previous" 0644
      systemctl restart docker.service || true
      die 'Docker 启动失败，已恢复本次 daemon.json 修改。'
    fi
  else
    systemctl start docker.service
  fi
  if [[ "$DOCKER_ADD_ADMIN_TO_GROUP" == yes ]]; then
    getent passwd "$ADMIN_USER" >/dev/null || die '请先初始化管理员账户，再授予 Docker 组权限。'
    usermod -aG docker "$ADMIN_USER"
    log '已授予管理员 docker 组权限；重新登录后生效。'
  fi
  check_docker
  log 'Docker 发布端口需单独控制；建议内部服务绑定 127.0.0.1，再经反向代理访问。'
}

check_docker() {
  step '检查 Docker 服务和 Compose 插件'
  systemctl is-active --quiet docker.service
  docker info --format 'Docker {{.ServerVersion}}；日志驱动 {{.LoggingDriver}}'
  docker compose version
}
