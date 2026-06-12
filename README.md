# IOAM-GOB Kernel Playground

This repository provides a complete development environment for experimenting with the **Global Opaque Block (GOB)** extension for **IOAM6** (In-Band Operational, Administration, and Maintenance over IPv6). GOB enables programmable in-band network telemetry through user-defined metadata processing via eBPF programs.

## Clone the Repository

```bash
git clone https://github.com/netgroup/ioam-gob-kernel-playground.git
cd ioam-gob-kernel-playground
```

## Prerequisites

- **Podman** v4.0 or later installed on the host system
- **Git** installed for managing submodules and version control operations
- **KVM support** enabled in the host kernel for QEMU virtualization
- **CPU virtualization** (VT-x/AMD-V) enabled in system BIOS settings
- **Root user** (or sudo access) for container operations

## Overview

### What is GOB?

GOB (Global Opaque Block) is a proposed IOAM6 extension that enables programmable metadata processing using eBPF programs.

**Note:** GOB is currently a research extension, not an IETF standard yet. Complete specifications are available in the project repository.

### Technical Details

| Parameter | Specification |
|-----------|---------------|
| **GOB Len** | 8-bit field: count of 4-octet payload units. Total size = 4 + (4 × GOB_Len) bytes |
| **Schema** | 24-bit identifier for metadata format definition |
| **eBPF Type** | `BPF_PROG_TYPE_IOAM6_GOB` |
| **Dedicated Helpers** | `bpf_ioam6_trace_gob_load_bytes()`, `bpf_ioam6_trace_gob_store_bytes()` |
| **Kernel Config** | `CONFIG_IPV6_IOAM6_GOB=y` |

## Architecture

The system consists of three main components:

| Component | Purpose |
|-----------|---------|
| **Host** | Development machine running Podman and providing KVM acceleration |
| **Container** | Builds kernel, runs QEMU for Guest VM |
| **Guest VM** | Executes tests with IOAM6/GOB kernel |

### Directory Layout

**Path Resolution:**
- All project paths are relative to the repository root directory
- In the container environment, the project is mounted at `/opt/kernel-playground`. All project commands should be run from this directory as it becomes the project root.
- QEMU runs from: `tests/vm/` (relative to project root, or `/opt/kernel-playground/tests/vm/` in container)

**Guest VM Mount Points (via 9p filesystem):**
- `/mnt/shared/`: eBPF programs (host: `tests/vm/shared/`)
- `/mnt/scripts/`: Test scripts from host
- `/mnt/iproute2/`: iproute2 source code (contains `ip` binary at `/mnt/iproute2/ip/ip` after build)

### Project Structure

```
ioam-gob-kernel-playground/
├── README.md                       # Project overview
├── AGENTS.md                       # Development guidelines
├── LICENSE                         # MIT License
├── podman/                         # Container environment setup
│   ├── Dockerfile                  # Defines container dependencies
│   ├── container-build.sh          # Builds Podman image
│   ├── setup-all.sh                # Initializes submodules and VM
│   └── README.md                   # Container setup documentation
├── kernel/
│   ├── Makefile                    # Linux kernel build rules
│   ├── configs/                    # Kernel configuration files
│   └── linux/ [submodule]          # Linux kernel source with IOAM6/GOB support
├── src/c/                          # GOB-specific eBPF code
│   ├── netprog.bpf.c               # Primary GOB eBPF program
│   ├── common.h                    # BPF helper definitions
│   └── Makefile                    # eBPF compilation rules
├── iproute2/ [submodule]           # IP tool extensions for GOB
├── libbpf/ [submodule]             # BPF library (dependency)
├── bpftool/ [submodule]            # BPF tools (dependency)
├── tests/                           # Test scripts and VM setup
│   ├── scripts/                    # Test scripts
│   │   └── ioam6-testbed.sh        # IOAM6/GOB network topology tests (routing/XDP tests removed)
│   └── vm/ [submodule]             # VM setup and QEMU (submodule)
│       ├── run.sh                  # Start QEMU VM
│       ├── enter.sh                # Connect via SSH to VM at localhost:10022
│       └── shared/                 # 9p shared directory for VM eBPF binaries
├── vmlinux/                        # vmlinux.h for BPF compilation (dependency, not a submodule)
```

