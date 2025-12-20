/* SPDX-License-Identifier: GPL-2.0 */
#include <vmlinux.h>
#include <errno.h>
#include <bpf/bpf_endian.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
//#include <linux/ipv6.h>
#include <string.h>

#define ETH_P_IPV6		0x86DD	/* IPv6 */
#define IPPROTO_ICMPV6		58	/* ICMPv6 */


#define likely(x)       __builtin_expect(!!(x), 1)
#define unlikely(x)     __builtin_expect(!!(x), 0)

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

/*
 * EIP simple counter example
 *
 * init EIP in the GOB
 * add LTV header:
 * 	extended code: 10
 * 	data len: 0 (total is 4 octects)
 * 	type: 666 (whatever)
 * init counter field (1 octet) to 0
 */

#define DISABLE_BPF_PRINTK 0

#if DISABLE_BPF_PRINTK == 1
#define bpf_log_printk(fmt, ...) (0)
#else
#define bpf_log_printk(...) bpf_printk(__VA_ARGS__)
#endif

// double extended (c) and 2 octects long (2)
#define LTV_LEN 0xc2
#define LTV_TYPE 0x666
#define ID1 1
#define ID2 2
#define ETH_HDR_LEN 14

/* node will increment next after writing at (next*4) Bytes in the stack */

SEC("ioam6_eip_init")
int test_ioam6_eip_init(struct __sk_buff *skb)
{
#define GOB_PAYLOAD 12
	struct gob {
		struct ioam6_trace_gob_hdr gob;
		__u8 data[GOB_PAYLOAD];
	} __attribute__((packed)) hdr = { 0, };

	void* data_end;
	void* data;
	struct ipv6hdr *ipv6_h;
	__u32 id = ID1;
	__u8 ttl;
	long ret;

	/* get TTL from IPv6 packet */
	ret = bpf_skb_pull_data(skb, sizeof(*ipv6_h));
	if (ret < 0) {
		bpf_log_printk("could not pull data");
		goto out;
	}

	data_end = (void *)(unsigned long)skb->data_end;
	data = (void *)(unsigned long)skb->data;
	/* check if packet is long enough for ipv6 */
	if (data + sizeof(*ipv6_h) > data_end) {
		bpf_log_printk("pkt too short for IPv6");
		goto out;
	}
	ipv6_h = data;
	ttl = ipv6_h->hop_limit;
	bpf_log_printk("ttl: %d", ttl);

	/* init EIP header and set TTL and ID */
	ret = bpf_ioam6_trace_gob_load_bytes(skb, 0, &hdr, sizeof(hdr));
	if (ret) {
		bpf_printk("Cannot read bytes from GOB");
		goto out;
	}
	hdr.data[0] = LTV_LEN;
	*(__be16 *)&hdr.data[1] = bpf_htons(LTV_TYPE);
	hdr.data[3] = 1; // because it is being populated
	hdr.data[4] = ttl;
	hdr.data[7] = id & 0xff;
	hdr.data[6] = (id >> 8) & 0xff;
	hdr.data[5] = (id >> 16) & 0xff;

	ret = bpf_ioam6_trace_gob_store_bytes(skb, 4, hdr.data,
                                              sizeof(hdr.data));
	if (ret) {
		bpf_printk("Cannot write on GOB Payload");
		goto out;
	}

out:
	bpf_log_printk("init out\n");
	return BPF_OK;
#undef GOB_PAYLOAD
}

