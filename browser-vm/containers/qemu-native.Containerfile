# Native QEMU, to run the browser VM image (same bzImage and disk) on the
# host in a minute or two, with KVM when the container can use /dev/kvm.
# Used by build.sh test-native. DEBIAN_IMAGE (pinned by digest) and
# SNAPSHOT come from build.sh.
ARG DEBIAN_IMAGE=docker.io/library/debian:trixie
FROM ${DEBIAN_IMAGE}
ARG SNAPSHOT
COPY apt-snapshot /usr/local/sbin/apt-snapshot
RUN apt-snapshot "$SNAPSHOT" && apt-get install -y --no-install-recommends \
	qemu-system-x86 \
	&& rm -rf /var/lib/apt/lists/*