### Git Submodules

The project uses Git submodules for kernel/linux, iproute2, libbpf, bpftool, and tests/vm:

| Submodule | Purpose |
|-----|-------|
| `kernel/linux` | Linux kernel source with IOAM6/GOB support |
| `iproute2` | iproute2 with GOB extension for `ip ioam gobschema` commands |
| `libbpf` | libbpf library for BPF compilation |
| `bpftool` | bpftool for BPF skeleton generation |
| `tests/vm` | VM setup scripts and QEMU configuration |

To update submodules:

```bash
git submodule update --init --recursive
```

## Build Commands

For iterative kernel development after initial setup:

```bash
cd kernel
make config        # Copy kernel config and run olddefconfig
make kbuild        # Build kernel with parallel jobs (nproc)
make install       # Symlink bzImage to tests/vm/
```

Or for full build from scratch:

```bash
cd kernel
make all           # Run config, kbuild, and install sequentially
# Equivalent to: make config && make kbuild && make install
# Symlinks bzImage to tests/vm/
```

See [kernel/Makefile](kernel/Makefile) and [AGENTS.md](AGENTS.md) for detailed build guidelines.

## Getting Started

**Note:** All commands below should be run from the project root directory.

### Build Container and Kernel (On Host)

```bash
cd podman
./container-build.sh    # Build container image
./setup-all.sh          # Initialize submodules, build kernel, create VM image
```

The container is used for development. After running `setup-all.sh`, enter the container environment:

```bash
./run-detach.sh
podman exec -it ioam-kernel-builder bash
cd /opt/kernel-playground
```

All subsequent builds (kernel, eBPF programs, Guest VM) occur under `/opt/kernel-playground` within the container.

### Build eBPF Programs (Inside Container)

```bash
# In the container shell
cd src/c
make && make install    # Build and install eBPF programs
# The compiled .bpf.o files are copied to tests/vm/shared/
```

### Run the VM (Inside Container)

```bash
cd tests/vm
./run.sh                # Start the VM (QEMU runs directly from the container)
```

### Enter the VM (Inside Container)

```bash
cd tests/vm
./enter.sh              # Connect via SSH to VM at localhost:10022
```

All VM operations (boot, stop, test) happen from within the container after changing to `/opt/kernel-playground`. The container has direct KVM access and runs QEMU without requiring host involvement.


### Build iproute2 (Inside Guest VM, mounted at /mnt/iproute2/)

```bash
# After entering the Guest VM
cd /mnt/iproute2
./configure && make                  # Build iproute2 (make install is optional)
# make install copies binaries to system paths but /mnt/iproute2/ip/ip remains available

# Verify binary exists
ls /mnt/iproute2/ip/ip
```

The iproute2 source is mounted from the Container at `/mnt/iproute2`. All iproute2 **build** commands must run within this directory. The VM image includes all necessary build dependencies (bison, flex, libmnl-dev, etc.).

### Run the ioam6-testbed.sh Test (Inside Guest VM)

The ioam6-testbed.sh script creates a network topology with multiple namespaces, sets up IOAM-6 tracing, and loads GOB eBPF programs. The test includes a tmux-based UI for easy navigation.

**Note:** Before running this test, ensure:
1. iproute2 is built in the VM: `cd /mnt/iproute2 && ./configure && make`
2. eBPF programs are built and installed: `cd src/c && make && make install` (in container, copies to tests/vm/shared/)
3. Verify `/mnt/iproute2/ip/ip` and `/mnt/shared/netprog.bpf.o` exist in the VM

**Running the test:**
```bash
# Start the test script
cd /mnt/scripts && ./ioam6-testbed.sh

# The script creates a tmux session named 'ioam6' with windows for: alfa, athos, porthos, aramis, beta
```