/* giulio originale, andrea ha tolto i printk sul trace pipe */
SEC("ioam6_eip_mid")
int test_ioam6_eip_mid(struct __sk_buff *skb)
{
#define GOB_PAYLOAD 12
	struct gob {
		struct ioam6_trace_gob_hdr gob;
		__u8 data[GOB_PAYLOAD];
	} __attribute__((packed)) hdr = { 0, };

	struct ipv6hdr *ipv6_h;
	void *data_end;
	__u32 id = ID2;
	__u8 ttl, next;
	__be16 type;
	void*data;
	long ret;

	/* get TTL from IPv6 packet */
	ret = bpf_skb_pull_data(skb, sizeof(*ipv6_h));
	if (ret < 0) {
		bpf_log_printk("could not pull data");
		goto out;
	}

	data_end = (void *)(unsigned long)skb->data_end;
	data = (void *)(unsigned long)skb->data;
	/* check if packet is long enough for ipv6 */
	if (data + sizeof(*ipv6_h) > data_end) {
		bpf_log_printk("pkt too short for IPv6");
		goto out;
	}
	ipv6_h = data;
	ttl = ipv6_h->hop_limit;
	bpf_log_printk("ttl: %d", ttl);

	/* process EIP header and set TTL and ID */
	ret = bpf_ioam6_trace_gob_load_bytes(skb, 0, &hdr, sizeof(hdr));
	if (ret) {
		bpf_printk("Cannot read bytes from GOB");
		goto out;
	}
	/* check LTV type */
	type = *(__be16 *)&hdr.data[1];
	if (bpf_ntohs(type) != LTV_TYPE) {
		bpf_printk("wrong LTV type: %d", type);
		goto out;
	}
	next = hdr.data[3];
	if (next > 1) {
		bpf_printk("LTV stack full, cannot add data");
		goto out;
	}
	hdr.data[3] = next + 1;
	hdr.data[4] = ttl;
	hdr.data[7] = id & 0xff;
	hdr.data[6] = (id >> 8) & 0xff;
	hdr.data[5] = (id >> 16) & 0xff;

	ret = bpf_ioam6_trace_gob_store_bytes(skb, 4, hdr.data,
					      sizeof(hdr.data));
	if (ret) {
		bpf_printk("Cannot write on GOB Payload");
		goto out;
	}

out:
	bpf_log_printk("init out\n");
	return BPF_OK;
#undef GOB_PAYLOAD
}

SEC("ioam6_gob_eip_idhoplim_init")
int test_ioam6_gob_eip_idhoplim_init(struct __sk_buff *skb)
{
#define GOB_PAYLOAD 8
	struct {
		union {
			struct {
				__be16 type;
				__u8 len;
				__u8 next;
				__be32 ttlhoplim;
			};
			__u8 data[GOB_PAYLOAD];
		};
	} __attribute__((packed)) hdr;
	struct ipv6hdr *ipv6_h;
	__u32 id = ID1;
	void *data_end;
	void *data;
	__u8 ttl;
	long ret;

	data_end = (void *)(unsigned long)skb->data_end;
	data = (void *)(unsigned long)skb->data;
	/* check if packet is long enough for ipv6 */
	if (data + sizeof(*ipv6_h) > data_end) {
		bpf_log_printk("pkt too short for IPv6");
		goto out;
	}

	ipv6_h = data;
	ttl = ipv6_h->hop_limit;
	bpf_log_printk("id: %d", id);
	bpf_log_printk("ttl: %d", ttl);

	/* init EIP header and set TTL and ID */
	ret = bpf_ioam6_trace_gob_load_bytes(skb, 4, &hdr, sizeof(hdr));
	if (ret) {
		bpf_printk("Cannot read bytes from GOB");
		goto out;
	}

	hdr.type = bpf_htons(LTV_TYPE);
	hdr.len = LTV_LEN;
	hdr.next = 1;
	hdr.ttlhoplim = bpf_htonl((ttl << 24) | (id & 0x00ffffffu));

	ret = bpf_ioam6_trace_gob_store_bytes(skb, 4, &hdr, sizeof(hdr));
	if (ret) {
                bpf_printk("Cannot write on GOB Payload");
                goto out;
        }
out:
	bpf_log_printk("init out\n");
	return BPF_OK;
#undef GOB_PAYLOAD
}

