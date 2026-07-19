# Incus 独立计算节点 + OVN + Ceph 部署指南

## 1. 目标与边界

本文在三台 Ubuntu 24.04 LTS（Noble）宿主机上，以 rootful Podman 运行 Incus fork 的 `alpine-novm` 镜像，并接入外部 OVN 和 Ceph 集群，构建多租户 Incus 系统容器平台。

本文只覆盖 Incus 系统容器，不安装或配置 QEMU、OVMF、KVM、虚拟机、GPU 直通和 VM profile。

部署边界如下：

- 每个 Incus 节点由一个 Podman 容器承载，使用宿主机网络和 PID 命名空间。
- 每个 Incus 都是独立单节点，不启用 Incus clustering/Cowsql；Nova
  负责放置和迁移编排，Podman 只是打包和进程托管边界。
- OVN Northbound/Southbound 数据库及 `ovn-controller` 运行在外部基础设施或宿主机，不运行在 Incus 镜像中。
- Open vSwitch 数据平面运行在宿主机，Incus 通过 `/run/openvswitch` 控制本机 OVS。
- 系统容器完整 rootfs 使用 Ceph RBD；租户普通文件不会写入宿主机本地实例存储。
- `/var/lib/incus` 仍需小型、持久、受容量限制的本地文件系统，用于 Incus 数据库、证书和控制面状态。

> Ceph 副本不是备份。生产环境仍需备份 Incus 数据库、配置和关键实例。

## 2. 参考拓扑

| 节点 | 管理 IP | Ceph 访问 IP | OVN Geneve IP | 外部网络 IP |
| --- | --- | --- | --- | --- |
| `cluster1` | `10.32.16.20` | `10.64.16.20` | `10.160.16.20` | `203.0.113.10` |
| `cluster2` | `10.32.16.40` | `10.64.16.40` | `10.160.16.40` | `203.0.113.11` |
| `cluster3` | `10.32.16.80` | `10.64.16.80` | `10.160.16.80` | `203.0.113.12` |

| 网络 | VLAN | 示例网段 | 用途 |
| --- | ---: | --- | --- |
| 管理网络 | 11 | `10.32.16.0/27` | Incus 迁移 API 和 OVN DB |
| Ceph 公网 | 12 | `10.64.16.0/27` | Ceph MON/OSD 客户端访问 |
| Ceph 集群网 | 13 | `10.96.16.0/27` | Ceph 后端复制，Incus 不直接使用 |
| OVN 外部网 | 14 | `203.0.113.0/24` | Uplink、Floating IP |
| OVN 隧道网 | 15 | `10.160.16.0/27` | Geneve 封装 |

示例使用文档保留地址 `203.0.113.0/24`。部署前必须替换为实际地址、网关、接口名、VLAN 和 Ceph 参数。

## 3. 必要条件

### 3.1 宿主机

所有节点必须满足：

- Linux 内核支持 cgroup v2、seccomp、AppArmor、用户命名空间和 overlayfs。
- rootful Podman 5.x 或更新版本。
- 节点主机名和管理地址稳定，时间同步正常。
- 管理网络只允许计算节点之间的 Incus 迁移 API 通信。
- Geneve 网络允许节点间 UDP 6081。
- 节点能访问 Ceph MON v2 端口 TCP 3300。
- AppArmor 已启用，`/sys/kernel/security/apparmor/.load` 可由 root 写入。

检查：

```bash
podman version
stat -fc %T /sys/fs/cgroup
cat /sys/module/apparmor/parameters/enabled
test -w /sys/kernel/security/apparmor/.load
```

`stat` 应输出 `cgroup2fs`，AppArmor 应输出 `Y`。

### 3.2 镜像能力预检

镜像地址：

```bash
export INCUS_IMAGE=ghcr.io/fivetime/incus@sha256:REPLACE_WITH_VERIFIED_DIGEST
podman pull "$INCUS_IMAGE"
```

OpenStack BFV 必须使用从 `fivetime/incus` fork 源码构建的镜像。通用的
`incus-docker-image` 镜像不包含 `storage_driver_cephext`、
`migration_shared_ceph_storage` 等 fork 扩展，不能替代该镜像。

