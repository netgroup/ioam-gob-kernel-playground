# GOB browser VM

The site at https://netgroup.github.io/gob-browser-vm/ boots the IOAM GOB
v3 Linux kernel in the browser. QEMU, compiled to WebAssembly, emulates an
x86_64 PC with a small Debian guest. Inside there are `ip` with the GOB
commands, `bpftool`, `clang` to build eBPF programs, and the 5-node GOB
demo with its tmux dashboard. Nothing runs on a server and nothing needs
to be installed: the page downloads the guest once per visit, about 94 MB
compressed. It is tested in Chromium.

## This repository is generated

The `gh-pages` branch is built and pushed by `./build.sh publish` in the
`browser-vm/` directory of
[ioam-gob-kernel-playground](https://github.com/netgroup/ioam-gob-kernel-playground),
branch `ioam6_gob_v3-dev`. Each publication replaces the branch with one
new commit, so a change made here is lost at the next one. Change the
sources there instead. `SOURCES.txt` lists the commits the site was built
from.

## Links

- [browser-vm/README.md](https://github.com/netgroup/ioam-gob-kernel-playground/blob/ioam6_gob_v3-dev/browser-vm/README.md):
  how the site is built, the measurements, the known limitations, and the
  [credits and licenses](https://github.com/netgroup/ioam-gob-kernel-playground/blob/ioam6_gob_v3-dev/browser-vm/README.md#credits-and-licenses).
- The GOB draft:
  [draft-mayer-bpm-ioam-gob](https://datatracker.ietf.org/doc/draft-mayer-bpm-ioam-gob/).
