# IOAM GOB v3 in the browser

This directory builds a web page that boots the IOAM GOB v3 Linux kernel in
the visitor's browser. Nothing runs on a server. The page can be published
on GitHub Pages.

Inside the virtual machine there are the tools to try GOB end to end:

- `ip` with `ip ioam gobschema` (the GOB iproute2 of this repository),
- `bpftool`, built from the GOB kernel tree,
- `clang`, to build eBPF programs inside the VM,
- the 5-node GOB demo of `tests/scripts/gob-demo/`, unchanged.

How it works, in short: QEMU is compiled to WebAssembly
([qemu-wasm](https://github.com/ktock/qemu-wasm)) and emulates an x86_64
PC in the browser. It boots the GOB kernel and a small Debian guest. The
page downloads the guest disk once (about 94 MB, compressed), decompresses
it in the browser, and starts QEMU with a terminal (xterm.js).

Everything is built in podman containers by one script, `build.sh`, and
everything it writes stays in `browser-vm/out/`.

## Contents

- [Quick start](#quick-start)
- [Requirements](#requirements)
- [The build steps](#the-build-steps)
- [Configuration](#configuration)
- [Reproducibility](#reproducibility)
- [What is in the VM](#what-is-in-the-vm)
- [Using the VM in the browser](#using-the-vm-in-the-browser)
- [Testing](#testing)
- [Publishing on GitHub Pages](#publishing-on-github-pages)
- [Measurements](#measurements)
- [Known limitations](#known-limitations)
- [Problems found and how they were solved](#problems-found-and-how-they-were-solved)
- [Design notes](#design-notes)
- [Troubleshooting](#troubleshooting)
- [Files](#files)
- [Credits and licenses](#credits-and-licenses)

## Quick start

```bash
git clone https://github.com/netgroup/ioam-gob-kernel-playground.git
cd ioam-gob-kernel-playground
git checkout ioam6_gob_v3-dev
git submodule update --init kernel/linux iproute2

cd browser-vm
./build.sh            # all the steps, about one hour the first time
./build.sh serve      # then open http://127.0.0.1:8000/
```

The site to publish is `browser-vm/out/site/`.

`./build.sh` builds what is committed: the kernel and iproute2 at the
commits recorded as submodules, and the demo files of the same commit.
Local changes that are not committed are not used.

## Requirements

- Linux x86_64 with **podman 4.9 or later**, rootless (the build was made
  with podman 4.9.3). No root and no KVM are needed.
- **cgroup v2 with the memory controller delegated to the user.** Every
  container runs with a memory cap (`--memory`). Check with:

  ```bash
  podman info --format '{{.Host.CgroupsVersion}} {{.Host.CgroupControllers}}'
  ```

  The output must say `v2` and list `memory`.
- **Memory:** the clang step uses up to about 12 GB. The containers are
  capped at 12 GB (`MEM_BUILD`) so that a build cannot push the host into
  the out-of-memory killer. A host with 16 GB or more is recommended.
- **Disk:** about 16 GB in `browser-vm/out/` (see [Measurements](#measurements)).
  If the disk of the repository is small, point `WORK` to a bigger one.
- **Network:** the build downloads container images, Debian and Ubuntu
  packages from their snapshot archives, LLVM, qemu-wasm and a few npm and
  pip packages. All of them at fixed versions (see
  [Reproducibility](#reproducibility)).
- The repository with the `kernel/linux` and `iproute2` submodules
  initialised (`git submodule update --init kernel/linux iproute2`).

## The build steps

```
./build.sh [step...]        # no step means all
```

| Step | What it does | Output |
|---|---|---|
| `images` | builds the builder image and the qemu-wasm build image, pulls Playwright | podman images |
| `sources` | exports kernel, iproute2 and the demo from the commit `REF`, clones qemu-wasm | `out/src/`, `out/src/SOURCES.txt` |
| `kernel` | GOB kernel (`bzImage`), `bpftool`, `vmlinux.h` | `out/build/kernel/`, `out/build/bpftool/`, `out/build/vmlinux.h` |
| `clang` | static clang 19.1.7 with only the BPF backend (the long step) | `out/build/clang-bpf/out/` |
| `qemu` | `qemu-system-x86_64` compiled to WebAssembly | `out/build/qemu/` |
| `guest` | guest disk image, ext4 | `out/build/guest/disk.ext4` |
| `pack` | the web site. The compressed disk is cached by the sha256 of kernel, disk and BIOS, so a change to the page only takes seconds | `out/site/` |
| `test` | self test in headless Chromium, about 6 minutes | `out/logs/test*` |
| `test-quick` | boot and a few commands in headless Chromium, about 1 minute. For changes to the page, not enough to publish | `out/logs/test-quick.log` |
| `test-native` | the self test with native QEMU in a container, KVM if usable. For changes to the guest, not enough to publish | `out/logs/test-native*.log` |
| `all` | every step above, in this order | |
| `serve` | serves `out/site/` on `http://127.0.0.1:8000/` | |
| `clean` | removes `out/`, podman storage included | |
| `publish` | pushes `out/site/` to the `gh-pages` branch of `PAGES_REPO` | |

Each step logs to `out/logs/<step>.log` and prints a short summary. A step
can be run again on its own. Which steps a change needs:

| Changed | Run |
|---|---|
| `web/` (the page) | `./build.sh pack test-quick`, then `test` before publishing |
| `guest/` (gob-init, motd, packages) or the demo in the playground | `./build.sh sources guest test-native`, then `pack test` before publishing |
| `kernel/gob-web.fragment` or the kernel submodule | `./build.sh sources kernel guest pack test` |

Every step runs in a container:

| Container | Used by | Defined in |
|---|---|---|
| `gobweb-builder` | sources, kernel, clang, serve | `containers/builder.Containerfile` |
| `gobweb-qemu` | qemu, pack | the qemu-wasm `Dockerfile`, adapted by `scripts/adapt-qemu-dockerfile.py` |
| `gobweb-guest` | guest | `guest/Containerfile` |
| Playwright | test | `mcr.microsoft.com/playwright/python` |

These are separate from the build container of the playground
(`podman/`). Nothing here uses or changes it.

## Configuration

Environment variables of `build.sh`:

| Variable | Default | Meaning |
|---|---|---|
| `WORK` | `browser-vm/out` | where everything is written |
| `PODMAN_ROOT` | `$WORK/podman-storage` | podman storage (`podman --root`) |
| `REPO` | the parent directory of `browser-vm` | the playground to build from |
| `REF` | `HEAD` | the playground commit to build |
| `MEM_BUILD` | `12g` | memory cap of the build containers |
| `MEM_TEST` | `8g` | memory cap of the browser test |
| `KERNEL_JOBS` | `16` | parallel jobs for the kernel |
| `CLANG_JOBS` | `10` | parallel jobs for LLVM. With 10 jobs the peak was about 12 GB |
| `PORT` | `8000` | port of `serve` |
| `PAGES_REPO` | `https://github.com/netgroup/gob-browser-vm.git` | where `publish` pushes the site |
| `KVM_SUDO` | `0` | `1`: `test-native` runs podman as root to use `/dev/kvm`, with its own storage in `$WORK/podman-root-storage` |
| `NATIVE_TIMEOUT` | `900` | seconds before `test-native` gives up |

The temporary files of podman and buildah go to `$WORK/tmp` (`TMPDIR`).
Only the small runtime state of podman stays in `/run/user/<uid>`.

Example, with everything on a second disk and fewer LLVM jobs:

```bash
WORK=/mnt/big/gob-browser-vm CLANG_JOBS=6 ./build.sh
```

## Reproducibility

Every input of the build is fixed, in `build.sh` (section "Pinned
inputs") or in the repository:

| Input | Fixed to |
|---|---|
| GOB kernel, iproute2 | the submodule commits at `REF` |
| demo scripts, eBPF source | the files at `REF` |
| Debian base images | `debian:trixie` and `debian:trixie-slim`, by digest |
| Debian packages | `snapshot.debian.org` at the date `SNAPSHOT` |
| emsdk image (qemu-wasm build) | `emscripten/emsdk:3.1.50`, by digest |
| Ubuntu packages in the emsdk image | `snapshot.ubuntu.com` at the date `SNAPSHOT` |
| qemu-wasm | one commit |
| glib, zlib, pixman, libffi, meson | the versions fixed by the qemu-wasm `Dockerfile` |
| LLVM | 19.1.7, the tarball checked against its sha256 |
| xterm, xterm-pty, coi-serviceworker | fixed npm versions |
| Playwright | image by digest, pip packages at fixed versions |

To move to newer packages, change `SNAPSHOT` and the image digests
together, then build and test.

The build also removes some sources of variation in the outputs: the
kernel gets a fixed build timestamp, user and host, the guest files get a
fixed time, and the ext4 image a fixed UUID, hash seed and creation time.
`gzip -n` leaves out names and times. Whether two builds give
byte-identical files has not been checked.

## What is in the VM

| Part | Details |
|---|---|
| Kernel | the `kernel/linux` submodule at `REF`. Config: the qemu-wasm x86_64 example config plus `kernel/gob-web.fragment` (IOAM, GOB, SRv6, BPF, BTF, veth, netns). No modules, no ACPI, one CPU |
| Guest | Debian trixie, reduced: bash, python3, tmux, make, ping, util-linux |
| `ip` | built from the `iproute2` submodule at `REF` (`ip ioam gobschema`) |
| `bpftool` | built from the GOB kernel tree |
| `clang` | 19.1.7, static, BPF backend only |
| `vmlinux.h` | from the BTF of this kernel, in `/opt/gob/include/` |
| Demo | `tests/scripts/gob-demo/` in `/mnt/scripts/gob-demo/`, unchanged |

The paths follow the QEMU VM of the playground (`/mnt/shared`,
`/mnt/iproute2/ip/ip`, `/mnt/scripts/gob-demo`), so the demo scripts run
as they are.

## Using the VM in the browser

Open the page and wait: it downloads about 94 MB, decompresses them and
boots. A shell appears in the terminal after about half a minute (in
headless Chromium, on the build host). The bar at the top shows the
progress, and links the Internet-Draft, the code and the IETF hackathon
projects about GOB.

Run the 5-node demo:

```bash
gob-demo-5node-recv-auto.sh
```

The demo scripts and their `gob-*` helpers are in the `PATH` of the shell
(`/etc/profile.d/gob-demo.sh`). It builds 7 network namespaces in a line (h1, n1 to n5, h2), loads the
GOB program with `ip ioam gobschema add` on every node, sends a ping from
h1 to h2 through the IOAM encapsulation, and checks what every node
received. It ends with `GOB_DEMO_5NODE_RECV=PASS`.

Or play with it step by step. Set the topology up, then use the `gob-*`
commands (`gob-help` lists them):

```bash
gob-demo-5node-recv-tmux.sh setup-only
gob-encap combined ; gob-ping ; gob-recv-show
gob-metric set n3 70 ; gob-ping ; gob-recv-show
```

`gob-recv-show` prints, for every node, the GOB block `{min, max, sum,
count}` it received from the previous node. After `gob-metric set n3 70`
the nodes after n3 see the new value: node 4 gets max 70 and sum 100,
node 5 gets max 70 and sum 140. `gob-encap gob`, `trad` and `off` switch
the encapsulation of n1 between GOB only, node data only and no IOAM.

The same script without `setup-only` prepares a tmux dashboard: run it,
then `tmux attach -t gobdemo` (detach with `Ctrl-b d`). The five panes at
the top show the metric of each node, RECEIVED shows what each node
received, and CONTROL, where the cursor starts, takes the `gob-*`
commands. The panes refresh after each `gob-ping`, `gob-metric set` and
`gob-encap`, on `gob-refresh` or `Ctrl-b R`, at each packet that reaches
n5 (RECEIVED follows a ping live), and every 15 s in the browser VM
(`GOB_DEMO_REFRESH`, set in `/etc/profile.d/gob-demo.sh`). One process,
`gob-dash-update`, reads the maps for all the panes and sends each pane its
text through a FIFO. A pane is redrawn only when its text changed.
`Ctrl-b r` redraws the whole screen. For another interval: `GOB_DEMO_REFRESH=5
gob-demo-5node-recv-tmux.sh` (0 means only on demand).

Build the eBPF program yourself, then run the demo again with your build:

```bash
cd /opt/gob/src && make
gob-demo-5node-recv-auto.sh
```

`make` writes `/mnt/shared/ioam6_gob_recv.bpf.o`, the object the demo
loads.

Everything lives in memory. Reloading the page starts again from the
original disk.

URL parameters:

| Parameter | Default | Meaning |
|---|---|---|
| `test=1` | off | run the self test at boot (see [Testing](#testing)) |
| `mem=` | `512M` | guest memory, QEMU `-m` |
| `tb=` | `500` | QEMU translation cache in MB (`-accel tcg,tb-size=`) |

## Testing

`./build.sh test` serves `out/site/` with a plain static server, with no
COOP/COEP headers, as GitHub Pages does. It opens `index.html?test=1` in
headless Chromium and reads the VM terminal.

With `?test=1`, `gob-init` runs at boot:

1. the 5-node demo, with the eBPF object built into the disk image,
2. `make` in `/opt/gob/src`: clang builds the program inside the VM,
3. the 5-node demo again, now with the object clang just built,
4. the `gob-*` commands of the welcome message, without tmux:
   `setup-only`, `gob-encap combined`, `gob-ping`, `gob-recv-show`,
   `gob-metric set n3 70`, `gob-ping`, `gob-recv-show`.

The test passes when all of these hold:

- the page became cross-origin isolated (coi-serviceworker works),
- the VM has one CPU,
- the demo printed `GOB_DEMO_5NODE_RECV=PASS` twice and never `FAIL`,
- the first demo, the clang build, the second demo and the interactive
  demo exited with 0,
- after `gob-metric set n3 70`, node 5 received min 10, max 70, sum 140,
  count 4.

`./build.sh test-quick` only opens the page, waits for the shell and runs
`uname -r`, `ip -V`, `bpftool version`, `clang --version` and `stty size`.
It also checks that the demo scripts and the `gob-*` helpers are in the
`PATH` of the shell, that tmux draws (`tmux attach` to a session running
`top`) and detaches, and it logs how long `python3 -c pass` takes.
It takes about a minute, and is meant for changes to the page. Run the
full `test` before publishing.

`./build.sh test-native` boots the same kernel and disk with native QEMU
in a container, with the kernel command line of `?test=1`, and checks the
same markers on the serial console. It tests the guest, not the page.
QEMU uses KVM when the user can open `/dev/kvm` (group `kvm`). Otherwise
`KVM_SUDO=1` runs podman as root for this step, with its own storage under
`out/`, and without either QEMU emulates (TCG).

The result of the full test is the last line of `out/logs/test.log`,
`BROWSER_VM_TEST=PASS` or `BROWSER_VM_TEST=FAIL`. The whole terminal is in
`out/logs/test-chromium.screen`, the timeline in
`out/logs/test-chromium.log`.

## Publishing on GitHub Pages

The site is static. The large files are split into parts of 50 MB, below
the 100 MiB limit that GitHub applies to a single file in a push. GitHub
Pages does not let a site set the COOP and COEP headers that
`SharedArrayBuffer` needs. `coi-serviceworker.js` adds them from a service
worker: on the first visit the page reloads once by itself. A `.nojekyll`
file turns off the Jekyll build.

The site goes to a repository of its own, not to this one. `git clone`
fetches every branch, so a site branch here would make every clone of
the playground download it. The build sources stay here, in
`browser-vm/`. The site records where it comes from in `SOURCES.txt`
(the playground, kernel, iproute2 and qemu-wasm commits).

1. Create an empty public repository on GitHub, for example
   `netgroup/gob-browser-vm` (the default of `PAGES_REPO`).
2. Publish `out/site/`:

   ```bash
   ./build.sh publish
   ```

   It copies the site into a new one-commit branch `gh-pages` and pushes
   it with `--force`, replacing the previous one, so the repository does
   not grow. The commit message lists the commits the site was built
   from (`SOURCES.txt`). It runs on the host, not in a container, because
   the push needs your GitHub credentials. Author, committer and
   `Signed-off-by` are the `user.name` and `user.email` of the playground
   repository, not your global git identity. For another repository:
   `PAGES_REPO=https://github.com/<owner>/<repo>.git ./build.sh publish`.
3. The first time only, on GitHub, in the settings of that repository:
   Pages, "Deploy from a branch", branch `gh-pages`, folder `/ (root)`.
4. After a few minutes the page is at
   `https://netgroup.github.io/gob-browser-vm/`.

For a new version: `./build.sh pack test publish` (or the steps that
changed, then `publish`).

The page works from a subdirectory: all its paths are relative.

GitHub limits a published Pages site to 1 GB and sets a soft bandwidth
limit of 100 GB per month. A visit downloads about 107 MB the first time.

`publish` was tested against a local repository, and the published site
passed the full self test in headless Chromium, loaded from GitHub Pages.

## Measurements

Measured on the build host (64 cores, Linux, podman 4.9.3) on 2026-11-14
and 2026-11-15, in headless Chromium from the Playwright image, with the
site served by a local static server. These are single runs, not
averages. A laptop browser, and a download from GitHub Pages, will
differ.

Site:

| File | Size |
|---|---|
| guest package (kernel, disk, BIOS), gzip, 2 parts | 94,677,482 bytes |
| `qemu-system-x86_64.wasm` | 11,703,534 bytes |
| whole site | about 107 MB |

Self test, seconds from opening the page:

| Event | Time |
|---|---|
| cross-origin isolated (download starts) | 6 s |
| shell ready, self test starts | 21 s |
| first demo PASS | 81 s |
| clang build in the VM | 81 s, done at 166 s |
| second demo (object built in the VM) done | 211 s |
| interactive demo done, end of the test | 256 s |

The same test before the performance section of the kernel config (see
[Design notes](#design-notes)): shell at 26 s, first demo at 106 s,
clang 93 s, end at 322 s.

Cost of a command in the VM, three runs in a row, after the boot:

| Command | Runs |
|---|---|
| `python3 -c pass` | 4.7 s, 1.6 s, 1.6 s (about 19 s for the very first run after the boot) |
| `gob-metric get n1` (bash, plus Python for the JSON) | 21.7 s, 16.5 s, 6.0 s |
| `gob-recv-show` (bash, plus Python for the JSON) | 6.1 s, 6.1 s, 6.0 s |
| `bpftool map dump` of `gob_recv` | 0.5 s, 0.5 s, 0.5 s |
| `bash -c true` | 0.2 s |

`./build.sh all` from an empty `out/`: 46 minutes (the clang step alone
about 17). Disk used by `out/` afterwards: 16 GB, podman storage
included.

## Known limitations

- **Tested in headless Chromium** on Linux, served locally and from
  GitHub Pages. By hand only on one old desktop with a 2013 CPU, where it
  works but is much slower.
- **Firefox:** with an earlier, bigger version of the disk (785 MB instead
  of 310 MB, and the Debian clang), headless Firefox passed the demo but
  the page ran out of memory during the clang build. The current version
  has not been tried in Firefox. WebKit has not been tried.
- **One CPU.** The kernel has no ACPI, so it brings up one CPU only. With
  ACPI and four CPUs the VM was slower in every step (boot, demo, clang).
- **No network** to the outside: QEMU runs with `-nic none`.
- **No persistence:** the disk lives in memory, reloading the page resets
  it.
- **The node-data under the RECEIVED table stays "(waiting for a ping)"**
  in the browser VM. It comes from `ioam-nodedata-collect`, a Python
  helper that the dashboard starts in the background, and Python is very
  slow under emulation (see [Measurements](#measurements)). The GOB table
  above it works.
- The QEMU WebAssembly JIT of qemu-wasm is experimental upstream.

## Problems found and how they were solved

Each entry: what was seen, what caused it and how it was shown, and the
fix.

- **tmux garbled the screen: text in the wrong pane, missing letters,
  stray characters.** A `Ctrl-b r` (full redraw) cleaned the screen, and
  `tmux capture-pane` showed the right content, so tmux was right and the
  damage happened on the way to xterm.js. A capture of the bytes written
  to xterm.js showed that all 1123 line feeds of the dashboard arrived as
  CR LF, none bare. Cause: xterm-pty converts NL to CR NL (`ONLCR` in its
  default termios), and QEMU keeps `OPOST` when it sets up its stdio
  (`qemu_chr_set_echo_stdio()` in `chardev/char-stdio.c`). tmux, in raw
  mode, sends a bare NL to move down one line in the same column, and the
  added CR sent the cursor to column 1. Fix: the page turns `ONLCR` off
  (`slave.ioctl('TCSETS', ...)`) before QEMU starts. Afterwards 964 of 976
  line feeds arrived bare and the dashboard stays clean. The guest still
  converts NL on its own terminals, so plain output is unchanged.
- **tmux did not draw at all.** After `tmux attach` the terminal did not
  change, though tmux was attached (`Ctrl-b d` detached it). The same
  tmux, attached through `script` (a pty), drew. Cause: the tmux client
  was attached directly to the serial console. Fix: `gob-init` runs the
  shell on a pty made by `script`.
- **Long lines wrapped badly.** `stty size` said `0 0`: a serial console
  has no window size. Fix: the page passes the size of its terminal on the
  kernel command line (`gobterm=COLSxROWS`) and `gob-init` sets it with
  `stty`.
- **`gob-help`, `gob-ping` and the other helpers were "command not
  found".** `gob-init` added them to `PATH`, but the shell is a login shell
  and `/etc/profile` sets `PATH` again. Fix: `/etc/profile.d/gob-demo.sh`.
  The self test had not seen it because it runs in the environment of
  `gob-init`. `test-quick` now checks it from the shell.
- **The dashboard froze the VM.** Its six panes ran `watch -n1`, and each
  run started Python to parse the JSON of `bpftool -j`: about 6 s each in
  the VM, so about 36 s of CPU per second. Fix: `gob-metric` and
  `gob-recv-show` read the plain `bpftool` output in bash (0.5 s and 1.2 s,
  same output), and the panes refresh when a `gob-*` command signals them
  (`tmux wait-for`) instead of every second.
- **RECEIVED did not follow a ping, and the node-data table stayed
  empty.** At each refresh each of the six panes started `bpftool`,
  `timeout` and a tmux client. With a 10 s refresh the VM was always
  busy (load 4 to 5, 0% idle), and after `gob-ping 30` RECEIVED went from
  0 to 30 packets in one step, 37 s later. The node-data collector, in
  Python, still showed "(waiting for a ping)" after a ping. Fix: one
  process, `gob-dash-update`, runs one `bpftool batch` per refresh for
  both maps and sends each pane its text through a FIFO, where the pane
  reads it with bash builtins. The collector is now bash, reads
  `stdbuf -oL ip ioam monitor` (without `-oL` the output of `ip` stays in
  its buffer), and wakes the dashboard at each packet. Requests that
  arrive during a refresh are served together, and after a refresh it
  pauses as long as the refresh took. Measured in headless Chromium:
  during `gob-ping 30` RECEIVED changes about every 2 s and shows 30
  after 13 s, a metric change shows in about 2 s, and the idle VM with the
  dashboard is about 15% busy.
- **A status bar with the CPU and memory of the VM was tried and
  dropped.** The guest wrote its numbers to a 9p share (`-virtfs`) every
  2 s. The share mounted, but creating a file in it failed with "Channel
  number out of range", the error filled the terminal, and the loop made
  the VM slower. It was removed. A persistence based on the same 9p share
  would hit the same problem first.

## Design notes

Why the main choices were made. The numbers are from single runs on the
build host.

- **QEMU WebAssembly, not v86 or WebVM.** v86 does not run 64-bit kernels.
  WebVM (CheerpX) emulates Linux system calls and does not boot a kernel,
  so it cannot run the GOB kernel. qemu-wasm emulates a full x86_64 PC
  and boots an unmodified kernel.
- **A BPF-only static clang.** The Debian clang brings about 250 MB of
  LLVM libraries. The static clang with only the BPF backend is about
  90 MB. `Release` and not `MinSizeRel`: `MinSizeRel` gives about 50 MB,
  but clang then built the demo program in 115 s instead of about 65 to
  96 s.
- **The disk is gzip compressed and split.** The browser decompresses it
  with `DecompressionStream`, which is built in, so no decompressor has to
  be downloaded. The uncompressed disk is about 310 MB, mostly empty space
  and libraries that compress well.
- **No ACPI, one CPU.** ACPI is needed only to bring up more than one CPU,
  and more CPUs made the emulation slower. Without ACPI the boot is about
  10 s shorter.
- **QEMU without `-g`.** The `.wasm` goes from about 41 MB to about 12 MB.
- **A kernel config for speed under emulation.** CPU vulnerability
  mitigations off (the VM is alone in a browser tab), `-O2` instead of the
  `-Os` of the qemu-wasm example, no timer tick when idle (`NO_HZ_IDLE`),
  no `PREEMPT_DYNAMIC`, no `DEBUG_PREEMPT`, `SLUB_DEBUG` or stack
  protector, and no SIT (it adds a `sit0` device to every network
  namespace, and the demo does not use it). The self test went from 322 s
  to 256 s. Starting Python did not get faster.
- **The shell runs on a pty.** tmux does not draw when its client is
  attached to a serial port. `gob-init` starts the shell with
  `script -q -c "/bin/bash -l" /dev/null` on the serial console, so the
  shell and everything started from it use a pty.
- **No NL to CR NL conversion in the page**: see
  [Problems found and how they were solved](#problems-found-and-how-they-were-solved).
- **gob-metric and gob-recv-show read the maps in bash**, not Python: in
  the VM a run went from about 6 s to 0.5 s and 1.2 s.
- **The terminal size goes on the kernel command line.** A serial console
  does not carry a window size, so `stty size` says `0 0` and long lines
  wrap badly. The page fits the terminal to the window, passes
  `gobterm=COLSxROWS` to the kernel, and `gob-init` sets it with `stty`.
  Resizing the window later does not change it.
- **A memory cap on every container.** A first attempt without caps ran
  the LLVM build with 64 parallel jobs next to a browser, and the host ran
  out of memory.

## Troubleshooting

- **`short-name ... did not resolve`**: podman needs fully qualified image
  names when no search registry is configured. The scripts use them, so
  this comes from a local change.
- **A step dies with no message, or `oom_kill` in `dmesg`**: a container
  reached its memory cap. Lower `CLANG_JOBS` or `KERNEL_JOBS`, or raise
  `MEM_BUILD` if the host has the memory. The step can be run again on its
  own.
- **`commit ... missing, run: git submodule update --init ...`**: the
  submodule is not initialised, or does not have the commit recorded at
  `REF`.
- **The page stays at "not cross-origin isolated"**: the page must be
  served over HTTPS or from `localhost`, with service workers allowed.
  Private windows may block them.
- **Out of disk space**: everything is in `WORK`. Remove it with
  `./build.sh clean` and point `WORK` elsewhere.

## Files

```
browser-vm/
├── README.md
├── build.sh                     the only entry point
├── containers/
│   ├── builder.Containerfile    builder image
│   ├── qemu-native.Containerfile  native QEMU, for test-native
│   └── apt-snapshot             apt on snapshot.debian.org
├── scripts/
│   ├── fetch-sources.sh         sources from the playground commit, qemu-wasm
│   ├── build-kernel.sh          kernel, bpftool, vmlinux.h
│   ├── build-clang.sh           BPF-only static clang
│   ├── adapt-qemu-dockerfile.py the qemu-wasm Dockerfile, for podman and pinned
│   ├── build-qemu.sh            qemu-system-x86_64 in WebAssembly
│   ├── pack-site.sh             compressed package and web site
│   └── test-native.sh           self test with native QEMU
├── kernel/gob-web.fragment      kernel options
├── guest/
│   ├── Containerfile            guest disk
│   ├── gob-init                 PID 1 of the guest, self test
│   ├── Makefile.bpf             make inside the VM
│   └── motd                     shown at boot
├── web/
│   ├── index.html               the page
│   └── module.js                QEMU arguments
└── test/
    ├── run_test.py              full headless browser test
    └── quick_test.py            one-minute headless browser test
```

## Credits and licenses

- [qemu-wasm](https://github.com/ktock/qemu-wasm) by Kohei Tokunaga: QEMU
  compiled to WebAssembly. The kernel base config and the page come from
  its x86_64 example. QEMU is GPL-2.0.
- [xterm.js](https://xtermjs.org/) (MIT) and
  [xterm-pty](https://github.com/mame/xterm-pty) (MIT): the terminal.
- [coi-serviceworker](https://github.com/gzuidhof/coi-serviceworker)
  (MIT): COOP and COEP headers on static hosting.
- [LLVM](https://llvm.org/) (Apache-2.0 with LLVM exceptions): clang.
- Debian packages, under their own licenses.

The files of this directory are under the license of the repository.
