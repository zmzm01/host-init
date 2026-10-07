# 排错、恢复与日常维护

[返回首页](../README.md) · [配置参考](configuration.md) · [SSH 加固](security.md)

## 先判断是警告还是失败

| 结果 | 行为 | 下一步 |
| --- | --- | --- |
| 常用工具或 `EXTRA_PACKAGES` 包名不存在、没有安装候选 | 跳过该包，继续其余工具和后续模块；最终汇总警告 | 修正包名或软件源，重跑 `tools` |
| `check` 发现常用工具缺失 | 记录警告，继续其他检查 | 查看缺失清单，按需补装 |
| APT 索引更新、依赖解析、下载或实际安装失败 | 停止 | 根据 APT 原始错误修复后重跑 |
| 软件包数据库损坏或包未配置完成 | 停止 | 先修复原有包状态；安装器不自动修复未知问题 |
| SSH、账户、防火墙、服务配置失败，或 Zellij 下载/校验失败 | 停止，并按对应模块执行局部恢复 | 查看日志和备份，处理原因后重跑 |

**退出码 0 表示流程结束，仍需检查警告汇总；非零表示失败。** 常用工具的容错不适用于基础依赖、维护工具或业务服务。即使已打印某个步骤的完成消息，也应以最终结果和未完成项为准。

## 查找日志

`init`、`tools`、`host` 等执行命令以及 `check` 在预检通过后创建日志：

```bash
sudo ls -lt /var/log/vps-init/
# 将下面文件名替换成报错提示的实际日志。
sudo tail -n 100 /var/log/vps-init/时间-进程号.log
sudo less /var/log/vps-init/时间-进程号.log
```

日志记录操作、系统版本、配置路径、APT 安装请求及输出、工具包查询状态，权限为 0600。主动报错会显示失败步骤与日志位置；未预期的命令失败还会显示行号和退出码。提交问题时附上相关错误前后的片段，并先检查是否包含你自行添加的私有地址等信息。

`plan`、`doctor`、`health` 不写安装日志。其他命令若在预检中失败，也尚未创建本次日志，应查看终端输出；不要把上一次日志误认为本次结果。

## 常见问题

| 提示或现象 | 原因与处理 |
| --- | --- |
| `常用工具尚未安装：dnsutils` | 旧版检查使用了虚拟包名；更新项目后实际检查 `bind9-dnsutils`，无需删除已安装的 DNS 工具 |
| `跳过常用工具 …：当前软件源中找不到可安装的软件包` | 检查 `EXTRA_PACKAGES` 拼写、Debian 版本和软件源组件；不要只为消除警告随意添加第三方源 |
| `/etc/default/locale` 被当作符号链接拒绝 | 旧版遗漏 Debian 13 的标准兼容链接；更新后保留链接并写入 `/etc/locale.conf`。未知目标或链式链接仍被拒绝 |
| `SSH_CONNECTION` 无法验证 | 在实际 SSH 会话中使用 `sudo --preserve-env=SSH_CONNECTION`，确认实际 SSH 服务和监听端口 |
| Docker/Tailscale 软件源冲突 | 检查并整合第三方源；项目不会盲目覆盖未知仓库 |
| 有待确认的 SSH 修改 | 用加固后的新连接运行 `confirm-ssh`，或等待 5 分钟自动回退；确认前不要重启 |
| Zellij 启动的还是旧版本 | 用 `command -v zellij` 检查 PATH；项目安装位置为 `/usr/local/bin/zellij`，其他位置的程序保留 |
| Tailscale 显示待登录 | 安装成功不等于登录；执行 `sudo tailscale up`，完成账号验证和需要的设备批准 |
| 时间服务刚启动但尚未同步 | 稍后运行 `health`；持续不同步时检查原时间服务、上游和出站网络 |

## 更新代码与重跑

以下命令在目标服务器的管理员 SSH 会话运行。配置路径始终沿用原来的那份：

```bash
cd /opt/host-init
sudo git status --short
sudo git pull --ff-only
sudo bash setup.sh plan --config config.conf
sudo --preserve-env=SSH_CONNECTION bash setup.sh doctor --config config.conf
sudo --preserve-env=SSH_CONNECTION bash setup.sh init --config config.conf
```

更新前处理源码中的本地改动；不要为了更新删除自己的配置。`git pull` 只更新文件，不执行安装。配置中缺失的新字段使用当前默认值，因此更新后应先运行 `plan`，确认新增选项再执行 `doctor` 和安装。

只补装常用工具时：

```bash
sudo bash /opt/host-init/setup.sh tools --config /opt/host-init/config.conf
sudo bash /opt/host-init/setup.sh check --config /opt/host-init/config.conf
```

重跑会保留已有账户、公钥及未修改的托管文件，但仍可能更新选中的软件包、重启受影响服务。`no` 或空值是跳过，不是卸载或撤销。已开始的初始化无需因为工具警告重装系统。

## 备份和恢复边界

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

旧的分目录入口已合并为 `setup.sh` 的子命令，具体对应关系见[迁移说明](migration.md)。主机端仍保留 `vps-init` 名称的托管配置、日志、备份和 SSH 回退状态，与之前版本兼容。

整个安装不是事务：已安装的软件、已创建的用户不会因后续失败自动撤销。恢复前先比较备份与现有文件，只恢复有问题的配置，不整批覆盖 `/etc`。初始化备份不是业务数据备份，业务恢复请看[备份与恢复](backup.md)。
