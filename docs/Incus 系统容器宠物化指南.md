# Incus 系统容器宠物化指南

## 1. 目标

本文将 Incus 系统容器配置成类似“宠物 VM”的长期实例：

- 每个实例拥有独立、完整、可写且持久化的 Linux rootfs。
- 租户通过 SSH 登录，可使用 `apt`、`dnf` 或 `yum` 安装软件。
- 软件包、用户、服务、数据库和业务文件在实例、Incus 及宿主机重启后仍然存在。
- 实例 rootfs 位于 Ceph RBD，租户写大文件不会填满 Incus 宿主机的本地实例存储。
- 每实例、每项目和 Ceph 后端都有容量边界。
- 租户拥有容器内 root 权限，但没有宿主机、Podman、Incus、Ceph 或 OVN 管理权限。

本文只讨论 Incus 系统容器，不使用 Incus VM。

## 2. 前置条件

开始前应完成《Incus 系统容器集群 + OVN + Ceph 部署指南》，并检查：

```bash
incus cluster list
incus storage show ceph-rbd
incus network list
incus info
```

必须满足：

- 所有 Incus 集群成员为 `ONLINE`。
- `ceph-rbd` 的驱动为 `ceph`，不是 `dir` 或 `cephfs`。
- 租户 OVN 网络已创建并可分配地址。
- AppArmor、seccomp、cgroup v2 和 subordinate ID 工作正常。
- 外层镜像的停止信号为 `SIGPWR`。

```bash
podman image inspect ghcr.io/fivetime/incus:alpine-novm \
  --format '{{.Config.StopSignal}}'

podman exec incus sh -c '
  for command in incusd ceph rbd mount.ceph mkfs.ext4 resize2fs; do
    command -v "$command" || exit 1
  done
'
```

第一条命令必须输出 `SIGPWR`。

## 3. 持久化边界

### 3.1 Ceph RBD rootfs

实例根设备使用 `ceph-rbd` 后，以下普通目录属于实例 rootfs：

```text
/etc  /home  /opt  /root  /srv  /usr  /var
```

默认情况下 `/tmp` 也属于 rootfs；如果发行版自行将其挂载成 tmpfs，则以 `findmnt` 结果为准。

以下内容都会持久化：

- apt/dnf/yum 安装的软件包；
- `/etc` 下的系统和服务配置；
- systemd/OpenRC 服务启用状态；
- 用户、密码哈希和 SSH authorized keys；
- `/var/lib` 中的数据库和应用状态；
- `/home`、`/root` 和业务目录中的文件。

### 3.2 临时运行时文件系统

| 路径 | 类型 | 资源 | 持久化 |
| --- | --- | --- | --- |
| `/dev` | tmpfs 和设备节点 | 内存/内核 | 否 |
| `/dev/shm` | tmpfs | 内存，可能涉及 swap | 否 |
| `/proc` | procfs/LXCFS | 内核动态数据 | 否 |
| `/sys` | sysfs | 内核动态数据 | 否 |
| `/sys/fs/cgroup` | cgroupfs | 内核动态数据 | 否 |
| `/run` | 通常为 tmpfs | 内存 | 否 |
| `/dev/incus/sock` | Incus guest API socket | 运行时通信 | 否 |

这些路径会覆盖 rootfs 中的空目录，不会把内容写入 Ceph RBD。检查实际挂载：

```bash
incus exec pet-01 -- findmnt / /dev /dev/shm /proc /sys /run
```

不要把 `/run`、`/dev/shm` 或 `/dev` 改挂到 Ceph 来追求持久化。它们需要临时文件系统的启动清空、低延迟及共享内存语义；持久化旧的 PID、socket、锁文件或设备节点可能导致 init 和服务启动异常。需要持久化的应用数据必须写到 `/var/lib/<应用>`、`/srv`、`/home` 等 rootfs 路径。

## 4. 隔离模型

推荐一租户一个 restricted project：

```text
租户项目
├── 独立 OVN 网络
├── 受控 profile
├── 系统容器 -> 独立 Ceph RBD root volume
└── 项目存储总配额
```

存储必须有三层限制：

