# 服务器初始化调研与项目取舍

调研日期：2026-10-05 至 2026-10-06。范围是少量 Debian 12/13 VPS、家庭服务器重装后的初始化，继续使用同一套模块化 Bash。下表结合 Debian 管理手册、发行版手册页和各项目官方文档，说明哪些操作已经自动化、哪些需要填写机器或业务信息。

| 常见操作 | 本项目的处理 | 默认选择 |
| --- | --- | --- |
| 系统身份、时区、字符集 | 时区已配置；新增可选主机名、保留 hosts 别名、cloud-init 主机名策略、默认 LANG | 主机名保留；示例使用 C.UTF-8 |
| 时间同步 | 新增沿用 Chrony/NTP 或安装 systemd-timesyncd，可指定 timesyncd 上游 | 启用，不开放 NTP 入站 |
| 软件包与安全更新 | 严格更新索引、检查 dpkg 状态、保留原源；每日 Debian 安全更新 | 全系统升级和自动重启关闭 |
| 管理账户、SSH 与防火墙 | 公钥、sudo、真实 SSH 端口、UFW、Fail2Ban、新 SSH 连接确认及超时回退 | 基础安装后单独验证并加固 SSH |
| 日志与磁盘占用 | journal 持久化、容量和时间限制；Docker 默认日志轮转；普通服务沿用包提供的轮转 | 启用已有安全模块 |
| 常用排障工具 | 终端、文件、网络工具；新增 sysstat、iotop-c、iftop、nethogs、needrestart | 性能工具开启 |
| 性能历史 | 新增 sysstat 定时采集，保留发行版其他配置，兼容 Debian 12/13 的定时器差异 | 保留 7 天，可设 1–365 天 |
| 内存余量 | 新增可选 Swap，沿用已有交换空间；新文件仅在 ext4/XFS 创建 | 关闭，按机器大小选择 |
| SSD 与磁盘健康 | 可选发行版 fstrim.timer；smartmontools、nvme-cli、lm-sensors | 家庭示例启用；VPS 示例关闭 |
| 数据备份与恢复演练 | 可选安装 restic，提供异地备份、检查和恢复流程 | 家庭示例装工具；仓库和计划自行配置 |
| Docker、组网与业务服务 | 已有 Docker、Tailscale、Syncthing、Nginx、Mihomo 模块 | 由配置选择 |
| 运行状态检查 | 新增只读 health：内存、磁盘与 inode、Swap、网卡、时间、失败服务和定时器 | 手动运行 |
| DNS、固定 IP、挂载、RAID、固件 | 需要实际网络、设备、文件系统和云平台信息，使用其原有配置流程 | 不用通用安装脚本猜测 |
| 业务备份、TLS、告警、重启窗口 | 需要域名、数据库、恢复目标、通知渠道或维护时间 | 业务上线时明确配置 |

