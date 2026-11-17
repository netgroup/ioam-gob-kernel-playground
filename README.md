# IOAM-GOB Kernel Playground

This repository provides a complete development environment for experimenting with the **Global Opaque Block (GOB)** extension for **IOAM6** (In-Band Operational, Administration, and Maintenance over IPv6). The GOB is one global metadata region carried at the tail of the IOAM Pre-allocated Trace Option. GOB-aware nodes process it at every hop with user-defined eBPF programs, and nodes that implement plain RFC 9197 are not affected.

**Quick look, nothing to build:** [IOAM GOB v3 in your browser](https://netgroup.github.io/gob-browser-vm/) runs a VM with the GOB v3 kernel in the browser. It is the v3 kernel, so the default mode only (see [GOB Modes](#gob-modes)). Its sources are in [`browser-vm/`](https://github.com/netgroup/ioam-gob-kernel-playground/tree/ioam6_gob_v3-dev/browser-vm) on the `ioam6_gob_v3-dev` branch.

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
- **A Linux bridge on the host** (default name `br0`), only if bridged guests must reach your LAN: `podman/run-detach.sh` attaches the container to it (see [Getting Started](#getting-started))

## Overview

### What is GOB?

The Global Opaque Block (GOB) is an extension of the IOAM Pre-allocated Trace Option (PTO) of [RFC 9197](https://www.rfc-editor.org/rfc/rfc9197). It adds one global metadata region at the tail of the option, after the pre-allocated node data space.

- **Path-level metadata.** Node data in the PTO is per node. The GOB carries what belongs to the packet, the flow or the path as a whole, for example an aggregate that every node updates in flight (minimum, maximum, sum and count of a per-node metric).
- **Transparent to legacy nodes.** RFC 9197 nodes fill the node data space from its tail toward its head, at offsets derived from RemainingLen, and never reach the GOB. They need no change: only the nodes that read or update the GOB are GOB-aware.
- **Programmable.** A GOB-aware node runs an eBPF program on the GOB payload at every hop. A new use case is a schema plus an eBPF program, with no kernel change.

The GOB is specified in the Internet-Draft [draft-mayer-bpm-ioam-gob](https://datatracker.ietf.org/doc/draft-mayer-bpm-ioam-gob/), an individual submission to the IETF BPM working group. It is not an IETF standard.

### GOB Modes

An IOAM namespace handles the GOB in one of two modes:

| | Default mode | Namespace-implied mode |
|---|---|---|
| **Presence of the GOB** | Per packet, signaled by the G bit in the trace header | Every packet of the namespace |
| **Size and schema** | Carried in the GOB trailer, the last 4 octets of the option | Configured on the namespace: no trailer in the packet |
| **G bit** | Set | Not used: the Reserved octet stays at zero |
| **On the wire** | PTO with the G bit set and a GOB trailer | A plain RFC 9197 PTO |
| **Namespace** | `gobschema ID` | `gobschema { ID \| none } gobimplied SIZE` |
| **Encapsulation route** | `gobsize SIZE` | `gobimplied SIZE` |

The namespace-implied mode removes the 4-octet trailer from every packet and, depending on alignment, some padding of the Hop-by-Hop Options header. Commands for both modes are in [GOB Modes: Commands](#gob-modes-commands-inside-guest-vm).

### Technical Details

| Parameter | Specification |
|-----------|---------------|
| **Position** | Tail of the IOAM Pre-allocated Trace Option, after the node data space |
| **GOB Trailer** | Default mode only. Last 4 octets of the option: GOB Len (8 bits) and Schema (24 bits) |
| **GOB Len** | 8-bit field: count of 4-octet payload units. Total size = 4 + (4 × GOB_Len) bytes in the default mode. In the namespace-implied mode the GOB is payload only, of the size configured on the namespace |
| **Schema** | 24-bit identifier for metadata format definition |
| **Payload size** | Non-zero multiple of 4 octets, at most 240 |
| **eBPF Type** | `BPF_PROG_TYPE_IOAM6_GOB` |
| **eBPF Context** | `struct bpf_ioam6_trace_gob_ctx`: `len` (payload length), `schema`, `data` / `data_end` (the GOB payload), `skb` |
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
├── LICENSE                         # BSD 3-Clause License
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
│   ├── ioam6_gob_recv.bpf.c        # Five-node aggregation demo (min, max, sum, count)
│   ├── ioam6_gob_acc4.bpf.c        # 4-octet accumulator example
│   ├── common.h                    # BPF helper definitions
│   └── Makefile                    # eBPF compilation rules
├── iproute2/ [submodule]           # IP tool extensions for GOB
├── libbpf/ [submodule]             # BPF library (dependency)
├── bpftool/ [submodule]            # BPF tools (dependency)
├── tests/                           # Test scripts and VM setup
│   ├── scripts/                    # Test scripts
│   │   ├── ioam6-testbed.sh        # IOAM6/GOB network topology tests (routing/XDP tests removed)
│   │   ├── gob-demo/               # Five-node in-flight aggregation demo
│   │   └── retrocompat/            # Backward-compatibility bench (GOB-aware and stock-kernel nodes)
│   └── vm/ [submodule]             # VM setup and QEMU (submodule)
│       ├── run.sh                  # Start QEMU VM (bridged by default, -u for user-mode networking)
│       ├── enter.sh                # Connect via SSH to a VM started with -u (localhost:10022)
│       └── shared/                 # 9p shared directory for VM eBPF binaries
├── vmlinux/                        # vmlinux.h for BPF compilation (dependency, not a submodule)
```

### Git Submodules

The project uses Git submodules for kernel/linux, iproute2, libbpf, bpftool, and tests/vm:

| Submodule | Purpose |
|-----|-------|
| `kernel/linux` | Linux kernel source with IOAM6/GOB support |
| `iproute2` | iproute2 with GOB support: `ip ioam gobschema`, `ip ioam namespace set ... gobimplied`, and the `gobsize` / `gobimplied` route options |
| `libbpf` | libbpf library for BPF compilation |
| `bpftool` | bpftool for BPF skeleton generation |
| `tests/vm` | VM setup scripts and QEMU configuration |

To update submodules:

```bash
git submodule update --init --recursive
```

The `kernel/linux` and `iproute2` submodules point to the `ioam6-gob_v4` branches of [netgroup/linux-kernel-dev](https://github.com/netgroup/linux-kernel-dev) and [netgroup/linux-iproute2-dev](https://github.com/netgroup/linux-iproute2-dev), which implement both GOB modes.

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

`run-detach.sh` starts the container and links it to the host with a veth pair. The host end is attached to the bridge `br0` (another name can be given with `UPLINK_BR=name ./run-detach.sh`); the other end goes to `br-gob`, a bridge created inside the container, where bridged guests are plugged.

If the host has no such bridge, the script prints a warning and goes on without the uplink: `br-gob` is still created, guests started with `run.sh -u` are not affected, and bridged guests reach each other but not your LAN.

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
./run.sh -u             # Start the VM with user-mode networking (QEMU runs directly from the container)
```

With `-u` the guest uses QEMU user-mode networking and its SSH port is forwarded to `localhost:10022` in the container, which is where `enter.sh` connects.

Without `-u`, `run.sh` starts a bridged guest: named `gob0`, attached with a tap device to `br-gob`, and it fails if `br-gob` does not exist. The options `-n`, `-M`, `-a`, `-g` and `-b` set the guest name, MAC address, static IPv4 address, gateway and bridge, so that several guests can run side by side, one per node, as in the backward-compatibility bench below. The full list of options is at the top of `tests/vm/run.sh`.

### Enter the VM (Inside Container)

```bash
cd tests/vm
./enter.sh              # Connect via SSH to the VM started with -u (localhost:10022)
```

`enter.sh` only reaches a guest started with `-u`. Connect to a bridged guest with SSH at its own address.

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

**Status:** this walkthrough was validated on the GOB v3 kernel and has not been re-run on v4 yet. It uses the default mode, whose commands are the same in v4. `ioam6_gobv2_cnt` is the historical name of the eBPF section in `src/c/netprog.bpf.c`.

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

### GOB Modes: Commands (Inside Guest VM)

A GOB schema binds a numerical ID to an eBPF program. The same schema can be linked to an IOAM namespace in either mode (see [GOB Modes](#gob-modes)).

**Default mode** (G bit and GOB trailer):

```bash
ip ioam gobschema add 170 object gob.bpf.o section ioam6_gob
ip ioam namespace set 1 gobschema 170

# Encapsulating node: 16-octet GOB payload followed by the 4-octet trailer
ip -6 route add 2001:db8:1::/64 encap ioam6 mode encap tundst 2001:db8:42::1 \
    trace prealloc type 0x800000 ns 1 size 12 gobsize 16 dev eth0
```

**Namespace-implied mode** (no trailer, G bit not used):

```bash
ip ioam namespace set 1 gobschema 170 gobimplied 16

# A node that must know the GOB size but runs no program on it
ip ioam namespace set 1 gobschema none gobimplied 16

# Encapsulating node: 16-octet GOB, payload only
ip -6 route add 2001:db8:1::/64 encap ioam6 mode encap tundst 2001:db8:42::1 \
    trace prealloc type 0x800000 ns 1 size 12 gobimplied 16 dev eth0
```

The GOB schema and the implied size are always set together: a `namespace set ... gobschema` command without `gobimplied` puts the namespace back in the default mode. In the namespace-implied mode every packet of the namespace carries the GOB, and all GOB-aware nodes of the domain must be configured with the same size. The full syntax is in the `ip-ioam(8)` and `ip-route(8)` man pages of the iproute2 submodule.

### GOB Demos and Test Benches

- [tests/scripts/gob-demo/](tests/scripts/gob-demo/): five-node demo of in-flight aggregation. Each node folds its own metric into the minimum, maximum, sum and count carried in the GOB (eBPF program `src/c/ioam6_gob_recv.bpf.c`). Shown at the IETF 126 Hackathon.
- [tests/scripts/retrocompat/rc-node-v4.sh](tests/scripts/retrocompat/rc-node-v4.sh): backward-compatibility bench, one node per guest. The path goes through a node running a stock kernel, with no GOB patches, or through a GOB-aware node as a control. In both GOB modes the stock node records its node data and leaves the GOB untouched. Two GOB layouts are covered: 16 octets (`ioam6_gob_recv.bpf.c`) and a 4-octet running sum (`src/c/ioam6_gob_acc4.bpf.c`). Topology, commands and expected results are in the header of the script. Used at the IETF 127 Hackathon.

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

1. **Internet-Draft**: [draft-mayer-bpm-ioam-gob](https://datatracker.ietf.org/doc/draft-mayer-bpm-ioam-gob/), "Global Opaque Block for IOAM Pre-allocated Trace Option"
2. **Research Paper**: A. Mayer, S. Salsano, G. Sidoretti, P. Loreti, L. Bracciale, H. ElBakoury, D. R. Lopez, "Integrating the Global Opaque Block into the IOAM Framework: A Unified Approach to In-Packet Telemetry and Metadata", IEEE/IFIP NOMS 2026. The paper describes an earlier design, with the GOB at the head of the option
3. **RFC 9197**: [Data Fields for In Situ Operations, Administration, and Maintenance (IOAM)](https://www.rfc-editor.org/rfc/rfc9197)
4. **Linux Kernel IOAM6 Documentation**: Documentation/networking/ioam6.txt
5. **eBPF Documentation**: https://ebpf.io

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
- [tests/vm/README.md](https://github.com/netgroup/ioam-gob-linux-kernel-qemu-setup/blob/golden-base/README.md) - VM setup instructions (`golden-base` is the branch followed by the `tests/vm` submodule)