镜像内只需要 Incus 和 Ceph 客户端。Incus 7.x 使用内置 OVSDB 客户端访问 OVN，不要求镜像包含 `ovs-vsctl`、`ovn-nbctl` 或 `ovn-sbctl`；这三个运维工具应安装在宿主机：

```bash
podman run --rm --entrypoint sh "$INCUS_IMAGE" -c '
  for command in incusd ceph rbd mount.ceph mkfs.ext4 resize2fs; do
    command -v "$command" || exit 1
  done
'

podman image inspect "$INCUS_IMAGE" --format '{{.Config.StopSignal}}'
```

停止信号必须输出 `SIGPWR`。若输出 `SIGTERM` 或为空，不能部署该构建：运行中的 Incus 实例可能无法在 Podman/systemd 超时前干净关闭。

建议生产环境固定不可变 digest，而不是长期跟随可变 tag：

```bash
podman pull "$INCUS_IMAGE"
podman image inspect "$INCUS_IMAGE" --format '{{.Digest}}'
```

## 4. 准备宿主机

### 4.1 主机名和解析

分别设置主机名：

```bash
hostnamectl set-hostname cluster1
```

所有节点配置一致的名称解析：

```text
10.32.16.20 cluster1
10.32.16.40 cluster2
10.32.16.80 cluster3
```

### 4.2 控制面本地文件系统

`/var/lib/incus` 不存放 Ceph RBD 中的租户 rootfs，但会保存 Incus 数据库、证书、配置和少量日志。应将其放在单独的受限文件系统，而不是宿主机根分区。

实例运行日志实际位于 `/var/log/incus/<instance>/`，也必须放在受限文件系统并设置容量告警。Incus 7.2 为系统容器设置
`lxc.console.buffer.size=auto` 和 `lxc.console.size=auto`；Ubuntu Noble 的 liblxc 将 `auto` 解释为 128 KiB 的内存 ring buffer 和 128 KiB 的落盘上限。因此 `console.log` 不是无界追加文件，但仍应监控 `/var/log/incus` 的多实例聚合占用。不要通过租户可设置的 `raw.lxc` 开放 console 参数。

### 4.3 禁止租户 core dump 写入宿主机

容器不能修改宿主全局的 `kernel.core_pattern`，但容器进程崩溃仍按该宿主设置处理。计算节点首选完全禁用 core dump 收集：

```bash
install -d -m 0755 /etc/sysctl.d
cat >/etc/sysctl.d/90-incus-compute-coredump.conf <<'EOF'
kernel.core_pattern=/dev/null
EOF
sysctl --system
test "$(cat /proc/sys/kernel/core_pattern)" = /dev/null
```

如确有故障分析需求而必须使用 `systemd-coredump`，不要使用发行版默认容量策略；至少显式设置 `Storage=external`、较小的 `ProcessSizeMax` 和 `MaxUse`，并把 `/var/lib/systemd/coredump` 放在独立受限文件系统。多租户生产节点更推荐 `Storage=none` 或上述 `/dev/null` 基线。

```bash
install -d -m 0700 /var/lib/incus
install -d -m 0700 /run/incus-podman
install -d -m 0755 /etc/ceph
```

生产环境建议为 `/var/lib/incus` 设置 20-50 GiB 文件系统上限和磁盘告警。不要使用 Podman 匿名卷承载该目录。

### 4.4 Open vSwitch 和 OVN Host

OVS、`ovn-controller` 和 Geneve 数据平面运行在宿主机。以下为 Ubuntu 示例，包名以实际发行版为准：

```bash
apt-get update
apt-get install -y openvswitch-switch ovn-host
systemctl enable --now openvswitch-switch.service ovn-host.service
```

确认宿主机工具和内核 datapath：

```bash
ovs-vsctl --version
ovn-nbctl --version
ovn-sbctl --version
lsmod | grep '^openvswitch' || modprobe openvswitch
test -S /run/openvswitch/db.sock
systemctl is-active openvswitch-switch.service ovn-host.service ovn-controller.service
```

