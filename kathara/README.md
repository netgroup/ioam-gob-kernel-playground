# IOAM GOB v3 on Kathara

This directory runs the IOAM GOB v3 demo as a Kathara lab, with a GOB
kernel per node: n1 to n5 are UML devices on the GOB v3 kernel of this
repository, which their image carries, and h1 and h2 are plain
containers on the kernel of the host. It is the five node demo of
`tests/scripts/gob-demo` (`gob-demo-5node-recv-auto.sh`), where the five
nodes are network namespaces of one kernel.

    h1 --A-- n1 --B-- n2 --C-- n3 --D-- n4 --E-- n5 --F-- h2
             encap                                End.DT6

Kathara with UML devices comes from
[kathara-uml-lab](https://github.com/netgroup/kathara-uml-lab), a
submodule here, which has in turn the Kathara fork as its submodule
`kathara`.

## Set it up

The lab needs an x86-64 Linux host, since User-Mode Linux runs only on
x86, with Docker, which Kathara runs the devices on, and Python 3 with
venv. Initialize the two submodules, kathara-uml-lab and the Kathara
fork inside it, and install that Kathara in a venv:

```
git submodule update --init --recursive kathara/kathara-uml-lab
python3 -m venv ~/kathara-uml-venv
~/kathara-uml-venv/bin/pip install kathara/kathara-uml-lab/kathara
alias kathara="$HOME/kathara-uml-venv/bin/python $PWD/kathara/kathara-uml-lab/kathara/src/kathara.py"
```

Nothing else is needed to run the lab: the GOB nodes run on the image
`ghcr.io/netgroup/kathara-uml-gob:6.18.0-rc1-494d8b67e580`, which carries
the GOB UML kernel together with the tools of GOB, and Kathara pulls it
at the first lstart. The GOB program, `lab/shared/ioam6_gob_recv.o`, is
in the repository. To build them yourself, see [Build it](#build-it).

## Run it

```
cd kathara/lab
kathara lstart --noterminals
kathara exec n5 "tail -1 /var/log/gob-node.log"    # gob-node: node 5 ready, metric 50
kathara exec h1 "ping -6 -c 3 -I fdcc::1 fdcc::2"
kathara exec n5 "bpftool map lookup pinned /sys/fs/bpf/tc/globals/gob_recv key 5 0 0 0"
kathara exec n5 "cat /sys/kernel/tracing/trace"
kathara lclean
```

Each node is ready once its `/var/log/gob-node.log` ends with `ready`:
start the ping after that. After 3 pings, slot K of the map `gob_recv`
on node K holds what the node received from the nodes before it:

| Node | min | max | sum | count | pkts |
|---|---|---|---|---|---|
| n2 | 10 | 10 | 10 | 1 | 3 |
| n3 | 10 | 20 | 30 | 2 | 3 |
| n4 | 10 | 30 | 60 | 3 | 3 |
| n5 | 10 | 40 | 100 | 4 | 3 |

and the trace buffer of n5 has a line per packet from `bpf_printk()`:

```
bpf_trace_printk: ioam6_gob_recv node=5: recv count=4 metric=50
```

## Build it

`build.sh` builds the kernel, the image and the program from the
playground commit, with Docker:

```
git submodule update --init kernel/linux iproute2
kathara/build.sh
```

It exports the sources at the commits that the playground commit
records, with `git archive`: `kernel/linux` and `iproute2` only need to
have those commits, and their work trees are not touched. Where they are
already work trees on other branches, do not run the first command,
which would move them to the recorded commits: fetch the commits into
them instead. In a worktree without them, give the playground that has
them: `REPO=<playground> kathara/build.sh`.

It writes the GOB UML kernel into `kathara/out/kernel/linux`, builds
the image with that kernel in it, tagged with the release and the commit
of the kernel, and the GOB program into `lab/shared/ioam6_gob_recv.o`.
`lab/lab.conf` must name the image that it builds: when the kernel
changes, build.sh stops and says which image to write there. The first
run builds LLVM for clang; give it more jobs with `CLANG_JOBS=<n>`. Docker
then reuses that build only for the same `CLANG_JOBS`: with another value
it builds LLVM again. Each step can also run alone: see the top of
[build.sh](build.sh).

## Run a node on another kernel

The kernel option of lab.conf takes the place of the kernel of the
image on a node, while the image keeps giving the node its tools. To try
a changed GOB kernel on n3 only, build it with `build.sh sources kernel`
and uncomment the line in [lab/lab.conf](lab/lab.conf):

```
n3[kernel]="../out/kernel/linux"
```

The path is relative to the lab directory. The example lab of
kathara-uml-lab,
[examples/router](https://github.com/netgroup/kathara-uml-lab/tree/main/examples/router), runs a
device on a kernel file and on an image of its own in the same way.

## The lab

| Device | Addresses | Role |
|---|---|---|
| h1 | fd01::1, fdcc::1 on lo | sends the traffic to fdcc::2 through n1 |
| n1 | fd01::2, fd12::1 | adds the IOAM trace with the GOB to the traffic for fdcc::2, and encapsulates it up to n5 (fcff::5) |
| n2 | fd12::2, fd23::2 | processes the trace on its input (eth0) |
| n3 | fd23::3, fd34::3 | the same |
| n4 | fd34::4, fd45::4 | the same |
| n5 | fd45::5, fd56::5 | processes the trace, takes the encapsulation off with End.DT6 (fcff::5) |
| h2 | fd56::6, fdcc::2 on lo | receives the traffic, answers fdcc::1 through n5 |

The addresses, the routes and the IOAM settings are those of
`gob-demo-5node-recv-auto.sh`, interface by interface.

Each GOB node runs `src/c/ioam6_gob_recv.bpf.c`: the GOB carries an
aggregation `{min, max, sum, count}` of a metric of the nodes, 10 for n1
up to 50 for n5. Each node records the GOB that it received in slot K of
its map `gob_recv`, then folds its own metric into it.

- [lab/lab.conf](lab/lab.conf): n1 to n5 on the image of the GOB nodes,
  and so on its kernel, h1 and h2 on kathara/base, IPv6 on.
- `lab/*.startup`: addresses and routes, the IOAM trace on n1, End.DT6 on
  n5, `ioam6_enabled` on the input of n2 to n5, and
  `bash /shared/gob-node.sh <node> <metric>` on each GOB node.
- [lab/shared/gob-node.sh](lab/shared/gob-node.sh): makes a device a GOB
  node: its IOAM node id, IOAM namespace 123, the section of the program
  for the node attached through GOB schema 0xAA, and its metric in the map
  `gob_metric`. It logs each step to `/var/log/gob-node.log`.

## Build the program inside a node

The image has clang, with only the BPF backend, and bpftool: the GOB
program can be built inside a node, against the BTF of the kernel it runs
on, and loaded in place of `lab/shared/ioam6_gob_recv.o`. On n3:

```
kathara exec n3 "bash -c 'bpftool btf dump file /sys/kernel/btf/vmlinux format c > /tmp/vmlinux.h'"
kathara exec n3 "clang -O2 -g -target bpf -I/tmp -c /shared/ioam6_gob_recv.bpf.c -o /tmp/ioam6_gob_recv.o"
kathara exec n3 "ip ioam namespace set 123 gobschema none"
kathara exec n3 "ip ioam gobschema del 0xAA"
kathara exec n3 "ip ioam gobschema add 0xAA object /tmp/ioam6_gob_recv.o section ioam6_gob_recv_n3"
kathara exec n3 "ip ioam namespace set 123 gobschema 0xAA"
kathara exec n3 "ip ioam gobschema show"     # gobschema 170 [namespace 123] prog ioam6_gob_recv.o:[ioam6_gob_recv_n3]
```

The next pings give the same results as before. To change the program
for every node, change `src/c/ioam6_gob_recv.bpf.c`, commit, and run
`build.sh sources program`.

## The pieces

- The kernel: `kernel/linux` of the playground commit, with the
  bpf_printk patch of [kernel/](kernel) (UML has no PERF_EVENTS, and
  without the patch the verifier refuses every program that calls
  `bpf_printk()`), built by `uml-kernel/build.sh` of kathara-uml-lab with
  its base, trace and net fragments and
  [kernel/gob.fragment](kernel/gob.fragment): GOB, SRv6 behaviors and BTF.
  `out/kernel/BUILD-INFO` records the commit and the fragments.
- The image, [image/Dockerfile](image/Dockerfile): kathara/base with the
  kernel, in `/usr/lib/kathara-uml/linux` with the label
  `org.kathara.uml.kernel` that makes Kathara run the nodes on it, the
  iproute2 of the playground commit (`ip ioam gobschema`), the bpftool
  and the libbpf headers of its kernel tree, which know the IOAM6_GOB
  program type, and a static clang with only the BPF backend (LLVM
  19.1.7). Its labels also give the repository, the tag and the
  playground commit it was built from.
- The program, `lab/shared/ioam6_gob_recv.o`: `src/c/ioam6_gob_recv.bpf.c`,
  copied next to it, built against the BTF of the kernel of the image, and
  linked again with `bpftool gen object`, which drops the DWARF and keeps
  the BTF.

## Test

`build.sh test` runs [tests/check-gob.sh](tests/check-gob.sh), where
Kathara and the image are. It starts a copy of the lab and checks that
every GOB node runs on the kernel of its image, the ping from h1 to h2,
the table above and the bpf_printk lines of n5. If build.sh has built
the kernel in `out/kernel`, it then starts the lab again with n3 on that
kernel through the kernel option, and checks the same.
