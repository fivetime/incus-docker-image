# incus-docker
A project to run incus in docker/podman

Incus is a fork of lxd. Please see here:
https://linuxcontainers.org/incus/

This project aims to maintain a Dockerfile to run incus in a docker/podman container.
It also installs the incus-ui-canonical to have a Web-based UI.

*Versions*

* Debian version: I recommend using this with any glibc-based distributions. This is based off of zabbly/incus stable builds ( https://github.com/zabbly/incus )

* Alpine version: Available, only in Dockerfile form. These will not be prioritized.

* Alpine no-vm version: Available, only in Dockerfile form. This is a smaller iamge which doesn't have qemu/VM functionality.

*Branches*

You can pull from:
* incus-docker:latest -- The default choice. The latest stable version of Incus (Debian based)
* incus-docker:daily -- The daily builds from zabbly/incus (Debian based)
* incus-docker:lts -- The 6.0 LTS version of incus. (Debian based)

How to use it:

*Note*: If you use the environment variable SETIPTABLES=true, it will be adding:
```
iptables (or iptables-legacy) -I DOCKER-USER -j ACCEPT
ip6tables (or ip6tables-legacy) -I DOCKER-USER -j ACCEPT
```

The reason is that, without doing this, docker's iptables settings will be blocking the connections from the incus bridge you create, and your containers/vms will not be able to access the internet. If you use podman, it's not needed.

# To use the image

First, make the directory to hold incus configuration:
``` mkdir /var/lib/incus ```


With Podman (needs root permissions) (recommended):
```
sudo podman run -d \
--name incus \
--log-driver=none \
--cgroups=no-conmon \
--cgroupns=host \
--security-opt unmask=/sys/fs/cgroup \
--privileged \
--network host \
--pid=host \
--volume /dev:/dev \
--volume /var/lib/incus:/var/lib/incus \
--volume /lib/modules:/lib/modules:ro \
ghcr.io/cmspam/incus-docker:latest
```
With Docker:

```
docker run -d \
--name incus \
--privileged \
--env SETIPTABLES=true \
--restart unless-stopped \
--network host \
--pid=host \
--cgroupns=host \
--volume /dev:/dev \
--volume /var/lib/incus:/var/lib/incus \
--volume /lib/modules:/lib/modules:ro \
ghcr.io/cmspam/incus-docker:latest
```

# Fixing cgroups issue

If you run 'podman logs incus' you may see an error such as
```
level=error msg="balance: Unable to set cpuset" err="setting cgroup item for the container failed"
name=(container) value="0,1,2,3"
```
This can be fixed by making sure you run with the option:
```--pid=host```

# Host Device Permissions (KVM GID)

If you are running this container on a host where you also run other virtualization tools (like libvirt or qemu on RHEL, CoreOS, or Fedora), the container's internal udevd might change the ownership of /dev/kvm and break your host's virtual machines.

To prevent this, find your host's KVM group ID:
```
getent group kvm | cut -d: -f3
```

Pass this value (e.g., 36 for RHEL/CoreOS) as an environment variable KVM_GID. This forces the container to use your host's ID, ensuring both the host and Incus can access the device simultaneously.

Example: add `-e KVM_GID=36` to your command if kvm is group 36.

# AppArmor

If you have AppArmor enabled on your setup, you may need to add permissions to dnsmasq so that it can work with Incus without permission errors.  Here is an example of how to do so with OpenSuse Tumbleweed, but it should be similar for other distributions.

Please edit the file:
```/etc/apparmor.d/usr.sbin.dnsmasq```

You will find a line like below, for Tumbleweed it was line 56 or so:
 ```/var/log/dnsmasq*.log w,```

Under that line, please add
 ```/var/lib/incus/** rw,```


If you want to use AppArmor functionality in incus, you can pass it through to the container by adding:

```--volume /sys/kernel/security:/sys/kernel/security```

# OpenVSwitch

If you use OpenVSwitch, add this line to your docker/podman command:
```--volume /run/openvswitch:/run/openvswitch```

# Alpine-based Image

NOTE: If you are using the alpine version with a glibc-based image, you can't depend on the ability to load the modules for VMs automatically. You should set up your environment to automatically load vhost_vsock and kvm modules. You can do it like this:

```
echo "vhost_vsock" > /etc/modules-load.d/incus.conf
echo "kvm" >> /etc/modules-load.d/incus.conf
```

## Hardened Alpine system-container image

The `alpine-novm` image is intended for unprivileged Incus system containers. It compiles the pinned `fivetime/incus` fork revision recorded in the OCI `org.opencontainers.image.revision` label; it does not install Alpine's Incus daemon package. The image also carries the pinned CRIU and liblxc fixes required by the tested stateful-migration path. It does not include QEMU or OVMF.

It requires rootful Podman, cgroup v2, seccomp, AppArmor, a host UTS namespace, a persistent `/run/incus` bind mount, and recursive shared propagation for `/var/lib/incus`. The entrypoint fails instead of starting Incus when these prerequisites or subordinate ID tools are unavailable.

Run it with:

```bash
sudo mkdir -p /var/lib/incus /run/incus-podman
sudo mount --bind /var/lib/incus /var/lib/incus
sudo mount --make-rshared /var/lib/incus

sudo podman run -d \
  --name incus \
  --restart unless-stopped \
  --log-driver none \
  --stop-timeout 60 \
  --cgroups=no-conmon \
  --cgroupns=host \
  --security-opt unmask=/sys/fs/cgroup \
  --security-opt apparmor=unconfined \
  --privileged \
  --network host \
  --pid=host \
  --uts=host \
  --volume /dev:/dev \
  --volume /var/lib/incus:/var/lib/incus:rshared \
  --volume /run/incus-podman:/run/incus:rshared \
  --volume /lib/modules:/lib/modules:ro \
  --volume /sys/kernel/security:/sys/kernel/security \
  --volume /etc/ceph:/etc/ceph:ro \
  ghcr.io/OWNER/REPOSITORY:alpine-novm
```

The Incus daemon writes its logs below `/var/log/incus` and exposes its event
stream through the Incus API. Disable Podman's log driver for this container.
Otherwise the daemon's stdout/stderr pipe belongs to `conmon` and can be
inherited by long-lived LXC monitor processes. Replacing the daemon container
then leaves the old `conmon` waiting for those guest processes to close the
pipe, even when `daemon.live_restore` keeps the guests running correctly.

For a systemd or Quadlet service, have systemd recreate the runtime bind
directory after every boot. `/run` is a tmpfs, so a one-time `mkdir` does not
survive a host reboot:

```ini
[Service]
RuntimeDirectory=incus-podman
RuntimeDirectoryMode=0700
```

`/var/lib/incus` is the persistent state directory. Keep it on durable host storage even when the outer Podman container is replaced. Packages and other changes made inside an Incus instance survive instance and Podman restarts because the instance root disk is stored there. The 60-second stop timeout gives Incus time to shut instances down cleanly.

`/run/incus` must also be a host bind mount so mount namespace state remains reachable while the outer Podman container is restarted. Sharing the host UTS namespace prevents CRIU from encountering an unsupported nested UTS namespace; tenant containers still receive their own UTS namespaces from Incus.

The image includes the Ceph client tools required by the Incus `ceph` and
`cephfs` storage drivers, and the ZFS user-space tools required by the `zfs`
driver. The ZFS kernel module and the named zpool remain host responsibilities;
the outer container must not install or own a second kernel module. The
`/etc/ceph` mount is only needed when using an existing external Ceph cluster;
it supplies that cluster's configuration and a least-privilege Incus keyring.
Do not expose the keyring to tenants. Create the storage pool with the values
for your cluster, for example:

```bash
incus storage create ceph-pool ceph \
  source=incus \
  ceph.cluster_name=ceph \
  ceph.user.name=incus
```

Use the Ceph pool for a new instance root disk by setting the project's default profile or by supplying `--storage ceph-pool` at launch. A local `dir`, Btrfs, or LVM pool is also persistent and is sufficient for a single Incus server; Ceph is useful when the root disks must live on shared, replicated cluster storage. Protect pet-style instances from accidental deletion and take scheduled snapshots or exports, because Ceph replication is not a backup:

```bash
incus config set INSTANCE security.protection.delete=true
incus snapshot create INSTANCE scheduled-backup
```

The outer Podman container is packaging, not a security boundary. It is deliberately unconfined so Incus can load a separate AppArmor profile for every instance. Do not give tenants access to Podman, the Incus Unix socket, an administrator certificate, or the host.

Use a restricted project for each tenant. The following baseline blocks privileged and nested containers, low-level LXC configuration, syscall interception, sensitive devices, and access to networks other than the tenant network:

```bash
incus project create tenant-a \
  -c restricted=true \
  -c features.profiles=true \
  -c features.images=false \
  -c restricted.containers.privilege=unprivileged \
  -c restricted.containers.nesting=block \
  -c restricted.containers.lowlevel=block \
  -c restricted.containers.interception=block \
  -c restricted.devices.unix-char=block \
  -c restricted.devices.unix-block=block \
  -c restricted.devices.gpu=block \
  -c restricted.devices.pci=block \
  -c restricted.devices.proxy=block \
  -c restricted.networks.access=tenant-a
```

Set these options on every tenant container, along with workload-specific CPU, memory, process, and storage limits:

```bash
incus config set INSTANCE security.privileged=false
incus config set INSTANCE security.idmap.isolated=true
incus config set INSTANCE security.nesting=false
incus config set INSTANCE limits.cpu=2
incus config set INSTANCE limits.memory=4GiB
incus config set INSTANCE limits.processes=4096
```

Before admitting tenants, verify that `aa-status` shows each `incus-INSTANCE_</var/lib/incus>` profile in enforce mode and that `/proc/1/status` inside an instance reports `Seccomp: 2`.

# Management

After you start the container, incus will be running. If you used the folder I suggested and used host networking, you can manage it immediately with the incus binary from the same machine. Grab the binary from the latest releases here:

https://github.com/lxc/incus/releases

For example, I use bin.linux.incus.x86_64 from the Assets at the above link.

You can then run **chmod +x bin.linux.incus.x86_64** to make it executable. Let's rename it to incus by running  **mv bin.linux.incus.x86_64 incus**

Now we can check it's working by running

```./incus admin init```

And we can proceed to configure incus.

I find it easiest to move the binary to /usr/local/bin so that I can just run **incus admin init** or whatever other incus command I need from PATH.

If you configure it to be manageable from the network, we can access the web UI, at https://{YOUR IP}:8443

I have successfully tested on both arm64 and x86_64, on ClearLinux (x86_64) and OpenSuse MicroOS (x86_64, arm64). If your distribution has a native Incus package, it's best to use it.

The focus is on x86_64 and arm64, but other platforms may work if you build the Alpine-based Dockerfile.