1. root 设备 `size`：单实例文件系统容量。
2. `limits.disk.pool.<pool>`：租户项目聚合逻辑容量。
3. Ceph pool `max_bytes`：后端物理容量。

仅限制 RBD image 大小不能阻止租户创建大量实例或快照；项目逻辑配额也不能代替 Ceph 物理配额。

## 5. 创建租户项目

```bash
export TENANT=tenant-a
export STORAGE_POOL=ceph-rbd
export TENANT_NETWORK=tenant-a-net
export UPLINK_NETWORK=UPLINK_NETWORK_NAME
```

```bash
incus project create "$TENANT" \
  -c features.networks=true \
  -c features.profiles=true \
  -c features.images=false

incus project set "$TENANT" \
  restricted=true \
  restricted.containers.privilege=unprivileged \
  restricted.containers.nesting=block \
  restricted.containers.lowlevel=block \
  restricted.containers.interception=block \
  restricted.devices.disk=managed \
  restricted.devices.unix-char=block \
  restricted.devices.unix-block=block \
  restricted.devices.gpu=block \
  restricted.devices.pci=block \
  restricted.devices.proxy=block \
  restricted.backups=block \
  restricted.snapshots=block \
  restricted.storage-pools.access="$STORAGE_POOL" \
  restricted.networks.access="$TENANT_NETWORK,$UPLINK_NETWORK" \
  limits.containers=10 \
  limits.disk.pool.ceph-rbd=500GiB
```

说明：

- `restricted.devices.disk=managed` 只允许 Incus 管理的存储卷，阻止挂载任意宿主机路径。
- `restricted.storage-pools.access` 将租户限制在指定 Ceph pool。
- OVN 项目网络引用上联网络时，`restricted.networks.access` 必须同时包含租户网络和上联网络；否则 Incus 会持续报告上联网络不在项目允许列表中。租户仍然只能通过 SSH 使用实例，不应获得 Incus API 权限。
- 阻止快照和备份适合租户拥有 Incus API 权限的场景；平台备份策略见第 12 节。

检查：

```bash
incus project show "$TENANT"
incus project info "$TENANT"
```

## 6. 创建宠物容器 profile

```bash
incus profile create pet-default --project "$TENANT"

incus profile set pet-default --project "$TENANT" \
  limits.cpu=2 \
  limits.memory=4GiB \
  limits.processes=4096 \
  security.privileged=false \
  security.idmap.isolated=true \
  security.nesting=false

incus profile device add pet-default root disk \
  --project "$TENANT" \
  path=/ \
  pool="$STORAGE_POOL" \
  size=50GiB

incus profile device add pet-default eth0 nic \
  --project "$TENANT" \
  network="$TENANT_NETWORK" \
  name=eth0
```

验证：

```bash
incus profile show pet-default --project "$TENANT"
```

不要设置 `security.privileged=true`、`security.nesting=true` 或 `raw.lxc`。

也不要在该 restricted profile 中设置 `limits.memory.swap=false`。Incus 7.2 在 `restricted.containers.lowlevel=block` 下会拒绝该配置。宿主机应统一规划 swap，不要为此开放租户 low-level 权限。

## 7. 选择系统镜像

先查询远程镜像，不要假定 alias 永远存在：

```bash
incus image list images: ubuntu architecture=x86_64
incus image list images: rockylinux architecture=x86_64
incus image list images: centos architecture=x86_64
```

常见示例：

```text
images:ubuntu/24.04
images:rockylinux/9
images:centos/9-Stream
```

生产要求：

- 固定发行版主版本和架构；
- 验证镜像来源、cloud-init、SSH、init 系统和包管理器；
- 不允许租户上传未经审核的镜像；
- 记录实例最初使用的镜像 fingerprint；
- 不以重建实例代替系统内升级，因为宠物容器状态位于当前 rootfs。

## 8. 创建实例并配置 SSH

### 8.1 准备 cloud-init

创建 `pet-01-cloud-init.yaml`：

```yaml
#cloud-config
users:
  - default
  - name: tenantadmin
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ssh-ed25519 REPLACE_WITH_TENANT_PUBLIC_KEY
ssh_pwauth: false
disable_root: true
package_update: true
```

