/* SPDX-License-Identifier: GPL-2.0 */
/*
 * IOAM6 GOB "received from the previous node" demo program.
 *
 * Dedicated eBPF object for the gob-demo-5node-recv-* tests. Every node runs
 * its own section (ioam6_gob_recv_nN). The GOB payload carries an in-flight
 * aggregation {min,max,sum,count} of a per-node metric X, read from the
 * gob_metric map (slot = node - 1). Before folding its own X, each node
 * records into the shared gob_recv map, under its own node id, the whole
 * aggregation block it received from the previous node. n1 is the degenerate
 * first hop and does not write to gob_recv. User space reads gob_recv to
 * show, per node, what each one received from upstream.
 *
 * The bpf_ioam6_trace_gob_ctx context type comes from vmlinux.h (kernel BTF).
 */
#include <vmlinux.h>
#include <bpf/bpf_endian.h>
#include <bpf/bpf_helpers.h>

char _license[] SEC("license") = "Dual BSD/GPL";

#define __may_pull(start, off, end) \
	(((unsigned char *)(start)) + (off) <= ((unsigned char *)(end)))

#ifndef MIN
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#endif
#ifndef MAX
#define MAX(a, b) ((a) > (b) ? (a) : (b))
#endif

/* GOB payload layout: the in-flight aggregation, u32 in network byte order. */
struct ioam6_gob_agg {
	__be32 min;
	__be32 max;
	__be32 sum;
	__be32 count;
};

/* per-node metric X, slot = node - 1 (shared, pinned by name) */
struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__type(key, __u32);
	__type(value, __u32);
	__uint(max_entries, 5);
	__uint(pinning, LIBBPF_PIN_BY_NAME);
} gob_metric SEC(".maps");

/* what each node received from the previous node, host byte order.
 * pkts counts every packet the node processed (bumped for every node).
 */
struct gob_recv_entry {
	__u32 min;
	__u32 max;
	__u32 sum;
	__u32 count;
	__u32 pkts;
};

struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__type(key, __u32);
	__type(value, struct gob_recv_entry);
	__uint(max_entries, 6);
	__uint(pinning, LIBBPF_PIN_BY_NAME);
} gob_recv SEC(".maps");

/* record, in a node's own slot, the aggregation block it received */
static __always_inline void
gob_recv_store(struct gob_recv_entry *slot, __u32 min, __u32 max,
	       __u32 sum, __u32 count)
{
	if (slot) {
		slot->min = min;
		slot->max = max;
		slot->sum = sum;
		slot->count = count;
	}
}

static __always_inline int
ioam6_gob_recv(struct bpf_ioam6_trace_gob_ctx *ctx, __u32 node)
{
	struct ioam6_gob_agg *agg = ctx->data;
	void *data_end = ctx->data_end;
	struct gob_recv_entry *slot;
	__u32 min, max, sum, count;
	__u32 key = node - 1;
	__u32 *metricp;
	__u32 metric;

	if (!__may_pull(agg, sizeof(*agg), data_end))
		goto out;

	metricp = bpf_map_lookup_elem(&gob_metric, &key);
	if (!metricp)
		goto out;

	metric = *metricp;

	/* every node counts every packet it processes */
	slot = bpf_map_lookup_elem(&gob_recv, &node);
	if (slot)
		slot->pkts++;

	count = bpf_ntohl(agg->count);
	if (!count) {
		/* first hop (n1): nothing received, seed with our metric */
		min = max = sum = metric;
	} else {
		min = bpf_ntohl(agg->min);
		max = bpf_ntohl(agg->max);
		sum = bpf_ntohl(agg->sum);

		/* record the block received from the previous node */
		gob_recv_store(slot, min, max, sum, count);

		min = MIN(min, metric);
		max = MAX(max, metric);
		sum += metric;
	}
	count++;

	agg->min = bpf_htonl(min);
	agg->max = bpf_htonl(max);
	agg->sum = bpf_htonl(sum);
	agg->count = bpf_htonl(count);

	bpf_printk("ioam6_gob_recv node=%u: recv count=%u metric=%u",
		   node, count - 1, metric);
out:
	return BPF_OK;
}

SEC("ioam6_gob_recv_n1")
int prog_ioam6_gob_recv_n1(struct bpf_ioam6_trace_gob_ctx *ctx)
{
	return ioam6_gob_recv(ctx, 1);
}

SEC("ioam6_gob_recv_n2")
int prog_ioam6_gob_recv_n2(struct bpf_ioam6_trace_gob_ctx *ctx)
{
	return ioam6_gob_recv(ctx, 2);
}

SEC("ioam6_gob_recv_n3")
int prog_ioam6_gob_recv_n3(struct bpf_ioam6_trace_gob_ctx *ctx)
{
	return ioam6_gob_recv(ctx, 3);
}

SEC("ioam6_gob_recv_n4")
int prog_ioam6_gob_recv_n4(struct bpf_ioam6_trace_gob_ctx *ctx)
{
	return ioam6_gob_recv(ctx, 4);
}

SEC("ioam6_gob_recv_n5")
int prog_ioam6_gob_recv_n5(struct bpf_ioam6_trace_gob_ctx *ctx)
{
	return ioam6_gob_recv(ctx, 5);
}