连接现有 OVN Southbound 集群并设置本机 Geneve 地址：

```bash
export OVN_SB='tcp:10.32.16.20:6642,tcp:10.32.16.40:6642,tcp:10.32.16.80:6642'
export ENCAP_IP='10.160.16.20' # 每个节点修改

ovs-vsctl set open_vswitch . \
  external_ids:ovn-remote="$OVN_SB" \
  external_ids:ovn-encap-type=geneve \
  external_ids:ovn-encap-ip="$ENCAP_IP"

ovn-sbctl --db="$OVN_SB" show
ovs-vsctl get open_vswitch . external_ids
```

如果 OVN Central 属于现有 OpenStack，必须先确认 Incus 获得独立且受控的 NB/SB 数据库使用边界。不要让两个控制平面无约束地管理同一组逻辑对象。

## 5. 配置 Ceph 凭据

### 5.1 创建独立 RBD 池

推荐至少为 Incus 创建独立 Ceph pool。需要严格租户物理容量隔离时，应进一步为每个租户创建独立 pool，并设置 Ceph `max_bytes`。

在 Ceph 管理端执行：

```bash
ceph osd pool create incus-rbd
rbd pool init incus-rbd
ceph osd pool set-quota incus-rbd max_bytes 1099511627776
```

上例限制为 1 TiB，仅供示范。

### 5.2 创建最小权限用户

不要沿用原文中曾出现的明文 key，也不要使用 `client.admin`。根据实际 pool 创建专用用户，例如：

```bash
ceph auth get-or-create client.incus \
  mon 'profile rbd' \
  mgr 'profile rbd pool=incus-rbd' \
  osd 'profile rbd pool=incus-rbd'
```

将以下文件安全分发到所有 Incus 节点：

```text
/etc/ceph/ceph.conf
/etc/ceph/ceph.client.incus.keyring
```

权限设置：

```bash
chown -R root:root /etc/ceph
chmod 0755 /etc/ceph
chmod 0600 /etc/ceph/ceph.client.incus.keyring
```

验证外部 Ceph：

```bash
ceph --name client.incus status
rbd --name client.incus --pool incus-rbd list
```

## 6. 使用 Podman 部署 Incus

### 6.1 使用 systemd Quadlet 托管

生产环境使用 rootful Podman Quadlet，不直接维护手写 `.service`，也不使用已经不推荐的新部署方式 `podman generate systemd`。Quadlet 文件放在 `/etc/containers/systemd/`，Podman 的 systemd generator 会生成 `incus.service`。

在每个节点确认 Quadlet generator 存在：

```bash
test -x /usr/lib/systemd/system-generators/podman-system-generator
install -d -m 0755 /etc/containers/systemd
```

创建 `/etc/containers/systemd/incus.container`：

```ini
[Unit]
Description=Incus system-container node (Podman Quadlet)
Documentation=https://linuxcontainers.org/incus/docs/main/
Wants=network-online.target
After=network-online.target openvswitch-switch.service ovn-host.service
Requires=openvswitch-switch.service ovn-host.service
RequiresMountsFor=/var/lib/incus /etc/ceph

[Container]
Image=ghcr.io/fivetime/incus@sha256:REPLACE_WITH_VERIFIED_DIGEST
ContainerName=incus
Network=host
Environment=INCUS_SOCKET_GID=REPLACE_WITH_HOST_INCUS_ADMIN_GID
Volume=/dev:/dev
Volume=/var/lib/incus:/var/lib/incus:rshared
Volume=/run/incus-podman:/run/incus:rshared
Volume=/lib/modules:/lib/modules:ro
Volume=/sys/kernel/security:/sys/kernel/security
Volume=/etc/ceph:/etc/ceph:ro
Volume=/run/openvswitch:/run/openvswitch
Volume=/run/udev:/run/udev:ro
PodmanArgs=--cgroups=no-conmon --cgroupns=host --security-opt=unmask=/sys/fs/cgroup --security-opt=apparmor=unconfined --privileged --pid=host --stop-timeout=60

[Service]
Restart=always
RestartSec=5s
TimeoutStartSec=120
TimeoutStopSec=75
ExecStartPre=/usr/bin/test -S /run/openvswitch/db.sock
ExecStartPre=/usr/bin/test -w /sys/kernel/security/apparmor/.load
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
```

