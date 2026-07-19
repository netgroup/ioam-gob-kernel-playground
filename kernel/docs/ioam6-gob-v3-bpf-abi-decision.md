# IOAM6 GOB v3 — BPF helper offset ABI decision

Branch: `ioam6-gob_v3`. Date: 2026-07-19.

## Context

GOB v3 moves the Global-Opaque Block from the head of the Pre-allocated
Trace Option to its tail. Physical layout of the GOB region becomes
`[payload (plen)][header word (4B)]`, i.e. the payload precedes the
header word.

The `bpf_ioam6_trace_gob_{load,store}_bytes()` helpers expose an offset.
Two ABIs were possible for what that offset is relative to.

## Option 1 — preserve the head-era ABI (not chosen, but legitimate)

Offset relative to the GOB header: `[0,4)` = header word (read-only),
`[4,len)` = payload. Same logical view as the head layout, so no BPF
program needs any change. This is the more conservative choice for ABI
stability, and it is not wrong.

In the tail layout the physical order is `[payload][header]`, so this
logical view no longer matches memory: offset 0 (header) sits physically
*after* offset 4 (payload start). The offset becomes a logical address
that inverts the physical order. It is hidden inside the helper (the BPF
author never sees memory), but it is a leaky abstraction.

Cost in the helper `__bpf_ioam6_gob_common()`:

- a piecewise mapping: header at `ctx->data_end`, payload at `ctx->data`.
- handling an access that straddles the header/payload boundary, which is
  no longer contiguous in memory. Two sub-options:
  - reject the straddle. Simpler, but the ABI is not preserved 100%: a
    single `load_bytes(ctx, 0, buf, gob_len)` that reads the whole GOB,
    valid in the head layout, now fails.
  - split it into two memcpys (header part + payload part). ABI preserved
    100%, but more code.

## Option 2 — payload-relative offset (CHOSEN)

Offset relative to the GOB payload: offset `0` = first payload byte. The
header is not addressable through the helpers. Its fields are read from
the context instead:

- Schema-ID: `ctx->schema`
- GOB_Len:   `(ctx->len - 4) / 4`  (payload length `plen = ctx->len - 4`)

Benefit: the kernel helper collapses to `ctx->data + offset` with a
single bound. `ioam6_trace_gob_hdr_from_bpf_ctx()` and the
`bpf_ctx_range(hdr)` write-guard are removed.

Cost: the demo programs in `src/c/netprog.bpf.c` that read the header via
`load_bytes(ctx, 0, ...)` (the `test_ioam6_newapi*` variants) must be
updated to use `ctx->len`. The deployed program `ioam6_gobv2_cnt` uses
only direct `ctx->data` access and is unaffected, since `ctx->data`
still points to the payload in both options.

## Decision

Option 2, because GOB is a research extension and not a stable upstream
ABI, and the only programs affected are the in-repo demos. The deployed
`ioam6_gobv2_cnt` uses direct `ctx->data` access and is unaffected, since
`ctx->data` still points to the payload in both options.

The criterion is the ABI stability. If instead an external or stable BPF
program relied on the header-relative offset ABI, Option 1 would be the
better call, precisely because it does not break that ABI. Option 1 is
the drop-in fallback: keep `ctx.data` at the payload and restore the
piecewise mapping, with the split-copy variant for full straddle support.
