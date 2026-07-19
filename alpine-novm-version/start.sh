#!/bin/sh
set -eu

fail() {
  echo "FATAL: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

[ "$(id -u)" -eq 0 ] || fail "Incus must run as root"
awk '$2 == "/sys/fs/cgroup" && $3 == "cgroup2" { found = 1 } END { exit !found }' /proc/mounts \
  || fail "A cgroup v2 host mount is required"
[ -w /sys/fs/cgroup ] || fail "/sys/fs/cgroup must be writable; use --cgroupns=host and unmask it"
[ -r /proc/sys/kernel/seccomp/actions_avail ] || fail "Kernel seccomp support is required"
grep -qw allow /proc/sys/kernel/seccomp/actions_avail || fail "Kernel seccomp filtering is unavailable"
[ -r /sys/module/apparmor/parameters/enabled ] || fail "Host AppArmor is required"
[ "$(cat /sys/module/apparmor/parameters/enabled)" = "Y" ] || fail "Host AppArmor is disabled"
[ -d /sys/kernel/security/apparmor ] || fail "AppArmor securityfs is unavailable; mount /sys/kernel/security"
[ -w /sys/kernel/security/apparmor/.load ] || fail "AppArmor policy loading is unavailable"

CURRENT_PROFILE=$(cat /proc/1/attr/current 2>/dev/null || true)
case "$CURRENT_PROFILE" in
  unconfined*) ;;
  *) fail "The outer Podman container must use --security-opt apparmor=unconfined" ;;
esac

for command_name in aa-exec apparmor_parser criu incus incusd lxcfs newgidmap newuidmap nft; do
  require_command "$command_name"
done

grep -q '^root:[0-9][0-9]*:[0-9][0-9]*$' /etc/subuid || fail "A root subordinate UID range is required"
grep -q '^root:[0-9][0-9]*:[0-9][0-9]*$' /etc/subgid || fail "A root subordinate GID range is required"

mkdir -p /var/lib/incus-lxcfs /var/log/incus

lxcfs /var/lib/incus-lxcfs --enable-loadavg --enable-cfs &
exec incusd
