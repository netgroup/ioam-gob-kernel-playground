#!/bin/bash

set -x
set -e

pushd ../

# Init all submodules
for module in $(git submodule status | awk '{print $2}'); do
	if [ "${module}" == "kernel/linux" ]; then
		# A shallow clone with depth 1 fetches only the latest code
		#snapshot of the Linux kernel repository, reducing download
		#size and time, which is helpful for limited resources.
		#However, it omits the full commit history, limiting access to
		#historical data and some Git functionalities that rely on
		#complete history.
		#git submodule update --init --recursive --depth 1 "${module}"
		git submodule update --init --recursive "${module}"
	else
		git submodule update --init --recursive "${module}"
	fi
done

# Setup the VM
#
# This builds a minimal rootfs to be used by the VM
pushd tests/vm
# GOLDEN_IMAGE=1 builds a shared base image, meant to back several per-guest
# qcow2 overlays: no hostname, machine-id or auto-configured network baked in,
# and the resulting image is read-only. Unset, the image is built as before.
./create-image.sh -f full ${GOLDEN_IMAGE:+-g}
popd

# Kernel setup
#
# 1) Copy the pre-shipped linux config file into the `kernel/linux` directory
#    containing the kernel source code;
# 2) Build the kernel;
# 3) Build the out-of-tree (OOT) kernel module, and then copy the resulting
#    module into the VM subproject's shared folder. Specifically, place the
#    module inside a directory shared with the VM instance at `/mnt/shared`.
#    This allows the module to be loaded directly from the running guest OS by
#    accessing this shared folder;
# 4) For installation, create a symbolic link to the compiled `bzImage` (built
#    for the current architecture, only x86_64 has been tested so far) within
#    the VM subproject. This ensures the VM will boot using this specific
#    kernel version. Note that the kernel configuration provided results in a
#    statically built kernel, so no external modules are required at runtime.
pushd kernel
make all
popd

# pushd bpftool/src && \ make clean && make -j$(nproc); popd
#
# pushd src/c && \ make clean && make -j$(nproc); popd
