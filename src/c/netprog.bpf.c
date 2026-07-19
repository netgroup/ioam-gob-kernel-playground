/* SPDX-License-Identifier: GPL-2.0 */
#include <vmlinux.h>
#include <errno.h>
#include <bpf/bpf_endian.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
//#include <linux/ipv6.h>
#include <string.h>

/* The BPFTOOL_IOAM6_GOB_SEC macro determines whether the ioam6_gob eBPF
 * programs are loaded with bpftool and later referenced by the `ip ioam`
 * command.  When the macro is defined (or set to 1) the following
 * behavior occurs:
 *
 * 1) bpftool scans the object file for a section declared as
 *    SEC("ioam6_gob") and loads the program whose C function name matches
 *    the required eBPF context.  The program is then made available either
 *    by its numeric ID or by a pinned object in the BPF filesystem
 *    (bpffs).
 *
 * 2) iproute2 does not use the function name; instead it selects a specific
 *    ioam6_gob variant by the section name.  Each variant therefore occupies
 *    its own dedicated section, allowing iproute2 to address the correct
 *    program even when multiple ioam6_gob programs are present.
 *
 * In summary, defining BPFTOOL_IOAM6_GOB_SEC enables a dual-lookup
 * mechanism: bpftool loads the program via the function name inside the
 * "ioam6_gob" section, while iproute2 chooses the desired variant by
 * referencing that section directly.
 */


//#define BPFTOOL_IOAM6_GOB_SEC	1

#define IPROUTE2_IOAM6_GOB_SEC 1

/* ---------------------------------------------------------------
 * Helper for selecting the eBPF program section.
 *
 * Requirements:
 *   - Exactly one of BPFTOOL_IOAM6_GOB_SEC or IPROUTE2_IOAM6_GOB_SEC
 *     must be defined at compile time.
 *   - If BPFTOOL_IOAM6_GOB_SEC is defined the program is placed in
 *     the fixed section "ioam6_gob".
 *   - If IPROUTE2_IOAM6_GOB_SEC is defined the program is placed in
 *     the section supplied to CSEC().
 *
 * Usage example:
 *
 *     CSEC("my_custom_section")
 *     int my_prog(struct bpf_ioam6_trace_gob_ctx *ctx)
 *     {
 *         return 0;
 *     }
 *
 * --------------------------------------------------------------- */

/* The kernel provides the SEC() macro (usually from <bpf/bpf_helpers.h>).
 * We require it to be visible before this header is included. */
#ifndef SEC
#error "SEC() macro is required - include <bpf/bpf_helpers.h> first"
#endif

/* Compile-time sanity checks: exactly one of the two control macros
 * must be defined. */
#if defined(BPFTOOL_IOAM6_GOB_SEC) && defined(IPROUTE2_IOAM6_GOB_SEC)
#error "Both BPFTOOL_IOAM6_GOB_SEC and IPROUTE2_IOAM6_GOB_SEC are defined; they must be mutually exclusive"
#elif !defined(BPFTOOL_IOAM6_GOB_SEC) && !defined(IPROUTE2_IOAM6_GOB_SEC)
#error "Neither BPFTOOL_IOAM6_GOB_SEC nor IPROUTE2_IOAM6_GOB_SEC is defined; exactly one must be defined"
#endif

/* Definition of CSEC():
 *   - BPFTOOL_IOAM6_GOB_SEC => always SEC("ioam6_gob")
 *   - IPROUTE2_IOAM6_GOB_SEC => SEC(<argument>) */
#ifdef BPFTOOL_IOAM6_GOB_SEC
#define CSEC(x)  SEC("ioam6_gob")
#else /* IPROUTE2_IOAM6_GOB_SEC is defined */
#define CSEC(x)  SEC(x)
#endif

#define likely(x)       __builtin_expect(!!(x), 1)
#define unlikely(x)     __builtin_expect(!!(x), 0)


#define ETH_P_IPV6		0x86DD	/* IPv6 */
#define IPPROTO_ICMPV6		58	/* ICMPv6 */

/* Byte-count bounds check; check if current pointer at @start + @off of header
 * is after @end.
 */
#define __may_pull(start, off, end) \
	(((unsigned char *)(start)) + (off) <= ((unsigned char *)(end)))

/* LLVM maps __sync_fetch_and_add() as a built-in function to the BPF atomic add
 * instruction (that is BPF_STX | BPF_XADD | BPF_W for word sizes)
 */
