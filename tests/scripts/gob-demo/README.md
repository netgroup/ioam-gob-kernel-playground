# IOAM6 GOB per-node-received demo

Interactive demo that shows, per node, the GOB aggregation block each one
received from the previous hop.

## What it does

Every node runs the `ioam6_gob_recv` eBPF program (one section per node).
The GOB payload carries an in-flight aggregation `{min, max, sum, count}` of
a per-node metric X. Each node folds its own X into the GOB and, before
folding, records the whole block it received from the previous node into a
shared pinned map `gob_recv`, keyed by its own node id. n1 is the degenerate
first hop and records nothing.

Topology (7 network namespaces, a line):

    h1 -- n1 -- n2 -- n3 -- n4 -- n5 -- h2
          encap                  decap

- h1, h2: plain IPv6 clients.
- n1: encapsulates client traffic in transit (IOAM6 + GOB).
- n2..n5: record on input.
- n5: decapsulates (End.DT6, table main) and forwards to h2.

## Layout

    gob-demo/
      gob-demo-5node-recv-tmux.sh   interactive tmux dashboard
      gob-demo-5node-recv-auto.sh   non-interactive validation
      bin/                          control helpers: gob-metric, gob-encap,
                                    gob-ping, gob-recv-show, gob-help, and
                                    ioam-nodedata-collect (background decoder
                                    for the traditional IOAM node-data at n5)

The eBPF source is `src/c/ioam6_gob_recv.bpf.c`.

## Build

Inside the ioam-kernel-builder container:

    cd src/c
    make ioam6_gob_recv
    make install        # copies ioam6_gob_recv.bpf.o into the VM's /mnt/shared

## Requirements (in the VM)

- a kernel with IPv6 IOAM6 + GOB support: provides the
  `bpf_ioam6_trace_gob_ctx` BTF the program is built against, and processes
  the GOB at runtime;
- the GOB-aware iproute2 at `/mnt/iproute2/ip/ip` (`ip ioam gobschema`,
  `encap ioam6 ... gobsize`);
- `bpftool` at `/mnt/shared/bpftool`;
- `tmux`, `python3`, `nsenter`.

The scripts check for the missing pieces and stop with a clear message.

## Run

    bash /mnt/scripts/gob-demo/gob-demo-5node-recv-tmux.sh
    tmux attach -t gobdemo

The RECEIVED pane shows two tables. The top one is the GOB (from the
gob_recv map, filled by the eBPF program). The bottom one is the traditional
IOAM node-data seen at n5 (decoded by the background ioam-nodedata-collect).

In the CONTROL pane type `gob-help` for the command list. Typical flow:

    gob-encap combined               # node-data + GOB at n1: both tables fill
    gob-ping                         # h1 pings h2 -> RECEIVED panel fills
    gob-metric set n3 70 ; gob-ping  # change a metric, watch it propagate
    gob-encap gob                    # only the GOB: node-data table empties
    gob-encap trad                   # only node-data: GOB table stops updating
    gob-encap off                    # plain fallback: net works, no IOAM

Non-interactive check:

    bash /mnt/scripts/gob-demo/gob-demo-5node-recv-auto.sh
