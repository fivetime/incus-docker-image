# syntax=docker/dockerfile:1

ARG ALPINE_VERSION=3.24
ARG INCUS_COMMIT=417e7057adec9188535eb59a341d6ed7726aaab2

FROM alpine:${ALPINE_VERSION} AS incus-build

ARG INCUS_COMMIT
ARG INCUS_REPOSITORY=https://github.com/fivetime/incus.git

RUN apk add --no-cache \
      acl-dev \
      cowsql-dev \
      eudev-dev \
      gcc \
      gettext-dev \
      git \
      go \
      libapparmor-dev \
      libcap-dev \
      libuv-dev \
      linux-headers \
      lxc-dev \
      make \
      musl-dev \
      pkgconf \
      raft-dev \
      sqlite-dev \
    && git clone --filter=blob:none "${INCUS_REPOSITORY}" /build/incus \
    && git -C /build/incus checkout --detach "${INCUS_COMMIT}" \
    && test "$(git -C /build/incus rev-parse HEAD)" = "${INCUS_COMMIT}"

ENV CGO_ENABLED=1 \
    CGO_LDFLAGS="-lintl" \
    CGO_LDFLAGS_ALLOW="(-Wl,-wrap,pthread_create)|(-Wl,-z,now)"

WORKDIR /build/incus
RUN --mount=type=cache,target=/root/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go build -trimpath -ldflags "-s -w" -o /out/incusd ./cmd/incusd \
    && go build -trimpath -ldflags "-s -w" -o /out/incus ./cmd/incus

COPY aa-exec.c /tmp/aa-exec.c
RUN cc -O2 -Wall -Wextra /tmp/aa-exec.c -lapparmor -o /out/aa-exec \
    && strip /out/aa-exec

FROM alpine:${ALPINE_VERSION} AS criu

ARG CRIU_COMMIT=b7bdc14736b1e8598f2ffbb371f42318835a111f

RUN apk add --no-cache \
      bash \
      build-base \
      coreutils \
      e2fsprogs \
      elfutils-dev \
      git \
      gnutls-dev \
      iproute2 \
      libaio-dev \
      libbsd-dev \
      libcap-dev \
      libnet-dev \
      libnl3-dev \
      lz4-dev \
      nftables-dev \
      perl \
      pkgconfig \
      protobuf-c-compiler \
      protobuf-c-dev \
      protobuf-dev \
      python3 \
      util-linux-dev \
    && git clone --filter=blob:none https://github.com/checkpoint-restore/criu.git /build/criu \
    && git -C /build/criu checkout --detach "${CRIU_COMMIT}" \
    && make -C /build/criu -j"$(nproc)" criu WERROR=0 \
    && /build/criu/criu/criu --version

FROM alpine:${ALPINE_VERSION} AS lxc

ARG LXC_COMMIT=e4415af07e3ec291205bc828e2b4e8141f91a499

RUN apk add --no-cache \
      build-base \
      dbus-dev \
      git \
      libapparmor-dev \
      libcap-dev \
      libseccomp-dev \
      linux-headers \
      meson \
      openssl-dev \
      samurai \
      util-linux-dev \
    && git clone --filter=blob:none https://github.com/lxc/lxc.git /build/lxc \
    && git -C /build/lxc checkout --detach "${LXC_COMMIT}"

COPY lxc-restore-finalize-cgroups.patch /tmp/lxc-restore-finalize-cgroups.patch
RUN git -C /build/lxc apply /tmp/lxc-restore-finalize-cgroups.patch \
    && meson setup /build/lxc/build /build/lxc \
      --prefix=/usr \
      -Dtests=false \
      -Dexamples=false \
      -Dman=false \
      -Dinit-script=openrc \
      -Ddistrosysconfdir=/etc \
      -Dselinux=false \
    && ninja -C /build/lxc/build liblxc.so.1.9.0 \
    && ldd /build/lxc/build/liblxc.so.1.9.0 \
    && ! ldd /build/lxc/build/liblxc.so.1.9.0 | grep -q "not found" \
    && strings /build/lxc/build/liblxc.so.1.9.0 | grep -q "apparmor"

FROM alpine:${ALPINE_VERSION}

ARG INCUS_COMMIT

LABEL org.opencontainers.image.source="https://github.com/fivetime/incus" \
      org.opencontainers.image.revision="${INCUS_COMMIT}" \
      io.github.fivetime.incus.variant="alpine-novm"

RUN apk add --no-cache \
      acl \
      apparmor \
      apparmor-profiles-abstractions \
      apparmor-profiles-tunables \
      attr \
      btrfs-progs \
      ceph19-common \
      ceph19-mount \
      dnsmasq \
      e2fsprogs \
      e2fsprogs-extra \
      gnutls \
      iproute2 \
      iptables \
      iptables-legacy \
      libbsd \
      libnet \
      libnl3 \
      lvm2 \
      lxc-libs \
      lxcfs \
      lz4-libs \
      nftables \
      protobuf-c \
      rsync \
      shadow-subids \
      squashfs-tools \
      thin-provisioning-tools \
      util-linux \
      util-linux-misc \
      xz \
      so:libacl.so.1 \
      so:libapparmor.so.1 \
      so:libcap.so.2 \
      so:libcowsql.so.0 \
      so:libgcc_s.so.1 \
      so:libintl.so.8 \
      so:libraft.so.0 \
      so:libsqlite3.so.0 \
      so:libudev.so.1 \
      so:libuv.so.1 \
    && printf '%s\n' 'root:1000000:1000000000' > /etc/subuid \
    && printf '%s\n' 'root:1000000:1000000000' > /etc/subgid \
    && mkdir -p /etc/criu /opt/incus/ui-canonical /var/lib/incus-lxcfs /var/log/incus \
    && printf '%s\n' 'enable-external-masters' > /etc/criu/default.conf

COPY --from=incus-build /out/incusd /usr/sbin/incusd
COPY --from=incus-build /out/incus /usr/bin/incus
COPY --from=incus-build /out/aa-exec /usr/local/bin/aa-exec
COPY --from=criu /build/criu/criu/criu /usr/local/sbin/criu
COPY --from=lxc /build/lxc/build/liblxc.so.1.9.0 /usr/lib/liblxc.so.1.9.0
COPY start.sh healthcheck.sh /usr/local/sbin/
RUN chmod 0755 /usr/local/sbin/start.sh /usr/local/sbin/healthcheck.sh \
    && test "$(incusd --version)" = "7.2" \
    && criu --version \
    && ! ldd /usr/sbin/incusd | grep -q "not found" \
    && ! ldd /usr/local/sbin/criu | grep -q "not found"

VOLUME ["/var/lib/incus"]
STOPSIGNAL SIGPWR
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD ["/usr/local/sbin/healthcheck.sh"]

ENTRYPOINT ["/usr/local/sbin/start.sh"]
