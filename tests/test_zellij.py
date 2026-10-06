"""Zellij installs use verified archives and preserve existing tools on failure."""
import hashlib
import io
import os
import tarfile

from test_workflow import WorkflowFixture


HEADER = r'''
. "$PROJECT/modules/tools.sh"
INSTALL_COMMON_TOOLS=yes
TERMINAL_MULTIPLEXER=zellij
EXTRA_PACKAGE_LIST=()
apt_install() { printf 'packages %s\n' "$*" >> "$TRACE"; }
apt-get() { :; }
dpkg() { printf '%s\n' "${ARCHITECTURE:-amd64}"; }
dpkg-query() { printf 'install ok installed'; }
curl() {
  printf 'download %s\n' "$*" >> "$TRACE"
  local destination=''
  while (($#)); do
    case "$1" in -o) destination=$2; shift 2 ;; *) shift ;; esac
  done
  cp "$FIXTURE/release.tar.gz" "$destination"
}
'''


class ZellijTests(WorkflowFixture):
    def run_bash(self, script, ok=True):
        return super().run_bash(HEADER + script, ok=ok)

    def archive(self, version='0.45.1', extra_path=None):
        archive = self.fixture / 'release.tar.gz'
        binary = f'#!/bin/bash\nprintf "zellij {version}\\n"\n'.encode()
        with tarfile.open(archive, 'w:gz') as package:
            entry = tarfile.TarInfo('zellij')
            entry.size = len(binary)
            entry.mode = 0o755
            package.addfile(entry, io.BytesIO(binary))
            if extra_path:
                entry = tarfile.TarInfo(extra_path)
                entry.size = 4
                package.addfile(entry, io.BytesIO(b'evil'))
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        # Substitute a fixture digest; production pins the official release digests.
        return 'zellij_asset() { ZELLIJ_ASSET=fixture.tar.gz; ZELLIJ_SHA256=' + digest + '; }\n'

    def old_binary(self):
        target = self.write('usr/local/bin/zellij', '#!/bin/bash\nprintf "zellij 0.44.0\\n"\n')
        target.chmod(0o755)
        return target

    def test_config_defaults_to_zellij_and_accepts_tmux_or_none(self):
        result = self.run_bash(r'load_config "$FIXTURE/config.conf"; printf "%s\n" "$TERMINAL_MULTIPLEXER"')
        self.assertIn('zellij', result.stdout)
        for value in ['tmux', 'none']:
            self.config.write_text('TERMINAL_MULTIPLEXER=' + value + '\n')
            self.run_bash(r'load_config "$FIXTURE/config.conf"')
        self.config.write_text(f'TERMINAL_MULTIPLEXER=$(touch {self.fixture}/executed)\n')
        self.run_bash(r'load_config "$FIXTURE/config.conf"', ok=False)
        self.assertFalse((self.fixture / 'executed').exists())

    def test_default_tools_install_zellij_without_adding_tmux(self):
        self.run_bash(self.archive() + 'install_common_tools\ncheck_common_tools\n')
        self.assertTrue((self.root / 'usr/local/bin/zellij').is_file())
        self.assertNotIn('tmux', self.trace())
        self.assertIn('download ', self.trace())
        self.assertIn('--proto =https --proto-redir =https', self.trace())

    def test_dns_tools_use_real_package_when_virtual_dnsutils_is_not_installed(self):
        self.run_bash(r'''
TERMINAL_MULTIPLEXER=none
dpkg-query() {
  if [[ "${@: -1}" == dnsutils ]]; then printf 'unknown ok not-installed';
  else printf 'install ok installed'; fi
}
install_common_tools
check_common_tools
''')
        self.assertIn(' bind9-dnsutils ', self.trace())
        self.assertNotIn(' dnsutils ', self.trace())

    def test_missing_package_reports_observed_status(self):
        result = self.run_bash(r'''
TERMINAL_MULTIPLEXER=none
dpkg-query() {
  if [[ "${@: -1}" == bind9-dnsutils ]]; then printf 'deinstall ok config-files';
  else printf 'install ok installed'; fi
}
check_common_tools
''')
        self.assertIn('bind9-dnsutils：deinstall ok config-files', result.stdout)
        self.assertIn('警告：常用工具尚未安装：bind9-dnsutils', result.stdout)

    def test_package_query_failure_is_logged_and_not_mistaken_for_installed(self):
        result = self.run_bash(r'''
dpkg-query() { printf 'package database unavailable\n' >&2; return 2; }
check_common_tools
''', ok=False)
        self.assertIn('package database unavailable', result.stdout)
        self.assertIn('查询退出码 2', result.stdout)

    def test_bad_optional_package_is_skipped_while_other_tools_and_later_steps_run(self):
        result = self.run_bash(r'''
TERMINAL_MULTIPLEXER=none
COMMON_PACKAGES=(git typo-package jq)
apt-get() {
  [[ "${@: -1}" != typo-package ]] || { printf 'E: Unable to locate package typo-package\n' >&2; return 100; }
}
dpkg-query() {
  [[ "${@: -1}" != typo-package ]] || { printf 'no packages found\n' >&2; return 1; }
  printf 'install ok installed'
}
install_common_tools
printf 'LATER_MODULE_RAN\n'
check_common_tools
printf 'LATER_CHECK_RAN\n'
report_warnings
''')
        self.assertIn('packages git jq', self.trace())
        self.assertNotIn('packages git typo-package', self.trace())
        self.assertIn('LATER_MODULE_RAN', result.stdout)
        self.assertIn('LATER_CHECK_RAN', result.stdout)
        self.assertIn('以下项目未完成', result.stdout)
        self.assertIn('typo-package', result.stdout)

    def test_extra_package_without_candidate_is_skipped_even_when_defaults_disabled(self):
        result = self.run_bash(r'''
INSTALL_COMMON_TOOLS=no
EXTRA_PACKAGE_LIST=(missing-extra sqlite3)
apt-get() {
  [[ "${@: -1}" != missing-extra ]] || { printf "E: Package 'missing-extra' has no installation candidate\n"; return 100; }
}
install_common_tools
report_warnings
''')
        self.assertEqual(self.trace(), 'packages sqlite3\n')
        self.assertIn('跳过常用工具 missing-extra', result.stdout)

    def test_all_missing_optional_packages_do_not_call_real_installer(self):
        result = self.run_bash(r'''
TERMINAL_MULTIPLEXER=none
COMMON_PACKAGES=(missing-package)
apt-get() { printf 'E: Unable to locate package missing-package\n'; return 100; }
install_common_tools
printf 'CONTINUED\n'
''')
        self.assertFalse((self.fixture / 'trace').exists())
        self.assertIn('CONTINUED', result.stdout)

    def test_dependency_failure_is_not_silently_treated_as_bad_package_name(self):
        result = self.run_bash(r'''
TERMINAL_MULTIPLEXER=none
COMMON_PACKAGES=(git)
apt-get() { printf 'E: Unmet dependencies. Try apt --fix-broken install.\n'; return 100; }
install_common_tools
printf 'UNEXPECTED_CONTINUE\n'
''', ok=False)
        self.assertNotIn('UNEXPECTED_CONTINUE', result.stdout)
        self.assertIn('APT 预检查失败', result.stderr)

    def test_actual_package_install_failure_still_stops_with_original_exit_code(self):
        result = self.run_bash(r'''
TERMINAL_MULTIPLEXER=none
COMMON_PACKAGES=(git)
apt_install() { return 100; }
install_common_tools
printf 'UNEXPECTED_CONTINUE\n'
''', ok=False)
        self.assertEqual(result.returncode, 100)
        self.assertNotIn('UNEXPECTED_CONTINUE', result.stdout)

    def test_partially_configured_tool_is_fatal_instead_of_missing_warning(self):
        result = self.run_bash(r'''
dpkg-query() { printf 'install ok half-configured'; }
check_common_tools
''', ok=False)
        self.assertIn('软件包状态异常', result.stderr)

    def test_repeated_install_keeps_binary_and_user_config_without_second_download(self):
        config = self.write('home/ops/.config/zellij/config.kdl', 'theme "custom"\n')
        self.run_bash(self.archive() + 'install_common_tools\ninstall_common_tools\n')
        self.assertEqual(self.trace().count('download '), 1)
        self.assertEqual(config.read_text(), 'theme "custom"\n')
        self.assertEqual((self.root / 'usr/local/bin/zellij').stat().st_mode & 0o777, 0o755)
        self.assertFalse((self.root / 'home/ops/.bashrc').exists())

    def test_updating_old_binary_saves_original(self):
        target = self.old_binary()
        previous = target.read_bytes()
        self.run_bash(self.archive() + 'install_common_tools\ncheck_common_tools\n')
        self.assertNotEqual(target.read_bytes(), previous)
        self.assertEqual((self.fixture / 'backups/usr/local/bin/zellij').read_bytes(), previous)

    def test_tmux_choice_uses_apt_and_does_not_touch_existing_zellij(self):
        target = self.old_binary()
        previous = target.read_bytes()
        self.run_bash('TERMINAL_MULTIPLEXER=tmux\ninstall_common_tools\ncheck_common_tools\n')
        self.assertIn('tmux', self.trace())
        self.assertNotIn('download ', self.trace())
        self.assertEqual(target.read_bytes(), previous)

    def test_none_choice_does_not_install_either_terminal_tool(self):
        self.run_bash('TERMINAL_MULTIPLEXER=none\ninstall_common_tools\ncheck_common_tools\n')
        self.assertIn('htop', self.trace())
        self.assertNotIn('tmux', self.trace())
        self.assertNotIn('download ', self.trace())

    def test_disabled_common_tools_do_not_download_even_on_unsupported_architecture(self):
        self.run_bash('INSTALL_COMMON_TOOLS=no\nARCHITECTURE=armhf\nEXTRA_PACKAGE_LIST=(sqlite3)\ninstall_common_tools\ncheck_common_tools\n')
        self.assertEqual(self.trace(), 'packages sqlite3\n')

    def test_bad_checksum_never_overwrites_existing_binary(self):
        target = self.old_binary()
        previous = target.read_bytes()
        self.run_bash(self.archive() + r'''
zellij_asset() { ZELLIJ_ASSET=fixture.tar.gz; ZELLIJ_SHA256=0000000000000000000000000000000000000000000000000000000000000000; }
install_common_tools
''', ok=False)
        self.assertEqual(target.read_bytes(), previous)
        self.assertFalse((self.fixture / 'backups/usr/local/bin/zellij').exists())

    def test_failed_download_keeps_existing_binary(self):
        target = self.old_binary()
        previous = target.read_bytes()
        self.run_bash(self.archive() + 'curl() { return 22; }\ninstall_common_tools\n', ok=False)
        self.assertEqual(target.read_bytes(), previous)

    def test_wrong_binary_version_rejected_before_replacement(self):
        target = self.old_binary()
        previous = target.read_bytes()
        self.run_bash(self.archive(version='0.1.0') + 'install_common_tools\n', ok=False)
        self.assertEqual(target.read_bytes(), previous)
        self.assertFalse((self.fixture / 'backups/usr/local/bin/zellij').exists())

    def test_only_binary_member_is_extracted_from_archive(self):
        escaped = self.fixture / 'escaped'
        self.run_bash(self.archive(extra_path=str(escaped)) + 'install_common_tools\n')
        self.assertFalse(escaped.exists())
        self.assertTrue((self.root / 'usr/local/bin/zellij').is_file())

    def test_symlink_hardlink_or_writable_binary_stops_before_installation(self):
        target = self.old_binary()
        destination = self.write('usr/local/bin/original', 'preserve\n')
        previous = target.read_bytes()
        target.unlink()
        target.symlink_to(destination)
        self.run_bash('install_common_tools\n', ok=False)
        target.unlink()
        os.link(destination, target)
        self.run_bash('install_common_tools\n', ok=False)
        target.unlink()
        target.write_bytes(previous)
        target.chmod(0o777)
        self.run_bash('install_common_tools\n', ok=False)
        self.assertEqual(self.trace(), '')
        self.assertEqual(destination.read_text(), 'preserve\n')

    def test_release_assets_match_architecture_and_fixed_digest(self):
        for architecture, asset in [('amd64', 'x86_64'), ('arm64', 'aarch64')]:
            result = self.run_bash(f'ARCHITECTURE={architecture}\nzellij_asset\nprintf "%s|%s\\n" "$ZELLIJ_ASSET" "$ZELLIJ_SHA256"')
            self.assertIn(f'zellij-{asset}-unknown-linux-musl.tar.gz', result.stdout)
            digest = result.stdout.strip().split('|')[1]
            self.assertEqual(len(digest), 64)
        self.run_bash('ARCHITECTURE=armhf\ninstall_common_tools\n', ok=False)
        self.assertEqual(self.trace(), '')

    def test_check_rejects_missing_or_wrong_version(self):
        self.run_bash('check_common_tools\n', ok=False)
        self.old_binary()
        self.run_bash('check_common_tools\n', ok=False)
