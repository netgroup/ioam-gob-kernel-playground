# Builder image: kernel, bpftool, BPF-only clang, and source export.
# DEBIAN_IMAGE (pinned by digest) and SNAPSHOT come from build.sh.
ARG DEBIAN_IMAGE=docker.io/library/debian:trixie
FROM ${DEBIAN_IMAGE}
ARG SNAPSHOT
COPY apt-snapshot /usr/local/sbin/apt-snapshot
RUN apt-snapshot "$SNAPSHOT" && apt-get install -y --no-install-recommends \
	build-essential flex bison bc libelf-dev libssl-dev dwarves \
	python3 cpio kmod rsync ca-certificates git curl xz-utils \
	cmake ninja-build \
	&& rm -rf /var/lib/apt/lists/*
RUN git config --system --add safe.directory '*'
WORKDIR /work
