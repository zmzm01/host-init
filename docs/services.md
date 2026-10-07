# 可选服务

[返回首页](../README.md) · [配置参考](configuration.md) · [排错与维护](operations.md)

Syncthing、Nginx 和 Mihomo 由项目的 `modules/services.sh` 提供，VPS、家庭服务器或其他 Debian 12/13 主机都可通过配置启用。H81 不需要专用入口。

## 初始化

先按[首页](../README.md#快速开始)把项目安装到 `/opt/host-init`。以下仅用于首次准备家庭配置，在 root 会话中执行；已有配置时直接编辑原文件，不用示例覆盖：

```bash
cd /opt/host-init
cp configs/homelab.example.conf config.conf
# 将 SSH_PUBLIC_KEY_FILE 改为已上传的公钥路径，例如 /root/id_ed25519.pub。
chmod 0600 config.conf
nano config.conf
bash setup.sh plan
bash setup.sh doctor
bash setup.sh init
```

默认安装共享基础模块、常用工具、Tailscale 和 Syncthing。Nginx、Mihomo 默认关闭，按需设置 `INSTALL_NGINX=yes`、`INSTALL_MIHOMO=yes`。服务也可单独安装：

```bash
sudo bash /opt/host-init/setup.sh services --config /opt/host-init/config.conf
sudo bash /opt/host-init/setup.sh check --config /opt/host-init/config.conf
sudo tailscale up
```

SSH 公钥验证、`harden --confirm-key-login`、新连接 `confirm-ssh` 及 5 分钟回退使用[SSH 加固说明](security.md#验证登录并加固-ssh)中的同一流程。默认读取项目根目录的 `config.conf`，也可给各命令传入 `--config`。从旧 H81 目录迁移请看[迁移说明](migration.md)。

## Syncthing 与局域网端口

家庭服务器示例默认 `SYNCTHING_USER=syncthing`，使用无 sudo 权限的专用系统账户，数据目录在 `/var/lib/syncthing`。同步文件夹必须让该账户可读写。

旧机器若已使用自己的账户和已有数据，请把 `SYNCTHING_USER` 改为原账户名，保持原配置目录和设备身份。切换到专用账户不会自动迁移原数据库，也不会停掉其他账户的旧服务；先规划迁移再手动停用旧实例。该账户若有免密 sudo 权限，服务也会拥有对应账户的提权能力。

`SERVICE_LAN_CIDR` 填实际 RFC1918 IPv4 私有网段，如 `192.168.1.0/24`，才为这个来源网段放行：

- 同步：`22000/TCP`、`22000/UDP`。
- 局域网发现：`21027/UDP`。
- 选中的 Nginx：`80/TCP`、`443/TCP`。

GUI 首次默认在本机 `8384`，不会为 GUI 增加 UFW 放行。建议通过 SSH 隧道访问：

```bash
ssh -L 8384:127.0.0.1:8384 ops@服务器IP
```

然后在自己的电脑访问 `http://127.0.0.1:8384`，设置 GUI 密码。既有 GUI 监听设置会保留，请检查是否已绑定所有地址。通过 Tailscale 访问仍需配置 tailnet 的访问策略。

## Mihomo

开启前自行从可信发行渠道准备与机器架构匹配的二进制及配置：

```text
/opt/mihomo/
├── mihomo                  # root 所有、可执行，不能有组/其他用户写权限
└── config/
    ├── config.yaml
    ├── geoip.metadb        # 及配置需要的数据文件
    └── ui/                # 若启用 UI
```

脚本验证二进制和配置可用，创建专用 `mihomo` 系统账户，将配置目录交给该账户，生成带有文件系统限制的 systemd 服务。代码及订阅配置由你提供，不自动下载二进制或覆盖订阅。旧脚本生成的已知 `mihomo.service` 符号链接会备份后迁移；未知链接会停止处理。

默认服务适合普通用户态代理：不授予 TUN、透明代理或特权端口所需的额外能力。需要这些模式时应另行配置路由及 systemd 权限。API/UI 请绑定本机或受控内网，并设置访问密钥；脚本不会自动公开管理端口。

## 网络与旧配置

先自行完成校园网登录，或通过系统 APT 代理配置解决下载访问。账号、密码、订阅密钥不写进安装脚本，也不再强制要求 proxychains。

Syncthing 和 Nginx 使用现有 Debian 软件源，不新增第三方源。旧第三方软件源仍可能影响 APT，迁移前检查并整合；已知旧 H81 Docker 源会与 VPS 源一样备份迁移。旧镜像加速配置会保留，不再写死公共加速站点。

参考：[Syncthing systemd 服务](https://docs.syncthing.net/users/autostart.html#using-systemd)、[同步端口](https://docs.syncthing.net/users/firewall.html)、[Mihomo 服务](https://wiki.metacubex.one/startup/service/)。