这些默认值是针对本项目使用场景的选择；官方文档支持各功能和约束，并没有要求所有服务器开启同一组设置。Debian 管理手册将时间、日志和备份作为独立管理工作：[杂项系统配置](https://www.debian.org/doc/manuals/debian-handbook/sect.config-misc.en.html)、[备份策略](https://www.debian.org/doc/manuals/debian-handbook/sect.backup.en.html)。

## 主机名、字符集和时间

`SERVER_HOSTNAME=` 留空保持原名，填写时使用 `vps-01`、`home01` 这样的单段小写名称。脚本保留 `/etc/hosts` 原有别名，必要时增加本机解析；有 cloud-init 的机器增加本项目自己的 `preserve_hostname: true` 文件。设置失败会恢复本次改动并尝试恢复运行时名称。[systemd 主机名规则](https://manpages.debian.org/bookworm/systemd/hostname.5.en.html)、[cloud-init update-hostname](https://docs.cloud-init.io/en/latest/reference/modules.html#update-hostname)。

`SYSTEM_LOCALE=C.UTF-8` 设置新会话默认 LANG，使用英文消息并支持 UTF-8 文件名；保留原来的 LC_TIME 等分类设置，已有 LC_ALL 仍可能覆盖 LANG。留空保持原值，中文消息等其他 locale 需要另行生成并配置。[Debian locale 说明](https://www.debian.org/doc/manuals/debian-reference/ch08.en.html)。

兼容 Debian 12 的 `/etc/default/locale` 和 Debian 13 的 `/etc/locale.conf`。遇到系统标准的 `/etc/default/locale → /etc/locale.conf` 兼容链接时，保留链接，修改并备份实际配置文件；异常链接或非普通文件在预检阶段拒绝。[Debian 13 update-locale 手册](https://manpages.debian.org/trixie/locales/update-locale.8.en.html)。

时间同步关系到日志时间与跨机器排障。脚本优先沿用已安装的 Chrony、ntpsec、OpenNTPD 或 timesyncd，不卸载它们；没有服务时安装 timesyncd。如果发现多套或未识别的时间服务，预检停止，整合原配置或设 `ENABLE_TIME_SYNC=no`。[Debian 时间配置](https://wiki.debian.org/DateTime)。

`NTP_SERVERS=` 留空保持已有配置和发行版/DHCP 上游；非空仅用于 timesyncd，接受空格分隔的 DNS 名、IPv4 或纯 IPv6，不附端口、URL、作用域或 IPv4 嵌入形式。现有 Chrony 等请在它们原来的配置中修改上游。默认出站规则允许 NTP；客户端同步不需要开放 UDP 123 入站。首次启动可能尚未完成同步，脚本显示这一状态，稍后运行 `health` 查看。配置项和上游合并规则见 [timesyncd.conf](https://manpages.debian.org/bookworm/systemd-timesyncd/timesyncd.conf.5.en.html)。

## 性能记录与重启安排

`INSTALL_MONITORING_TOOLS=yes` 安装诊断工具；`ENABLE_SYSSTAT_HISTORY=yes` 独立控制 sysstat 定时记录。即使关闭其他性能工具，历史记录仍会按需安装 sysstat。Debian 12 启用 collect/summary 定时器；Debian 13 存在 rotate 定时器时一并启用。[Debian sysstat 配置](https://wiki.debian.org/sysstat)、[Debian 12 文件清单](https://packages.debian.org/bookworm/amd64/sysstat/filelist)、[Debian 13 文件清单](https://packages.debian.org/trixie/amd64/sysstat/filelist)。

初始化后常用命令：

```bash
sar -u                 # 当天 CPU 历史，采集一段时间后才有数据
sar -r                 # 内存历史
sar -n DEV             # 网卡历史
iostat -xz 1 5         # 磁盘负载
sudo iotop -o          # 当前产生 I/O 的进程
sudo iftop             # 当前流量；需要时用 -i 指定网卡
sudo needrestart -r l  # 列出需要重启的服务/内核，随后安排维护
```

安装阶段给 needrestart 设置列表模式，避免由其自动选择重启；APT 同时使用 `--no-remove`，拒绝通过移除已有包来满足依赖。软件包自己的安装脚本仍可能重启服务。自动安全更新保持独立策略，未因安装器的临时环境变量而被关闭。[needrestart 模式](https://manpages.debian.org/bookworm/needrestart/needrestart.1.en.html)、[APT no-remove](https://manpages.debian.org/bookworm/apt/apt-get.8.en.html)。

## Swap 与存储维护

`SWAP_SIZE_MB=0` 不管理 Swap；小内存机器可按容量、负载和磁盘情况设为 1024 或 2048 MiB，支持 128–32768 MiB。已有启用的 Swap 且没有本项目文件时，保留原配置；已有本项目文件则验证格式和大小，不重格式化、不在线扩缩容。新文件在基础包安装后、较大的选装软件之前准备，通过对应的 systemd swap 单元开机启用，不改 `/etc/fstab`。

自动创建仅限 ext4/XFS，并检查创建后至少还有 256 MiB 可用空间；这只是分配检查，业务数据需要更多余量。使用完整写零文件，避开空洞文件；Btrfs 有额外的 COW、设备和快照限制，应按其要求单独配置。未启用的本次新文件在服务启用失败时清理，已经在使用的文件保留。[swapon 文件约束](https://manpages.debian.org/bookworm/mount/swapon.8.en.html)、[systemd swap 单元](https://manpages.debian.org/bookworm/systemd/systemd.swap.5.en.html)、[Btrfs swap 约束](https://manpages.debian.org/trixie/btrfs-progs/btrfs.5.en.html)。

`ENABLE_FSTRIM=yes` 启用发行版的定期 TRIM。保留发行版周期，不修改分区；若定时器采用补跑策略，启动后可能补执行错过的任务。设备、虚拟化和存储后端决定是否支持 discard，先用 `lsblk -D` 查看，并遵循云平台或存储管理员策略。[fstrim 说明](https://manpages.debian.org/trixie/util-linux/fstrim.8.en.html)、[上游定时器](https://github.com/util-linux/util-linux/blob/master/sys-utils/fstrim.timer)。

家庭服务器选 `INSTALL_HARDWARE_TOOLS=yes` 后，可检查实际存在的硬件：

```bash
sudo smartctl --scan-open      # 列出可检查的设备
sudo smartctl -a /dev/sda      # 换成实际 SATA/SAS 设备
sudo nvme smart-log /dev/nvme0 # 仅适用于实际 NVMe 设备
sensors                       # 内核已提供的温度传感器
```

SMART/温度需要持续观察，工具安装不等于建立了告警。发行版包可能启动自己的 SMART 服务，具体磁盘、周期和通知地址仍需要配置。不自动进行全盘自检、传感器探测或硬件压力测试。

H81 等 Intel 实体机器还应确认 CPU 微码和实际需要的固件。`intel-microcode` 位于 `non-free-firmware`；确认 CPU 和原 APT 组件后，可加到 `EXTRA_PACKAGES`。脚本不会为此重写系统源，也不在 VPS 上猜测宿主机微码需求。[Debian Intel 微码包](https://packages.debian.org/bookworm/intel-microcode)。

## 备份与上线后工作

安装 restic 后按[备份与恢复流程](backup.md)配置仓库并完成一次恢复演练。Syncthing 是同步服务，删除和错误修改也会影响其他设备；需要另行设计备份保留。日志和初始化配置备份用于恢复配置，不能代替业务数据备份。

需要固定 IP、数据盘挂载或磁盘阵列时，先确认云镜像/家庭路由网络和实际设备；业务上线后再配置域名、TLS、数据库一致性备份、监控通知及重启窗口。它们需要机器或业务信息，本项目保持可复用的主机基础安装，不默认套用 BBR、DNS 替换、端口改号或磁盘重分区。
