# Debian 主机初始化

用于少量 Debian 12/13 主机的重装初始化，适用于 VPS、家庭服务器和 H81 等设备，要求 systemd 和正在运行的 `ssh.service`。所有机器使用同一个 Bash 入口和同一套模块；用户名、公钥、端口和安装选项由配置文件决定。

VPS 和家庭服务器只是两份配置示例，服务模块也可以在 VPS 上启用。当前支持 Debian 12/13，不根据硬件型号分支。[服务器初始化调研](docs/server-baseline.md)说明常见操作、默认选择和官方依据；[可选服务说明](docs/services.md)介绍 Syncthing、Nginx 和 Mihomo；从旧目录迁移请看[迁移说明](docs/migration.md)。

## 文件结构

```text
host-init/
├── setup.sh                    # 统一入口
├── .github/workflows/checks.yml # GitHub 上的 Debian 12/13 离线检查
├── configs/
│   ├── vps.example.conf        # VPS 配置示例
│   └── homelab.example.conf    # 家庭服务器配置示例
├── lib/common.sh               # 配置、预检、日志、备份、原子写入与软件源恢复
├── modules/system.sh           # 用户、公钥、时区、UFW、Fail2Ban
├── modules/docker.sh           # Docker 仓库、安装、配置与检查
├── modules/ssh.sh              # SSH 加固、新连接确认与自动回退
├── modules/security.sh         # 内核安全参数、日志上限与自动安全更新
├── modules/tools.sh            # 常用工具及额外软件包
├── modules/tailscale.sh        # Tailscale 官方源安装和状态检查
├── modules/services.sh         # Syncthing、Nginx、Mihomo
├── modules/host.sh             # 主机名、hosts、cloud-init 与默认 LANG
├── modules/time.sh             # 沿用已有时间服务或安装 timesyncd
├── modules/swap.sh             # 保留已有 Swap，按需创建并验证新文件
├── modules/maintenance.sh      # 性能记录、TRIM、诊断和备份工具、只读健康报告
├── docs/                       # 调研、备份恢复、可选服务、迁移与验收说明
└── tests/                      # 使用临时目录和模拟系统命令的回归测试
```

## 准备

