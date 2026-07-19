# syntax=docker/dockerfile:1

ARG ALPINE_VERSION=edge

FROM --platform=$BUILDPLATFORM alpine:${ALPINE_VERSION} AS ui

ARG INCUS_UI_COMMIT=7752cfdacfdab5b7bc7c5d749c728debe089f8cc

RUN apk add --no-cache git nodejs npm yarn
WORKDIR /build/incus-ui-canonical
RUN git clone https://github.com/canonical/lxd-ui.git . \
    && git checkout --detach "${INCUS_UI_COMMIT}" \
    && sed -i "s/LXD/Incus/g" src/*/*.ts* src/*/*/*.ts* src/*/*/*/*.ts* \
    && sed -i "s/devlxd/guestapi/g" src/*/*.ts* src/*/*/*.ts* src/*/*/*/*.ts* \
    && sed -i "s/dev\/lxd/dev\/incus/g" src/*/*.ts* src/*/*/*.ts* src/*/*/*/*.ts* \
    && sed -i "s/lxd_/incus_/g" src/*/*.ts* src/*/*/*.ts* src/*/*/*/*.ts* \
    && sed -i "s/\"lxd\"/\"incus\"/g" src/*/*.ts* src/*/*/*.ts* src/*/*/*/*.ts* \
    && yarn install --frozen-lockfile \
    && yarn build

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

FROM alpine:${ALPINE_VERSION}

RUN apk add --no-cache \
      acl \
      apparmor \
      apparmor-profiles-abstractions \
      apparmor-profiles-tunables \
      apparmor-utils \
      attr \
      btrfs-progs \
      ceph19-common \
      ceph19-mount \
      dnsmasq \
      e2fsprogs \
      e2fsprogs-extra \
      gnutls \
      incus-feature \
      incus-feature-client \
      iproute2 \
      iptables \
      libbsd \
      libnet \
      libnl3 \
      lvm2 \
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
    && printf '%s\n' 'root:1000000:1000000000' > /etc/subuid \
    && printf '%s\n' 'root:1000000:1000000000' > /etc/subgid \
    && mkdir -p /opt/incus/ui-canonical /var/lib/incus-lxcfs /var/log/incus

COPY aa-exec.c /tmp/aa-exec.c
RUN apk add --no-cache --virtual .aa-exec-build build-base libapparmor-dev \
    && cc -O2 -Wall -Wextra /tmp/aa-exec.c -lapparmor -o /usr/local/bin/aa-exec \
    && strip /usr/local/bin/aa-exec \
    && rm /tmp/aa-exec.c \
    && apk del .aa-exec-build

COPY --from=ui /build/incus-ui-canonical/build/ui/ /opt/incus/ui-canonical/
COPY --from=criu /build/criu/criu/criu /usr/local/sbin/criu
COPY start.sh healthcheck.sh /usr/local/sbin/
RUN chmod 0755 /usr/local/sbin/start.sh /usr/local/sbin/healthcheck.sh

ENV INCUS_UI=/opt/incus/ui-canonical/

VOLUME ["/var/lib/incus"]
STOPSIGNAL SIGPWR
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD ["/usr/local/sbin/healthcheck.sh"]

ENTRYPOINT ["/usr/local/sbin/start.sh"]