SEC("ioam6_gob_eip_idhoplim")
int test_ioam6_gob_eip_idhoplim(struct __sk_buff *skb)
{
#define GOB_PAYLOAD 8
	struct {
		union {
			struct {
				__u16 type;
				__u8 len;
				__u8 next;
				__be32 ttlhoplim;
			};
			__u8 data[GOB_PAYLOAD];
		};
	} __attribute__((packed)) hdr;

	struct ipv6hdr *ipv6_h;
	void *data_end;
	__u32 id = ID2;
	__u8 ttl, next;
	__be16 type;
	void *data;
	long ret;

	data_end = (void *)(unsigned long)skb->data_end;
	data = (void *)(unsigned long)skb->data;
	/* check if packet is long enough for ipv6 */
	if (unlikely(data + sizeof(*ipv6_h) > data_end)) {
		bpf_log_printk("pkt too short for IPv6");
		goto out;
	}

	ipv6_h = data;
	ttl = ipv6_h->hop_limit;
	bpf_log_printk("id: %d", id);
	bpf_log_printk("ttl: %d", ttl);

	/* process EIP header and set TTL and ID */
	ret = bpf_ioam6_trace_gob_load_bytes(skb, 4, &hdr, sizeof(hdr));
	if (unlikely(ret)) {
		bpf_printk("Cannot read bytes from GOB");
		goto out;
	}
	/* check LTV type */
	type = bpf_ntohs(hdr.type);
	if (unlikely(type != LTV_TYPE)) {
		bpf_printk("wrong LTV type: %d", type);
                goto out;
	}
	next = hdr.next++;
	if (unlikely(next > 1)) {
		bpf_printk("LTV stack full, cannot add data");
                goto out;
	}

	hdr.ttlhoplim = bpf_htonl((ttl << 24) | (id & 0x00ffffffu));

	ret = bpf_ioam6_trace_gob_store_bytes(skb, 4, &hdr, sizeof(hdr));
	if (unlikely(ret)) {
                bpf_printk("Cannot write on GOB Payload");
                goto out;
        }
out:
	bpf_log_printk("init out\n");
	return BPF_OK;
#undef GOB_PAYLOAD
}

SEC("ioam6_gob_eip_idhoplim_rraw")
int test_ioam6_gob_eip_idhoplim_rraw(struct __sk_buff *skb)
{
#define GOB_PAYLOAD 8
	struct {
		union {
			struct {
				__u16 type;
				__u8 len;
				__u8 next;
				__be32 ttlhoplim;
			};
			__u8 data[GOB_PAYLOAD];
		};
	} __attribute__((packed)) hdr;

	struct ioam6_trace_gob_hdr *gob;
	struct ipv6hdr *ipv6_h;
	void *data_end;
	__u32 id = ID2;
	__u8 ttl, next;
	__be16 type;
	void *data;
	long ret;

	data_end = (void *)(unsigned long)skb->data_end;
	data = (void *)(unsigned long)skb->data;
	/* check if packet is long enough for ipv6 */
	if (unlikely(data + sizeof(*ipv6_h) > data_end)) {
		bpf_log_printk("pkt too short for IPv6");
		goto out;
	}

	ipv6_h = data;
	ttl = ipv6_h->hop_limit;
	bpf_log_printk("id: %d", id);
	bpf_log_printk("ttl: %d", ttl);

	gob = (struct ioam6_trace_gob_hdr *)(data +
					sizeof(struct ipv6hdr) +
                                        sizeof(struct ipv6_opt_hdr) + 2 +
                                        sizeof(struct ioam6_hdr) +
					sizeof(struct ioam6_trace_hdr));
	if (unlikely((void *)gob + sizeof(*gob) + sizeof(hdr) > data_end)) {
		bpf_log_printk("pkt too short for GOB");
		goto out;
	}

	/* cast to __u64 * to align to 8 bytes */
	memcpy(&hdr, (__u64 *)((void *)gob + sizeof(*gob)), sizeof(hdr));

	/* check LTV type */
	type = bpf_ntohs(hdr.type);
	if (unlikely(type != LTV_TYPE)) {
		bpf_printk("wrong LTV type: %d", type);
                goto out;
	}
	next = hdr.next++;
	if (unlikely(next > 1)) {
		bpf_printk("LTV stack full, cannot add data");
                goto out;
	}

	hdr.ttlhoplim = bpf_htonl((ttl << 24) | (id & 0x00ffffffu));

	ret = bpf_ioam6_trace_gob_store_bytes(skb, 4, &hdr, sizeof(hdr));
	if (unlikely(ret)) {
                bpf_printk("Cannot write on GOB Payload");
                goto out;
        }
out:
	bpf_log_printk("init out\n");
	return BPF_OK;
#undef GOB_PAYLOAD
}

