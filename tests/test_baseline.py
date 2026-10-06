"""Host baseline and maintenance checks; no real host configuration is changed."""
import os
import subprocess

from test_workflow import WorkflowFixture


HEADER = r'''
. "$PROJECT/modules/host.sh"
. "$PROJECT/modules/time.sh"
. "$PROJECT/modules/swap.sh"
. "$PROJECT/modules/maintenance.sh"
SERVER_HOSTNAME=''
SYSTEM_LOCALE=''
ENABLE_TIME_SYNC=yes
NTP_SERVERS=''
SWAP_SIZE_MB=0
INSTALL_MONITORING_TOOLS=no
ENABLE_SYSSTAT_HISTORY=no
SYSSTAT_HISTORY_DAYS=7
ENABLE_FSTRIM=no
INSTALL_BACKUP_TOOLS=no
INSTALL_HARDWARE_TOOLS=no
'''
TIME_MOCKS = r'''
PROVIDERS=''
NTP_ENABLED=no
NTP_SYNCED=no
dpkg-query() { [[ " $PROVIDERS " != *" ${@: -1} "* ]] || printf 'install ok installed'; }
apt_install() {
  printf 'packages %s\n' "$*" >> "$TRACE"
  [[ " $* " != *' systemd-timesyncd '* ]] || PROVIDERS=systemd-timesyncd
}
timedatectl() {
  case "$*" in
    *property=NTPSynchronized*) printf '%s\n' "$NTP_SYNCED" ;;
    *property=NTP*) printf '%s\n' "$NTP_ENABLED" ;;
    *) return 99 ;;
  esac
}
systemctl() { printf 'systemctl %s\n' "$*" >> "$TRACE"; }
'''
MAINTENANCE_MOCKS = r'''
apt_install() { printf 'packages %s\n' "$*" >> "$TRACE"; }
systemctl() {
  printf 'systemctl %s\n' "$*" >> "$TRACE"
  if [[ "$1" == show ]]; then printf '%s\n' "${ROTATE_STATE:-not-found}"; fi
}
'''
SWAP_MOCKS = r'''
SWAP_SIZE_MB=128
mkswap() { /usr/sbin/mkswap "$@"; }
blkid() { /usr/sbin/blkid "$@"; }
findmnt() { printf '%s\n' "${FILESYSTEM:-ext4}"; }
df() { printf 'Filesystem 1M-blocks Used Available Use%% Mounted\nfixture 10000 0 %s 0%% /\n' "${AVAILABLE:-10000}"; }
swapon() { [[ ! -f "$FIXTURE/active-swap" ]] || cat "$FIXTURE/active-swap"; }
dd() {
  printf 'allocate\n' >> "$TRACE"
  local arg path=''
  for arg in "$@"; do [[ "$arg" != of=* ]] || path=${arg#of=}; done
  # A sparse test fixture saves test disk space; production uses real dd.
  truncate -s "$((SWAP_SIZE_MB * 1024 * 1024))" "$path"
}
systemctl() {
  printf 'systemctl %s\n' "$*" >> "$TRACE"
  if [[ "$1" == enable ]]; then
    [[ "${FAIL_ACTIVATION:-no}" != yes || "${PARTIAL_ACTIVATION:-no}" == yes ]] || return 1
    printf '%s\n' "$ROOT_PREFIX/var/lib/vps-init/swapfile" > "$FIXTURE/active-swap"
    [[ "${FAIL_ACTIVATION:-no}" != yes ]] || return 1
  fi
}
'''


