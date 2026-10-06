"""Security, package and optional service checks using disposable system fixtures."""
import subprocess
from test_workflow import WorkflowFixture, PROJECT, SSH_MOCKS


HEADER = r"""
. "$PROJECT/modules/security.sh"
. "$PROJECT/modules/tools.sh"
. "$PROJECT/modules/tailscale.sh"
. "$PROJECT/modules/services.sh"
INSTALL_SECURITY_HARDENING=yes
ENABLE_UNATTENDED_UPGRADES=yes
INSTALL_COMMON_TOOLS=yes
EXTRA_PACKAGE_LIST=()
INSTALL_TAILSCALE=yes
TAILSCALE_UDP_PORT=''
VERSION_CODENAME=trixie
INSTALL_SYNCTHING=no
SYNCTHING_USER=syncthing
INSTALL_NGINX=no
INSTALL_MIHOMO=no
SERVICE_LAN_CIDR=''
MIHOMO_DIR=/opt/mihomo
"""
TAILSCALE_MOCKS = r"""
apt-get() { :; }
apt_install() { printf 'packages %s\n' "$*" >> "$TRACE"; }
curl() { printf 'fixture public key\n' > "$WORK_DIR/tailscale.gpg"; }
gpg() { :; }
systemctl() { printf 'systemctl %s\n' "$*" >> "$TRACE"; }
ufw() { printf 'ufw %s\n' "$*" >> "$TRACE"; }
tailscale() {
  printf 'tailscale %s\n' "$*" >> "$TRACE"
  case "$1" in
    version) printf 'fixture version\n' ;;
    status) printf '{"BackendState":"NeedsLogin"}\n' ;;
    *) return 99 ;;
  esac
}
"""
SERVICE_MOCKS = r"""
apt_install() { printf 'packages %s\n' "$*" >> "$TRACE"; }
systemctl() { printf 'systemctl %s\n' "$*" >> "$TRACE"; }
ufw() { printf 'ufw %s\n' "$*" >> "$TRACE"; }
nginx() { printf 'nginx %s\n' "$*" >> "$TRACE"; }
getent() { printf 'syncthing:x:123:123::%s/var/lib/syncthing:/usr/sbin/nologin\n' "$ROOT_PREFIX"; }
"""