生产环境应将 `Image=` 改成已经验证的不可变 digest，例如：

```ini
Image=ghcr.io/fivetime/incus@sha256:REPLACE_WITH_VERIFIED_DIGEST
```

`INCUS_SOCKET_GID` 必须替换为宿主机 `incus-admin` 组的数字 GID，可用
`getent group incus-admin | cut -d: -f3` 查询。镜像会用相同 GID 创建容器内
组并让 `incusd` 以该组权限创建 Unix socket，使宿主机 Nova 用户可以通过
组权限访问 API；不得把 socket 改成全局可写。该参数需要包含提交
`c7d030598` 或更新版本的镜像。

加载并启动：

```bash
systemctl daemon-reload
systemctl start incus.service
systemctl status incus.service --no-pager
systemctl is-enabled incus.service
```

Quadlet 的 `[Install]` 段负责建立开机启动关系。不要对 generator 生成的 service 执行 `systemctl enable`；修改 `.container` 后应执行 `daemon-reload` 和 `restart`。

`systemctl is-enabled incus.service` 在 Quadlet 下正常输出通常是 `generated`。如果 service 显示 `not-found`，执行以下诊断：

```bash
/usr/libexec/podman/quadlet -dryrun
file /etc/containers/systemd/incus.container
sed -n '1,5p' /etc/containers/systemd/incus.container
```

文件第一行必须准确显示 `[Unit]`，不能带 UTF-8 BOM。直接在 Linux 上使用本文的 heredoc 创建文件不会产生 BOM；从 Windows 编辑器上传时必须明确保存为 UTF-8 without BOM。

如果节点上已有手工执行 `podman run --name incus` 创建的容器，先确认其使用同一个持久化目录，再正常停止并删除容器对象。删除容器对象不会删除 bind mount 的 `/var/lib/incus`：

```bash
podman inspect incus --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}'
podman stop --time 60 incus
podman rm incus
systemctl daemon-reload
systemctl start incus.service
```

不得在没有核对 mount 的情况下删除旧容器，也不得删除 `/var/lib/incus`。

关键边界：

- `--privileged` 和外层 `apparmor=unconfined` 是为了让 Incus 管理内层 LXC、cgroup、网络和每实例 AppArmor profile；外层 Podman 不是租户安全边界。
- 不得把 Podman socket、Incus Unix socket、宿主机 SSH 或管理员证书交给租户。
- `/dev`、`/lib/modules` 和 securityfs 是内核能力挂载，不是租户持久存储。
- `/run/openvswitch` 只提供本机 OVS 控制 socket；不要跨节点共享。
- `/run/udev` 必须只读挂载。容器内 `rbd map` 依靠宿主机 udev
  完成 KRBD 设备确认；缺少该挂载时，内核设备可能已经出现，但命令会持续等待并导致 Nova spawn 超时。
- 镜像使用 `SIGPWR` 作为停止信号，以便 Incus 干净关闭系统容器。

检查：

```bash
systemctl status incus.service --no-pager
journalctl -u incus.service --no-pager -n 100
podman ps --filter name=incus
podman logs incus
podman exec incus incus admin waitready --timeout=60
podman exec incus incus info
```

`storage_supported_drivers` 应包含 `ceph`，`driver` 应为 `lxc`。缺少 QEMU 的警告符合 no-VM 镜像预期。

完成单节点验证后测试开机自启动。生产集群应逐节点测试，不能同时重启三台：

```bash
systemctl reboot

# 节点恢复后执行
systemctl is-active incus.service
podman exec incus incus admin waitready --timeout=60
```

### 6.2 宿主机管理命令

本文统一通过以下形式管理，避免要求宿主机安装 Incus 客户端：

