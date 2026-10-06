"""Failure recovery and preflight checks must not leave unrelated system changes."""
import fcntl
import os
from test_workflow import WorkflowFixture


HEADER = r"""
. "$PROJECT/modules/security.sh"
. "$PROJECT/modules/services.sh"
INSTALL_SECURITY_HARDENING=yes
ENABLE_UNATTENDED_UPGRADES=no
INSTALL_SYNCTHING=yes
SYNCTHING_USER=syncthing
INSTALL_MIHOMO=no
"""


class ReliabilityTests(WorkflowFixture):
    def run_bash(self, script, ok=True):
        return super().run_bash(HEADER + script, ok=ok)

    def test_duplicate_config_key_is_rejected_with_both_line_numbers(self):
        self.config.write_text("INSTALL_DOCKER=no\nINSTALL_DOCKER=yes\n")
        result = self.run_bash(r'load_config "$FIXTURE/config.conf"', ok=False)
        self.assertIn("第 2 行重复定义 INSTALL_DOCKER", result.stderr)
        self.assertIn("第 1 行", result.stderr)

    def test_unknown_config_key_cannot_execute_subscript_expression(self):
        for key in ("", f"seen[$(touch {self.fixture}/executed)]"):
            with self.subTest(key=key):
                self.config.write_text(key + "=yes\n")
                result = self.run_bash(r'load_config "$FIXTURE/config.conf"', ok=False)
                self.assertIn("未知选项", result.stderr)
                self.assertFalse((self.fixture / "executed").exists())

    def test_begin_run_preserves_existing_lock_directory_permissions(self):
        directory = self.write("run/lock/existing", "unrelated").parent
        directory.chmod(0o1777)
        self.run_bash("begin_run\n")
        self.assertEqual(directory.stat().st_mode & 0o7777, 0o1777)
        self.assertEqual((directory / "existing").read_text(), "unrelated")
        self.assertEqual((directory / "vps-init.lock").stat().st_mode & 0o777, 0o600)

    def test_begin_run_rejects_symlink_lock_without_truncating_target(self):
        target = self.write("etc/example.conf", "keep original\n")
        directory = self.root / "run/lock"
        directory.mkdir(parents=True)
        directory.chmod(0o1777)
        (directory / "vps-init.lock").symlink_to(target)
        result = self.run_bash("begin_run\n", ok=False)
        self.assertIn("符号链接", result.stderr)
        self.assertEqual(target.read_text(), "keep original\n")

    def test_begin_run_does_not_truncate_existing_regular_lock(self):
        target = self.write("run/lock/vps-init.lock", "existing marker\n")
        target.parent.chmod(0o1777)
        self.run_bash("begin_run\n")
        self.assertEqual(target.read_text(), "existing marker\n")

    def test_begin_run_rejects_shared_lock_directory_without_sticky_bit(self):
        directory = self.root / "run/lock"
        directory.mkdir(parents=True)
        directory.chmod(0o777)
        result = self.run_bash("begin_run\n", ok=False)
        self.assertIn("sticky bit", result.stderr)
        self.assertFalse((directory / "vps-init.lock").exists())

    def test_begin_run_rejects_hardlinked_lock_without_changing_target_mode(self):
        target = self.write("etc/example.conf", "keep\n")
        target.chmod(0o644)
        directory = self.root / "run/lock"
        directory.mkdir(parents=True)
        directory.chmod(0o1777)
        os.link(target, directory / "vps-init.lock")
        result = self.run_bash("begin_run\n", ok=False)
        self.assertIn("硬链接", result.stderr)
        self.assertEqual(target.stat().st_mode & 0o777, 0o644)
        self.assertEqual(target.read_text(), "keep\n")

    def test_begin_run_blocks_concurrent_run_before_creating_logs(self):
        target = self.write("run/lock/vps-init.lock", "")
        target.parent.chmod(0o1777)
        with target.open("a") as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_bash("begin_run\n", ok=False)
        self.assertIn("另一个初始化或 SSH 回退操作", result.stderr)
        self.assertFalse((self.root / "var/log/vps-init").exists())

    def test_broken_package_state_is_reported_before_package_install(self):
        result = self.run_bash(r"""
dpkg() { printf 'unconfigured package\n'; }
apt_install() { printf 'UNEXPECTED_INSTALL\n'; }
check_package_state
apt_install curl
""", ok=False)
        self.assertIn("unconfigured package", result.stderr)
        self.assertNotIn("UNEXPECTED_INSTALL", result.stdout)

    def test_empty_package_audit_is_successful(self):
        self.run_bash("dpkg() { :; }; check_package_state\n")

    def test_repository_index_failure_restores_existing_source_and_key(self):
        repo = self.write("etc/apt/sources.list.d/example.sources", "original source\n")
        key = self.write("etc/apt/keyrings/example.asc", "original key\n")
        (self.fixture / "candidate.asc").write_text("replacement key\n")
        result = self.run_bash(r"""
apt-get() { return 100; }
write_apt_repository "$ROOT_PREFIX/etc/apt/keyrings/example.asc" \
  "$ROOT_PREFIX/etc/apt/sources.list.d/example.sources" "$FIXTURE/candidate.asc" <<< 'replacement source'
printf UNEXPECTED_SUCCESS
""", ok=False)
        self.assertEqual(repo.read_text(), "original source\n")
        self.assertEqual(key.read_text(), "original key\n")
        self.assertNotIn("UNEXPECTED_SUCCESS", result.stdout)

    def test_repository_index_failure_removes_only_new_managed_files(self):
        unrelated = self.write("etc/apt/sources.list.d/unrelated.sources", "keep\n")
        (self.fixture / "candidate.asc").write_text("replacement key\n")
        self.run_bash(r"""
apt-get() { return 100; }
write_apt_repository "$ROOT_PREFIX/etc/apt/keyrings/example.asc" \
  "$ROOT_PREFIX/etc/apt/sources.list.d/example.sources" "$FIXTURE/candidate.asc" <<< 'replacement source'
""", ok=False)
        self.assertFalse((self.root / "etc/apt/sources.list.d/example.sources").exists())
        self.assertFalse((self.root / "etc/apt/keyrings/example.asc").exists())
        self.assertEqual(unrelated.read_text(), "keep\n")

    def test_repository_invalid_target_is_rejected_before_changing_key(self):
        key = self.write("etc/apt/keyrings/example.asc", "original key\n")
        unrelated = self.write("etc/apt/sources.list.d/unrelated.sources", "keep\n")
        unrelated.with_name("example.sources").symlink_to(unrelated)
        (self.fixture / "candidate.asc").write_text("replacement key\n")
        self.run_bash(r"""
write_apt_repository "$ROOT_PREFIX/etc/apt/keyrings/example.asc" \
  "$ROOT_PREFIX/etc/apt/sources.list.d/example.sources" "$FIXTURE/candidate.asc" <<< 'replacement source'
""", ok=False)
        self.assertEqual(key.read_text(), "original key\n")
        self.assertEqual(unrelated.read_text(), "keep\n")

    def test_fail2ban_restart_failure_restores_and_restarts_previous_config(self):
        target = self.write("etc/fail2ban/jail.d/90-vps-init.local", "original\n")
        self.run_bash(r"""
apt_install() { :; }; fail2ban-client() { :; }
restart_count=0
systemctl() {
  printf '%s\n' "$*" >> "$TRACE"
  if [[ "$1" == restart ]]; then
    restart_count=$((restart_count + 1))
    [[ "$restart_count" == 2 ]]
  fi
}
SSH_PORTS=(2222)
configure_fail2ban
""", ok=False)
        self.assertEqual(target.read_text(), "original\n")
        self.assertEqual(self.trace().count("restart fail2ban.service"), 2)

    def test_fail2ban_missing_jail_restores_previous_config(self):
        target = self.write("etc/fail2ban/jail.d/90-vps-init.local", "original\n")
        self.run_bash(r"""
apt_install() { :; }; sleep() { :; }
fail2ban-client() { [[ "$1" == -t ]]; }
systemctl() { printf '%s\n' "$*" >> "$TRACE"; }
SSH_PORTS=(2222)
configure_fail2ban
""", ok=False)
        self.assertEqual(target.read_text(), "original\n")
        self.assertEqual(self.trace().count("restart fail2ban.service"), 2)

    def test_kernel_redirects_cover_existing_interfaces_with_dotted_names(self):
        for family, parameter in (("ipv4", "accept_redirects"), ("ipv4", "send_redirects"),
                                  ("ipv6", "accept_redirects")):
            self.write(f"proc/sys/net/{family}/conf/eth0.100/{parameter}", "1")
        self.run_bash(r"""
sysctl() { printf '%s\n' "$*" >> "$TRACE"; [[ "$1" != -n ]] || printf '1\n'; }
configure_kernel_security
""")
        config = (self.root / "etc/sysctl.d/90-vps-init-security.conf").read_text()
        self.assertIn("net/ipv4/conf/eth0.100/accept_redirects = 0", config)
        self.assertIn("net/ipv4/conf/eth0.100/send_redirects = 0", config)
        self.assertIn("net/ipv6/conf/eth0.100/accept_redirects = 0", config)
        self.assertIn("-n net/ipv4/conf/eth0.100/accept_redirects", self.trace())

    def test_security_check_detects_redirects_still_enabled_on_interface(self):
        self.write("proc/sys/net/ipv4/conf/eth0/accept_redirects", "1")
        result = self.run_bash("sysctl() { printf '1\\n'; }; check_security\n", ok=False)
        self.assertIn("net/ipv4/conf/eth0/accept_redirects", result.stderr)

    def test_syncthing_custom_account_fails_preflight_before_install(self):
        result = self.run_bash(r"""
SYNCTHING_USER=otheruser
getent() { return 2; }
apt_install() { printf UNEXPECTED_INSTALL; }
services_preflight init
configure_syncthing
""", ok=False)
        self.assertNotIn("UNEXPECTED_INSTALL", result.stdout)

    def test_syncthing_preflight_allows_admin_to_be_created_by_init(self):
        self.run_bash("SYNCTHING_USER=ops\ngetent() { return 2; }; services_preflight init\n")
        self.run_bash("SYNCTHING_USER=ops\ngetent() { return 2; }; services_preflight doctor\n")
        self.run_bash("SYNCTHING_USER=ops\ngetent() { return 2; }; services_preflight services\n", ok=False)

    def test_syncthing_preflight_rejects_account_with_root_uid(self):
        self.run_bash("getent() { printf 'syncthing:x:0:0::/root:/bin/bash\\n'; }; services_preflight init\n", ok=False)

    def test_doctor_does_not_execute_supplied_mihomo_binary(self):
        directory = self.root / "opt/mihomo"
        binary = self.write("opt/mihomo/mihomo", '#!/bin/bash\ntouch "$(dirname "$0")/executed"\n')
        binary.chmod(0o755)
        directory.chmod(0o755)
        self.write("opt/mihomo/config/config.yaml", "mixed-port: 7890\n")
        self.run_bash(r'''
INSTALL_SYNCTHING=no
INSTALL_MIHOMO=yes
MIHOMO_DIR=/opt/mihomo
# Fixture files may belong to the developer; simulate the checked deployment ownership.
stat() { [[ "$1:$2" != -c:%u ]] && command stat "$@" || printf '0\n'; }
services_preflight doctor
''')
        self.assertFalse((directory / "executed").exists())
