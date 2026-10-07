# host-init：Debian 主机初始化

为少量 Debian 12/13 VPS 和家庭服务器提供重装后的一键初始化。使用模块化 Bash，同一入口支持 H81 等实体设备；通过一份配置选择账户、公钥、工具、安全设置和服务。

需要运行中的 systemd 与 `ssh.service`。基础安装保留原 SSH 登录方式，确认新管理员公钥可用后，再单独加固 SSH。常用工具包名错误会记录警告并继续；关键系统错误会停止并提示日志位置。

## 文档导航

| 要做的事 | 文档 |
| --- | --- |
| 第一次安装 | 本页的快速开始 |
| 选择功能、修改配置、了解默认值 | [配置参考](docs/configuration.md) |
| 验证公钥登录、加固 SSH、了解 Docker/Tailscale 网络 | [安全与 SSH 加固](docs/security.md) |
| 查日志、处理警告、失败后重跑、更新代码 | [排错与维护](docs/operations.md) |
| 使用 Zellij、性能工具、主机和存储维护 | [工具与主机维护](docs/tools.md) |
| 配置 Syncthing、Nginx、Mihomo | [可选服务](docs/services.md) |
| 建立业务备份并演练恢复 | [备份与恢复](docs/backup.md) |
| 了解服务器初始化的取舍和依据 | [初始化调研](docs/server-baseline.md) |
| 从旧 VPS/H81 目录迁移 | [迁移说明](docs/migration.md) |
| 在真实 Debian 12/13 上验证 | [真机验收](docs/validation.md) |

## 快速开始

### 1. 上传自己的公钥

在**自己的电脑**执行，替换服务器地址；非默认 SSH 端口给 `scp` 加 `-P 端口`：

```bash
scp ~/.ssh/id_ed25519.pub root@服务器IP:/root/id_ed25519.pub
```

只上传 `.pub`，私钥留在客户端。若使用的密钥不同，替换本地公钥路径。

### 2. 克隆并准备配置

在**目标服务器的 root SSH 会话**执行：

```bash
apt-get -o Acquire::Retries=3 --error-on=any update
apt-get install -y git ca-certificates nano
git clone https://github.com/zmzm01/host-init.git /opt/host-init
chmod -R go-w /opt/host-init
cd /opt/host-init
cp configs/vps.example.conf config.conf
# 家庭服务器改用：cp configs/homelab.example.conf config.conf
chmod 0600 config.conf
nano config.conf
```

把配置中的公钥路径改为已上传的位置：

```ini
SSH_PUBLIC_KEY_FILE=/root/id_ed25519.pub
```

配置按字面读取，不加引号、不写行尾注释、不展开变量。两份示例默认创建 `ops` 管理员，安装 Docker、Tailscale、Zellij，并启用安全更新、时间同步和性能记录；家庭示例另启用 Syncthing、TRIM、硬件与备份工具。按实际需要调整，完整选项见[配置参考](docs/configuration.md)。

