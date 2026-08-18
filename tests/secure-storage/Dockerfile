FROM debian:13

ENV container=docker
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        systemd \
        systemd-sysv \
        dbus \
        expect \
        ca-certificates \
        curl \
        gnupg \
        procps \
        iproute2 \
        util-linux \
        mount \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN systemctl mask \
      dev-hugepages.mount \
      sys-fs-fuse-connections.mount \
      systemd-remount-fs.service \
      getty@.service \
      console-getty.service || true

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
