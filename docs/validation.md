# 真机验收

[返回首页](../README.md) · [配置参考](configuration.md) · [排错与维护](operations.md)

离线测试验证脚本的分支和失败处理。以下流程用于检查真实 Debian 12/13 上的 APT、SSH、systemd 和防火墙交互，建议分别在两种版本的可重装主机上执行。保留云控制台或其他本地控制台作为恢复入口。

## 基础安装与重跑

1. 按项目说明部署代码、公钥和配置，在 root 会话运行 `plan`、`doctor`、`init`。
2. 用管理员的新公钥连接验证登录，执行 `sudo -v`，然后运行 `check`。额外 SSH 端口也应验证可以连接。
3. 再次运行 `init` 和 `check`，确认原用户、公钥、APT 源和 Docker 镜像源保留，没有重复键、重复软件源或重复托管规则。
4. 检查 Docker 和 Compose 可用、Tailscale 首次显示待登录；执行 `tailscale up` 登录，再次安装 Tailscale 后设备身份应保持。
5. 家庭服务器配置还应验证 Syncthing 的服务账户、设备身份和同步目录权限；选用 Nginx/Mihomo 时检查相应服务及实际访问范围。
6. 运行 `health` 查看时间同步、Swap、磁盘/inode、失败单元及定时器；时间服务刚启动时可等待稍后再看。用 `sudo needrestart -r l` 安排服务/内核更新后的维护。
7. 默认终端工具为 Zellij，在管理员会话检查 `command -v zellij` 和 `zellij --version`，进入/退出一次会话；重复运行 `tools` 不应重复下载同版本或修改用户配置。设置 `TERMINAL_MULTIPLEXER=tmux`/`none` 后不再安装 Zellij，已有工具保留。分别验证 amd64/arm64 的实际程序可执行。

每次运行使用同一份配置。安装日志在 `/var/log/vps-init/`，修改前备份在 `/var/backups/vps-init/`。`no` 表示跳过，不用于卸载或撤销此前的选择。

## 新增主机和维护功能

- 选一个测试主机名，运行 `host`，检查 `hostnamectl --static`、`getent hosts 名称` 和原有 hosts 别名。云镜像有 cloud-init 时重启后名称应保留；留空时不应改原名。默认 LANG 在新会话验证，已有 LC_* 分类保留。
- 分别验证 Debian 12 的 `/etc/default/locale` 和 Debian 13 的 `/etc/locale.conf`：Debian 13 的兼容链接应保持，备份包含实际配置文件，重复运行 `host`/`init` 后 `check` 通过。异常链接应在 `doctor` 预检时被拒绝。
- 在没有时间服务的主机上确认 timesyncd 启动并最终同步；另在已有 Chrony 的主机上确认沿用其配置。自定义 `NTP_SERVERS` 的 timesyncd 应使用所选上游，重复运行不重复写入；Chrony 配置自定义上游时预检应提示改原服务配置。
- 分别检查 Debian 12/13 的 sysstat collect/summary 定时器；Debian 13 的 rotate 存在时应启用。等待采集后用 `sar` 查看记录，确认 `/etc/sysstat/sysstat` 保留原有其他参数，HISTORY 与配置一致。
- 有 SSD 或 thin provisioning 的测试存储启用 TRIM 后检查发行版定时器和执行结果，确认不支持的设备按发行版处理。家庭主机检查磁盘健康工具适用性，不把 VPS 虚拟盘当作实体 SMART 设备。
- 仅在可重装测试主机的 ext4/XFS 文件系统选择非零 Swap 大小。检查 `swapon --show`、文件权限 0600、对应单元启用，重启后仍有效；重复运行不重新格式化，修改大小应停止。另验证已有分区 Swap/zram 时不创建额外文件，Btrfs 自动创建应被拒绝。重启测试应在 SSH 加固确认完成后进行。
- 按[备份流程](backup.md)实际做一次异地备份和恢复演练；确认业务数据盘与数据库导出已列入，密码和远端连接恢复方法在另一台设备可用。

## SSH 确认与回退

先按项目说明强制使用公钥认证并关闭客户端连接复用。在管理员会话运行 `harden --confirm-key-login`，保留该会话，再打开新连接执行 `confirm-ssh`。确认之后应可以继续公钥登录，root/密码登录应被拒绝；回退定时任务与待确认目录应清理。

另在全新的可重装测试主机上重复基础安装和加固，故意不执行 `confirm-ssh`。等待至少 5 分钟，检查原 SSH 登录策略是否恢复、待确认目录是否清理，并查看 `journalctl -t vps-init`。加固前已经建立的其他连接也应无法取消回退。测试窗口内不重启主机。

## 故障与配置冲突

- 在测试配置的 `EXTRA_PACKAGES` 中添加不存在的包名：确认该包被跳过，其他工具和后续模块继续，结束时有警告汇总；`check` 不因工具缺失而终止。模拟真实依赖或安装错误时仍应停止。
- 分别触发预检失败与安装阶段失败：前者只显示终端错误、未创建本次日志；后者应提示 `/var/log/vps-init/` 下的具体日志，包含失败步骤及相关 APT/包状态输出。

- 上传无效公钥、重复配置键或使用不存在的服务账户，确认预检失败且未开始安装。
- 在测试主机上保留第三方 Docker/Tailscale 源，确认预检指出冲突，不自动覆盖。
- 在可恢复的测试网络中模拟新仓库不可访问，确认索引更新失败后本次托管源和密钥恢复，没有继续安装软件。
- 加入会覆盖 SSH 策略的 `Match` 配置，确认加固检测到当前管理员或 root 策略不符时恢复配置。
- 检查现有网卡及后续新建网卡的 ICMP 重定向实际值；`check` 应发现被其他设置重新开启的参数。

故障注入只在测试机器进行。已安装软件、用户及迁移的旧软件源不会随失败自动撤销，应结合日志和备份确认下一步恢复动作。