**Testing the IOAM-6/GOB functionality:**

1. **In the tmux window "athos":** Send test packets
   ```bash
   ping6 -c 5 db22::2
   ```
   This pings the beta node through the IOAM-6/SRv6 path.

2. **In the tmux window "beta":** Observe GOB eBPF program debug output
   ```bash
   # The tracefs is automatically mounted by the script's beta namespace
   # Tracing is enabled by the eBPF programs when they load
   cat /sys/kernel/tracing/trace_pipe
   ```

   You will see output lines showing:
   - `ioam6_gobv2_cnt: cnt before=X` - counter value before increment
   - `ioam6_gobv2_cnt: cnt after=X` - counter value after increment
   - Each line corresponds to one packet passing through the GOB processing

**tmux navigation:**
- `Ctrl-b n` - switch to next window (alfa → athos → porthos → aramis → beta)
- `Ctrl-b p` - switch to previous window
- `Ctrl-b d` - detach from tmux session (script will clean up resources)

When finished, detach from tmux (Ctrl-b d). The script's EXIT trap will automatically clean up all namespaces, veth devices, and the tmux session.

### (Interactive) Deploy GOB eBPF Program (Inside Guest VM)

**Note:** This deployment step requires:
1. iproute2 to be built in the VM (see [Build iproute2](#build-iproute2-inside-guest-vm-mounted-at-mntiproute2) section)
2. eBPF programs are built and copied to `tests/vm/shared/` (see [Build eBPF Programs](#build-ebpf-programs-inside-container) section)
3. `/mnt/iproute2/ip/ip` and `/mnt/shared/netprog.bpf.o` to exist

```bash
ip ioam gobschema add 77 object /mnt/shared/netprog.bpf.o section ioam6_gobv2_cnt
ip ioam namespace set 123 gobschema 77

# Verify schema
ip ioam gobschema show
```

## License

This project is licensed under the **BSD 3-Clause License** - see the [LICENSE](LICENSE) file for details.

Please note that this repository makes use of external Git submodules and includes portions of code from other open-source projects, which are distributed under their own respective licenses:
* **Linux Kernel** and **iproute2** are licensed under the GNU General Public License v2.0 (GPLv2).
* **libbpf** is dual-licensed under the BSD 2-Clause and LGPL-2.1 licenses.
* Certain files originally from the **syzkaller** project are licensed under the **Apache License 2.0** (see [LICENSE.Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0)).

While the source code specific to this repository is provided under the permissive BSD 3-Clause License, please be aware that if you compile this project and link it against the aforementioned GPL components, the resulting combined executable will be subject to the terms and conditions of the **GPLv2**.

## Acknowledgments

**Main Contributors:**
- Andrea Mayer
- Stefano Salsano
- Giulio Sidoretti

**Institution:**
- Università degli Studi di  Roma "Tor Vergata"

## References

1. **Research Paper**: Available upon publication
2. **Linux Kernel IOAM6 Documentation**: Documentation/networking/ioam6.txt
3. **eBPF Documentation**: https://ebpf.io

## Troubleshooting

### VM Cannot Boot
- Ensure `bzImage` is linked in `tests/vm/`
- Check kernel config has `CONFIG_IPV6_IOAM6_GOB=y`

### eBPF Program Fails to Load
- Verify libbpf and bpftool are properly built
- Check vmlinux.h is in `vmlinux/$(ARCH)/vmlinux.h`
- Run `make` before `make install` to compile first

### iproute2 Missing IOAM6 Commands
- Ensure iproute2 is built inside the Guest VM: `cd /mnt/iproute2 && ./configure && make`
- Verify `/mnt/iproute2/ip/ip` exists and is executable
- Check iproute2 submodules are initialized

## See Also

- [podman/README.md](podman/README.md) - Container setup documentation
- [tests/vm/README.md](https://github.com/netgroup/ioam-gob-linux-kernel-qemu-setup/blob/ioam6-gob_v1/README.md) - VM setup instructions
