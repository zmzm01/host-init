# 从 VPS / H81 目录迁移

项目现在只有根目录的 `setup.sh` 和一套 `lib/`、`modules/`、`tests/`。VPS 与家庭服务器的差异移到 `configs/` 的配置示例中，原来的分目录脚本入口已经移除。

| 旧入口 | 新入口 |
| --- | --- |
| `VPS/setup.sh <命令>` | `setup.sh <命令>` |
| `H81/setup.sh <命令>` | `setup.sh <命令>` |
| `VPS/debian_system-init.sh`、`H81/debian_system-init.sh` | `setup.sh init` |
| `VPS/debian_docker-install.sh` | `setup.sh docker` |
| `H81/debian_service-init.sh` | `setup.sh services` |
| `VPS/config.example.conf` | `configs/vps.example.conf` |
| `H81/config.example.conf` | `configs/homelab.example.conf` |

已配置的机器保留原 `config.conf` 的内容，复制到新项目根目录，或用 `--config` 指向原文件；不要用示例覆盖已经调整过的配置。如果原来同时保存两份配置，将它们分别放到 `configs/vps.conf`、`configs/home.conf`，在对应主机上明确选择其中一份。

相对公钥路径仍按配置文件所在目录解析。移动配置时，应把公钥一起移动，或调整 `SSH_PUBLIC_KEY_FILE` 为新相对路径或绝对路径。例如配置在 `configs/home.conf`、公钥在项目根目录时，填 `SSH_PUBLIC_KEY_FILE=../id_ed25519.pub`。先执行 `plan` 检查选择的配置及公钥，再执行安装命令。脚本、配置和公钥均应由 root 控制写权限。

示例路径为 `/opt/host-init`，实际项目仍可放在其他目录。更新自动化命令和快捷方式中的脚本路径即可。普通 `--config` 相对路径按执行命令时的工作目录解析；省略该参数时，始终读取 `setup.sh` 同目录下的 `config.conf`。

主机端原有的 `/var/log/vps-init/`、`/var/backups/vps-init/`、`/var/lib/vps-init/`、运行锁、托管配置文件名和 SSH 回退任务名称保持兼容，不需要搬动或删除。若有待确认的 SSH 加固，先完成新连接确认或等待回退，再执行其他变更。

已有 Syncthing 实例继续使用原 `SYNCTHING_USER`，保持数据目录和设备身份；目录合并不会迁移数据、切换服务账户或停用旧实例。[服务说明](services.md)介绍旧 Docker 源、Mihomo 服务和 Syncthing 的迁移边界。
