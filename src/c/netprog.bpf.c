/* SPDX-License-Identifier: GPL-2.0 */
#include <vmlinux.h>
#include <errno.h>
#include <bpf/bpf_endian.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

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

int bpf_ioam6_trace_gob_store_bytes(struct __sk_buff *,
				    u32, const void *, u32) __ksym;

SEC("ioam6_cntv1")
int test_ioam6_cntv1(struct __sk_buff *skb)
{
#define GOB_PAYLOAD 8
	struct trace_hdr {
		struct ioam6_trace_hdr trace;
		struct ioam6_trace_gob_hdr gob;
		__u8 data[GOB_PAYLOAD];
	} hdr = { 0, };
	__u32 counter, ocounter;
	__u32 trace_off;
	int ret;

	/* offset starts from skb->data which is network (IPv6) aligned */
	trace_off = sizeof(struct ipv6hdr) + sizeof(struct ioam6_lwt_encap) -
                    sizeof(struct ioam6_trace_hdr);
	ret = bpf_skb_load_bytes(skb, trace_off, &hdr, sizeof(hdr));
	if (ret) {
		bpf_printk("Cannot read the IOAM trace headers");
		goto out;
	}

	if (!hdr.trace.type.gob)
		/* no gob header found */
		goto out;

	ocounter = counter = bpf_ntohl(*(__be32 *)hdr.data);
	++counter;
	*(__be32 *)hdr.data = bpf_htonl(counter);

	ret = bpf_ioam6_trace_gob_store_bytes(skb, 4, hdr.data,
					      sizeof(hdr.data));
	if (ret) {
		bpf_printk("Cannot write on GOB Payload");
		goto out;
	}

	hdr.data[4] = 0xde;
	hdr.data[5] = 0xad;
	hdr.data[6] = 0xbe;
	hdr.data[7] = 0xef;

	ret = bpf_ioam6_trace_gob_store_bytes(skb, 8, hdr.data + 4, 4);
	if (!ret) {
		bpf_printk("ancillary data written");
	}

	bpf_printk("IOAM PTO GOB read before=%d, after=%d",
		   ocounter, counter);
out:
	return BPF_OK;
#undef GOB_PAYLOAD
}

int bpf_ioam6_trace_gob_load_bytes(struct __sk_buff *, u32, void *, u32) __ksym;

SEC("ioam6_cntv2")
int test_ioam6_cntv2(struct __sk_buff *skb)
{
#define GOB_PAYLOAD 8
	struct gob {
		struct ioam6_trace_gob_hdr gob;
		__u8 data[GOB_PAYLOAD];
	} __attribute__((packed)) hdr = { 0, };
	__u32 counter, ocounter;
	__u32 gob_len;
	int ret;

	ret = bpf_ioam6_trace_gob_load_bytes(skb, 0, &hdr, sizeof(hdr));
	if (ret) {
		bpf_printk("Cannot read bytes from GOB");
		goto out;
	}

	gob_len = (bpf_htonl(hdr.gob.hdr) >> 24) * 4 + sizeof(hdr.gob);

	ocounter = counter = bpf_ntohl(*(__be32 *)hdr.data);
	++counter;
	*(__be32 *)hdr.data = bpf_htonl(counter);

	ret = bpf_ioam6_trace_gob_store_bytes(skb, 4, hdr.data,
					      sizeof(hdr.data));
	if (ret) {
		bpf_printk("Cannot write on GOB Payload");
		goto out;
	}

	hdr.data[4] = 0xde;
	hdr.data[5] = 0xad;
	hdr.data[6] = 0xbe;
	hdr.data[7] = 0xef;

	ret = bpf_ioam6_trace_gob_store_bytes(skb, 8, hdr.data + 4, 4);
	if (ret) {
		bpf_printk("cannot write ancillary data");
	}

	bpf_printk("IOAM PTO GOB (Len=%d) read before=%d, after=%d",
		   gob_len, ocounter, counter);
out:
	return BPF_OK;
#undef GOB_PAYLOAD
}

struct scratch {
#define SCRATCH_AREA_SIZE 64
	__u8 data[SCRATCH_AREA_SIZE];
};

struct {
	__uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
	__type(key, __u32);
	__type(value, struct scratch);
	__uint(max_entries, 1);
} ioam6_scratch_map SEC(".maps");

SEC("ioam6_cntv3")
int test_ioam6_cntv3(struct __sk_buff *skb)
{
#define GOB_PAYLOAD 8
	struct gob {
		struct ioam6_trace_gob_hdr gob;
		/* payload data */
		union {
			__be32 counter;
			__u8 data[GOB_PAYLOAD];
		};
	} __attribute__((packed)) *h;
	struct scratch *sarea = NULL;
	__u32 counter, ocounter;
	__be32 ancillary_data;
	const __u32 index = 0;
	__u32 gob_plen;
	int ret;

	/* get access to scratch area */
	sarea = bpf_map_lookup_elem(&ioam6_scratch_map, &index);
	if (!sarea) {
		bpf_printk("Cannot access to scratch area");
		goto out;
	}
	h = (struct gob *)sarea->data;

	/* read the gob header */
	ret = bpf_ioam6_trace_gob_load_bytes(skb, 0, h, sizeof(h->gob));
	if (ret) {
		bpf_printk("Cannot read the GOB Header");
		goto out;
	}

	/* eval GOB payload len, and read from the beginning of the payload */
	gob_plen = h->gob.hbl.len * 4;
	if (gob_plen > sizeof(sarea->data) - sizeof(h->gob) ||
	    gob_plen > sizeof(h->data)) {
		bpf_printk("No space for reading the whole GOB");
		goto out;
	}

	/* read the full GOB payload */
	ret = bpf_ioam6_trace_gob_load_bytes(skb, offsetof(struct gob, data),
					     h->data, gob_plen);
	if (ret) {
		bpf_printk("Cannot read bytes from GOB payload");
		goto out;
	}

	ocounter = counter = bpf_ntohl(h->counter);
	++counter;
	h->counter = bpf_htonl(counter);

	ret = bpf_ioam6_trace_gob_store_bytes(skb,
					      offsetof(struct gob, data),
					      h->data, sizeof(h->counter));
	if (ret) {
		bpf_printk("Cannot write bytes in GOB Payload");
		goto out;
	}

	ancillary_data = bpf_htonl(0xcafec001);
	ret = bpf_ioam6_trace_gob_store_bytes(skb,
					      offsetofend(struct gob, counter),
					      &ancillary_data,
					      sizeof(ancillary_data));
	if (ret) {
		bpf_printk("cannot write ancillary data");
	}

	bpf_printk("IOAM PTO GOB (PLen=%d) read before=%d, after=%d",
		   gob_plen, ocounter, counter);
out:
	return BPF_OK;
#undef GOB_PAYLOAD
}

char _license[] SEC("license") = "Dual BSD/GPL";