推荐直接在目标主机克隆 [zmzm01/host-init](https://github.com/zmzm01/host-init)。下面在目标主机的 root 会话执行；使用自己的 fork 时替换地址，私有仓库需要先配置只读访问身份：

```bash
apt-get -o Acquire::Retries=3 --error-on=any update
apt-get install -y git ca-certificates
git clone https://github.com/zmzm01/host-init.git /opt/host-init
chmod -R go-w /opt/host-init
cd /opt/host-init
cp configs/vps.example.conf config.conf
# 家庭服务器改用：cp configs/homelab.example.conf config.conf
nano config.conf
# 设置 SSH_PUBLIC_KEY_FILE 为上传到服务器的公钥文件路径。
bash setup.sh plan
bash setup.sh doctor
bash setup.sh init
```

公钥仍需从客户端上传，私钥留在客户端。也可以把配置放到仓库之外，如 `/etc/host-init/config.conf`，后续每个命令使用同一个 `--config`。克隆只下载项目，`init` 才执行选中的安装操作。

### 尚未发布时手工上传

在自己的电脑上准备已有公钥，例如 `~/.ssh/id_ed25519.pub`。只上传 `.pub`，私钥保留在自己的电脑上。

```bash
# 在自己的电脑、项目的父目录执行，把完整项目和公钥上传到新主机。
scp -r "装机自动化" root@服务器IP:/root/
scp ~/.ssh/id_ed25519.pub root@服务器IP:/root/装机自动化/
```

在目标主机的 root 会话中执行：

```bash
cp -a /root/装机自动化 /opt/host-init
chown -R root:root /opt/host-init
chmod -R go-w /opt/host-init
cd /opt/host-init
cp configs/vps.example.conf config.conf
# 家庭服务器改用：cp configs/homelab.example.conf config.conf
nano config.conf
bash setup.sh plan
bash setup.sh doctor
bash setup.sh init
```

脚本和配置应由 root 控制写权限；它们将通过 sudo 执行。修改配置前可以再次运行 `plan`。配置是按字面读取的 `KEY=value`，不执行 Shell 表达式、不展开变量，不加引号和行尾注释。未知选项和重复定义均会报错，避免后面的值意外覆盖前面的选择。相对公钥路径以配置文件目录为基准。支持在公钥文件中放多条普通公钥。

默认配置始终是 `setup.sh` 所在目录的 `config.conf`，不受当前工作目录影响。配置示例需复制并编辑后再使用；每台机器只使用自己的一份完整配置，没有隐式叠加：

```bash
cp configs/homelab.example.conf configs/home.conf
nano configs/home.conf
# 公钥若放在项目根目录，将此配置中的 SSH_PUBLIC_KEY_FILE 改成 ../id_ed25519.pub。
bash setup.sh plan --config configs/home.conf
bash setup.sh doctor --config configs/home.conf
bash setup.sh init --config configs/home.conf
```

后续 `harden`、`confirm-ssh`、`check` 使用同一份 `--config`。本地配置和公钥已加入忽略规则；私钥应留在客户端。

两份示例均创建管理员 `ops`，导入公钥，设置上海时区和 C.UTF-8，配置 UFW、Fail2Ban、Docker、Tailscale、常用工具和系统安全配置，启用时间同步与 7 天性能记录。家庭服务器示例额外启用 Syncthing、定期 TRIM，并安装磁盘健康和 restic 备份工具；Nginx、Mihomo 在两份示例中默认关闭。主机名保留，Swap 默认不创建。

默认免密 sudo：该管理员拥有完整 root 权限，凭 SSH 公钥管理机器。若改成 `PASSWORDLESS_SUDO=no`，新用户需要在初始化时交互设置密码；已有用户须先设置密码。

全系统升级默认关闭，保留现有 APT 源和 SSH 端口。需要全系统升级可设置 `UPGRADE_PACKAGES=yes`。每次运行仍会安装或更新选中的软件包。

## 安装前检查

`plan` 可以在开发电脑上运行，显示配置并验证填写的公钥。`doctor` 在目标主机的 root 会话中运行，或使用：

```bash
sudo --preserve-env=SSH_CONNECTION bash /opt/host-init/setup.sh doctor \
  --config /opt/host-init/config.conf
```

它检查 Debian/systemd/SSH 是否符合要求、是否有待确认的 SSH 修改、是否存在未配置完成的软件包、公钥与管理员账户是否可用、实际 SSH 端口、所选 Docker/Tailscale 软件源冲突、主机名和字符集前提、已有时间服务、Swap 文件与空间、服务安装前提，并显示 `/`、`/var`、`/tmp` 的磁盘空间。除选中的 Swap 分配检查外，磁盘空间由你按所选软件和数据量判断，没有统一最低阈值。预检不更新软件源、不安装软件、不写日志或备份。Mihomo 只检查所需文件及权限，二进制的配置验证和下载连通性留到实际安装阶段。

`init` 使用同一套安装前检查。单独安装软件的命令也会检查 dpkg 状态；发现不完整状态时停止，先修复原有安装再重跑，不自动清理或重装未知软件包。

## 验证登录并加固 SSH

基础初始化不会关闭 root 或密码登录。保留原 root 会话，在自己的电脑新开一个终端，强制使用公钥认证，禁用连接复用：

```bash
ssh -i ~/.ssh/id_ed25519 \
  -o IdentitiesOnly=yes \
  -o PreferredAuthentications=publickey \
  -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
  -o ControlMaster=no -o ControlPath=none ops@服务器IP
```

如果服务器使用其他 SSH 端口，给 `ssh` 添加 `-p 端口`。在这个新管理员会话执行：

```bash
sudo -v
sudo --preserve-env=SSH_CONNECTION bash /opt/host-init/setup.sh harden \
  --config /opt/host-init/config.conf --confirm-key-login
```

`--confirm-key-login` 表示你已经完成上述客户端公钥验证。服务端仅靠公钥文件存在，无法证明客户端拥有对应私钥。加固会禁止 root、密码和键盘交互认证，要求公钥认证；先检查语法和生效配置，再重载 SSH。

**加固后有 5 分钟确认窗口。** 保留当前会话，再从自己的电脑运行同一条 `ssh` 命令，打开真正的新连接，在新连接执行：

```bash
sudo --preserve-env=SSH_CONNECTION bash /opt/host-init/setup.sh confirm-ssh \
  --config /opt/host-init/config.conf
sudo bash /opt/host-init/setup.sh check --config /opt/host-init/config.conf
```

确认前不要重启服务器。未确认时，systemd 定时任务会恢复此前的 SSH 配置并重载服务；该任务是临时任务，不跨服务器重启。旧连接不能取消回退。回退程序保存在 root 控制的 `/var/lib/vps-init/ssh-rollback.sh`，不依赖上传目录或配置文件。

若原有 `Include` 顺序或 `Match` 规则覆盖加固策略，检查会失败并立即恢复；需要先整合已有 SSH 配置。检查覆盖全局配置及当前连接对应的管理员和 root 配置，不能穷举所有自定义 `Match` 场景。脚本不修改云厂商安全组。

## 重跑、恢复与单独安装

```bash
sudo --preserve-env=SSH_CONNECTION bash /opt/host-init/setup.sh init --config /opt/host-init/config.conf
sudo bash /opt/host-init/setup.sh docker --config /opt/host-init/config.conf
sudo bash /opt/host-init/setup.sh services --config /opt/host-init/config.conf
sudo bash /opt/host-init/setup.sh host --config /opt/host-init/config.conf
sudo bash /opt/host-init/setup.sh maintenance --config /opt/host-init/config.conf
sudo bash /opt/host-init/setup.sh check --config /opt/host-init/config.conf
sudo bash /opt/host-init/setup.sh health --config /opt/host-init/config.conf
```

已有用户会保留；公钥按密钥内容去重，保留原有公钥；配置内容相同时不重复写入。`no` 表示跳过该模块，不卸载此前已安装的服务。中途失败会停止，可修复原因后重跑。整体安装不提供事务回滚，已安装的软件和用户会保留。

- 日志：`/var/log/vps-init/时间-进程号.log`。
- 修改前备份：`/var/backups/vps-init/时间-进程号/`，内部保持原始路径。
- SSH、sudo 和 Fail2Ban 配置校验失败时恢复本次修改；Docker、Fail2Ban 配置造成服务启动失败时也会恢复配置并尝试恢复服务。Fail2Ban 的 sshd jail 在启动后仍不可用时同样处理。
- APT 下载最多重试 3 次；索引更新启用严格错误处理，任何源更新失败都会停止，不悄悄使用旧索引继续安装。Docker/Tailscale 新增或修改的源与密钥在随后的索引验证失败时恢复。已经迁移的旧 Docker 源仍可从本次备份中手动恢复，软件包安装失败不回滚整次初始化。
- 软件包安装使用 `--no-remove`，拒绝为解决依赖而移除已有包；安装阶段的 needrestart 使用列表模式，软件包自己的安装脚本仍可能重启服务。更新完成后用 `sudo needrestart -r l` 检查并安排维护窗口。
- 显式设置主机名失败时恢复本次文件修改；timesyncd 上游配置造成重启失败时恢复配置；Swap 不自动停用、调整或覆盖已有交换文件。
- 运行锁保留 `/run/lock` 原有权限，安全创建只允许特权账户访问的普通锁文件，拒绝符号链接和不受保护的共享目录，不截断既有文件。
- SSH 回退结果：`journalctl -t vps-init`；定时任务状态：`systemctl status vps-init-ssh-rollback.timer`。
- UFW 放行实际 SSH 配置端口及当前连接端口，额外端口由 `ALLOW_TCP_PORTS`、`ALLOW_UDP_PORTS` 配置。规则以补齐为主，重跑不会删除以前允许的端口。
- 不自动卸载冲突的 Docker 软件包。检测到已有第三方 Docker 源会停止，先手动整合。旧 VPS 脚本生成的单一 `docker.list` 会备份并迁移到新的 deb822 源。
- 若旧脚本已生成 `/etc/fail2ban/jail.d/sshd.local`，请先修正其行尾注释，或备份后停用；已有配置会参与完整校验。

旧的分目录入口已合并为 `setup.sh` 的子命令，具体对应关系见[迁移说明](docs/migration.md)。主机端仍保留 `vps-init` 名称的托管配置、日志、备份和 SSH 回退状态，与之前版本兼容。

## Docker 配置与端口

Docker 使用官方 Debian 仓库，安装 Engine、Buildx 和 Compose 插件。默认通过 `sudo docker` 操作；`DOCKER_ADD_ADMIN_TO_GROUP=yes` 会授予管理员等同 root 的 Docker 权限，重新登录后生效。

保留现有 `daemon.json` 的镜像源等设置。使用默认 `json-file` 日志驱动时，补齐每个容器 10 MB × 3 个文件的日志轮转；已有轮转参数优先。daemon 配置变化才重启 Docker，重启可能影响运行中的容器；现有容器需要重建才能采用新的日志默认值。检查使用 `docker info` 和 `docker compose version`，不会每次拉取测试镜像。

**Docker 发布的端口可能绕过 UFW。** 内部服务建议绑定回环地址，再经反向代理对外访问，例如 Compose：

```yaml
ports:
  - "127.0.0.1:8080:80"
```

需要直接公开容器端口时，在云安全组或 Docker 对应的防火墙规则中控制访问。脚本不会通过关闭 Docker 的 iptables 管理来处理这个问题。

## 系统安全加固

`INSTALL_SECURITY_HARDENING=yes` 启用以下设置，可单独运行 `sudo bash setup.sh security`：

- 限制非特权账户读取内核指针和内核日志；启用硬链接/符号链接保护及 TCP SYN cookies，关闭 IPv4/IPv6 ICMP 重定向。覆盖 `all`、`default` 和已存在的网卡，支持带点的 VLAN 网卡名；仅写当前内核支持的参数。在选中的网络服务安装后应用，减少服务启动时重置网络参数的影响。
- 持久保存 systemd journal，磁盘日志上限 200 MB、内存日志上限 50 MB、最长保留一个月；UFW 使用 low 日志级别。
- 单独执行 SSH `harden` 时，追加 30 秒认证窗口、最多 3 次认证尝试，关闭 X11、空密码和用户环境设置，并检查生效配置。SSH 转发仍可用于管理隧道。

`ENABLE_UNATTENDED_UPGRADES=yes` 独立控制每日 Debian 安全仓库更新，默认关闭自动重启和自动删除未使用依赖。安全更新不自动升级 Docker、Tailscale 等第三方仓库的软件；这些服务按自己的维护窗口更新。更新可能重启受影响的服务，内核更新需要你择机重启。

这些设置不会更改 IP forwarding、rp_filter 或禁用 IPv6，兼顾 Docker 和 Tailscale 的路由需求。已有更晚加载的系统配置仍可能覆盖设置，`check` 会检查内核实际值。默认 journal 限额由本模块统一设置，已有特殊日志策略需先整合。

网卡参数按 [Linux 内核的重定向规则](https://kernel.org/doc/html/v6.1/networking/ip-sysctl.html)处理；带点的接口名使用 [sysctl 的斜杠路径格式](https://manpages.debian.org/bookworm/systemd/sysctl.d.5.en.html)。APT 严格错误模式在 [Debian 12](https://manpages.debian.org/bookworm/apt/apt-get.8.en.html)和 [Debian 13](https://manpages.debian.org/trixie/apt/apt-get.8.en.html)均有支持。

## 常用工具

`INSTALL_COMMON_TOOLS=yes` 安装编辑器、诊断和文件管理工具：

| 用途 | 工具 |
| --- | --- |
| 编辑和终端 | vim-tiny、nano、tmux、bash-completion |
| 系统与磁盘 | htop、ncdu、lsof、tree |
| 文件和开发 | git、rsync、wget、jq、ripgrep、fd-find |
| 归档压缩 | unzip、zip、zstd |
| 网络诊断 | dnsutils、iputils-ping、mtr-tiny、netcat-openbsd |

`EXTRA_PACKAGES=sqlite3 iperf3` 可添加普通 Debian 包名。关闭常用工具时，额外包仍会安装。单独运行：`sudo bash setup.sh tools`。Debian 的 fd-find 使用 `fdfind` 命令。

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

Swap 新文件仅支持 ext4/XFS；Btrfs 等需单独配置。定期 TRIM 可能在定时器启动后补跑错过的任务。磁盘工具不自动配置业务告警；安装备份工具也不等于已经备份数据。完整取舍见[调研说明](docs/server-baseline.md)，实际备份步骤见[备份与恢复](docs/backup.md)。

## Tailscale

`INSTALL_TAILSCALE=yes` 使用官方 Debian 稳定仓库和独立 Signed-By 密钥安装，启动 `tailscaled`。支持单独运行：

```bash
sudo bash setup.sh tailscale --config config.conf
sudo tailscale up
tailscale status
tailscale netcheck
```

首次 `tailscale up` 按提示完成账号登录和设备批准；安装过程不保存 auth key，也不重置已经登录的设备。默认不自动启用 Tailscale SSH、出口节点、子网路由或修改你的 DNS 接收偏好。

一般无需额外开放端口；需要改善直连时，可将 `TAILSCALE_UDP_PORT` 填为实际 tailscaled 监听端口（通常 41641），脚本只添加对应 UFW UDP 规则，不更改 daemon 监听参数。云安全组还需要自行放行。Tailscale 可能直接管理 netfilter 规则，tailnet 内访问应使用其访问策略控制，不能仅依赖 UFW。

参考：[官方 Debian 安装源](https://pkgs.tailscale.com/stable/)、[Tailscale Linux 登录](https://tailscale.com/docs/install/linux)、[Tailscale 防火墙](https://tailscale.com/docs/reference/faq/firewall-ports)、[Debian 自动更新配置](https://sources.debian.org/src/unattended-upgrades/2.12/README.md)。

## 验证

在开发机器运行，不需要 root，不会安装软件或修改真实 SSH、防火墙：

```bash
python3 -m unittest discover -s tests -v
```

测试使用临时目录和模拟系统命令，覆盖软件源与服务配置恢复、运行锁权限、逐网卡安全参数、主机名与时间配置恢复、Swap 保留与失败处理、维护定时器，以及复制项目后独立运行和只读预检/健康报告。少量测试用真实 mkswap、blkid 和 systemd 单元检查器验证临时文件，仍不启用真实 Swap。正式使用前，建议按[真机验收说明](docs/validation.md)在可重装的 Debian 12/13 测试主机上验证；离线测试无法验证真实的 SSH/systemd/UFW 行为。

上传到 GitHub 后，`Checks` 工作流在 push、pull request 或手工触发时，分别在 Debian 12/13 容器中检查 Bash 语法并运行这套离线回归。测试依赖只安装在 CI 容器，工作流不运行 `init`，不部署到服务器。第一次推送后在仓库 Actions 页面查看结果。

## GitHub 维护与服务器更新

源码、示例配置、文档和测试放进仓库。实际 `config.conf`、`configs/*.conf` 和 SSH 密钥已在忽略规则中；已有被跟踪的文件不会因添加忽略规则而自动移出仓库，首次推送前检查暂存清单。仓库的公开/私有选择、许可证和首次推送由仓库所有者决定。

后续由 Codex 在授权仓库中修改、测试和提交 PR，通过检查后合并。服务器更新代码时，在 root 会话执行：

```bash
cd /opt/host-init
git status --short
git pull --ff-only
bash setup.sh plan --config config.conf
bash setup.sh doctor --config config.conf
# 查看变更说明和计划后，再运行需要更新的模块或 init。
# SSH 登录策略仍按前面的新连接验证和确认流程单独处理。
```

更新前处理源码中的本地改动，避免与仓库修改冲突。`git pull` 只更新项目文件，不自动执行安装；重跑安装仍可能升级选中的软件包和重启受影响服务。已有配置不会自动补齐示例中的新字段，未填写的字段使用当前默认值，更新后应先查看 `plan`。较稳定的服务器可使用经验证的 tag/提交版本，而开发分支用于维护和测试。

参考：[Docker Debian 安装](https://docs.docker.com/engine/install/debian/)、[Docker 防火墙](https://docs.docker.com/engine/network/packet-filtering-firewalls/)、[Fail2Ban 配置](https://manpages.debian.org/trixie/fail2ban/jail.conf.5.en.html)、[sshd 校验选项](https://manpages.debian.org/trixie/openssh-server/sshd.8.en.html)。
