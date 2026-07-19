#!/bin/sh
set -eu

incus admin waitready --timeout=5 >/dev/null
incus info | grep -q 'driver: lxc'
test -d /sys/kernel/security/apparmor
awk '$2 == "/sys/fs/cgroup" && $3 == "cgroup2" { found = 1 } END { exit !found }' /proc/mounts