只使用 SSH 公钥。不要在文档、cloud-init 或 Incus config 中保存明文密码。

### 8.2 初始化但暂不启动

Ubuntu 示例：

```bash
incus init images:ubuntu/24.04 pet-01 \
  --project "$TENANT" \
  --profile pet-default

incus config set pet-01 --project "$TENANT" \
  cloud-init.user-data - < pet-01-cloud-init.yaml

incus config set pet-01 --project "$TENANT" \
  security.protection.delete=true

incus config set pet-01 --project "$TENANT" \
  boot.autostart=true

incus start pet-01 --project "$TENANT"
```

Rocky Linux 示例：

```bash
incus init images:rockylinux/9 pet-rocky-01 \
  --project "$TENANT" \
  --profile pet-default
```

等待初始化完成：

```bash
incus exec pet-01 --project "$TENANT" -- cloud-init status --wait
incus list --project "$TENANT"
```

如果镜像没有 cloud-init，应先通过 `incus exec` 创建管理员用户和 authorized key，再开放网络访问。

### 8.3 SSH 验证

```bash
PET_IP=$(incus list pet-01 --project "$TENANT" --format csv -c 4 | cut -d' ' -f1)
ssh tenantadmin@"$PET_IP"
```

租户只能得到实例地址和 SSH 主机指纹，不能得到：

- Podman socket 或宿主机 shell；
- `/var/lib/incus/unix.socket`；
- Incus 管理员证书、OIDC 管理角色或 cluster token；
- Ceph keyring；
- OVN Northbound/Southbound 凭据。

## 9. 验证软件持久化

### 9.1 Ubuntu

```bash
incus exec pet-01 --project "$TENANT" -- bash -lc '
  apt-get update
  apt-get install -y jq
  printf "%s\n" persistent > /root/pet-marker
  systemctl enable ssh
'
```

### 9.2 Rocky/CentOS

```bash
incus exec pet-rocky-01 --project "$TENANT" -- bash -lc '
  dnf install -y jq
  printf "%s\n" persistent > /root/pet-marker
  systemctl enable sshd
'
```

### 9.3 重启实例

```bash
incus restart pet-01 --project "$TENANT"
incus exec pet-01 --project "$TENANT" -- jq --version
incus exec pet-01 --project "$TENANT" -- test -f /root/pet-marker
```

### 9.4 实例内 reboot 和 poweroff 的语义

系统容器运行真实 PID 1。租户执行 `reboot` 或 `shutdown -h now` 时，systemd/openrc 先正常停止服务；随后 PID namespace 内的 `reboot(2)` 不会作用于宿主内核。Linux 3.4 及以上将意图编码给父进程：restart/restart2 使 namespace PID 1 以 `SIGHUP` 终止，halt/poweroff 以 `SIGINT` 终止。PID 1 退出时，内核再以 `SIGKILL` 清除该 PID namespace 的所有残余进程。

liblxc/Incus 据此把 reboot 转换为停止后立即启动同一实例，把 poweroff 转换为 `STOPPED`。重启会创建新的 PID/network namespace 并重新执行发行版启动序列，但不会重启宿主或影响其他实例。rootfs、Incus 设备配置、MAC 和 Neutron 地址分配保持不变；namespaced sysctl 由发行版启动配置重新应用。

它与 VM 有三个重要差异：

- rootfs 仍是同一持久 Ceph 卷，软件和数据不会因正常重启消失。
- 容器没有自己的运行内核；安装 `linux-image-*` 只会写入 rootfs，重启后仍使用宿主内核。
- 容器重启省略固件、bootloader 和内核引导，通常明显快于 VM，但不能承诺固定的 1-3 秒 SLA。

`reboot -f` 仍被 PID namespace 隔离，不会重启宿主，但它跳过正常服务停止和同步流程。未提交的应用数据可能丢失；不能以宿主页缓存或 ext4 journal 宣称它与优雅重启具有相同的一致性保证。

