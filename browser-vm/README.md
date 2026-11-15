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
| `pack` | the web site | `out/site/` |
| `test` | self test in headless Chromium | `out/logs/test*` |
| `all` | every step above, in this order | |
| `serve` | serves `out/site/` on `http://127.0.0.1:8000/` | |
| `clean` | removes `out/`, podman storage included | |
| `publish` | pushes `out/site/` to the `gh-pages` branch of `PAGES_REPO` | |

Each step logs to `out/logs/<step>.log` and prints a short summary. A step
can be run again on its own, for example after a change to the guest:

```bash
./build.sh guest pack test
```

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
bash /mnt/scripts/gob-demo/gob-demo-5node-recv-auto.sh
```

It builds 7 network namespaces in a line (h1, n1 to n5, h2), loads the
GOB program with `ip ioam gobschema add` on every node, sends a ping from
h1 to h2 through the IOAM encapsulation, and checks what every node
received. It ends with `GOB_DEMO_5NODE_RECV=PASS`.

Or play with it step by step. Set the topology up, then use the `gob-*`
commands (`gob-help` lists them):

```bash
bash /mnt/scripts/gob-demo/gob-demo-5node-recv-tmux.sh setup-only
gob-encap combined ; gob-ping ; gob-recv-show
gob-metric set n3 70 ; gob-ping ; gob-recv-show
```

`gob-recv-show` prints, for every node, the GOB block `{min, max, sum,
count}` it received from the previous node. After `gob-metric set n3 70`
the nodes after n3 see the new value: node 4 gets max 70 and sum 100,
node 5 gets max 70 and sum 140. `gob-encap gob`, `trad` and `off` switch
the encapsulation of n1 between GOB only, node data only and no IOAM.

The same script without `setup-only` opens a tmux dashboard. That does
not work in the browser VM yet (see [Known limitations](#known-limitations)).

Build the eBPF program yourself, then run the demo again with your build:

```bash
cd /opt/gob/src && make
bash /mnt/scripts/gob-demo/gob-demo-5node-recv-auto.sh
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
4. the interactive demo as the welcome message shows it: `setup-only`,
   `gob-encap combined`, `gob-ping`, `gob-recv-show`,
   `gob-metric set n3 70`, `gob-ping`, `gob-recv-show`.

The test passes when all of these hold:

- the page became cross-origin isolated (coi-serviceworker works),
- the VM has one CPU,
- the demo printed `GOB_DEMO_5NODE_RECV=PASS` twice and never `FAIL`,
- the first demo, the clang build, the second demo and the interactive
  demo exited with 0,
- after `gob-metric set n3 70`, node 5 received min 10, max 70, sum 140,
  count 4.

The result is the last line of `out/logs/test.log`,
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

`publish` was tested against a local repository. GitHub Pages itself has
not been tested yet: the tests so far served the site with a local static
server.

## Measurements

Measured on the build host (64 cores, Linux, podman 4.9.3) on 2026-11-14
and 2026-11-15, in headless Chromium from the Playwright image, with the
site served by a local static server. These are single runs, not
averages. A laptop browser, and a download from GitHub Pages, will
differ.

Site:

| File | Size |
|---|---|
| guest package (kernel, disk, BIOS), gzip, 2 parts | 94,917,070 bytes |
| `qemu-system-x86_64.wasm` | 11,703,534 bytes |
| whole site | about 107 MB |

Self test, seconds from opening the page:

| Event | Time |
|---|---|
| cross-origin isolated (download starts) | 6 s |
| shell ready, self test starts | 26 s |
| first demo PASS | 106 s |
| clang build in the VM | 93 s, done at 212 s |
| second demo (object built in the VM) done | 262 s |
| interactive demo done, end of the test | 322 s |

Across the runs of these two days, the clang build in the VM took
between 65 and 96 seconds, and the first demo ended between 86 and 107
seconds after opening the page.

`./build.sh all` from an empty `out/`: 46 minutes (the clang step alone
about 17). Disk used by `out/` afterwards: 16 GB, podman storage
included.

## Known limitations

- **Tested only in headless Chromium**, on Linux, served locally. Not yet
  on GitHub Pages, and not yet by hand in a desktop browser.
- **Firefox:** with an earlier, bigger version of the disk (785 MB instead
  of 310 MB, and the Debian clang), headless Firefox passed the demo but
  the page ran out of memory during the clang build. The current version
  has not been tried in Firefox. WebKit has not been tried.
- **One CPU.** The kernel has no ACPI, so it brings up one CPU only. With
  ACPI and four CPUs the VM was slower in every step (boot, demo, clang).
- **No network** to the outside: QEMU runs with `-nic none`.
- **No persistence:** the disk lives in memory, reloading the page resets
  it.
- **The tmux dashboard does not show up.** `gob-demo-5node-recv-tmux.sh`
  without arguments sets the topology up and creates the tmux session, but
  after `tmux attach` the terminal of the page does not change. tmux runs
  (`Ctrl-b d` detaches it), so its output is lost somewhere between the
  serial console and xterm.js. The cause is not known yet. Use
  `setup-only` and the `gob-*` commands instead.
- The QEMU WebAssembly JIT of qemu-wasm is experimental upstream.

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
│   └── apt-snapshot             apt on snapshot.debian.org
├── scripts/
│   ├── fetch-sources.sh         sources from the playground commit, qemu-wasm
│   ├── build-kernel.sh          kernel, bpftool, vmlinux.h
│   ├── build-clang.sh           BPF-only static clang
│   ├── adapt-qemu-dockerfile.py the qemu-wasm Dockerfile, for podman and pinned
│   ├── build-qemu.sh            qemu-system-x86_64 in WebAssembly
│   └── pack-site.sh             compressed package and web site
├── kernel/gob-web.fragment      kernel options
├── guest/
│   ├── Containerfile            guest disk
│   ├── gob-init                 PID 1 of the guest, self test
│   ├── Makefile.bpf             make inside the VM
│   └── motd                     shown at boot
├── web/
│   ├── index.html               the page
│   └── module.js                QEMU arguments
└── test/run_test.py             headless browser test
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
