# 备份与恢复

`INSTALL_BACKUP_TOOLS=yes` 安装 Debian 的 restic。仓库地址、备份密码、远端 SSH 身份和备份时间由你配置，安装器不把凭据写进 `config.conf`、不初始化远端仓库、不自动删除旧快照。初始化时的 `/var/backups/vps-init/` 只保存本次修改前的配置，不包含完整业务数据。

选一台不同于被备份机器的服务器或适合的对象存储保存仓库，并记录需要恢复的目录。数据库先用数据库自身的导出或一致性快照方法取得可恢复的数据；直接复制运行中的数据库目录并不能保证恢复成功。Debian 的[备份策略](https://www.debian.org/doc/manuals/debian-handbook/sect.backup.en.html)也讨论了异地存储和数据库一致性。

下面用官方支持的 SFTP 仓库举例，替换用户、地址和路径，先给远端专用账户配置写入目标目录的权限。由 root 运行备份时，先在 root 的 SSH 配置中完成连接与主机指纹核对，不关闭主机密钥检查。仓库密码用于加密，与 SSH 登录凭据不同；丢失密码会失去数据访问能力，需要另存到你的密码管理器。[restic 仓库与 SFTP](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html)。

## 第一次备份

在目标机器的 root 会话中操作，密码文件只在第一次创建；不要覆盖已有仓库的密码：

```bash
install -d -m 0700 /root/.config/restic
test -e /root/.config/restic/password || install -m 0600 /dev/null /root/.config/restic/password
nano /root/.config/restic/password
chmod 0600 /root/.config/restic/password

# 变量只用于当前手工备份会话，不是安装器配置项。
backup_repo=sftp:backup@backup.example.net:/srv/restic/home01
backup_password=/root/.config/restic/password

# 新仓库仅初始化一次；已有仓库直接查看 snapshots。
restic -r "$backup_repo" --password-file "$backup_password" init

# 按实际业务修改目录，不存在的目录应从列表移除。
# 另挂载的数据盘必须明确列入，不能只依赖 /srv。
restic -r "$backup_repo" --password-file "$backup_password" backup \
  --one-file-system /etc /opt /srv /var/lib/syncthing

restic -r "$backup_repo" --password-file "$backup_password" snapshots
```

确认 Compose 文件、Mihomo 配置、Syncthing 身份与数据目录，以及数据库导出都在清单中。实际 Docker 卷可能不在 `/srv`，应从部署配置确定位置并确保应用一致性。`--one-file-system` 避免意外跨越其他挂载点，同时也要求你明确列出想备份的其他文件系统根目录。[restic 备份与文件系统边界](https://restic.readthedocs.io/en/stable/040_backup.html)。

## 检查并恢复一个文件

下面继续使用同一个会话变量。检查快照结构、完整读取仓库数据，然后从 `snapshots` 中选一个明确的快照 ID，恢复到单独目录：

```bash
restic -r "$backup_repo" --password-file "$backup_password" check
restic -r "$backup_repo" --password-file "$backup_password" check --read-data

# 替换为真实快照 ID；避免用 latest 意外选到其他主机的快照。
backup_snapshot=替换成快照ID
restic -r "$backup_repo" --password-file "$backup_password" ls "$backup_snapshot"
restore_dir=$(mktemp -d /var/tmp/restic-restore.XXXXXX)
restic -r "$backup_repo" --password-file "$backup_password" restore "$backup_snapshot" \
  --target "$restore_dir" --include /etc/hostname
cat "$restore_dir/etc/hostname"
```

`check --read-data` 会读取完整数据，时间和流量随仓库大小增长；大仓库可依据官方文档安排抽样检查。检查通过还需要恢复业务文件、校验权限，并尝试从数据库导出恢复到测试实例。恢复默认会覆盖目标目录的同名文件，因此使用新目录检查后再决定如何恢复业务。[仓库检查](https://restic.readthedocs.io/en/stable/045_working_with_repos.html)、[恢复行为](https://restic.readthedocs.io/en/stable/050_restore.html)。

## 建立定期计划

手工备份和恢复通过后，再针对你的业务配置 systemd timer、数据库导出前置步骤和失败通知。按数据变化与可接受损失确定备份周期；按容量和需要回溯的时间确定快照保留。先确认仓库可访问、密码离线有副本、恢复路径可用，再启用删除旧快照的策略。

脚本目前只安装工具和提供流程，没有自动异地备份或告警。重装前应把安装配置、公钥、业务配置和备份凭据的恢复方法记录到另一台设备，先检查最近一次备份，再重装。
