# 配置参考

[返回首页](../README.md) · [排错与维护](operations.md) · [工具与主机维护](tools.md)

## 选用和保存配置

从 `configs/vps.example.conf` 或 `configs/homelab.example.conf` 复制一份完整配置，按主机修改。两份示例只是起点，任何支持的机器都可以启用同一套模块，不按 VPS/H81 型号分支。

| 示例选择 | 共同设置 | 额外设置 |
| --- | --- | --- |
| VPS | `ops` 管理员、公钥、上海时区、C.UTF-8、Docker、Tailscale、Zellij、Fail2Ban、系统加固、安全更新、时间同步、7 天性能记录 | 默认不启用业务服务、TRIM、硬件和备份工具 |
| 家庭服务器 | 与 VPS 共享基础设置 | Syncthing 专用账户、定期 TRIM、硬件诊断和 restic 工具 |

两份示例都保留主机名，不创建 Swap，不做全系统升级；Nginx、Mihomo 默认关闭。配置可以放在项目根目录的 `config.conf`，也可以放在仓库外：

```bash
# 目标服务器的 root 会话；公钥已上传到 /root/id_ed25519.pub。
install -d -m 0700 /etc/host-init
cp /opt/host-init/configs/vps.example.conf /etc/host-init/config.conf
chmod 0600 /etc/host-init/config.conf
nano /etc/host-init/config.conf
# 将 SSH_PUBLIC_KEY_FILE 设置成 /root/id_ed25519.pub。
bash /opt/host-init/setup.sh plan --config /etc/host-init/config.conf
```

后续每个命令都使用同一份 `--config`。代码、配置及公钥应由 root 控制写权限。实际配置和密钥不提交到 Git；本项目忽略 `config.conf`、`configs/*.conf`（保留示例）及常见密钥文件，放在其他路径的文件需要自行确认。

## 格式和路径规则

配置是字面 `KEY=value`，不执行 Shell，也不展开变量。不要加引号、行尾注释、`~` 或 `$HOME`。注释放在单独一行；同一个键只能定义一次，未知键会报错。

```ini
# 正确：多值使用空格分隔，路径写明确地址。
SSH_PUBLIC_KEY_FILE=/root/id_ed25519.pub
EXTRA_PACKAGES=sqlite3 iperf3
ALLOW_TCP_PORTS=80 443
SERVER_HOSTNAME=
```

- 省略 `--config`：读取 `setup.sh` 同目录的 `config.conf`，与当前工作目录无关。
- `--config configs/home.conf`：按当前工作目录解析配置路径。
- `SSH_PUBLIC_KEY_FILE=../id_ed25519.pub`：按配置文件所在目录解析公钥路径。
- 公钥文件支持多条普通公钥，不接受私钥或带 `authorized_keys` 限制选项的条目。
- `no` 或留空只跳过对应操作，不自动卸载、删除规则或恢复此前的配置。

缺失字段使用脚本默认值，并非示例默认值。例如脚本缺省时区是 `UTC`，缺省 `SYSTEM_LOCALE` 留空；两份示例则明确选择上海时区和 C.UTF-8。升级代码后先运行 `plan` 检查当前默认值。

## 账户与安装

以下默认值指脚本缺省值；示例中的不同选择另行注明。

| 选项 | 缺省值 | 用法 |
| --- | --- | --- |
| `ADMIN_USER` | `ops` | 普通管理员用户名，不能是 root |
| `SSH_PUBLIC_KEY_FILE` | 空，初始化时必填 | 上传的公钥文件；私钥留在客户端 |
| `PASSWORDLESS_SUDO` | `yes` | 管理员拥有完整 root 权限；设为 no 时新用户交互设置密码，已有用户须先有密码 |
| `TIMEZONE` | `UTC` | 时区名；示例为 `Asia/Shanghai` |
| `UPGRADE_PACKAGES` | `no` | 是否进行全系统升级；关闭后仍会安装或更新选中的包 |
| `INSTALL_DOCKER` | `yes` | 安装 Docker Engine、Buildx、Compose 插件 |
| `DOCKER_ADD_ADMIN_TO_GROUP` | `no` | yes 授予等同 root 的 Docker 权限，重新登录生效 |
| `INSTALL_COMMON_TOOLS` | `yes` | 常用编辑、网络及文件工具 |
| `TERMINAL_MULTIPLEXER` | `zellij` | `zellij`、`tmux` 或 `none`；随常用工具开关生效 |
| `EXTRA_PACKAGES` | 空 | 空格分隔的普通 Debian 包名；关闭常用工具时仍处理 |