在 OpenStack 下，实例内 poweroff 后 Incus 会立即显示 `STOPPED`，Nova API 可能暂时仍显示 `ACTIVE`。Nova 默认 `sync_power_state_interval=600` 秒，周期任务最终将其对账为 `SHUTOFF`，租户随后可执行 `openstack server start`。生产上应评估订阅 Incus `/1.0/events` lifecycle 流以缩短这一窗口，同时保留周期对账作为兜底。

### 9.5 重启外层 Incus

```bash
systemctl restart incus.service
podman exec incus incus admin waitready --timeout=60
incus exec pet-01 --project "$TENANT" -- jq --version
incus exec pet-01 --project "$TENANT" -- test -f /root/pet-marker
```

`systemctl restart` 不应达到停止超时，也不应回退到 SIGKILL。
`boot.autostart=true` 是宠物化实例的必要设置；否则外层 Incus 或宿主机重启后，实例会保持 `STOPPED`。

### 9.6 重启宿主机

一次只验证一个集群成员：

```bash
systemctl reboot

# 节点恢复后
systemctl is-active incus.service
podman exec incus incus admin waitready --timeout=60
incus list --project "$TENANT"
```

## 10. 确认 rootfs 位于 Ceph

检查实例展开配置：

```bash
incus config show pet-01 --project "$TENANT" --expanded
```

root 设备必须显示：

```yaml
root:
  path: /
  pool: ceph-rbd
  size: 50GiB
  type: disk
```

同时检查 Incus 和 Ceph：

```bash
incus storage volume list ceph-rbd --project "$TENANT"
rbd --name client.incus --pool incus-rbd list
rbd --name client.incus --pool incus-rbd du
```

不要仅通过实例内 `findmnt /` 判断后端。容器内通常只显示 ext4 等文件系统类型；必须结合 root 设备的 `pool` 和 RBD 列表确认。

## 11. 容量和资源保护

### 11.1 单实例 rootfs

```bash
incus config device override pet-01 root \
  --project "$TENANT" \
  size=100GiB
```

扩容前检查：

```bash
incus project info "$TENANT"
ceph df detail
rbd --name client.incus --pool incus-rbd du
```

不要向租户开放任意扩容权限。

### 11.2 项目逻辑上限

```bash
incus project set "$TENANT" \
  limits.disk.pool.ceph-rbd=500GiB \
  limits.containers=10
```

### 11.3 Ceph 物理上限

严格租户物理隔离需要独立 Ceph pool：

```bash
ceph osd pool create incus-tenant-a
rbd pool init incus-tenant-a
ceph osd pool set-quota incus-tenant-a max_bytes 549755813888
```

共享 Ceph pool 时，Incus 项目限制逻辑分配，但不能提供独立的 Ceph pool 物理配额。

### 11.4 tmpfs、内存和进程

租户写 `/dev/shm` 或 `/run` 消耗内存而不是 RBD。tmpfs、进程匿名内存和页缓存共同计入实例 cgroup 内存上限；达到上限时通常由该实例回收内存或触发 cgroup OOM，而不是无限消耗宿主机内存。它仍然属于可由租户触发的实例内 DoS，并且在允许 swap 时可能造成宿主机 swap I/O 压力。

必须为每个实例限制 CPU、内存和进程数：

```bash
incus config set pet-01 --project "$TENANT" \
  limits.cpu=2 \
  limits.memory=4GiB \
  limits.processes=4096
```

不要以实例内 `df` 显示的 tmpfs 容量作为安全上限；它可能显示宿主机级容量，实际资源边界是 cgroup。验收 cgroup 上限：

```bash
incus exec pet-01 --project "$TENANT" -- \
  cat /sys/fs/cgroup/memory.max
incus exec pet-01 --project "$TENANT" -- \
  cat /sys/fs/cgroup/memory.current
incus exec pet-01 --project "$TENANT" -- \
  cat /sys/fs/cgroup/memory.events
```

`memory.max` 必须等于配置的 `limits.memory`，不能是 `max`。宿主机 swap 必须使用固定容量，禁止自动无限扩展，并监控 swap 使用率、swap I/O、内存压力和 cgroup OOM。不要为了单独调整 swap 而放开 `restricted.containers.lowlevel=block`；统一的宿主机 swap 策略和实例内存上限是这里的安全边界。