#ifndef lock_xadd
#define lock_xadd(ptr, val)	((void) __sync_fetch_and_add(ptr, val))
#endif

#ifndef offsetof
#define offsetof(TYPE, MEMBER)	__builtin_offsetof(TYPE, MEMBER)
#endif

/**
 * sizeof_field() - Report the size of a struct field in bytes
 *
 * @TYPE: The structure containing the field of interest
 * @MEMBER: The field to return the size of
 */
#define sizeof_field(TYPE, MEMBER) sizeof((((TYPE *)0)->MEMBER))

/**
 * offsetofend() - Report the offset of a struct field within the struct
 *
 * @TYPE: The type of the structure
 * @MEMBER: The member within the structure to get the end offset of
 */
#define offsetofend(TYPE, MEMBER) \
	(offsetof(TYPE, MEMBER)	+ sizeof_field(TYPE, MEMBER))

#if 0
struct proc_stats {
	__u64 drop;
};

#define XDP_STATS_MAP_NELEM_MAX 1
struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__type(key, __u32);
	__type(value, struct proc_stats);
	__uint(max_entries, XDP_STATS_MAP_NELEM_MAX);
} xdp_stats_map SEC(".maps");

/* Header cursor to keep track of current parsing position */
struct hdr_cursor {
	void *pos;
};

SEC("xdp")
int  xdp_prog_pass(struct xdp_md *ctx)
{
	return XDP_PASS;
}

static __always_inline int
parse_ethhdr(struct hdr_cursor *nh, void *data_end, struct ethhdr **ethhdr)
{
	struct ethhdr *eth = nh->pos;
	int hdrsize = sizeof(*eth);
	__u16 h_proto;

	if (!__may_pull(eth, hdrsize, data_end))
		return -EINVAL;

	/* Move the cursor ahead as we have parsed the ethernet header */
	nh->pos += hdrsize;
	/* network-byte-order */
	h_proto = eth->h_proto;

	if (ethhdr)
		*ethhdr = eth;

	return h_proto;
}

static __always_inline int
parse_ip6hdr(struct hdr_cursor *nh, void *data_end, struct ipv6hdr **ip6hdr)
{
	struct ipv6hdr *ip6h = nh->pos;
	int hdrsize = sizeof(*ip6h);

	/* Pointer-arithmetic bounds check; pointer +1 points to after end of
	 * thing being pointed to.
	 */
	if (!__may_pull(ip6h, hdrsize, data_end))
		return -EINVAL;

	nh->pos += hdrsize;

	if (ip6hdr)
		*ip6hdr = ip6h;

	return ip6h->nexthdr;
}

static __always_inline int
process_ipv6hdr(struct hdr_cursor *nh, void *data_end)
{
	struct proc_stats *pstats;
	struct ipv6hdr *ip6h;
	const int key = 0;
	int nexthdr;

	nexthdr = parse_ip6hdr(nh, data_end, &ip6h);
	if (nexthdr < 0)
		return XDP_PASS;

	/* Do processing based on the IPv6 next header. In this specific case,
	 * drop any ICMPv6 packet.
	 */
	if (nexthdr != IPPROTO_ICMPV6)
		return XDP_PASS;

	/* Lookup in kernel BPF-side return pointer to stats record */
	pstats = bpf_map_lookup_elem(&xdp_stats_map, &key);
	if (!pstats) {
		/* BPF kernel-side verifier will reject program if the
		 * NULL pointer check isn't performed here. Even-though
		 * this is a static array where we know key lookup
		 * XDP_PASS always will succeed.
		 */
		bpf_printk("XDP: Cannot access to proc stats, weird!?! Abort!");
		return XDP_ABORTED;
	}


	/* Multiple CPUs can access data record. Thus, the accounting needs to
	 * use an atomic operation.
	 */
	lock_xadd(&pstats->drop, 1);

	bpf_printk("XDP: received ICMPv6 packet! Drop it!");
	return XDP_DROP;
}

SEC("xdp")
int  xdp_prog_drop_icmpv6(struct xdp_md *ctx)
{
	void *data_end = (void *)(long)ctx->data_end;
	void *data = (void *)(long)ctx->data;
	struct hdr_cursor nh;
	struct ethhdr *eth;
	int h_proto;
       __u16 proto;

	/* These keep track of the next header type and interator pointer */
	nh.pos = data;

	h_proto = parse_ethhdr(&nh, data_end, &eth);
	if (h_proto < 0)
		/* we cannot parse the ethernet header; instead of droppig the
		 * packet we allow it to go in the kernel networking stack to
		 * be further processed.
		 */
		goto out;

	/* From network-byte-order to machine endianess */
	proto = bpf_ntohs(h_proto);
	switch (proto) {
	case ETH_P_IPV6:
		return process_ipv6hdr(&nh, data_end);
	};

	/* Pass the packet to the upper kernel networking */
out:
	return XDP_PASS;
}