```bash
alias incus='podman exec incus incus'
incus info
```

自动化脚本中不要依赖 alias，应使用完整的 `podman exec incus incus ...`。

## 7. 初始化独立 Incus 计算节点

在三台机器上分别初始化，**不要启用 clustering**：

```bash
incus admin init --minimal
```

每个节点只绑定自己的迁移管理地址。例如 `cluster1`：

```bash
incus config set core.https_address=10.32.16.20:8443
incus config get core.https_address
incus cluster list
```

`incus cluster list` 应只显示本机或表明未启用集群。不得生成加入令牌，也不得把三个
节点加入同一个 Cowsql 集群。计算节点注册、资源放置、故障状态和迁移由
Nova/Placement 管理。

## 8. 创建 Cinder BFV Ceph 池

在**每个独立节点**创建同名 `cephext` 池，指向同一个 Cinder RBD pool：

```bash
incus storage create cinder-bfv cephext \
  source=cinder-volumes-rbd-pool \
  ceph.cluster_name=ceph \
  ceph.user.name=cinder
```

该驱动来自 `fivetime/incus` fork。创建前必须验证：

```bash
incus query /1.0 | jq -e '
  .api_extensions
  | index("storage_driver_cephext") != null
    and index("migration_shared_ceph_storage") != null'
incus storage show cinder-bfv
rbd --id cinder --pool cinder-volumes-rbd-pool list
```

不要把 `cinder-bfv` 配置为 `default` profile 的普通 root 设备。Nova 驱动在
boot-from-volume 时通过 `initial.ceph.rbd.image_name` 认领 Cinder 已创建的根卷。
普通 Incus `ceph` 池与 Cinder BFV 是不同 ownership 模型，不得混用。

## 9. 接入 Neutron ML2/OVN

Neutron 是租户网络的唯一控制面。Incus 不连接 OVN Northbound，不创建 Incus
managed OVN network、uplink、ACL、forward、zone 或 BGP 配置。

宿主机上的 `ovn-controller` 和 Open vSwitch 由 Neutron 部署并管理。所有计算节点
至少验证：

```bash
systemctl is-active openvswitch-switch
systemctl is-active ovn-controller
ovs-vsctl br-exists br-int
ovs-vsctl get Open_vSwitch . external_ids:system-id
```

Nova Incus 驱动通过 os-vif 创建宿主 veth，将外侧端口接入 `br-int`，再把内侧
veth 作为 Incus `physical` NIC 交给系统容器。跨节点 Geneve、IP/MAC、Security
Group、Floating IP 和路由全部由 Neutron/OVN 保持。

只通过 OpenStack API 验证租户网络：

```bash
openstack server create --flavor <flavor> --volume <root-volume> \
  --network <neutron-network> <server-name>
openstack port list --server <server-name>
ovs-vsctl --columns=name,external_ids find Interface \
  external_ids:iface-id=<neutron-port-uuid>
```

## 10. 多租户安全基线

### 10.1 Incus 管理权限与 `security.shifted`

必须把 `incus-admin` 组视为宿主机 root 权限：该组可以访问完整的 Incus Unix socket，并能通过实例设备、宿主机路径和低级配置取得宿主机控制权。`incus` 组只访问受限的 user socket 和每用户 project，但它仍是敏感控制面入口，不能授予 OpenStack 租户、容器内用户或普通宿主机登录用户。OpenStack 租户只能通过 Nova、Neutron 和 Cinder API 操作资源。

