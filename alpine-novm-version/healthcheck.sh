#!/bin/sh
set -eu

incus admin waitready --timeout=5 >/dev/null
incus info | grep -q 'driver: lxc'
criu --version >/dev/null
command -v iptables-restore >/dev/null
command -v ip6tables-restore >/dev/null
command -v iptables-legacy-restore >/dev/null
command -v ip6tables-legacy-restore >/dev/null
mountpoint -q /run/incus
awk '$5 == "/var/lib/incus" {
       for (i = 7; i <= NF && $i != "-"; i++)
         if ($i ~ /^shared:/) found = 1
     }
     END { exit !found }' /proc/self/mountinfo
test -d /sys/kernel/security/apparmor
awk '$2 == "/sys/fs/cgroup" && $3 == "cgroup2" { found = 1 } END { exit !found }' /proc/mounts