SEC("pdum0")
int test_pdummy0(struct __sk_buff *skb)
{
	return BPF_OK;
}

SEC("pdum1")
int test_pdummy1(struct __sk_buff *skb)
{
	bpf_printk("hello pdum1");
	return BPF_OK;
}

SEC("ioam6_dum0")
int test_ioam6_dum0(struct __sk_buff *skb)
{
	struct ipv6hdr ip6h;
	__u8 hop_limit;

	if (skb->protocol != bpf_htons(ETH_P_IPV6))
		goto out;

	if (bpf_skb_load_bytes(skb, 0, &ip6h, sizeof(ip6h)))
		goto out;

	bpf_printk("ioam6_dum0: IPv6 nexthdr proto=%d", ip6h.nexthdr);

	hop_limit = ip6h.hop_limit;
	if (hop_limit > 64) {
		bpf_printk("ioam6_dum0: IPv6 hoplimit (%d) must be <= 64; packet will be dropped",
			   hop_limit);
		 return BPF_DROP;
	}
out:
	return BPF_OK;
}

SEC("ioam6_dum1")
int test_ioam6_dum1(struct __sk_buff *skb)
{
	struct ipv6hdr ip6h;
	__u8 hop_limit;

	if (skb->protocol != bpf_htons(ETH_P_IPV6))
		goto out;

	if (bpf_skb_load_bytes(skb, 0, &ip6h, sizeof(ip6h)))
		goto out;

	hop_limit = ip6h.hop_limit;

	bpf_printk("IPv6 Hop Limit=%d", hop_limit);

out:
	return BPF_OK;
}
#endif

int bpf_dynptr_from_skb(struct __sk_buff *skb, __u64 flags,
			struct bpf_dynptr *ptr__uninit) __ksym;

void *bpf_dynptr_slice(const struct bpf_dynptr *ptr,
		       uint32_t offset, void *buffer,
		       uint32_t buffer__sz) __ksym;

void *bpf_dynptr_slice_rdwr(const struct bpf_dynptr *ptr,
			    uint32_t offset, void *buffer,
			    uint32_t buffer__sz) __ksym;

int bpf_ioam6_trace_gob_store_bytes(struct bpf_ioam6_trace_gob_ctx *, u32,
				    const void *, u32) __ksym;

int bpf_ioam6_trace_gob_load_bytes(struct bpf_ioam6_trace_gob_ctx *, u32,
				   void *, u32) __ksym;

CSEC("ioam6_newapi")
int test_ioam6_newapi(struct bpf_ioam6_trace_gob_ctx *ctx)
{
	struct sk_buff *skb = ctx->skb;
	__be32 pdata;
	__u32 schema = ctx->schema;
	__u32 skb_len = skb->len;
	struct ipv6hdr ip6h, *p;
	struct bpf_dynptr ptr;
	__u32 len = ctx->len;
	__u8 hoplim;
	int ret;

	bpf_printk("GOB New API; GOB Len=%d, Schema=%d, SKB Len=%d",
		   len, schema, skb_len);

	ret = bpf_dynptr_from_skb((struct __sk_buff *)skb, 0, &ptr);
	if (ret) {
		bpf_printk("bpf_dyn_ptr_from_skb error=%d", ret);
		goto out;
	}

	p = bpf_dynptr_slice(&ptr, 0, &ip6h, sizeof(ip6h));
	if (!p) {
		bpf_printk("bpf_dynptr_slice error");
		goto out;
	}

	hoplim = p->hop_limit;
	bpf_printk("GOB New API, IPv6 HopLimit=%d", hoplim);

	/* the offset is payload-relative now; read the first payload word */
	ret = bpf_ioam6_trace_gob_load_bytes(ctx, 0, &pdata, sizeof(pdata));
	if (ret) {
		bpf_printk("Cannot read the GOB payload through gob_load_bytes=%d",
			   ret);
		goto out;
	}

	/* the GOB length comes from the context; the header is not addressable */
	bpf_printk("GOB payload[0]=%u, GOB Len=%d", bpf_ntohl(pdata), len);

out:
	return BPF_OK;
}