[CVE-2025-64507](https://github.com/lxc/incus/security/advisories/GHSA-56mx-8g9f-5crf) 的利用前提包括：攻击者同时拥有宿主机普通用户身份、容器内 root、带 `security.shifted=true` 的自定义卷，并能通过受限 Incus 用户接口操纵相关资源。受影响版本为 `< 6.0.6` 和 `6.1.0` 至 `6.18.x`，修复版本为 `6.0.6` 和 `6.19.0`。本文目标 Incus 7.2 已包含修复，但仍执行纵深防御：

- 不允许租户或普通宿主机用户加入 `incus-admin`、`incus`、`podman` 等控制面组；Podman 管理权限同样按 root 权限管理。
- 不向租户暴露 Incus Unix socket、user socket、HTTPS API 客户端证书或 `podman exec` 能力。
- 业务卷不得设置 `security.shifted=true`；使用非特权容器、isolated idmap 和 Incus 管理的 Ceph 卷。
- Incus 版本低于已修复版本时不得上线；升级后仍要审计组成员、socket ACL、信任证书和所有自定义卷属性。
- 自动化服务使用专用身份和最小权限，不允许交互式登录；管理员账号使用独立审计和强认证。

检查宿主机和外层容器中的权限及卷配置：

```bash
getent group incus-admin || true
getent group incus || true
getent group podman || true
podman exec incus getent group incus-admin || true
podman exec incus getent group incus || true
podman exec incus incus config trust list
podman exec incus incus storage volume list ceph-rbd --all-projects
```

对列出的自定义卷逐一执行 `incus storage volume show ceph-rbd <卷名> --project <项目>`，确认没有 `security.shifted: "true"`。组成员检查和卷属性审计必须纳入持续合规任务，不能只在首次部署时执行。

如果因紧急原因仍在运行受影响版本，官方公告给出的临时缓解是收紧 Incus 存储池目录权限；在本 Podman 部署中应进入外层容器执行：

```bash
podman exec incus sh -c 'chmod 0700 /var/lib/incus/storage-pools/*/*'
podman exec incus sh -c 'chmod 0711 /var/lib/incus/storage-pools/*/buckets*'
podman exec incus sh -c 'chmod 0711 /var/lib/incus/storage-pools/*/container*'
```

这只是升级前的短期缓解，不能代替升级。Incus 7.2 应已在启动时为现有和新存储池应用修复后的权限；变更生产目录前仍须结合实际存储驱动核对路径，并先在测试节点验证。

为每个租户创建独立 restricted project：

```bash
incus project set tenant-a \
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
  restricted.snapshots=block \
  restricted.backups=block \
  restricted.storage-pools.access=ceph-rbd \
  restricted.networks.access=tenant-a-net \
  limits.containers=10 \
  limits.disk.pool.ceph-rbd=500GiB
```

> `restricted.devices.disk=managed` 只允许 Incus 管理的存储卷，并结合 `restricted.storage-pools.access=ceph-rbd` 阻止租户挂载宿主机路径。具体授权模型上线前必须用租户身份验证。

创建租户 profile：

```bash
incus profile create tenant-default --project tenant-a
incus profile set tenant-default --project tenant-a \
  limits.cpu=2 \
  limits.memory=4GiB \
  limits.processes=4096 \
  security.privileged=false \
  security.idmap.isolated=true \
  security.nesting=false

incus profile device add tenant-default root disk \
  --project tenant-a path=/ pool=ceph-rbd size=50GiB
incus profile device add tenant-default eth0 nic \
  --project tenant-a network=tenant-a-net name=eth0
```

不要在该 restricted profile 中设置 `limits.memory.swap=false`。Incus 7.2 在 `restricted.containers.lowlevel=block` 下会将它判定为禁止的低级配置并拒绝整个 profile 更新。保持 low-level 为 `block`，在宿主机层统一规划 swap；不要为了单实例关闭 swap 而放开租户 low-level 权限。

## 11. 验收测试

### 11.1 启动系统容器

```bash
incus launch images:ubuntu/24.04 c1 \
  --project tenant-a \
  --profile tenant-default
```

确认实例类型和根盘：

```bash
incus list --project tenant-a
incus config show c1 --project tenant-a --expanded
incus storage volume list ceph-rbd --project tenant-a
rbd --name client.incus --pool incus-rbd list
```

### 11.2 安全验证

```bash
incus exec c1 --project tenant-a -- cat /proc/1/status | grep Seccomp
aa-status | grep 'incus-c1_' || true
incus exec c1 --project tenant-a -- findmnt / /dev /proc /sys
```

验收条件：

- 实例为非特权系统容器。
- `Seccomp` 为 `2`。
- 实例 AppArmor profile 处于 enforce 状态。
- `/` 位于 `ceph-rbd` 管理的实例卷。
- `/dev` 为 tmpfs，`/proc` 和 `/sys` 为内核虚拟文件系统。
- 租户无法访问 Podman、Incus 管理 socket、宿主机路径或其他租户网络。

### 11.3 停止和恢复

```bash
systemctl restart incus.service
podman exec incus incus admin waitready --timeout=60
incus list --project tenant-a
```

`systemctl restart` 会调用 Podman，并按镜像的 `SIGPWR` 停止 Incus。Podman 不应报告达到 60 秒后使用 SIGKILL，systemd 也不应达到 75 秒的 `TimeoutStopSec`。若发生强杀，先修复停止信号和实例关机问题，再进入生产环境。

## 12. 运维与故障排查

常用命令：

```bash
journalctl -u incus.service --no-pager -n 200
podman logs --tail 200 incus
podman exec incus incus warning list
podman exec incus incus monitor --type=logging
podman exec incus incus info c1 --project tenant-a --show-log
ovs-vsctl show
ovn-sbctl --db="$OVN_SB" show
ceph --name client.incus status
```

| 现象 | 检查重点 |
| --- | --- |
| 镜像启动即退出 | cgroup v2、AppArmor、securityfs、subuid/subgid |
| `ceph` 驱动不可用 | 镜像客户端包、`/etc/ceph`、MON 网络和 keyring 权限 |
| `ovn` 网络创建失败 | 宿主机 OVS/OVN 版本、NB/SB 地址、`/run/openvswitch` socket、接口名长度 |
| Quadlet service 为 `not-found` | 运行 `quadlet -dryrun`，检查 `.container` 首行和 UTF-8 BOM |
| 实例无网络 | `ovn-controller`、chassis、Geneve UDP 6081、MTU、uplink |
| 宿主机本地盘增长 | `/var/lib/incus`、Podman overlay、镜像缓存、日志和导出文件 |
| Ceph 空间异常增长 | RBD 快照、克隆、项目逻辑配额和 Ceph pool 物理配额 |

升级流程：

1. 先备份 Incus 数据库和 `/etc/ceph`。
2. 固定并拉取新镜像 digest。
3. 一次只升级一个 Incus 节点。
4. 修改 `/etc/containers/systemd/incus.container` 中的 `Image=` digest。
5. 执行 `systemctl daemon-reload && systemctl restart incus.service`，不直接使用 `podman stop/restart`，更不能使用 `kill -9`。
6. 验证集群、Ceph、OVN、AppArmor 和租户实例后再升级下一节点。

## 13. 上线检查表

- [ ] `alpine-novm` digest 已固定，amd64/arm64 架构与节点一致。
- [ ] 镜像内 Incus/Ceph 客户端和宿主机 OVS/OVN 工具预检全部通过。
- [ ] 镜像 `StopSignal` 明确为 `SIGPWR`。
- [ ] 三个 Incus 成员均为 `ONLINE`。
- [ ] `/var/lib/incus` 独立、持久且有限额，并已纳入备份。
- [ ] Ceph 使用独立 pool、最小权限 keyring 和物理 `max_bytes` 配额。
- [ ] 所有系统容器 rootfs 均位于 Ceph RBD。
- [ ] OVS/OVN 服务、Geneve、MTU、uplink 和回程路由验证完成。
- [ ] 每租户独立 restricted project、OVN 网络和资源配额。
- [ ] 租户不能创建本地 disk、特权容器、嵌套容器、快照或备份。
- [ ] 每实例 CPU、内存、进程和 rootfs 大小均有限制，宿主机 swap 策略已确认。
- [ ] AppArmor enforce、seccomp mode 2 和 isolated idmap 已验证。
- [ ] Podman 正常停止使用 `SIGPWR`，没有回退到 SIGKILL。
- [ ] Ceph、Incus 控制面和宿主机磁盘均配置容量与健康告警。