定期检查：

```bash
incus info pet-01 --project "$TENANT" --resources
incus exec pet-01 --project "$TENANT" -- df -hT
incus exec pet-01 --project "$TENANT" -- free -h
cat /proc/swaps
systemctl status systemd-oomd --no-pager
```

`systemd-oomd` 是否启用取决于发行版和平台策略；即使未启用，也必须采集 `memory.events` 中的 `oom`、`oom_kill` 和 `max` 计数并告警。多租户容量规划还必须考虑所有实例内存上限的聚合超配比例，避免多个租户同时制造内存和 swap 压力。

## 12. 删除保护、快照和备份

### 12.1 删除保护

```bash
incus config set pet-01 --project "$TENANT" \
  security.protection.delete=true
```

删除保护能阻止误执行 `incus delete`，但不能代替备份。

### 12.2 快照策略

项目使用 `restricted.snapshots=block` 时不能创建常规快照。平台应选择一种明确模型：

1. 租户拥有 Incus API 权限：保持 `block`，由平台备份系统管理备份。
2. 租户只有 SSH 权限：可设置为 `allow`，由平台配置带过期时间的快照。

SSH-only 示例：

```bash
incus project set "$TENANT" restricted.snapshots=allow

incus config set pet-01 --project "$TENANT" \
  snapshots.schedule='0 3 * * *' \
  snapshots.expiry=7d \
  snapshots.schedule.stopped=true
```

快照会保留被覆盖的旧 RBD 数据块。必须配合过期时间、Ceph 告警和 pool 配额。

### 12.3 导出备份

备份必须写入独立备份存储，不能写入 Incus 宿主机根分区：

```bash
incus project set "$TENANT" restricted.backups=allow

incus export pet-01 \
  /mnt/backup/incus/tenant-a/pet-01-$(date +%F).tar.zst \
  --project "$TENANT" \
  --optimized-storage

incus project set "$TENANT" restricted.backups=block
```

上述临时放开操作只能由平台自动化在维护窗口执行，并且租户不能拥有备份 API 权限；脚本必须用 trap 或等效机制确保失败时恢复为 `block`。更稳妥的生产实现是使用细粒度授权将备份操作只授予平台备份身份。备份目标应有容量和生命周期限制，并定期执行恢复演练。

### 12.4 Ceph 不是备份

Ceph 副本不能自动防止：

- 租户误删或加密文件；
- 管理员误删实例或 RBD；
- 应用逻辑损坏；
- 错误操作同步到所有副本；
- Ceph 集群级事故。

## 13. 容器内日常维护

Ubuntu：

```bash
sudo apt-get update
sudo apt-get upgrade
sudo systemctl enable --now APPLICATION.service
```

Rocky/CentOS：

```bash
sudo dnf upgrade
sudo systemctl enable --now APPLICATION.service
```

平台仍应规定：

- 安全更新和重启窗口；
- 支持的发行版及生命周期；
- 日志、监控、备份和磁盘告警要求；
- 禁止自行修改网络、内核、cgroup 和设备边界；
- 容器内软件许可和供应链策略。

系统容器共享宿主机内核。租户安装新内核包不会替换实际运行内核，也不能加载宿主机内核模块。

## 14. 安全验收

### 14.1 管理组和 shifted 卷边界

容器内 root 不等于宿主机 root，但任何能够访问 Incus 完整管理 socket 的身份都必须按宿主机 root 对待。`incus-admin` 提供完整 API 权限；`incus` 提供受限 user socket，也只能授予经过审核的宿主机用户。租户 SSH 用户不得加入这些组，也不得获得 Incus/Podman socket、宿主机账号或管理证书。