SEC("ioam6_gob_nop")
int test_ioam6_gob_nop(struct __sk_buff *skb)
{
	return BPF_OK;
}

SEC("ioam6_cntv2")
int test_ioam6_cntv2(struct __sk_buff *skb)
{
#define GOB_PAYLOAD 4
	struct gob {
		struct ioam6_trace_gob_hdr gob;
		__u8 data[GOB_PAYLOAD];
	} __attribute__((packed)) hdr = { 0, };
	__u8 counter = 0, ltv_len;
	__u16 ltv_type;
	__u32 gob_len;
	int ret;

	ret = bpf_ioam6_trace_gob_load_bytes(skb, 0, &hdr, sizeof(hdr));
	if (ret) {
		bpf_printk("Cannot read bytes from GOB");
		goto out;
	}

	gob_len = (bpf_htonl(hdr.gob.hdr) >> 24) * 4 + sizeof(hdr.gob);
	bpf_log_printk("gob len: %d", gob_len);

	/* init EIP header and set counter to 0 */
	ltv_len = 0x40;
	ltv_type = 666;
	hdr.data[0] = ltv_len;
	*(__be16 *)&hdr.data[1] = bpf_htons(ltv_type);
	hdr.data[3] = counter;

	ltv_len = hdr.data[0];
	bpf_log_printk("ltv len: 0x%02x", ltv_len);

	ltv_type = bpf_htons(*(__be16 *)&hdr.data[1]);
	bpf_log_printk("ltv type: %d", ltv_type);

	counter = hdr.data[3];
        bpf_log_printk("counter: %d", counter);

	bpf_log_printk("hdr.data: 0x%08x", *(__u32 *)hdr.data);

	ret = bpf_ioam6_trace_gob_store_bytes(skb, 4, hdr.data,
                                              sizeof(hdr.data));
        if (ret) {
                bpf_printk("Cannot write on GOB Payload");
                goto out;
        }
/*
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

	bpf_printk("IOAM PTO GOB (Len=%d)",
		   gob_len);
*/

out:
	bpf_log_printk("\n");
	return BPF_OK;
#undef GOB_PAYLOAD
}