class ExtensionTests(WorkflowFixture):
    def run_bash(self, script, ok=True):
        return super().run_bash(HEADER + script, ok=ok)

    def test_new_config_switches_and_extra_packages(self):
        self.config.write_text(
            "INSTALL_SECURITY_HARDENING=no\nENABLE_UNATTENDED_UPGRADES=yes\n"
            "INSTALL_COMMON_TOOLS=no\nEXTRA_PACKAGES=sqlite3 iperf3\n"
            "INSTALL_TAILSCALE=yes\nTAILSCALE_UDP_PORT=41641\n"
            "INSTALL_SYNCTHING=yes\nSYNCTHING_USER=syncthing\nSERVICE_LAN_CIDR=192.168.1.0/24\n"
        )
        result = self.run_bash(r'load_config "$FIXTURE/config.conf"; declare -p EXTRA_PACKAGE_LIST')
        self.assertIn("sqlite3", result.stdout)
        self.assertIn("iperf3", result.stdout)

    def test_invalid_extensions_are_rejected(self):
        for value in ["EXTRA_PACKAGES=--allow-unauthenticated", "TAILSCALE_UDP_PORT=0",
                      "INSTALL_TAILSCALE=maybe", "SYNCTHING_USER=root",
                      "SERVICE_LAN_CIDR=0.0.0.0/0", "SERVICE_LAN_CIDR=10.0.0.0/0",
                      "SERVICE_LAN_CIDR=192.168.999.0/24", "MIHOMO_DIR=/opt/../../etc"]:
            with self.subTest(value=value):
                self.config.write_text(value + "\n")
                self.run_bash(r'load_config "$FIXTURE/config.conf"', ok=False)

    def test_private_cidr_ranges(self):
        for cidr in ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]:
            self.run_bash(f"valid_private_cidr '{cidr}'")
        for cidr in ["172.15.0.0/16", "172.32.0.0/16", "192.168.0.0/15", "8.8.8.0/24"]:
            self.run_bash(f"valid_private_cidr '{cidr}'", ok=False)

    def test_tools_with_extras_use_package_arguments(self):
        self.run_bash(r"""
apt_install() { printf '%s\n' "$@" >> "$TRACE"; }
EXTRA_PACKAGE_LIST=(sqlite3 iperf3)
install_common_tools
""")
        for name in ["tmux", "htop", "ripgrep", "jq", "sqlite3", "iperf3"]:
            self.assertIn(name, self.trace().splitlines())

    def test_tools_disabled_keeps_only_explicit_extras(self):
        self.run_bash(r"""
apt_install() { printf '%s\n' "$@" >> "$TRACE"; }
INSTALL_COMMON_TOOLS=no
EXTRA_PACKAGE_LIST=(sqlite3)
install_common_tools
""")
        self.assertEqual(self.trace().strip(), "sqlite3")

    def test_security_sysctl_avoids_network_routing_changes(self):
        self.write("proc/sys/kernel/kptr_restrict", "0")
        self.write("proc/sys/net/ipv4/tcp_syncookies", "1")
        self.run_bash(r"""
sysctl() { [[ "$1" != -n ]] || printf '0\n'; }
configure_kernel_security
""")
        data = (self.root / "etc/sysctl.d/90-vps-init-security.conf").read_text()
        self.assertIn("kernel.kptr_restrict = 2", data)
        for forbidden in ["ip_forward", "forwarding", "rp_filter", "disable_ipv6"]:
            self.assertNotIn(forbidden, data)

    def test_failed_sysctl_capture_does_not_write_config(self):
        self.write("proc/sys/kernel/kptr_restrict", "0")
        self.run_bash("sysctl() { return 1; }\nconfigure_kernel_security\n", ok=False)
        self.assertFalse((self.root / "etc/sysctl.d/90-vps-init-security.conf").exists())

    def test_sysctl_failure_restores_file_and_runtime_values(self):
        self.write("proc/sys/kernel/kptr_restrict", "0")
        target = self.write("etc/sysctl.d/90-vps-init-security.conf", "original\n")
        self.run_bash(r"""
sysctl() {
  if [[ "$1" == -n ]]; then printf '0\n'; return 0; fi
  printf 'sysctl %s\n' "$*" >> "$TRACE"
  [[ "$2" == "$WORK_DIR/sysctl-before" ]]
}
configure_kernel_security
""", ok=False)
        self.assertEqual(target.read_text(), "original\n")
        self.assertIn("sysctl-before", self.trace())

    def test_journal_limits_are_idempotent(self):
        self.run_bash(r"""
systemctl() { printf '%s\n' "$*" >> "$TRACE"; }
journalctl() { :; }
configure_journal_limits
configure_journal_limits
""")
        target = self.root / "etc/systemd/journald.conf.d/90-vps-init.conf"
        self.assertIn("SystemMaxUse=200M", target.read_text())
        self.assertEqual(self.trace().count("restart systemd-journald.service"), 1)

    def test_journal_start_failure_restores_previous_config(self):
        target = self.write("etc/systemd/journald.conf.d/90-vps-init.conf", "original\n")
        self.run_bash("systemctl() { return 1; }\nconfigure_journal_limits\n", ok=False)
        self.assertEqual(target.read_text(), "original\n")

    def test_security_updates_limit_origins_and_disable_reboot(self):
        self.run_bash(r"""
apt_install() { :; }; apt-config() { :; }; systemctl() { :; }
configure_security_updates
""")
        target = self.root / "etc/apt/apt.conf.d/99-vps-init-security"
        data = target.read_text()
        self.assertIn("#clear Unattended-Upgrade::Origins-Pattern;", data)
        self.assertIn("codename=trixie-security", data)
        self.assertIn('Automatic-Reboot "false"', data)
        # Parse the fragment with real APT; this only reads config, never updates packages.
        parsed = subprocess.run(["apt-config", "-c", str(target), "shell", "REBOOT",
                                 "Unattended-Upgrade::Automatic-Reboot"],
                                text=True, capture_output=True, check=True)
        self.assertIn("REBOOT='false'", parsed.stdout)

    def test_extra_ssh_restrictions_keep_forwarding_available(self):
        self.run_bash(SSH_MOCKS + "harden_ssh\n")
        data = (self.root / "etc/ssh/sshd_config.d/00-00-vps-init.conf").read_text()
        self.assertIn("MaxAuthTries 3", data)
        self.assertIn("X11Forwarding no", data)
        self.assertNotIn("AllowTcpForwarding no", data)

    def test_tailscale_installs_without_login_or_network_role_changes(self):
        self.run_bash(TAILSCALE_MOCKS + "install_tailscale\ninstall_tailscale\n")
        data = (self.root / "etc/apt/sources.list.d/vps-init-tailscale.sources").read_text()
        self.assertIn("Suites: trixie", data)
        self.assertIn("Signed-By: /etc/apt/keyrings/vps-init-tailscale.gpg", data)
        self.assertIn("enable --now tailscaled.service", self.trace())
        self.assertNotIn("tailscale up", self.trace())
        self.assertNotIn("ufw allow", self.trace())

    def test_tailscale_optional_udp_rule(self):
        self.run_bash(TAILSCALE_MOCKS + "TAILSCALE_UDP_PORT=41641\ninstall_tailscale\n")
        self.assertIn("ufw allow 41641/udp", self.trace())

    def test_existing_tailscale_source_is_rejected(self):
        target = self.write("etc/apt/sources.list.d/tailscale.list",
                            "deb https://pkgs.tailscale.com/stable/debian trixie main\n")
        self.run_bash("tailscale_preflight\n", ok=False)
        self.assertTrue(target.exists())

    def test_tailscale_keeps_authenticated_state(self):
        self.run_bash(TAILSCALE_MOCKS + r"""
tailscale() {
  printf 'tailscale %s\n' "$*" >> "$TRACE"
  [[ "$1" != status ]] || printf '{"BackendState":"Running"}\n'
}
check_tailscale
""")
        self.assertNotIn("tailscale up", self.trace())

    def test_syncthing_ports_are_lan_scoped_and_complete(self):
        self.run_bash(SERVICE_MOCKS + r"""
SERVICE_LAN_CIDR=192.168.1.0/24
configure_syncthing
""")
        self.assertIn("syncthing@syncthing.service", self.trace())
        for port, protocol in [(22000, "tcp"), (22000, "udp"), (21027, "udp")]:
            self.assertIn(f"from 192.168.1.0/24 to any port {port} proto {protocol}", self.trace())
        self.assertNotIn("port 8384", self.trace())

    def test_without_lan_does_not_open_service_ports(self):
        self.run_bash(SERVICE_MOCKS + "configure_syncthing\nconfigure_nginx\n")
        self.assertNotIn("ufw", self.trace())
        self.assertIn("nginx -t", self.trace())

    def test_syncthing_refuses_root_uid(self):
        self.run_bash(SERVICE_MOCKS + r"""
getent() { printf 'syncthing:x:0:0::/root:/bin/bash\n'; }
configure_syncthing
""", ok=False)
        self.assertNotIn("systemctl enable", self.trace())

    def test_optional_mihomo_missing_binary_stops_preflight(self):
        self.run_bash("INSTALL_MIHOMO=yes\nservices_preflight init\n", ok=False)

    def mihomo_fixture(self):
        self.write("opt/mihomo/config/config.yaml", "mixed-port: 7890\n")
        self.write("opt/mihomo/mihomo", "#!/bin/bash\nexit 0\n").chmod(0o755)
        return r"""
getent() { printf 'mihomo:x:123:123::/opt/mihomo:/usr/sbin/nologin\n'; }
chown() { :; }; runuser() { :; }; systemd-analyze() { :; }
systemctl() { printf 'systemctl %s\n' "$*" >> "$TRACE"; }
"""

    def test_mihomo_unit_is_restricted_and_rerunnable(self):
        self.run_bash(self.mihomo_fixture() + "configure_mihomo\nconfigure_mihomo\n")
        data = (self.root / "etc/systemd/system/mihomo.service").read_text()
        self.assertIn("User=mihomo", data)
        self.assertIn("NoNewPrivileges=yes", data)
        self.assertIn("ProtectSystem=strict", data)
        self.assertNotIn("CAP_NET_ADMIN", data)
        self.assertEqual(self.trace().count("restart mihomo.service"), 1)

    def test_mihomo_restart_failure_restores_previous_service(self):
        target = self.write("etc/systemd/system/mihomo.service", "previous\n")
        self.run_bash(self.mihomo_fixture() + r"""
systemctl() { [[ "$1" != restart ]]; }
configure_mihomo
""", ok=False)
        self.assertEqual(target.read_text(), "previous\n")

    def test_legacy_docker_source_with_ascii_key_is_supported(self):
        target = self.write("etc/apt/sources.list.d/docker.list",
                            "deb [signed-by=/etc/apt/keyrings/docker.asc] "
                            "https://download.docker.com/linux/debian trixie stable\n")
        self.run_bash(r"""
dpkg-query() { return 1; }; dpkg() { printf 'amd64\n'; }
docker_preflight; migrate_legacy_docker_source
""")
        self.assertFalse(target.exists())
        self.assertTrue((self.fixture / "backups/etc/apt/sources.list.d/docker.list").exists())
