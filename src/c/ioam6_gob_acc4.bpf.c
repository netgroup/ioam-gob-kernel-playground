/* SPDX-License-Identifier: GPL-2.0 */
/*
 * IOAM6 GOB "4-octet accumulator" test program.
 *
 * Smallest useful GOB: one 32-bit word, in network byte order, carrying the
 * running sum of a per-node metric X. Every node runs its own section
 * (ioam6_gob_acc4_nN), reads X from the gob_metric map (slot = node - 1, the
 * same pinned map used by ioam6_gob_recv), adds it to the word and records
 * into the gob_acc4 map, under its own node id, what it saw.
 *
 * Unlike ioam6_gob_recv, which only uses ctx->data and ctx->data_end, this
 * program is written to exercise the rest of the eBPF interface of the GOB:
 *
 *   ctx->len     payload length; checked against the expected 4 octets
 *   ctx->schema  schema id; recorded
 *   bpf_ioam6_trace_gob_load_bytes()   reads the word at payload offset 0
 *   bpf_ioam6_trace_gob_store_bytes()  writes the updated word
 *   a load one octet past the payload  must be refused (-EFAULT)
 *   ctx->data / ctx->data_end          read the word back after the store and
 *                                      check that the directly addressable
 *                                      window is not wider than ctx->len
 *
 * The same object works in the default mode (GOB trailer, G bit set) and in
 * the namespace-implied mode (no trailer): in both ctx->len is the payload
 * length.
 *
 * The bpf_ioam6_trace_gob_ctx context type comes from vmlinux.h (kernel BTF).
 */
#include <vmlinux.h>
#include <bpf/bpf_endian.h>
#include <bpf/bpf_helpers.h>

char _license[] SEC("license") = "Dual BSD/GPL";

#define GOB_ACC4_LEN	4

/* gob_acc4_entry.err */
#define GOB_ACC4_OK		0
#define GOB_ACC4_ERR_LEN	1	/* ctx->len is not GOB_ACC4_LEN */
#define GOB_ACC4_ERR_METRIC	2	/* no metric for this node */
#define GOB_ACC4_ERR_LOAD	3	/* gob_load_bytes failed */
#define GOB_ACC4_ERR_STORE	4	/* gob_store_bytes failed */
#define GOB_ACC4_ERR_DIRECT	5	/* payload not reachable via ctx->data */

int bpf_ioam6_trace_gob_store_bytes(struct bpf_ioam6_trace_gob_ctx *ctx,
				    u32 offset, const void *from,
				    u32 from__sz) __ksym;

int bpf_ioam6_trace_gob_load_bytes(struct bpf_ioam6_trace_gob_ctx *ctx,
				   u32 offset, void *to, u32 to__sz) __ksym;

/* per-node metric X, slot = node - 1 (shared, pinned by name) */
struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__type(key, __u32);
	__type(value, __u32);
	__uint(max_entries, 5);
	__uint(pinning, LIBBPF_PIN_BY_NAME);
} gob_metric SEC(".maps");

/* what each node saw on the last packet, host byte order */
struct gob_acc4_entry {
	__u32 recv;	/* word received from the previous node */
	__u32 sent;	/* word written by this node */
	__u32 len;	/* ctx->len */
	__u32 schema;	/* ctx->schema */
	__s32 oob;	/* return value of the load past the payload */
	__u32 readback;	/* word read through ctx->data after the store */
	__u32 wider;	/* 1 if ctx->data_end is beyond ctx->data + ctx->len */
	__u32 err;	/* GOB_ACC4_* */
	__u32 pkts;	/* packets seen by this node */
};

struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__type(key, __u32);
	__type(value, struct gob_acc4_entry);
	__uint(max_entries, 6);
	__uint(pinning, LIBBPF_PIN_BY_NAME);
} gob_acc4 SEC(".maps");

static __always_inline int
ioam6_gob_acc4(struct bpf_ioam6_trace_gob_ctx *ctx, __u32 node)
{
	struct gob_acc4_entry *slot;
	__u32 key = node - 1;
	__u32 recv, sent;
	__u8 *data, *data_end;
	__u32 *metricp;
	__be32 word = 0;
	__u8 probe = 0;
	int ret;

	slot = bpf_map_lookup_elem(&gob_acc4, &node);
	if (!slot)
		goto out;

	slot->pkts++;
	slot->len = ctx->len;
	slot->schema = ctx->schema;

	if (ctx->len != GOB_ACC4_LEN) {
		/* not our layout: leave the GOB alone */
		slot->err = GOB_ACC4_ERR_LEN;
		goto out;
	}

	metricp = bpf_map_lookup_elem(&gob_metric, &key);
	if (!metricp) {
		slot->err = GOB_ACC4_ERR_METRIC;
		goto out;
	}

	/* offsets are relative to the GOB payload */
	ret = bpf_ioam6_trace_gob_load_bytes(ctx, 0, &word, sizeof(word));
	if (ret) {
		slot->err = GOB_ACC4_ERR_LOAD;
		goto out;
	}

	/* one octet past the payload: the kernel must refuse it */
	slot->oob = bpf_ioam6_trace_gob_load_bytes(ctx, GOB_ACC4_LEN, &probe,
						   sizeof(probe));

	recv = bpf_ntohl(word);
	sent = recv + *metricp;
	word = bpf_htonl(sent);

	ret = bpf_ioam6_trace_gob_store_bytes(ctx, 0, &word, sizeof(word));
	if (ret) {
		slot->err = GOB_ACC4_ERR_STORE;
		goto out;
	}

	slot->recv = recv;
	slot->sent = sent;

	/* direct access: the store must be visible, the window must end
	 * where the payload ends
	 */
	data = ctx->data;
	data_end = ctx->data_end;
	if (data + GOB_ACC4_LEN > data_end) {
		slot->err = GOB_ACC4_ERR_DIRECT;
		goto out;
	}

	slot->readback = bpf_ntohl(*(__be32 *)data);
	slot->wider = data + GOB_ACC4_LEN + 1 <= data_end;
	slot->err = GOB_ACC4_OK;

	bpf_printk("ioam6_gob_acc4 node=%u: recv=%u sent=%u", node, recv, sent);
out:
	return BPF_OK;
}

SEC("ioam6_gob_acc4_n1")
int prog_ioam6_gob_acc4_n1(struct bpf_ioam6_trace_gob_ctx *ctx)
{
	return ioam6_gob_acc4(ctx, 1);
}

SEC("ioam6_gob_acc4_n2")
int prog_ioam6_gob_acc4_n2(struct bpf_ioam6_trace_gob_ctx *ctx)
{
	return ioam6_gob_acc4(ctx, 2);
}

SEC("ioam6_gob_acc4_n3")
int prog_ioam6_gob_acc4_n3(struct bpf_ioam6_trace_gob_ctx *ctx)
{
	return ioam6_gob_acc4(ctx, 3);
}

SEC("ioam6_gob_acc4_n4")
int prog_ioam6_gob_acc4_n4(struct bpf_ioam6_trace_gob_ctx *ctx)
{
	return ioam6_gob_acc4(ctx, 4);
}

SEC("ioam6_gob_acc4_n5")
int prog_ioam6_gob_acc4_n5(struct bpf_ioam6_trace_gob_ctx *ctx)
{
	return ioam6_gob_acc4(ctx, 5);
}
