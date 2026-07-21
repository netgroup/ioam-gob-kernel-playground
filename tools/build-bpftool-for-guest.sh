#!/bin/bash
#
# Build a bpftool that actually runs inside the QEMU guest.
#
# Why this script exists
# ----------------------
# The gob-demo needs bpftool at /mnt/shared/bpftool inside the guest. Building it
# in the ioam-kernel-builder container does not work: that container is Ubuntu
# (glibc 2.39) while the guest rootfs produced by tests/vm/create-image.sh is
# Debian bookworm (glibc 2.36), so the binary fails at startup with
#
#     /mnt/shared/bpftool: /lib/x86_64-linux-gnu/libc.so.6:
#     version `GLIBC_2.38' not found (required by /mnt/shared/bpftool)
#
# The C library cannot be worked around by dropping optional dependencies, so
# this script builds bpftool in a throwaway Debian bookworm container instead:
# same distribution as the guest, hence a binary the guest can run.
#
# Both disassembler backends are disabled on purpose. The demo never uses
# `bpftool prog dump jited`, and each backend drags in a dependency tree the
# guest does not have:
#
#   * LLVM   pulls in ~15 extra shared libraries (libz3, libxml2, libicu,
#            libstdc++, libedit, ...), none of which exist in the guest;
#   * libbfd/libopcodes are versioned against the build distribution's binutils
#            (libbfd-2.42-system.so on Ubuntu 24.04), so they would not resolve
#            in the guest even with the right glibc.
#
# With both disabled, bpftool needs only libelf, libz, libcap and libc, all of
# which are present in the guest.
#
# Usage
# -----
#   ./tools/build-bpftool-for-guest.sh
#
# Run it on the host that has podman (not inside the builder container). The
# resulting binary is installed into tests/vm/shared/, which the guests mount
# read-only at /mnt/shared.
#
set -eu

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${REPO}/tests/vm/shared/bpftool"
IMAGE="${IMAGE:-docker.io/library/debian:bookworm}"

if ! command -v podman >/dev/null 2>&1; then
	echo "error: podman not found. Run this on the host, not inside the builder container." >&2
	exit 1
fi

if [ ! -d "${REPO}/bpftool/src" ]; then
	echo "error: the bpftool submodule is not initialised." >&2
	echo "       run: git submodule update --init bpftool" >&2
	exit 1
fi

mkdir -p "$(dirname "${OUT}")"

echo "building bpftool in ${IMAGE} (matching the guest's glibc)"

podman run --rm -v "${REPO}:/src" "${IMAGE}" bash -eux -c '
	export DEBIAN_FRONTEND=noninteractive
	apt-get update
	apt-get install -y --no-install-recommends \
		build-essential libelf-dev zlib1g-dev libcap-dev \
		clang llvm pkg-config
	cd /src/bpftool/src
	make clean
	make -j"$(nproc)" feature-llvm=0 feature-libbfd=0
	install -m 0755 bpftool /src/tests/vm/shared/bpftool
	# Leave no object files behind: they were built with this toolchain, and a
	# later build from the Ubuntu builder container would mix two glibc and fail
	# with an error that does not resemble its cause.
	make clean
'

echo
echo "installed: ${OUT}"
echo "shared library dependencies (must all exist in the guest):"
ldd "${OUT}" 2>/dev/null || true
echo
echo "verify from inside a guest with:  /mnt/shared/bpftool version"