脚本及配置应由 root 控制写权限。已有项目或配置时直接沿用，勿重新克隆到同一目录或用示例覆盖自己的配置。也可以[将配置放在仓库外](docs/configuration.md#选用和保存配置)。

### 3. 检查计划并安装

继续在**目标服务器的 root SSH 会话**执行：

```bash
bash setup.sh plan --config config.conf
bash setup.sh doctor --config config.conf
bash setup.sh init --config config.conf
```

`plan` 展示选项并验证填写的公钥；`doctor` 检查系统、SSH、软件包状态和配置冲突，不安装软件。预检不验证所有下载连通性，实际安装时仍可能遇到网络或软件源问题。

安装结束检查警告汇总。错误工具包名会跳过，其他模块继续；APT 下载、依赖或实际安装失败仍会停止。日志在 `/var/log/vps-init/`，配置备份在 `/var/backups/vps-init/`。处理方法见[排错与维护](docs/operations.md)。

### 4. 验证新登录，再加固 SSH

保留原 root 会话，按[公钥验证及 SSH 加固步骤](docs/security.md#验证登录并加固-ssh)完成：新管理员公钥登录 → 验证 sudo → `harden` → 再建新连接 → `confirm-ssh`。

**加固后只有 5 分钟确认窗口，确认前不要重启。** 未确认时自动恢复原 SSH 配置；普通旧连接不能取消回退。

安装 Tailscale 后自行执行 `sudo tailscale up` 登录。Zellij 在管理员会话运行 `zellij`。安装 restic 只提供工具，业务备份仍需按[备份流程](docs/backup.md)配置和验证。

## 命令速查

所有执行命令使用同一份配置。除 `plan` 外需在目标 Debian 主机运行并拥有 root 权限；`help` 不需要配置。管理员通过 sudo 执行 `doctor`、`init`、`harden`、`confirm-ssh` 时保留 `SSH_CONNECTION`：

```bash
sudo --preserve-env=SSH_CONNECTION bash /opt/host-init/setup.sh doctor \
  --config /opt/host-init/config.conf
```

| 命令 | 用途 |
| --- | --- |
| `help` | 查看用法 |
| `plan` | 查看选择和公钥，不修改系统 |
| `doctor` | 安装前预检，不修改系统或写日志 |
| `init` | 执行基础初始化及选中的模块 |
| `tools` | 常用工具、终端工具和额外软件包 |
| `docker` / `tailscale` / `services` | 单独安装对应模块 |
| `host` | 主机名、默认 LANG 和时间同步；时区在 init 设置 |
| `maintenance` | 维护工具、性能历史、TRIM 和 Swap |
| `security` | 内核安全参数、journal 及选中的安全更新 |
| `harden --confirm-key-login` | 验证新管理员登录后加固 SSH |
| `confirm-ssh` | 在加固后的真正新连接中取消回退 |
| `check` | 检查账户、SSH、防火墙、工具和选中的服务；缺失工具为警告 |
| `health` | 只读资源与服务报告，不写安装日志 |

`no` 或留空表示跳过，不卸载或撤销之前的选择。整体安装不是事务，失败不会撤销此前所有操作；修复原因后可以用同一配置重跑。

## 更新项目

在目标服务器的管理员 SSH 会话运行；项目和配置由 root 管理，因此更新代码也使用 sudo：

```bash
cd /opt/host-init
sudo git status --short
sudo git pull --ff-only
sudo bash setup.sh plan --config config.conf
sudo --preserve-env=SSH_CONNECTION bash setup.sh doctor --config config.conf
# 确认计划后运行需要更新的模块，例如：
sudo bash setup.sh tools --config config.conf
```

拉取代码不会自动安装。缺失的新配置字段使用当前默认值，重跑仍可能升级软件或重启服务。先处理源码的本地改动，并沿用自己的配置；完整流程见[维护说明](docs/operations.md#更新代码与重跑)。

## 项目结构与验证

```text
setup.sh       统一命令入口
configs/       VPS 与家庭服务器的配置示例
lib/           配置解析、日志、备份、锁和通用写入
modules/       账户、SSH、安全、工具、服务、主机及维护功能
docs/          使用、配置、排错、调研与验收文档
tests/         临时目录和模拟系统命令的离线回归
.github/       Debian 12/13 容器中的 CI 检查
```

开发机器运行离线回归：

```bash
python3 -m unittest discover -s tests -v
```

需要 Bash、Python 3、OpenSSH 客户端、systemd 工具和 util-linux 等测试依赖；环境限制可能阻止 systemd 单元校验。测试不修改真实 SSH/UFW，不启用真实 Swap；部分测试使用真实 `mkswap`、`blkid` 和单元检查器验证临时文件。GitHub `Checks` 在 Debian 12/13 容器中检查 Bash 语法并执行测试，不运行安装或部署。离线测试不能代替[真机验收](docs/validation.md)。