class BaselineTests(WorkflowFixture):
    def run_bash(self, script, ok=True):
        return super().run_bash(HEADER + script, ok=ok)

    def test_defaults_add_time_and_history_without_renaming_or_allocating_swap(self):
        result = self.run_bash(r'''
load_config "$FIXTURE/config.conf"
printf '%s|%s|%s|%s|%s|%s|%s\n' "$ENABLE_TIME_SYNC" "$ENABLE_SYSSTAT_HISTORY" \
  "$INSTALL_MONITORING_TOOLS" "$SERVER_HOSTNAME" "$SYSTEM_LOCALE" "$SWAP_SIZE_MB" "$ENABLE_FSTRIM"
''')
        self.assertIn('yes|yes|yes|||0|no', result.stdout)

    def test_invalid_baseline_values_stop_before_writes(self):
        for value in ['SERVER_HOSTNAME=localhost', 'SERVER_HOSTNAME=-home', 'SERVER_HOSTNAME=home.local',
                      'SERVER_HOSTNAME=' + 'a' * 64, 'SYSTEM_LOCALE=zh_CN.UTF-8', 'ENABLE_TIME_SYNC=maybe',
                      'SWAP_SIZE_MB=127', 'SWAP_SIZE_MB=32769', 'SWAP_SIZE_MB=0128',
                      'SYSSTAT_HISTORY_DAYS=0', 'SYSSTAT_HISTORY_DAYS=366',
                      'NTP_SERVERS=pool.ntp.org:123', 'NTP_SERVERS=https://pool.ntp.org',
                      'NTP_SERVERS=999.1.2.3', 'NTP_SERVERS=2001:::1', 'NTP_SERVERS=1:2:3',
                      'NTP_SERVERS=::ffff:192.0.2.1', 'NTP_SERVERS=a..b',
                      'ENABLE_TIME_SYNC=no\nNTP_SERVERS=pool.ntp.org']:
            with self.subTest(value=value):
                self.config.write_text(value + '\n')
                self.run_bash(r'load_config "$FIXTURE/config.conf"', ok=False)
        self.assertFalse((self.root / 'var/lib/vps-init/swapfile').exists())

    def test_ntp_addresses_accept_dns_ipv4_and_compressed_ipv6_without_shell_execution(self):
        self.config.write_text('NTP_SERVERS=pool.ntp.org. 192.0.2.1 2001:db8::1 ::1 1:2:3:4:5:6:7:8\n')
        self.run_bash(r'load_config "$FIXTURE/config.conf"')
        self.config.write_text(f'NTP_SERVERS=$(touch {self.fixture}/executed)\n')
        self.run_bash(r'load_config "$FIXTURE/config.conf"', ok=False)
        self.assertFalse((self.fixture / 'executed').exists())

    def test_hostname_preserves_aliases_and_cloud_init_on_repeated_runs(self):
        hosts = self.write('etc/hosts', '127.0.0.1 localhost\n127.0.1.1 old.example old # original\n::1 localhost\n')
        self.write('etc/hostname', 'old\n')
        self.write('etc/cloud/cloud.cfg', 'manage_etc_hosts: false\n')
        self.run_bash(r'''
SERVER_HOSTNAME=home01
hostnamectl() { printf '%s\n' "$*" >> "$TRACE"; }
configure_hostname
configure_hostname
''')
        self.assertIn('old.example old home01 # original', hosts.read_text())
        self.assertEqual(hosts.read_text().count('home01'), 1)
        self.assertEqual((self.root / 'etc/hostname').read_text(), 'home01\n')
        self.assertEqual((self.root / 'etc/cloud/cloud.cfg.d/99-vps-init-hostname.cfg').read_text(),
                         'preserve_hostname: true\n')
        self.assertEqual((self.root / 'etc/cloud/cloud.cfg').read_text(), 'manage_etc_hosts: false\n')

    def test_hostname_failure_restores_all_modified_files_and_runtime_name(self):
        hosts = self.write('etc/hosts', '127.0.0.1 localhost\n')
        hostname = self.write('etc/hostname', 'old\n')
        self.write('etc/cloud/cloud.cfg', 'fixture\n')
        cloud = self.write('etc/cloud/cloud.cfg.d/99-vps-init-hostname.cfg', 'preserve_hostname: false\n')
        self.run_bash(r'''
SERVER_HOSTNAME=home01
uname() { printf 'old\n'; }
hostnamectl() { printf '%s\n' "$*" >> "$TRACE"; return 1; }
configure_hostname
''', ok=False)
        self.assertEqual(hosts.read_text(), '127.0.0.1 localhost\n')
        self.assertEqual(hostname.read_text(), 'old\n')
        self.assertEqual(cloud.read_text(), 'preserve_hostname: false\n')
        self.assertIn('--transient set-hostname old', self.trace())

    def test_locale_assignment_preserves_other_categories_without_executing_config(self):
        locale = self.write('etc/default/locale', '# local policy\nLANG=en_US.UTF-8\nexport LANG=C\nLC_TIME=C\n')
        self.run_bash('SYSTEM_LOCALE=C.UTF-8\nconfigure_host\nconfigure_host\n')
        self.assertEqual(locale.read_text(), '# local policy\nLANG="C.UTF-8"\nLC_TIME=C\n')

    def test_host_preflight_rejects_symlink_without_changing_destination(self):
        target = self.write('etc/real-hostname', 'original\n')
        (self.root / 'etc/hostname').symlink_to(target)
        self.run_bash('SERVER_HOSTNAME=home01\nhost_preflight\n', ok=False)
        self.assertEqual(target.read_text(), 'original\n')

    def test_locale_debian13_compatibility_links_preserve_link_categories_and_backup(self):
        for destination in ['../locale.conf', '/etc/locale.conf']:
            with self.subTest(destination=destination):
                original = '# policy\nLANG=C\nLC_TIME=C\n'
                canonical = self.write('etc/locale.conf', original)
                legacy = self.root / 'etc/default/locale'
                legacy.parent.mkdir(parents=True, exist_ok=True)
                if legacy.is_symlink():
                    legacy.unlink()
                legacy.symlink_to(destination)
                self.run_bash('VERSION_ID=13\nSYSTEM_LOCALE=C.UTF-8\nhost_preflight\n'
                              'configure_host\nconfigure_host\ncheck_host\n')
                self.assertEqual(os.readlink(legacy), destination)
                self.assertEqual(canonical.read_text(), '# policy\nLANG="C.UTF-8"\nLC_TIME=C\n')
                self.assertEqual((self.fixture / 'backups/etc/locale.conf').read_text(), original)
                self.assertFalse((self.fixture / 'backups/etc/default/locale').exists())

    def test_locale_missing_files_use_distribution_default(self):
        for version, relative in [('12', 'etc/default/locale'), ('13', 'etc/locale.conf')]:
            with self.subTest(version=version):
                self.run_bash(f'VERSION_ID={version}\nSYSTEM_LOCALE=C.UTF-8\nhost_preflight\n'
                              'configure_host\ncheck_host\n')
                target = self.root / relative
                self.assertEqual(target.read_text(), 'LANG="C.UTF-8"\n')
                target.unlink()

    def test_locale_missing_canonical_file_keeps_standard_compatibility_link(self):
        legacy = self.root / 'etc/default/locale'
        legacy.parent.mkdir(parents=True)
        legacy.symlink_to('../locale.conf')
        self.run_bash('SYSTEM_LOCALE=C.UTF-8\nhost_preflight\nconfigure_host\ncheck_host\n')
        self.assertEqual(os.readlink(legacy), '../locale.conf')
        self.assertEqual((self.root / 'etc/locale.conf').read_text(), 'LANG="C.UTF-8"\n')

    def test_locale_preflight_rejects_unknown_link_without_writes(self):
        target = self.write('etc/other-config', 'original\n')
        legacy = self.root / 'etc/default/locale'
        legacy.parent.mkdir(parents=True)
        legacy.symlink_to('../other-config')
        self.run_bash('SYSTEM_LOCALE=C.UTF-8\nhost_preflight\n', ok=False)
        self.assertEqual(target.read_text(), 'original\n')
        self.assertFalse((self.root / 'etc/locale.conf').exists())

    def test_locale_preflight_rejects_chained_symlink_and_directory(self):
        target = self.write('etc/other-config', 'original\n')
        legacy = self.root / 'etc/default/locale'
        legacy.parent.mkdir(parents=True)
        legacy.symlink_to('../locale.conf')
        canonical = self.root / 'etc/locale.conf'
        canonical.symlink_to(target)
        self.run_bash('SYSTEM_LOCALE=C.UTF-8\nhost_preflight\n', ok=False)
        canonical.unlink()
        canonical.mkdir()
        self.run_bash('SYSTEM_LOCALE=C.UTF-8\nhost_preflight\n', ok=False)
        self.assertEqual(target.read_text(), 'original\n')

    def test_locale_empty_setting_leaves_unknown_link_untouched(self):
        target = self.write('etc/other-config', 'original\n')
        legacy = self.root / 'etc/default/locale'
        legacy.parent.mkdir(parents=True)
        legacy.symlink_to('../other-config')
        self.run_bash('host_preflight\nconfigure_host\ncheck_host\n')
        self.assertEqual(os.readlink(legacy), '../other-config')
        self.assertEqual(target.read_text(), 'original\n')

    def test_existing_chrony_is_enabled_without_replacement_or_config_changes(self):
        target = self.write('etc/chrony/chrony.conf', 'server existing.example iburst\n')
        self.run_bash(TIME_MOCKS + 'PROVIDERS=chrony\nconfigure_time_sync\n')
        self.assertIn('enable --now chrony.service', self.trace())
        self.assertNotIn('packages', self.trace())
        self.assertEqual(target.read_text(), 'server existing.example iburst\n')

    def test_custom_ntp_stops_on_existing_chrony_and_unknown_or_duplicate_providers(self):
        for settings in ['PROVIDERS=chrony\nNTP_SERVERS=pool.ntp.org', 'NTP_ENABLED=yes',
                         "PROVIDERS='chrony systemd-timesyncd'"]:
            with self.subTest(settings=settings):
                self.run_bash(TIME_MOCKS + settings + '\ntime_preflight\n', ok=False)
        self.assertNotIn('systemctl', self.trace())

    def test_timesyncd_sets_only_explicit_upstream_and_restarts_once(self):
        self.run_bash(TIME_MOCKS + "NTP_SERVERS='pool.ntp.org 2001:db8::1'\nconfigure_time_sync\nconfigure_time_sync\n")
        target = self.root / 'etc/systemd/timesyncd.conf.d/90-vps-init.conf'
        self.assertEqual(target.read_text(), '[Time]\nNTP=\nNTP=pool.ntp.org 2001:db8::1\n')
        self.assertEqual(self.trace().count('restart systemd-timesyncd.service'), 1)

    def test_timesyncd_restart_failure_restores_existing_dropin(self):
        target = self.write('etc/systemd/timesyncd.conf.d/90-vps-init.conf', '[Time]\nNTP=old.example\n')
        self.run_bash(TIME_MOCKS + r'''
NTP_SERVERS=new.example
systemctl() { printf '%s\n' "$*" >> "$TRACE"; [[ "$1" != restart ]]; }
configure_time_sync
''', ok=False)
        self.assertEqual(target.read_text(), '[Time]\nNTP=old.example\n')
        self.assertEqual(self.trace().count('restart systemd-timesyncd.service'), 2)

    def test_timesyncd_waiting_for_first_sync_is_reported_without_install_failure(self):
        result = self.run_bash(TIME_MOCKS + 'configure_time_sync\n')
        self.assertIn('尚未同步', result.stdout)
        self.assertFalse((self.root / 'etc/systemd/timesyncd.conf.d').exists())

    def test_time_disabled_keeps_existing_dropin_and_does_not_touch_service(self):
        target = self.write('etc/systemd/timesyncd.conf.d/90-vps-init.conf', '[Time]\nNTP=old.example\n')
        self.run_bash(TIME_MOCKS + 'ENABLE_TIME_SYNC=no\nconfigure_time_sync\ncheck_time_sync\n')
        self.assertEqual(target.read_text(), '[Time]\nNTP=old.example\n')
        self.assertEqual(self.trace(), '')

    def test_maintenance_packages_follow_explicit_selections(self):
        self.run_bash(MAINTENANCE_MOCKS + 'INSTALL_BACKUP_TOOLS=yes\nINSTALL_HARDWARE_TOOLS=yes\ninstall_maintenance_tools\n')
        for package in ['restic', 'smartmontools', 'nvme-cli', 'lm-sensors']:
            self.assertIn(package, self.trace())
        self.assertNotIn('needrestart', self.trace())

    def test_sysstat_preserves_package_settings_and_handles_debian_12_and_13_timers(self):
        config = self.write('etc/sysstat/sysstat', '# keep\nHISTORY=28\nCOMPRESSAFTER=10\n')
        self.write('etc/default/sysstat', '# keep\nENABLED="false"\n')
        self.run_bash(MAINTENANCE_MOCKS + r'''
ENABLE_SYSSTAT_HISTORY=yes
SYSSTAT_HISTORY_DAYS=14
configure_sysstat
ROTATE_STATE=loaded
configure_sysstat
check_maintenance
''')
        self.assertEqual(config.read_text(), '# keep\nHISTORY=14\nCOMPRESSAFTER=10\n')
        self.assertEqual(self.trace().count('enable --now sysstat-rotate.timer'), 1)
        self.assertIn('sysstat-collect.timer sysstat-summary.timer', self.trace())

    def test_each_sysstat_timer_must_be_active(self):
        self.write('etc/default/sysstat', 'ENABLED="true"\n')
        self.write('etc/sysstat/sysstat', 'HISTORY=7\n')
        self.run_bash(r'''
ENABLE_SYSSTAT_HISTORY=yes
systemctl() { [[ "$*" != 'is-active --quiet sysstat-summary.timer' ]]; }
check_maintenance
''', ok=False)

    def test_trim_uses_distributions_timer_without_direct_discard(self):
        self.run_bash(MAINTENANCE_MOCKS + 'ENABLE_FSTRIM=yes\nconfigure_trim\n')
        self.assertIn('enable --now fstrim.timer', self.trace())
        self.assertNotIn('blkdiscard', self.trace())
        self.assertNotIn('fstrim --', self.trace())

    def test_installation_apt_disallows_package_removal_and_needrestart_auto_restart(self):
        self.run_bash(r'''
apt-get() { printf '%s|%s|%s\n' "$DEBIAN_FRONTEND" "$NEEDRESTART_MODE" "$*" >> "$TRACE"; }
apt_install systemd-timesyncd
''')
        self.assertIn('noninteractive|l|', self.trace())
        self.assertIn('--no-remove install -y systemd-timesyncd', self.trace())

    def test_swap_preserves_existing_partition_without_allocating_or_editing_fstab(self):
        fstab = self.write('etc/fstab', '/dev/fixture none swap sw 0 0\n')
        (self.fixture / 'active-swap').write_text('/dev/fixture\n')
        self.run_bash(SWAP_MOCKS + 'configure_swap\ncheck_swap\n')
        self.assertEqual(self.trace(), '')
        self.assertEqual(fstab.read_text(), '/dev/fixture none swap sw 0 0\n')
        self.assertFalse((self.root / 'var/lib/vps-init/swapfile').exists())

    def test_swap_preflight_rejects_unsupported_filesystem_or_insufficient_space(self):
        for settings in ['FILESYSTEM=btrfs', 'FILESYSTEM=overlay', 'AVAILABLE=383']:
            with self.subTest(settings=settings):
                self.run_bash(SWAP_MOCKS + settings + '\nswap_preflight\n', ok=False)
        self.assertFalse((self.root / 'var/lib/vps-init').exists())

    def test_swap_never_overwrites_unknown_file_or_foreign_unit(self):
        target = self.write('var/lib/vps-init/swapfile', 'not swap\n')
        self.run_bash(SWAP_MOCKS + 'configure_swap\n', ok=False)
        self.assertEqual(target.read_text(), 'not swap\n')
        target.unlink()
        unit = subprocess.run(['systemd-escape', '--path', '--suffix=swap', str(target)],
                              text=True, capture_output=True, check=True).stdout.strip()
        self.write('etc/systemd/system/' + unit, '[Swap]\nWhat=/dev/foreign\n')
        self.run_bash(SWAP_MOCKS + 'configure_swap\n', ok=False)
        self.assertNotIn('allocate', self.trace())

    def test_swap_refuses_symlink_and_hardlinked_file(self):
        target = self.write('var/lib/vps-init/real', 'original\n')
        swap = target.with_name('swapfile')
        swap.symlink_to(target)
        self.run_bash(SWAP_MOCKS + 'configure_swap\n', ok=False)
        swap.unlink()
        os.link(target, swap)
        self.run_bash(SWAP_MOCKS + 'configure_swap\n', ok=False)
        self.assertEqual(target.read_text(), 'original\n')

    def test_swap_real_signature_and_systemd_validation_then_rerun_without_reformatting(self):
        # Real mkswap/blkid/validator only touch a disposable sparse fixture, never activate swap.
        self.run_bash(SWAP_MOCKS + 'configure_swap\nconfigure_swap\n')
        target = self.root / 'var/lib/vps-init/swapfile'
        self.assertEqual(target.stat().st_size, 128 * 1024 * 1024)
        self.assertEqual(target.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.trace().count('allocate\n'), 1)
        units = list((self.root / 'etc/systemd/system').glob('*.swap'))
        self.assertEqual(len(units), 1)
        self.assertIn(f'What={target}', units[0].read_text())
        self.assertIn('WantedBy=swap.target', units[0].read_text())
        self.assertFalse((self.root / 'etc/fstab').exists())
        self.run_bash(SWAP_MOCKS + 'SWAP_SIZE_MB=256\nconfigure_swap\n', ok=False)
        self.assertEqual(target.stat().st_size, 128 * 1024 * 1024)

    def test_swap_activation_failure_cleans_only_new_inactive_file(self):
        self.run_bash(SWAP_MOCKS + 'FAIL_ACTIVATION=yes\nconfigure_swap\n', ok=False)
        self.assertFalse((self.root / 'var/lib/vps-init/swapfile').exists())
        self.assertEqual(list((self.root / 'etc/systemd/system').glob('*.swap')), [])
        self.assertEqual(list((self.root / 'var/lib/vps-init').glob('.swap.*')), [])
        self.assertIn('disable ', self.trace())

    def test_swap_partial_activation_failure_keeps_active_file_and_unit(self):
        self.run_bash(SWAP_MOCKS + 'FAIL_ACTIVATION=yes\nPARTIAL_ACTIVATION=yes\nconfigure_swap\n', ok=False)
        self.assertTrue((self.root / 'var/lib/vps-init/swapfile').exists())
        self.assertEqual(len(list((self.root / 'etc/systemd/system').glob('*.swap'))), 1)
        self.assertNotIn('disable ', self.trace())

    def test_swap_allocation_failure_cleans_own_temporary_file(self):
        self.run_bash(SWAP_MOCKS + 'dd() { return 1; }\nconfigure_swap\n', ok=False)
        self.assertFalse((self.root / 'var/lib/vps-init/swapfile').exists())
        self.assertEqual(list((self.root / 'var/lib/vps-init').glob('.swap.*')), [])

    def test_exit_cleanup_removes_own_staging_swap_after_interrupted_allocation(self):
        self.run_bash(SWAP_MOCKS + r'''
trap cleanup EXIT
dd() { exit 2; }
configure_swap
''', ok=False)
        self.assertFalse((self.root / 'var/lib/vps-init/swapfile').exists())
        self.assertEqual(list((self.root / 'var/lib/vps-init').glob('.swap.*')), [])

    def test_health_reads_only_and_reports_reboot_without_executing_restart_tool(self):
        self.write('var/run/reboot-required', '')
        before = {p.relative_to(self.root): p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        result = self.run_bash(r'''
uptime() { :; }; free() { :; }; df() { :; }; swapon() { :; }; lsblk() { :; }; ip() { :; }
timedatectl() { printf 'NTPSynchronized=no\n'; }
systemctl() { printf 'fixture %s\n' "$*"; }
needrestart() { die UNEXPECTED_RESTART; }
health_report
''')
        after = {p.relative_to(self.root): p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        self.assertEqual(before, after)
        self.assertIn('需要重启', result.stdout)
        self.assertIn('sysstat*', result.stdout)
