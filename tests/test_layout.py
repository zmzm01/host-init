"""A copied project must run independently of its original location or working directory."""
import shutil
import subprocess
import os

from test_workflow import WorkflowFixture, PROJECT


class LayoutTests(WorkflowFixture):
    def setUp(self):
        super().setUp()
        self.deployment = self.fixture / "copied project with spaces"
        self.deployment.mkdir()
        shutil.copy2(PROJECT / "setup.sh", self.deployment / "setup.sh")
        for name in ("lib", "modules", "configs"):
            shutil.copytree(PROJECT / name, self.deployment / name)
        (self.deployment / "id_ed25519.pub").write_text(self.public_key + "\n")

    def run_entrypoint(self, *args, ok=True):
        result = subprocess.run(["bash", str(self.deployment / "setup.sh"), *args],
                                cwd=self.fixture, env=dict(os.environ, FIXTURE=str(self.fixture)),
                                text=True, capture_output=True, timeout=5)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_copied_project_help_needs_no_config_or_sibling(self):
        result = self.run_entrypoint("--help")
        self.assertIn("configs/homelab.example.conf", result.stdout)
        self.assertIn("services", result.stdout)

    def test_both_examples_work_as_default_config_from_another_directory(self):
        # A conflicting file in the working directory must not shadow the deployment config.
        self.config.write_text("ADMIN_USER=root\n")
        for profile, syncthing in (("vps", "no"), ("homelab", "yes")):
            with self.subTest(profile=profile):
                shutil.copy2(self.deployment / f"configs/{profile}.example.conf",
                             self.deployment / "config.conf")
                before = {p.relative_to(self.deployment): p.read_bytes()
                          for p in self.deployment.rglob("*") if p.is_file()}
                result = self.run_entrypoint("plan")
                self.assertIn(f"配置：{self.deployment / 'config.conf'}", result.stdout)
                self.assertIn("已验证 1 条公钥", result.stdout)
                self.assertIn(f"Syncthing：{syncthing}；Nginx：no；Mihomo：no", result.stdout)
                after = {p.relative_to(self.deployment): p.read_bytes()
                         for p in self.deployment.rglob("*") if p.is_file()}
                self.assertEqual(before, after)

    def test_custom_config_can_enable_services_on_vps_and_resolve_relative_key(self):
        profile = self.deployment / "configs/vps.example.conf"
        config = self.deployment / "configs/my-server.conf"
        config.write_text(profile.read_text().replace("INSTALL_SYNCTHING=no", "INSTALL_SYNCTHING=yes")
                          .replace("./id_ed25519.pub", "../id_ed25519.pub"))
        result = self.run_entrypoint("plan", "--config", str(config))
        self.assertIn(f"公钥：{self.deployment / 'id_ed25519.pub'}", result.stdout)
        self.assertIn("Syncthing：yes", result.stdout)
        self.assertIn("已验证 1 条公钥", result.stdout)

    def test_missing_default_config_points_to_current_examples(self):
        result = self.run_entrypoint("plan", ok=False)
        self.assertIn(str(self.deployment / "config.conf"), result.stderr)
        self.assertIn("configs/", result.stderr)

    def mock_host_for_preflight(self):
        # Replace host reads in a disposable copy. Any installation attempt fails the test.
        services = self.deployment / "modules/maintenance.sh"
        with services.open("a") as stream:
            stream.write(r'''
ROOT_PREFIX="$FIXTURE/root"
require_target() { :; }
inspect_admin() { :; }
read_ssh_ports() { SSH_PORTS=(2222); }
dpkg() { :; }
docker_preflight() { :; }
tailscale_preflight() { :; }
services_preflight() { printf 'service preflight: %s\n' "$1"; }
host_preflight() { :; }
time_preflight() { :; }
swap_preflight() { :; }
tools_preflight() { :; }
df() { printf 'mock disk space\n'; }
begin_run() { die 'UNEXPECTED_WRITE'; }
apt-get() { die 'UNEXPECTED_INSTALL'; }
''')
        shutil.copy2(self.deployment / "configs/homelab.example.conf",
                     self.deployment / "config.conf")

    def test_doctor_checks_host_without_logs_backups_or_installation(self):
        self.mock_host_for_preflight()
        before = {p.relative_to(self.fixture): p.read_bytes()
                  for p in self.fixture.rglob("*") if p.is_file()}
        result = self.run_entrypoint("doctor")
        self.assertIn("实际 SSH 端口：2222", result.stdout)
        self.assertIn("安装前检查通过", result.stdout)
        self.assertIn("service preflight: doctor", result.stdout)
        self.assertIn("mock disk space", result.stdout)
        after = {p.relative_to(self.fixture): p.read_bytes()
                 for p in self.fixture.rglob("*") if p.is_file()}
        self.assertEqual(before, after)

    def test_doctor_blocks_pending_ssh_before_any_mutation(self):
        self.mock_host_for_preflight()
        (self.root / "var/lib/vps-init/ssh-pending").mkdir(parents=True)
        result = self.run_entrypoint("doctor", ok=False)
        self.assertIn("SSH 加固正在等待确认", result.stderr)
        self.assertNotIn("UNEXPECTED", result.stderr)

    def test_health_bypasses_installation_and_logging(self):
        self.mock_host_for_preflight()
        with (self.deployment / "modules/maintenance.sh").open("a") as stream:
            stream.write(r'''
uptime() { :; }; free() { :; }; swapon() { :; }; lsblk() { :; }; ip() { :; }
timedatectl() { printf 'NTPSynchronized=yes\n'; }
systemctl() { printf 'health fixture %s\n' "$*"; }
''')
        before = {p.relative_to(self.fixture): p.read_bytes()
                  for p in self.fixture.rglob("*") if p.is_file()}
        result = self.run_entrypoint("health")
        self.assertIn("查看主机运行状态", result.stdout)
        self.assertIn("NTPSynchronized=yes", result.stdout)
        self.assertNotIn("UNEXPECTED", result.stderr)
        after = {p.relative_to(self.fixture): p.read_bytes()
                 for p in self.fixture.rglob("*") if p.is_file()}
        self.assertEqual(before, after)

    def test_init_applies_security_after_starting_selected_network_services(self):
        self.mock_host_for_preflight()
        with (self.deployment / "modules/maintenance.sh").open("a") as stream:
            stream.write(r'''
begin_run() { BACKUP_DIR="$FIXTURE/backups"; }
migrate_legacy_docker_source() { :; }
prepare_packages() { :; }
install_common_tools() { printf 'installed common tools\n'; }
configure_host() { :; }
configure_time_sync() { :; }
configure_swap() { printf 'configured swap\n'; }
configure_maintenance() { :; }
configure_admin() { :; }
configure_firewall() { :; }
configure_fail2ban() { :; }
install_docker() { printf 'started Docker\n'; }
install_tailscale() { printf 'started Tailscale\n'; }
install_services() { printf 'started optional services\n'; }
configure_security() { printf 'applied kernel security\n'; }
configure_security_updates() { :; }
check_system() { :; }
check_common_tools() { :; }
check_host() { :; }
check_maintenance() { :; }
check_swap() { :; }
check_security() { printf 'checked security\n'; }
''')
        result = self.run_entrypoint("init")
        self.assertLess(result.stdout.index("configured swap"), result.stdout.index("installed common tools"))
        for label in ("started Docker", "started Tailscale", "started optional services"):
            self.assertLess(result.stdout.index("configured swap"), result.stdout.index(label))
            self.assertLess(result.stdout.index(label), result.stdout.index("applied kernel security"))
        self.assertLess(result.stdout.index("applied kernel security"), result.stdout.index("checked security"))
