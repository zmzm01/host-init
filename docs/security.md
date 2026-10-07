# 安全配置与 SSH 加固

[返回首页](../README.md) · [配置参考](configuration.md) · [排错与维护](operations.md)

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

## Tailscale 登录与访问

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
