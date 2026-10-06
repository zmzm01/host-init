"""Offline regression tests; all system writes and commands use disposable fixtures."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]
PRELUDE = r"""
set -Eeuo pipefail
. "$PROJECT/lib/common.sh"
. "$PROJECT/modules/system.sh"
. "$PROJECT/modules/docker.sh"
. "$PROJECT/modules/ssh.sh"
ROOT_PREFIX="$FIXTURE/root"
WORK_DIR="$FIXTURE/work"
BACKUP_DIR="$FIXTURE/backups"
mkdir -p "$WORK_DIR" "$BACKUP_DIR"
TRACE="$FIXTURE/trace"
ADMIN_USER=ops
PASSWORDLESS_SUDO=yes
INSTALL_FAIL2BAN=yes
DOCKER_ADD_ADMIN_TO_GROUP=no
CONFIRM_KEY_LOGIN=yes
CLIENT_ADDRESS=192.0.2.1
SERVER_ADDRESS=192.0.2.2
SERVER_PORT=2222
SUDO_USER=ops
SSH_CONNECTION='192.0.2.1 12345 192.0.2.2 2222'
"""
ADMIN_MOCKS = r"""
getent() { printf 'ops:x:1000:1000::%s/home/ops:/bin/bash\n' "$ROOT_PREFIX"; }
id() { command id "$1"; }
usermod() { :; }; chown() { :; }; sudo() { :; }; visudo() { :; }
install() {
  local args=()
  while (($#)); do
    case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac
  done
  command install "${args[@]}"
}
"""
SSH_MOCKS = r"""
inspect_admin() { ADMIN_HOME="$ROOT_PREFIX/home/ops"; }
systemctl() { printf 'systemctl %s\n' "$*" >> "$TRACE"; }
systemd-run() { printf 'timer %s\n' "$*" >> "$TRACE"; }
ss() { printf '0 0 192.0.2.2:2222 192.0.2.1:12345\n0 0 192.0.2.2:2222 192.0.2.1:12346\n'; }
sshd() {
  printf 'sshd %s\n' "$*" >> "$TRACE"
  if [[ "$1" == -T ]]; then
    if [[ -f "$ROOT_PREFIX/etc/ssh/sshd_config.d/00-00-vps-init.conf" ]]; then
      awk '$1 !~ /^#/ && NF {print tolower($1), $2}' "$ROOT_PREFIX/etc/ssh/sshd_config.d/00-00-vps-init.conf"
    else
      printf 'permitrootlogin yes\npasswordauthentication yes\n'
    fi
  fi
}
"""
DOCKER_MOCKS = r"""
VERSION_CODENAME=trixie
LEGACY_DOCKER_LIST=''
apt-get() { :; }; apt_install() { :; }
dpkg() { printf 'amd64\n'; }
curl() { printf 'fixture public key\n' > "$WORK_DIR/docker.asc"; }
gpg() { :; }; dockerd() { :; }; docker() { :; }
systemctl() { printf 'systemctl %s\n' "$*" >> "$TRACE"; }
"""


class WorkflowFixture(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.key_dir = tempfile.TemporaryDirectory()
        key = Path(cls.key_dir.name) / "test-key"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)], check=True)
        cls.public_key = key.with_suffix(".pub").read_text().strip()

    @classmethod
    def tearDownClass(cls):
        cls.key_dir.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.fixture = Path(self.temp.name)
        self.root = self.fixture / "root"
        self.write("usr/share/zoneinfo/UTC", "")
        self.write("usr/share/zoneinfo/Asia/Shanghai", "")
        self.write("home/ops/.ssh/authorized_keys", self.public_key + "\n")
        (self.fixture / "public key.pub").write_text(self.public_key + "\n")
        self.config = self.fixture / "config.conf"
        self.config.write_text("SSH_PUBLIC_KEY_FILE=./public key.pub\n")

    def tearDown(self):
        self.temp.cleanup()

    def write(self, relative, content):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def run_bash(self, script, ok=True):
        env = dict(os.environ, FIXTURE=str(self.fixture), PROJECT=str(PROJECT))
        result = subprocess.run(["bash", "-c", PRELUDE + script], env=env,
                                text=True, capture_output=True, timeout=15)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def trace(self):
        path = self.fixture / "trace"
        return path.read_text() if path.exists() else ""

class WorkflowTests(WorkflowFixture):
    def test_config_relative_paths_and_valid_keys(self):
        self.config.write_text("SSH_PUBLIC_KEY_FILE=./public key.pub\nALLOW_TCP_PORTS=80 443\nTIMEZONE=Asia/Shanghai\n")
        result = self.run_bash(r'load_config "$FIXTURE/config.conf"; load_public_keys; printf "%s\n" "$SSH_PUBLIC_KEY_FILE"; declare -p PUBLIC_KEYS')
        self.assertIn(str(self.fixture / "public key.pub"), result.stdout)
        self.assertIn(self.public_key, result.stdout)

    def test_config_never_executes_shell_expressions(self):
        self.config.write_text(f"ADMIN_USER=$(touch {self.fixture}/executed)\n")
        self.run_bash(r'load_config "$FIXTURE/config.conf"', ok=False)
        self.assertFalse((self.fixture / "executed").exists())

    def test_invalid_config_is_rejected(self):
        for value in ["UNKNOWN=yes", "INSTALL_DOCKER=maybe", "ALLOW_TCP_PORTS=0",
                      "ALLOW_TCP_PORTS=65536", "ALLOW_TCP_PORTS=22;touch", "ADMIN_USER=root"]:
            with self.subTest(value=value):
                self.config.write_text(value + "\n")
                self.run_bash(r'load_config "$FIXTURE/config.conf"', ok=False)

    def test_malformed_second_public_key_is_rejected(self):
        (self.fixture / "public key.pub").write_text(self.public_key + "\nssh-ed25519 garbage\n")
        self.run_bash(r'load_config "$FIXTURE/config.conf"; load_public_keys', ok=False)

    def test_atomic_write_is_idempotent_and_backs_up_original(self):
        target = self.write("etc/example.conf", "old\n")
        result = self.run_bash(r"""
write_managed_file "$ROOT_PREFIX/etc/example.conf" 0644 <<< new
printf 'first=%s\n' "$FILE_CHANGED"
write_managed_file "$ROOT_PREFIX/etc/example.conf" 0644 <<< new
printf 'second=%s\n' "$FILE_CHANGED"
""")
        self.assertEqual(target.read_text(), "new\n")
        self.assertEqual((self.fixture / "backups/etc/example.conf").read_text(), "old\n")
        self.assertIn("first=yes\nsecond=no", result.stdout)

    def test_candidate_validation_failure_keeps_original(self):
        target = self.write("etc/example.conf", "old\n")
        self.run_bash(r'reject() { return 1; }; write_managed_file "$ROOT_PREFIX/etc/example.conf" 0644 reject <<< invalid', ok=False)
        self.assertEqual(target.read_text(), "old\n")

    def test_symlink_target_is_rejected(self):
        target = self.write("etc/real.conf", "old\n")
        target.with_name("link.conf").symlink_to(target)
        self.run_bash(r'write_managed_file "$ROOT_PREFIX/etc/link.conf" 0644 <<< new', ok=False)
        self.assertEqual(target.read_text(), "old\n")

    def test_existing_user_and_key_comment_are_preserved(self):
        self.run_bash(ADMIN_MOCKS + r"""
load_config "$FIXTURE/config.conf"; load_public_keys
PUBLIC_KEYS=("$PUBLIC_KEYS changed-comment")
configure_admin
configure_admin
""")
        self.assertEqual((self.root / "home/ops/.ssh/authorized_keys").read_text(), self.public_key + "\n")
        self.assertIn("NOPASSWD", (self.root / "etc/sudoers.d/90-vps-init").read_text())

    def test_sudo_validation_failure_restores_policy(self):
        target = self.write("etc/sudoers.d/90-vps-init", "old-policy\n")
        self.run_bash(ADMIN_MOCKS + r"""
load_config "$FIXTURE/config.conf"; load_public_keys
visudo() { [[ "$1" == -cf ]]; }
configure_admin
""", ok=False)
        self.assertEqual(target.read_text(), "old-policy\n")

    def test_ssh_ports_are_allowed_before_firewall_enable(self):
        self.run_bash(r"""
sshd() { printf 'port 2200\nport 22\n'; }
ss() { printf 'LISTEN 0 128 0.0.0.0:2244 0.0.0.0:* users:(("sshd",pid=123,fd=3))\n'; }
ufw() { printf '%s\n' "$*" >> "$TRACE"; }
TCP_PORTS=(443); UDP_PORTS=()
read_ssh_ports; configure_firewall
""")
        for port in [22, 2200, 2222, 2244]:
            self.assertLess(self.trace().index(f"allow {port}/tcp"), self.trace().index("--force enable"))
        self.assertNotIn("reset", self.trace())

    def test_unknown_live_ssh_port_stops_before_firewall(self):
        self.run_bash(r"""
SSH_CONNECTION=''
sshd() { printf 'port 22\n'; }
ss() { :; }
read_ssh_ports
""", ok=False)

    def test_existing_parent_directory_permissions_are_preserved(self):
        target = self.write("private/config.conf", "old\n")
        target.parent.chmod(0o700)
        self.run_bash(r'write_managed_file "$ROOT_PREFIX/private/config.conf" 0644 <<< new')
        self.assertEqual(target.parent.stat().st_mode & 0o777, 0o700)

    def test_fail2ban_journal_config(self):
        self.run_bash(r"""
apt_install() { :; }; systemctl() { :; }; fail2ban-client() { :; }
SSH_PORTS=(22 2222); configure_fail2ban
""")
        data = (self.root / "etc/fail2ban/jail.d/90-vps-init.local").read_text()
        self.assertIn("backend = systemd", data)
        self.assertIn("port = 22,2222", data)
        self.assertNotIn("logpath", data)
        self.assertNotIn("#", data)

    def test_invalid_fail2ban_config_restores_original(self):
        target = self.write("etc/fail2ban/jail.d/90-vps-init.local", "old\n")
        self.run_bash(r"""
apt_install() { :; }; systemctl() { :; }; fail2ban-client() { return 1; }
SSH_PORTS=(22); configure_fail2ban
""", ok=False)
        self.assertEqual(target.read_text(), "old\n")

    def test_docker_config_preserves_mirrors_and_rotation(self):
        self.write("etc/docker/daemon.json", json.dumps({
            "registry-mirrors": ["https://example.com"], "log-opts": {"max-size": "20m"},
        }))
        data = json.loads(self.run_bash(r'docker_log_config "$ROOT_PREFIX/etc/docker/daemon.json"').stdout)
        self.assertEqual(data["registry-mirrors"], ["https://example.com"])
        self.assertEqual(data["log-opts"], {"max-size": "20m", "max-file": "3"})

    def test_custom_docker_log_driver_is_preserved(self):
        original = {"log-driver": "journald", "log-opts": {"tag": "service"}}
        self.write("etc/docker/daemon.json", json.dumps(original))
        data = json.loads(self.run_bash(r'docker_log_config "$ROOT_PREFIX/etc/docker/daemon.json"').stdout)
        self.assertEqual(data, original)

    def test_malformed_docker_json_is_not_overwritten(self):
        target = self.write("etc/docker/daemon.json", "{invalid")
        self.run_bash(r'docker_log_config "$ROOT_PREFIX/etc/docker/daemon.json"', ok=False)
        self.assertEqual(target.read_text(), "{invalid")

    def test_docker_rerun_preserves_config_and_avoids_another_restart(self):
        self.write("etc/docker/daemon.json", json.dumps({"registry-mirrors": ["https://example.com"]}))
        self.run_bash(DOCKER_MOCKS + "install_docker\ninstall_docker\n")
        data = json.loads((self.root / "etc/docker/daemon.json").read_text())
        self.assertEqual(data["registry-mirrors"], ["https://example.com"])
        self.assertEqual(self.trace().count("systemctl restart docker.service"), 1)

    def test_docker_candidate_failure_keeps_original_config(self):
        target = self.write("etc/docker/daemon.json", '{"registry-mirrors": []}\n')
        self.run_bash(DOCKER_MOCKS + "dockerd() { return 1; }\ninstall_docker\n", ok=False)
        self.assertEqual(target.read_text(), '{"registry-mirrors": []}\n')
        self.assertNotIn("systemctl restart", self.trace())

    def test_docker_restart_failure_restores_original_config(self):
        target = self.write("etc/docker/daemon.json", '{"registry-mirrors": []}\n')
        self.run_bash(DOCKER_MOCKS + r"""
systemctl() { [[ "$1" != restart ]]; }
install_docker
""", ok=False)
        self.assertEqual(target.read_text(), '{"registry-mirrors": []}\n')

    def test_docker_group_uses_configured_admin_not_current_user(self):
        self.run_bash(DOCKER_MOCKS + r"""
DOCKER_ADD_ADMIN_TO_GROUP=yes
USER=root
getent() { :; }
usermod() { printf 'usermod %s\n' "$*" >> "$TRACE"; }
install_docker
""")
        self.assertIn("usermod -aG docker ops", self.trace())

    def test_legacy_docker_repo_migrates_with_backup(self):
        target = self.write("etc/apt/sources.list.d/docker.list",
                            "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] "
                            "https://download.docker.com/linux/debian bookworm stable\n")
        self.run_bash(r"""
dpkg-query() { return 1; }; dpkg() { printf 'amd64\n'; }
docker_preflight; migrate_legacy_docker_source
""")
        self.assertFalse(target.exists())
        self.assertTrue((self.fixture / "backups/etc/apt/sources.list.d/docker.list").exists())

    def test_other_docker_repo_is_rejected(self):
        target = self.write("etc/apt/sources.list.d/docker.sources", "URIs: https://download.docker.com/linux/debian\n")
        self.run_bash(r'dpkg-query() { return 1; }; dpkg() { printf "amd64\n"; }; docker_preflight', ok=False)
        self.assertTrue(target.exists())

    def test_conflicting_docker_package_is_rejected(self):
        self.run_bash(r'dpkg-query() { printf "install ok installed"; }; docker_preflight', ok=False)

    def test_comment_only_docker_repo_is_ignored(self):
        self.write("etc/apt/sources.list", "  # https://download.docker.com/linux/debian\n")
        self.run_bash(r'dpkg-query() { return 1; }; dpkg() { printf "amd64\n"; }; docker_preflight')

    def test_hardening_requires_admin_session_and_key_confirmation(self):
        for guard in ["SUDO_USER=root", "CONFIRM_KEY_LOGIN=no"]:
            with self.subTest(guard=guard):
                self.run_bash(SSH_MOCKS + guard + "\nharden_ssh\n", ok=False)
                self.assertNotIn("timer", self.trace())

    def test_recovery_is_scheduled_before_ssh_reload(self):
        self.run_bash(SSH_MOCKS + "harden_ssh\n")
        self.assertLess(self.trace().index("timer "), self.trace().index("systemctl reload ssh.service"))
        self.assertTrue((self.root / "var/lib/vps-init/ssh-pending").is_dir())

    def test_timer_failure_does_not_change_ssh(self):
        self.run_bash(SSH_MOCKS + "systemd-run() { return 1; }\nharden_ssh\n", ok=False)
        self.assertFalse((self.root / "etc/ssh/sshd_config.d/00-00-vps-init.conf").exists())
        self.assertFalse((self.root / "var/lib/vps-init/ssh-pending").exists())

    def test_effective_ssh_override_restores_previous_config(self):
        target = self.write("etc/ssh/sshd_config.d/00-00-vps-init.conf", "old-config\n")
        self.run_bash(SSH_MOCKS + r"""
sshd() { [[ "$1" != -T ]] || printf 'passwordauthentication yes\n'; }
harden_ssh
""", ok=False)
        self.assertEqual(target.read_text(), "old-config\n")
        self.assertFalse((self.root / "var/lib/vps-init/ssh-pending").exists())

    def test_old_connection_cannot_cancel_recovery(self):
        self.run_bash(SSH_MOCKS + "harden_ssh\nconfirm_ssh\n", ok=False)
        self.assertTrue((self.root / "var/lib/vps-init/ssh-pending").exists())
        self.assertNotIn("systemctl stop", self.trace())

    def test_another_preexisting_connection_cannot_cancel_recovery(self):
        self.run_bash(SSH_MOCKS + r"""
harden_ssh
SSH_CONNECTION='192.0.2.1 12346 192.0.2.2 2222'
confirm_ssh
""", ok=False)
        self.assertTrue((self.root / "var/lib/vps-init/ssh-pending").exists())
        self.assertNotIn("systemctl stop", self.trace())

    def test_ipv6_connection_addresses_are_normalized(self):
        result = self.run_bash(r"""
SSH_CONNECTION='2001:0db8:0:0:0:0:0:1 12345 2001:db8::2 2222'
ssh_connection_token
ss() { printf '0 0 [2001:db8::2]:2222 [2001:db8::1]:12345\n'; }
snapshot_ssh_connections
""")
        self.assertEqual(result.stdout.splitlines(), ["2001:db8::1 12345 2001:db8::2 2222"] * 2)

    def test_new_connection_confirms_and_cancels_recovery(self):
        self.run_bash(SSH_MOCKS + r"""
harden_ssh
SSH_CONNECTION='192.0.2.1 54321 192.0.2.2 2222'
confirm_ssh
""")
        self.assertFalse((self.root / "var/lib/vps-init/ssh-pending").exists())
        self.assertIn("systemctl stop vps-init-ssh-rollback.timer", self.trace())

    def test_generated_recovery_restores_and_reloads(self):
        self.run_bash(SSH_MOCKS + "harden_ssh\n")
        pending = self.root / "var/lib/vps-init/ssh-pending"
        (pending / "previous.conf").write_text("previous\n")
        script = (self.root / "var/lib/vps-init/ssh-rollback.sh").read_text()
        for path in ["/run/lock/vps-init.lock", "/var/lib/vps-init/ssh-pending",
                     "/etc/ssh/sshd_config.d/00-00-vps-init.conf"]:
            script = script.replace(path, str(self.root) + path)
        script = script.replace("/usr/sbin/sshd", "sshd")
        (self.root / "run/lock").mkdir(parents=True)
        (self.root / "run/lock/vps-init.lock").touch()
        self.run_bash(SSH_MOCKS + "logger() { :; }\n" + script)
        self.assertEqual((self.root / "etc/ssh/sshd_config.d/00-00-vps-init.conf").read_text(), "previous\n")
        self.assertFalse(pending.exists())
        self.assertIn("systemctl reload ssh.service", self.trace())

    def test_package_failure_stops_before_later_steps(self):
        result = self.run_bash(r'apt-get() { return 42; }; prepare_packages; printf UNEXPECTED_SUCCESS', ok=False)
        self.assertEqual(result.returncode, 42)
        self.assertNotIn("UNEXPECTED_SUCCESS", result.stdout)

    def test_real_entrypoint_help_without_config(self):
        result = subprocess.run(["bash", str(PROJECT / "setup.sh"), "--help"],
                                text=True, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("用法", result.stdout)
        self.assertIn("Syncthing/Nginx/Mihomo", result.stdout)

    def test_real_plan_does_not_modify_system(self):
        result = subprocess.run(["bash", str(PROJECT / "setup.sh"), "plan", "--config", str(self.config)],
                                text=True, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("已验证 1 条公钥", result.stdout)


if __name__ == "__main__":
    unittest.main()