[CVE-2025-64507](https://github.com/lxc/incus/security/advisories/GHSA-56mx-8g9f-5crf) 说明“受限 Incus 用户 + 宿主机普通账号 + 容器 root + `security.shifted=true` 自定义卷”的组合曾可导致宿主机提权。漏洞已在 Incus 6.0.6 和 6.19.0 修复，Incus 7.2 不属于已知受影响版本，但本方案仍禁止租户卷使用 `security.shifted=true`，并要求持续审计组成员、socket ACL、API 信任关系和卷配置。

生产环境至少验证：

```bash
getent group incus-admin || true
getent group incus || true
getent group podman || true
incus config trust list
incus storage volume list ceph-rbd --all-projects
```

只有平台运维自动化和少量受审计管理员可以控制 Incus；OpenStack 租户只通过 Nova、Neutron 和 Cinder API 使用系统容器。修补版本是上线前提，但不能替代最小权限和控制面隔离。

检查实例配置：

```bash
incus config get pet-01 security.privileged --project "$TENANT"
incus config get pet-01 security.idmap.isolated --project "$TENANT"
incus exec pet-01 --project "$TENANT" -- cat /proc/1/uid_map
```

实例 root 不应映射到宿主机 UID 0。

检查 seccomp：

```bash
incus exec pet-01 --project "$TENANT" -- \
  grep '^Seccomp:' /proc/1/status
```

预期为 `Seccomp: 2`。

检查 AppArmor：

```bash
aa-status | grep 'incus-pet-01_'
```

对应 profile 必须位于 enforce 状态。

检查项目限制：

```bash
incus project show "$TENANT"
incus project info "$TENANT"
```

租户的实例内 root 权限不等于宿主机 root、Podman 控制权、Incus 管理员、Ceph 用户或 OVN/OVS 管理员。

## 15. 升级与迁移

### 15.1 实例操作系统升级

先创建受控快照或备份，再按发行版官方路径升级。跨主版本升级前验证：

- init/systemd 能在 LXC 环境启动；
- SSH 和网络配置不会被替换；
- cloud-init 不会重新执行破坏性初始化；
- 应用和数据库支持目标版本；
- rootfs 有足够空间。

### 15.2 外层 Incus 镜像升级

外层镜像升级不应改变租户 rootfs。逐成员操作：

```bash
podman pull ghcr.io/fivetime/incus@sha256:NEW_DIGEST

# 修改 /etc/containers/systemd/incus.container 中的 Image=
systemctl daemon-reload
systemctl restart incus.service
podman exec incus incus admin waitready --timeout=60
```

确认节点和实例健康后再升级下一个成员。

### 15.3 集群节点迁移

Ceph 是共享远程存储时，rootfs 不依赖某个节点的本地数据盘，但迁移和恢复仍要求：

- Incus 集群数据库健康；
- 目标节点访问同一 Ceph 和 OVN；
- 目标节点具有相同内核能力、AppArmor 和 subordinate IDs；
- 网络 MTU、Geneve 和 uplink 一致。

## 16. 故障排查

| 现象 | 检查 |
| --- | --- |
| 安装软件后重启丢失 | root 设备是否错误使用本地测试池，是否重建而不是重启实例 |
| 宿主机本地盘增长 | Podman overlay、`/var/lib/incus`、镜像缓存、日志和备份导出 |
| `/dev/shm` 写满 | 实例内存、宿主机 swap 和 tmpfs 使用量 |
| 容器 rootfs 写满 | root 设备 `size`、实例 `df` 和 RBD 容量 |
| Ceph pool 增长过快 | RBD 快照、克隆、废弃镜像和 Ceph 配额 |
| SSH 无法登录 | OVN DHCP、ACL、防火墙、cloud-init、sshd 和 authorized key |
| Incus 重启后实例异常 | 镜像是否为 `SIGPWR`，日志是否出现 SIGKILL 或 `/run/incus` 丢失 |
| profile 更新被拒绝 | restricted project 是否禁止 low-level、设备或网络配置 |

常用命令：

```bash
systemctl status incus.service --no-pager
journalctl -u incus.service --no-pager -n 200
podman logs --tail 200 incus
incus warning list
incus info pet-01 --project "$TENANT" --show-log
incus storage volume list ceph-rbd --project "$TENANT"
ceph --name client.incus status
rbd --name client.incus --pool incus-rbd du
```

## 17. 无 Ceph 时的本地 LVM 验证

这一节只用于部署验收，不替代生产 Ceph。Incus 的 `lvm` 驱动在未指定块设备时会创建固定表观大小的稀疏回环文件，因此仍占用宿主机存储，但最大范围由池文件限制。

### 17.1 创建有界测试池和项目

```bash
incus storage create pet-lvm lvm size=8GiB

incus project create pet-verify \
  -c features.networks=true \
  -c features.profiles=true \
  -c features.images=false

incus project set pet-verify \
  restricted=true \
  restricted.containers.privilege=unprivileged \
  restricted.containers.nesting=block \
  restricted.containers.lowlevel=block \
  restricted.containers.interception=block \
  restricted.devices.disk=managed \
  restricted.storage-pools.access=pet-lvm \
  limits.containers=2 \
  limits.disk.pool.pet-lvm=6GiB
```

创建测试 profile 时使用 `pool=pet-lvm size=4GiB`，并设置 `limits.memory=1GiB`、`security.privileged=false` 和 `security.idmap.isolated=true`。然后创建实例：

```bash
incus launch images:ubuntu/24.04 pet-01 \
  --project pet-verify --profile pet-default
incus config set pet-01 --project pet-verify \
  security.protection.delete=true boot.autostart=true
```

### 17.2 验证 root、隔离和持久化

```bash
incus exec pet-01 --project pet-verify -- id
incus exec pet-01 --project pet-verify -- cat /proc/1/uid_map
incus exec pet-01 --project pet-verify -- grep '^Seccomp:' /proc/1/status
incus exec pet-01 --project pet-verify -- cat /sys/fs/cgroup/memory.max

incus exec pet-01 --project pet-verify -- sh -c \
  'echo persistent-root >/root/pet-marker'
systemctl restart incus.service
podman exec incus incus admin waitready --timeout=60
incus exec pet-01 --project pet-verify -- cat /root/pet-marker
```

预期容器内为 `uid=0`，但 `uid_map` 中容器 UID 0 映射到宿主机非零 UID；`Seccomp` 为 `2`，内存上限为 `1073741824`。外层服务重启后，实例应自动运行且标记仍存在。

验证不能绑定宿主机路径：

```bash
incus config device add pet-01 escape disk \
  source=/ target=/host --project pet-verify
```

预期失败并显示 `Attaching disks not backed by a pool is forbidden`。

### 17.3 验证写满边界

此命令会故意写满测试实例，不能对生产实例执行。`oflag=direct` 避免测试数据首先占满 1 GiB 内存 cgroup 的页缓存：

```bash
incus exec pet-01 --project pet-verify -- \
  dd if=/dev/zero of=/var/tmp/fill.bin \
  bs=16M count=300 oflag=direct status=none

incus exec pet-01 --project pet-verify -- df -h / /var /tmp
df -h /
du -h /var/lib/incus/disks/pet-lvm.img

incus exec pet-01 --project pet-verify -- rm -f /var/tmp/fill.bin
incus exec pet-01 --project pet-verify -- sync
```

预期 `dd` 返回 `No space left on device`，实例的 4 GiB 根盘接近 100%，宿主机根分区仍有空间，池文件表观大小不超过 8 GiB。再创建一个 4 GiB 实例应被项目 6 GiB 聚合配额拒绝：

```bash
incus init images:ubuntu/24.04 pet-02 \
  --project pet-verify --profile pet-default
```

### 17.4 “不能写爆宿主机”的准确边界

不能声称系统容器的任何写入都绝对不增加宿主机磁盘。可保证的是：

- `/etc`、`/home`、`/opt`、`/root`、`/srv`、`/usr`、`/var` 和默认的 `/tmp` 受实例根卷容量限制；生产 Ceph RBD 将这些数据块移出 Incus 宿主机。
- `/dev`、`/dev/shm` 和 `/run` 是 tmpfs/运行时挂载，不写入根卷，但消耗实例 cgroup 内存，并可能间接使用宿主机 swap。必须限制实例内存，并为宿主机 swap 设置容量、监控和告警。
- `/proc`、`/sys`、`/sys/fs/cgroup` 是受内核、user namespace、AppArmor 和 seccomp 约束的虚拟文件系统，不是租户数据盘。
- Incus 数据库、日志、镜像缓存、外层 Podman overlay 和备份仍会使用宿主机空间。应把 `/var/lib/incus`、Podman graphroot 和日志放在独立的有配额文件系统中，并设置告警；不能只依赖租户 RBD 配额。
- 系统容器 console 使用 liblxc ring buffer。Incus 7.2 的 `auto` 在 Ubuntu Noble 上将内存 buffer 和落盘文件分别限制为 128 KiB；日志路径是 `/var/log/incus/<instance>/console.log`，不是 `/var/lib/incus/logs`。单实例有界不等于聚合有界，仍须监控并限制整个 `/var/log/incus` 文件系统。洪泛后 console API 还可能返回 `message too long`，这是该实例 console 的可用性风险。
- 容器进程的 core dump 由宿主全局 `kernel.core_pattern` 处置。生产计算节点应显式设置为 `/dev/null`，或者配置 `systemd-coredump` 的 `Storage=none`；若业务必须保留 core，则必须收紧 `ProcessSizeMax`/`MaxUse` 并使用独立受限文件系统，不能接受默认按宿主磁盘百分比使用空间。
- 不向租户提供 Incus/Podman/Ceph/OVN API、宿主机 bind mount 或特权容器能力，是上述容量边界成立的前提。

2026-07-15 在 Ubuntu 26.04 测试 VM、Incus 7.2、Podman 5.7 和 Ubuntu 24.04 系统容器上完成了上述 LVM 流程。实测容器 root 映射到宿主机 UID `1196608`，使用容器内 root 通过 `apt` 安装的 `hello` 软件包在实例重启后仍可执行，根盘写满在约 4 GiB 返回 `ENOSPC`，项目聚合配额拒绝第二个 4 GiB 实例，外层服务重启后数据和实例自启动均正常。测试 OVN 上联没有公网 DNS，软件包由管理端预下载并推入实例后交给实例内 `apt` 安装；这验证了 root 和包状态持久化，不构成租户公网出口验收。由于测试环境无 Ceph，这些结果不代替 Ceph RBD、集群迁移和故障恢复验收。

## 18. 上线检查表

- [ ] 实例 root 设备明确使用 `ceph-rbd`，不是本地 `dir` 测试池。
- [ ] 单实例 rootfs、项目聚合容量和 Ceph pool 物理容量均有限制。
- [ ] 租户使用独立 restricted project 和 OVN 网络。
- [ ] 实例为非特权容器，并启用 isolated idmap。
- [ ] AppArmor 位于 enforce，容器内 `Seccomp: 2`。
- [ ] 租户只能通过 SSH 进入实例，不能访问 Podman、Incus、Ceph 或 OVN 管理面。
- [ ] Ubuntu apt 或 Rocky/CentOS dnf 安装持久化测试通过。
- [ ] 实例、`incus.service` 和单节点宿主机重启测试通过。
- [ ] 镜像 `StopSignal=SIGPWR`，停止日志没有 SIGKILL。
- [ ] `/dev`、`/proc`、`/sys`、`/run` 等运行时挂载边界已确认。
- [ ] `/run`、`/dev/shm` 和 `/dev` 保持临时挂载，未错误持久化到 Ceph。
- [ ] 每个实例的 `memory.max` 不是 `max`，进程数有上限，cgroup OOM 事件已有告警。
- [ ] 宿主机 swap 容量固定，swap 使用率和 I/O 已监控，并完成多实例并发内存压力评估。
- [ ] 快照有过期策略，备份写入独立存储并完成恢复演练。
- [ ] 宿主机控制面文件系统、Podman 存储和 Ceph 均有容量告警。
- [ ] `/var/log/incus` 位于受限文件系统，已完成十分钟 console 洪泛测试并验证单实例日志不持续增长。
- [ ] `kernel.core_pattern=/dev/null`，或 `systemd-coredump` 已禁用存储/配置严格容量上限；重启后再次验证。
- [ ] 发行版升级、安全更新、重启和生命周期责任已经明确。