CSEC("ioam6_newapi_rdwr")
int test_ioam6_newapi_rdwr(struct bpf_ioam6_trace_gob_ctx *ctx)
{
	struct sk_buff *skb = ctx->skb;
	__u32 schema = ctx->schema;
	__u32 skb_len = skb->len;
	struct ipv6hdr ip6h, *p;
	void *data, *data_end;
	struct bpf_dynptr ptr;
	__u32 len = ctx->len;
	__be32 counter;
	__u8 hoplim;
	__u32 cnt;
	__be32 *v;
	int ret;

	bpf_printk("GOB New API; GOB Len=%d, Schema=%d, SKB Len=%d",
		   len, schema, skb_len);

	ret = bpf_dynptr_from_skb((struct __sk_buff *)skb, 0, &ptr);
	if (ret) {
		bpf_printk("bpf_dyn_ptr_from_skb error=%d", ret);
		goto out;
	}

	p = bpf_dynptr_slice(&ptr, 0, &ip6h, sizeof(ip6h));
	if (!p) {
		bpf_printk("bpf_dynptr_slice error");
		goto out;
	}

	hoplim = p->hop_limit;
	bpf_printk("GOB New API, IPv6 HopLimit=%d", hoplim);

	/* the GOB length comes from the context; the header is not addressable */
	bpf_printk("GOB Len from ctx->len=%d", len);

	/* offset is payload-relative: write the first payload word */
	counter = bpf_htonl(17);
	ret = bpf_ioam6_trace_gob_store_bytes(ctx, 0, &counter,
					      sizeof(counter));
	if (ret) {
		bpf_printk("Cannot write using gob_store_bytes() helper func=%d",
			   ret);
		goto out;
	}

	/* direct access to GOB payload */
	data_end = ctx->data_end;
	data = ctx->data;
	if (data + sizeof(*v) > data_end) {
		bpf_printk("cannot access in READ ctx->data");
		goto out;
	}

	v = (__be32 *)data;
	cnt = bpf_ntohl(*v);
	++cnt;
	*v = bpf_htonl(cnt);

	bpf_printk("v is written, now v=%d", cnt);
out:
	return BPF_OK;
}

#define __gob_data_may_pull(start, size, end) \
	__may_pull((start), (size), (end))

struct ioam6_gob_stats {
	__u32 counter;
};

struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__type(key, __u32);
	__type(value, struct ioam6_gob_stats);
	__uint(max_entries, 1);
} ioam6_gob_stats_map SEC(".maps");

CSEC("ioam6_gobv2_cnt_map")
int prog_ioam6_gobv2_cnt_map(struct bpf_ioam6_trace_gob_ctx *ctx)
{
	void *data_end = ctx->data_end;
	struct ioam6_gob_stats *stats;
	void *data = ctx->data;
	const __u32 key = 0;
	__u32 cnt;

	if (!__gob_data_may_pull(data, sizeof(cnt), data_end))
		goto out;

	/* read the counter from GOB payload, convert in cpu long arch,
	 * increase it and write it back to the packet in network-byte order.
	 */
	cnt = bpf_ntohl(*(__be32 *)data);
	*(__be32 *)data = bpf_htonl(++cnt);

	/* update the map jsut for testing */
	stats = bpf_map_lookup_elem(&ioam6_gob_stats_map, &key);
	if (!stats)
		goto out;

	/* XXX: possibily race condition but we don't care at the moment */
	++stats->counter;
out:
	return BPF_OK;
}

CSEC("ioam6_gobv2_cnt")
int prog_ioam6_gobv2_cnt(struct bpf_ioam6_trace_gob_ctx *ctx)
{
	void *data_end = ctx->data_end;
	void *data = ctx->data;
	__u32 cnt;

	if (!__gob_data_may_pull(data, sizeof(cnt), data_end))
		goto out;

	/* read the counter from GOB payload, convert in cpu long arch,
	 * increase it and write it back to the packet in network-byte order.
	 */
	cnt = bpf_ntohl(*(__be32 *)data);
	bpf_printk("ioam6_gobv2_cnt: cnt before=%d", cnt);

	*(__be32 *)data = bpf_htonl(++cnt);
	bpf_printk("ioam6_gobv2_cnt: cnt after=%d", cnt);
out:
	return BPF_OK;
}