SEC("ioam6_cntv2a")
int test_ioam6_cntv2a(struct __sk_buff *skb)
{
#define GOB_PAYLOAD 4
	struct gob {
		struct ioam6_trace_gob_hdr gob;
		__u8 data[GOB_PAYLOAD];
	} __attribute__((packed)) hdr = { 0, };
	__u8 counter = 0, ltv_len;
	__u16 ltv_type;
	__u32 gob_len;
	int ret;

	ret = bpf_ioam6_trace_gob_load_bytes(skb, 0, &hdr, sizeof(hdr));
	if (ret) {
		bpf_printk("Cannot read bytes from GOB");
		goto out;
	}

	gob_len = (bpf_htonl(hdr.gob.hdr) >> 24) * 4 + sizeof(hdr.gob);
	bpf_log_printk("gob len: %d", gob_len);

	/* retrieve data from packet */
	ltv_len = hdr.data[0];
	bpf_log_printk("ltv len: 0x%02x", ltv_len);
	if (ltv_len != 0x40) {
		bpf_log_printk("unknown ltv length");
                goto out;
	}

	ltv_type = bpf_htons(*(__be16 *)&hdr.data[1]);
	bpf_log_printk("ltv type: %d", ltv_type);
	if (ltv_type != 666) {
                bpf_log_printk("unknown ltv type");
                goto out;
        }

	counter = hdr.data[3];
        bpf_log_printk("previous counter: %d", counter);
	/* increment counter and rewrite it into hdr.data */
	counter++;
	bpf_log_printk("new counter: %d", counter);
	hdr.data[3] = counter;

	bpf_log_printk("hdr.data: 0x%08x", *(__u32 *)hdr.data);

	ret = bpf_ioam6_trace_gob_store_bytes(skb, 4, hdr.data,
                                              sizeof(hdr.data));
        if (ret) {
                bpf_printk("Cannot write on GOB Payload");
                goto out;
        }
out:
	bpf_log_printk("\n");
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

SEC("ioam6_cntv4")
int ioam6_gob_counter(struct __sk_buff *skb)
{
	struct {
		struct ioam6_trace_gob_hdr gob;
		__be32 counter;
	} __attribute__((packed)) hdr;
	__u32 counter;

	/* read the whole GOB header and 4 bytes of payload, if possibile */
	if (bpf_ioam6_trace_gob_load_bytes(skb, 0, &hdr, sizeof(hdr))) {
		bpf_printk("cannot read GOB");
		goto out;
	}

	counter = bpf_ntohl(hdr.counter);
	++counter;
	hdr.counter = bpf_htonl(counter);

	/* write only the counter into the GOB payload */
	if (bpf_ioam6_trace_gob_store_bytes(skb, sizeof(hdr.gob),
					   &hdr.counter, sizeof(counter)))
		bpf_printk("cannot update counter in GOB payload");
out:
	return BPF_OK;
}

int bpf_dynptr_from_skb(struct __sk_buff *skb, __u64 flags,
			struct bpf_dynptr *ptr__uninit) __ksym;
void *bpf_dynptr_slice(const struct bpf_dynptr *ptr,
		       uint32_t offset, void *buffer, uint32_t buffer__sz) __ksym;
void *bpf_dynptr_slice_rdwr(const struct bpf_dynptr *ptr,
			    uint32_t offset, void *buffer, uint32_t buffer__sz) __ksym;

SEC("ioam6_dynptr")
int test_ioam6_dynptr(struct __sk_buff *skb)
{
	struct {
		struct ipv6hdr pkt;
		__u8 data[200];
	} __attribute__((packed)) hdr, *phdr;
	struct bpf_dynptr ptr;
	struct ipv6hdr *p;
	u8 hop_limit;
	int ret;

	if (skb->len < sizeof(*p)) {
		bpf_printk("skb->len error");
		goto out;
	}

	ret = bpf_dynptr_from_skb(skb, 0, &ptr);
	if (ret) {
		bpf_printk("bpf_dynptr_from_skb failed ret=%d", ret);
		goto out;
	}

	phdr = bpf_dynptr_slice(&ptr, 0, &hdr, sizeof(hdr));
	if (!phdr) {
		bpf_printk("bpf_dynptr_slice error");
		goto out;
	}

	hop_limit = phdr->pkt.hop_limit;
	bpf_printk("IPv6 hop_limit=%d", hop_limit);

out:
	return BPF_OK;
}

SEC("ioam6_denywrite")
int test_ioam6_denywrite(struct __sk_buff *skb)
{
	void *data, *data_end;
	struct ipv6hdr *ip6h;
	u8 hop_limit;

	data_end = (void *)(unsigned long)skb->data_end;
	data = (void *)(unsigned long)skb->data;
	if (data + sizeof(*ip6h) > data_end) {
		bpf_printk("pkt too short for IPv6");
		goto out;
	}

	ip6h = data;

	hop_limit = ip6h->hop_limit--;
	bpf_printk("IPv6 hop_limit=%d", hop_limit);

out:
	return BPF_OK;
}

char _license[] SEC("license") = "Dual BSD/GPL";