错误工具包名会跳过并警告，结束时汇总；其他 APT 和关键配置错误仍停止。详细规则见[排错与维护](operations.md)。Zellij 固定版本和架构支持见[工具说明](tools.md)。

## 安全与网络

| 选项 | 缺省值 | 用法 |
| --- | --- | --- |
| `INSTALL_FAIL2BAN` | `yes` | 安装并配置 SSH jail |
| `INSTALL_SECURITY_HARDENING` | `yes` | 内核安全参数及 journal 限额；SSH 禁用密码另行执行 harden |
| `ENABLE_UNATTENDED_UPGRADES` | `yes` | 每日 Debian 安全更新，不自动重启或升级第三方仓库 |
| `ALLOW_TCP_PORTS` | 空 | 额外 TCP 入站端口，空格分隔，例如 `80 443` |
| `ALLOW_UDP_PORTS` | 空 | 额外 UDP 入站端口，空格分隔 |
| `INSTALL_TAILSCALE` | `yes` | 安装并启动 tailscaled；首次登录自行执行 tailscale up |
| `TAILSCALE_UDP_PORT` | 空 | 可选实际监听端口，常见为 `41641`；只添加 UFW 规则 |

端口范围为 1–65535。实际 SSH 端口自动放行，重跑只补齐规则，不删除已有规则。云安全组由你管理；Docker 发布端口和 Tailscale 访问策略的边界见[安全说明](security.md)。

## 主机、时间与存储

| 选项 | 缺省值 | 用法 |
| --- | --- | --- |
| `SERVER_HOSTNAME` | 空 | 保留原名；设置时为 1–63 位小写字母、数字或连字符的单段名称，不能是 localhost |
| `SYSTEM_LOCALE` | 空 | 保留原值；仅支持 `C.UTF-8`，示例启用；保留其他 LC_* 分类 |
| `ENABLE_TIME_SYNC` | `yes` | 沿用已有时间服务；没有时安装 timesyncd |
| `NTP_SERVERS` | 空 | 空格分隔的 DNS/IPv4/纯 IPv6，非空只用于 timesyncd，不能带端口或 URL |
| `SWAP_SIZE_MB` | `0` | 不创建；可选 128–32768 MiB；已有 Swap 保留，新文件仅支持 ext4/XFS |
| `INSTALL_MONITORING_TOOLS` | `yes` | sysstat、iotop-c、iftop、nethogs、needrestart |
| `ENABLE_SYSSTAT_HISTORY` | `yes` | 独立启用性能历史，即使关闭其他性能工具也会安装 sysstat |
| `SYSSTAT_HISTORY_DAYS` | `7` | 范围 1–365 |
| `ENABLE_FSTRIM` | `no` | 启用发行版定期 TRIM；家庭示例为 yes |
| `INSTALL_BACKUP_TOOLS` | `no` | 安装 restic；家庭示例为 yes，备份仓库和计划自行设置 |
| `INSTALL_HARDWARE_TOOLS` | `no` | smartmontools、nvme-cli、lm-sensors；家庭示例为 yes |

Debian 13 标准 locale 兼容链接会保留，写入实际 `/etc/locale.conf`；异常链接仍拒绝。已有 Chrony 等服务的自定义上游应在原配置中调整。Swap 大小不会在线扩缩容。详细取舍见[服务器初始化调研](server-baseline.md)，业务备份见[备份与恢复](backup.md)。

## 可选服务

| 选项 | 缺省值 | 用法 |
| --- | --- | --- |
| `INSTALL_SYNCTHING` | `no` | 家庭示例为 yes |
| `SYNCTHING_USER` | 跟随 `ADMIN_USER` | 两份示例均指定 `syncthing`；旧机器应沿用原服务账户 |
| `INSTALL_NGINX` | `no` | 安装服务，站点、域名和 TLS 自行配置 |
| `INSTALL_MIHOMO` | `no` | 使用自己准备的可信二进制和配置，不自动下载 |
| `SERVICE_LAN_CIDR` | 空 | 实际 RFC1918 IPv4 网段，如 `192.168.1.0/24`，限制服务端口来源 |
| `MIHOMO_DIR` | `/opt/mihomo` | `/opt` 下的目录，需提前放置二进制和配置 |

账户权限、数据目录、同步端口和代理运行约束见[可选服务](services.md)。