/* Per-node GOB test program. Same shared counter as ioam6_gobv2_cnt (read the
 * first word of the GOB payload, increment, write back), but the hardcoded
 * node id is printed too. Loading a distinct section per node (n1/n2/n3) lets
 * the trace tell the hops apart and pin which node processed last: the line
 * with the highest counter must belong to the last node in the path.
 */
static __always_inline int
ioam6_gobtest(struct bpf_ioam6_trace_gob_ctx *ctx, __u32 node)
{
	void *data_end = ctx->data_end;
	void *data = ctx->data;
	__u32 cnt;

	if (!__gob_data_may_pull(data, sizeof(cnt), data_end))
		goto out;

	cnt = bpf_ntohl(*(__be32 *)data);
	*(__be32 *)data = bpf_htonl(cnt + 1);
	bpf_printk("ioam6_gobtest node=%u: cnt %u -> %u", node, cnt, cnt + 1);
out:
	return BPF_OK;
}

CSEC("ioam6_gobtest_n1")
int prog_ioam6_gobtest_n1(struct bpf_ioam6_trace_gob_ctx *ctx)
{
	return ioam6_gobtest(ctx, 1);
}

CSEC("ioam6_gobtest_n2")
int prog_ioam6_gobtest_n2(struct bpf_ioam6_trace_gob_ctx *ctx)
{
	return ioam6_gobtest(ctx, 2);
}

CSEC("ioam6_gobtest_n3")
int prog_ioam6_gobtest_n3(struct bpf_ioam6_trace_gob_ctx *ctx)
{
	return ioam6_gobtest(ctx, 3);
}

CSEC("ioam6_gobv2_dynptr")
int prog_ioam6_gobv2_dynptr(struct bpf_ioam6_trace_gob_ctx *ctx)
{
	struct sk_buff *skb = ctx->skb;
	struct ipv6hdr ip6h, *p;
	struct bpf_dynptr ptr;
	int ret;

	ret = bpf_dynptr_from_skb((struct __sk_buff *)skb, 0, &ptr);
	if (ret) {
		bpf_printk("bpf_dynptr_from_skb error=%d", ret);
		goto out;
	}

	p = bpf_dynptr_slice(&ptr, 0, &ip6h, sizeof(ip6h));
	if (!p) {
		bpf_printk("bpf_dynptr_slice error");
		goto out;
	}

	bpf_printk("OK >>> bpf_dynptr_slice <<< OK");
out:
	return BPF_OK;
}

#if 0
/* this program MUST NOT load properly!; the slice_rdwr which is forbidden and
 * thus the program must be rejected.
 */
SEC("ioam6_gobv2_dynptr_rw")
int prog_ioam6_gobv2_dynptr_rdrw(struct bpf_ioam6_trace_gob_ctx *ctx)
{
	struct sk_buff *skb = ctx->skb;
	struct ipv6hdr ip6h, *p;
	struct bpf_dynptr ptr;
	int ret;

	ret = bpf_dynptr_from_skb((struct __sk_buff *)skb, 0, &ptr);
	if (ret) {
		bpf_printk("bpf_dynptr_from_skb error=%d", ret);
		goto out;
	}

	p = bpf_dynptr_slice_rdwr(&ptr, 0, &ip6h, sizeof(ip6h));
	if (!p) {
		bpf_printk("bpf_dynptr_slice_rdwr error");
		goto out;
	}

	bpf_printk("!!!KO >>> bpf_dynptr_slice_rdwr <<< KO!!!");
out:
	return BPF_OK;
}
#endif

CSEC("ioam6_gobv2_dynptr_write")
int prog_ioam6_gobv2_dynptr_write(struct bpf_ioam6_trace_gob_ctx *ctx)
{
	struct sk_buff *skb = ctx->skb;
	__u8 write_data[2] = { 1, 2 };
	struct bpf_dynptr ptr;
	int ret;

	ret = bpf_dynptr_from_skb((struct __sk_buff *)skb, 0, &ptr);
	if (ret) {
		bpf_printk("bpf_dynptr_from_skb error=%d", ret);
		goto out;
	}

	ret = bpf_dynptr_write(&ptr, 0, write_data, sizeof(write_data), 0);
	if (ret) {
		bpf_printk("bpf_dynptr_write error=%d", ret);
		goto out;
	}

	bpf_printk("!!!KO >>> bpf_dynptr_write <<< KO!!!");
out:
	return BPF_OK;
}

char _license[] SEC("license") = "Dual BSD/GPL";
