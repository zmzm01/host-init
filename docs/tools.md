# 常用工具与主机维护

[返回首页](../README.md) · [配置参考](configuration.md) · [排错与维护](operations.md)

## 常用工具

`INSTALL_COMMON_TOOLS=yes` 安装编辑器、诊断和文件管理工具：

| 用途 | 工具 |
| --- | --- |
| 编辑和终端 | vim-tiny、nano、Zellij、bash-completion |
| 系统与磁盘 | htop、ncdu、lsof、tree |
| 文件和开发 | git、rsync、wget、jq、ripgrep、fd-find |
| 归档压缩 | unzip、zip、zstd |
| 网络诊断 | bind9-dnsutils（dig、nslookup）、iputils-ping、mtr-tiny、netcat-openbsd |

`EXTRA_PACKAGES=sqlite3 iperf3` 可添加普通 Debian 包名。关闭常用工具时，额外包仍会安装。单独运行：`sudo bash setup.sh tools`。Debian 的 fd-find 使用 `fdfind` 命令。

终端复用工具默认 `TERMINAL_MULTIPLEXER=zellij`，也可设为 `tmux` 或 `none`。Zellij 从官方 GitHub Release 安装固定的 **0.45.1** 预编译版本，支持 Debian amd64/arm64；下载前检查架构，下载后核对项目内固定的官方 SHA-256，验证版本后原子安装到 `/usr/local/bin/zellij`。已有同版本直接沿用，更新其他版本前保存原程序。不会编译 Rust、改 Shell 启动文件或覆盖用户的 Zellij 配置。[官方安装方式](https://zellij.dev/documentation/installation.html)、[固定版本与发布校验值](https://github.com/zellij-org/zellij/releases/expanded_assets/v0.45.1)。

旧配置没有该字段时也默认 Zellij；关闭常用工具会一并跳过终端工具。已经安装的 tmux 保留，仍可继续使用。已有服务器更新安装器后，只需更新常用工具：

```bash
cd /opt/host-init
sudo git pull --ff-only
# 确认 config.conf 的 INSTALL_COMMON_TOOLS=yes；可明确添加 TERMINAL_MULTIPLEXER=zellij。
sudo bash setup.sh tools --config config.conf
# 在管理员会话中启动：
zellij
```

固定版本升级由本项目更新版本和两种架构的校验值，不会每次安装自动追踪 latest。已有其他安装位置的 Zellij 会保留；若启动的仍是旧版本，用 `command -v zellij` 检查 PATH 优先级。

## 主机与维护配置

| 选项 | 作用与默认值 |
| --- | --- |
| `SERVER_HOSTNAME=` | 保留原主机名；填写时同步主机名和 hosts，有 cloud-init 时保留显式选择 |
| `SYSTEM_LOCALE=` | 留空保留；示例为 `C.UTF-8`，只设置默认 LANG |
| `ENABLE_TIME_SYNC=yes` | 沿用已有 Chrony/NTP 服务，没有时安装 systemd-timesyncd |
| `NTP_SERVERS=` | 空格分隔的 DNS/IPv4/纯 IPv6；留空沿用上游，非空仅用于 timesyncd |
| `SWAP_SIZE_MB=0` | 默认跳过；可选 128–32768 MiB，已有 Swap 保留，不自动扩缩容 |
| `INSTALL_MONITORING_TOOLS=yes` | sysstat、iotop-c、iftop、nethogs、needrestart |
| `ENABLE_SYSSTAT_HISTORY=yes` | 独立启用 sysstat 性能历史；`SYSSTAT_HISTORY_DAYS=7`，范围 1–365 |
| `ENABLE_FSTRIM=no` | 按需启用发行版定期 TRIM；家庭示例为 yes |
| `INSTALL_BACKUP_TOOLS=no` | 安装 restic；家庭示例为 yes，仓库和计划另行配置 |
| `INSTALL_HARDWARE_TOOLS=no` | smartmontools、nvme-cli、lm-sensors；家庭示例为 yes |

`host` 单独设置主机名、字符集和时间服务；时区在 `init` 设置。`maintenance` 安装维护工具并配置所选的性能历史、TRIM 和 Swap。`health` 只读显示资源、磁盘/inode、Swap、网卡、时间同步、失败服务和维护定时器，不安装软件或写安装日志；与其他主机命令一样，使用已有配置，并要求 root、Debian 12/13、systemd 和可用 SSH 服务。

旧配置没有这些字段时，默认新增时间同步、性能工具和 7 天历史记录，主机名和字符集保留，Swap/TRIM/硬件/备份工具跳过。`no` 或空值跳过相关设置，不自动撤销之前启用的功能或清除以前的上游。

Swap 新文件仅支持 ext4/XFS；Btrfs 等需单独配置。定期 TRIM 可能在定时器启动后补跑错过的任务。磁盘工具不自动配置业务告警；安装备份工具也不等于已经备份数据。完整取舍见[调研说明](server-baseline.md)，实际备份步骤见[备份与恢复](backup.md)。
