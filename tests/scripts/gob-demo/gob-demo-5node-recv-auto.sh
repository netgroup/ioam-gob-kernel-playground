#!/usr/bin/env bash
#=============================================================
# GOB demo (received-from-previous-node variant) - auto test.
#
# Topology (7 namespaces, still a line):
#
#   h1 -- n1 -- n2 -- n3 -- n4 -- n5 -- h2
#  client ingress transit transit transit egress client
#         +encap                        +decap
#         GOB1   GOB2   GOB3   GOB4   GOB5
#
#   h1, h2: plain IPv6 clients (no IOAM), fdcc::1 / fdcc::2 on lo.
#   n1: ingress. Encaps client traffic to h2 in transit (mode encap,
#       tundst = SID fcff::5 on n5).
#   n2..n4: transit, IOAM recording on input.
#   n5: IOAM recording on input + End.DT6 (table main) -> forwards the
#       decapsulated packet to h2. n5 forwards (not local delivery), so
#       the stale control-block bug does not trigger.
#
#   Every node n1..n5 runs the ioam6_gob_recv program: it records into
#   the shared gob_recv map, under its own node id, the whole GOB
#   aggregation block {min,max,sum,count} it received from the previous
#   node, then folds its own metric X into the GOB (same GOB write as
#   ioam6_gob_agg). n1 is the degenerate first hop and does not write to
#   gob_recv. Metrics X: n1=10 n2=20 n3=30 n4=40 n5=50.
#
#   Expected gob_recv after one ping (what each node received):
#     node 1 : (empty, degenerate)
#     node 2 : min10 max10 sum10  count1   (from n1)
#     node 3 : min10 max20 sum30  count2   (from n2)
#     node 4 : min10 max30 sum60  count3   (from n3)
#     node 5 : min10 max40 sum100 count4   (from n4)
#
# IMPORTANT: gobschema add MUST run through nsenter --net, never via
# ip netns exec (mount-ns unshare kills the pinned maps).
#=============================================================

set -euo pipefail

readonly BPF_OBJ="/mnt/shared/ioam6_gob_recv.bpf.o"
readonly P_IP="/mnt/iproute2/ip/ip"
readonly BT="/mnt/shared/bpftool"
readonly NS_ID=123
readonly GOBSCHEMA_ID=0xAA
readonly METRIC_PIN="/sys/fs/bpf/tc/globals/gob_metric"
readonly RECV_PIN="/sys/fs/bpf/tc/globals/gob_recv"

if [[ ! -e "${BPF_OBJ}" ]]; then
    echo "ERROR: BPF object not found: ${BPF_OBJ}"
    echo "It must be compiled inside the ioam-kernel-builder container; it then"
    echo "lands in shared/ (mounted at /mnt/shared in the VM):"
    echo "    cd src/c && make ioam6_gob_recv && make install"
    exit 1
fi
for f in "${P_IP}" "${BT}"; do
    if [[ ! -e "$f" ]]; then
        echo "ERROR: required file '$f' not found."
        exit 1
    fi
done

#------------------------------------------------------------
# 1. Clean-up
#------------------------------------------------------------
cleanup() {
    echo "=== cleanup ==="
    for ns in h1 n1 n2 n3 n4 n5 h2; do
        ip netns delete "$ns" 2>/dev/null || true
    done
    rm -f "${METRIC_PIN}" "${RECV_PIN}" 2>/dev/null || true
}
cleanup
trap cleanup EXIT

#------------------------------------------------------------
# 2. Namespaces, veth links, addressing
#------------------------------------------------------------
for ns in h1 n1 n2 n3 n4 n5 h2; do
    ip netns add "$ns"
    ip netns exec "$ns" ip link set lo up
done

ip link add e01a netns h1 type veth peer name e01b netns n1
ip link add v12a netns n1 type veth peer name v12b netns n2
ip link add v23a netns n2 type veth peer name v23b netns n3
ip link add v34a netns n3 type veth peer name v34b netns n4
ip link add v45a netns n4 type veth peer name v45b netns n5
ip link add e56a netns n5 type veth peer name e56b netns h2

ip -n h1 addr add fd01::1/64 dev e01a
ip -n n1 addr add fd01::2/64 dev e01b
ip -n n1 addr add fd12::1/64 dev v12a
ip -n n2 addr add fd12::2/64 dev v12b
ip -n n2 addr add fd23::2/64 dev v23a
ip -n n3 addr add fd23::3/64 dev v23b
ip -n n3 addr add fd34::3/64 dev v34a
ip -n n4 addr add fd34::4/64 dev v34b
ip -n n4 addr add fd45::4/64 dev v45a
ip -n n5 addr add fd45::5/64 dev v45b
ip -n n5 addr add fd56::5/64 dev e56a
ip -n h2 addr add fd56::6/64 dev e56b

ip -n h1 addr add fdcc::1/128 dev lo
ip -n h2 addr add fdcc::2/128 dev lo

ip -n h1 link set e01a up
ip -n n1 link set e01b up
ip -n n1 link set v12a up
ip -n n2 link set v12b up
ip -n n2 link set v23a up
ip -n n3 link set v23b up
ip -n n3 link set v34a up
ip -n n4 link set v34b up
ip -n n4 link set v45a up
ip -n n5 link set v45b up
ip -n n5 link set e56a up
ip -n h2 link set e56b up

#------------------------------------------------------------
# 3. Forwarding on the network nodes
#------------------------------------------------------------
for ns in n1 n2 n3 n4 n5; do
    ip netns exec "$ns" sysctl -wq net.ipv6.conf.all.forwarding=1
done

#------------------------------------------------------------
# 4. Routing
#------------------------------------------------------------
# forward path: client traffic toward h2, tunnel toward SID fcff::5 on n5
ip -n h1 route add fdcc::2/128 via fd01::2 dev e01a
ip -n n1 route add fcff::5/128 via fd12::2 dev v12a
ip -n n2 route add fcff::5/128 via fd23::3 dev v23a
ip -n n3 route add fcff::5/128 via fd34::4 dev v34a
ip -n n4 route add fcff::5/128 via fd45::5 dev v45a
# n5 main-table route to h2 for the decapsulated inner packet
ip -n n5 route add fdcc::2/128 via fd56::6 dev e56a

# return path: plain IPv6 from h2 back to h1
ip -n h2 route add fdcc::1/128 via fd56::5 dev e56b
ip -n n5 route add fdcc::1/128 via fd45::4 dev v45b
ip -n n4 route add fdcc::1/128 via fd34::3 dev v34b
ip -n n3 route add fdcc::1/128 via fd23::2 dev v23b
ip -n n2 route add fdcc::1/128 via fd12::1 dev v12b
ip -n n1 route add fdcc::1/128 via fd01::1 dev e01b

#------------------------------------------------------------
# 5. IOAM ids and per-interface enable (recorders n1..n5)
#------------------------------------------------------------
ip netns exec n1 sysctl -wq net.ipv6.ioam6_id=1
ip netns exec n2 sysctl -wq net.ipv6.ioam6_id=2
ip netns exec n3 sysctl -wq net.ipv6.ioam6_id=3
ip netns exec n4 sysctl -wq net.ipv6.ioam6_id=4
ip netns exec n5 sysctl -wq net.ipv6.ioam6_id=5

# n1 records at encap, the others on their ingress interface
ip netns exec n2 sysctl -wq net.ipv6.conf.v12b.ioam6_enabled=1
ip netns exec n3 sysctl -wq net.ipv6.conf.v23b.ioam6_enabled=1
ip netns exec n4 sysctl -wq net.ipv6.conf.v34b.ioam6_enabled=1
ip netns exec n5 sysctl -wq net.ipv6.conf.v45b.ioam6_enabled=1

#------------------------------------------------------------
# 6. IOAM namespace + per-node GOB program (nsenter --net!)
#------------------------------------------------------------
for i in 1 2 3 4 5; do
    ip netns exec n$i ip ioam namespace add ${NS_ID}
    nsenter --net=/var/run/netns/n$i "${P_IP}" ioam gobschema add ${GOBSCHEMA_ID} \
        object "${BPF_OBJ}" section ioam6_gob_recv_n$i
    nsenter --net=/var/run/netns/n$i "${P_IP}" ioam namespace set ${NS_ID} \
        gobschema ${GOBSCHEMA_ID}
done

#------------------------------------------------------------
# 7. Per-node metrics X: n1=10 n2=20 n3=30 n4=40 n5=50
#------------------------------------------------------------
"${BT}" map update pinned "${METRIC_PIN}" key 0 0 0 0 value 10 0 0 0
"${BT}" map update pinned "${METRIC_PIN}" key 1 0 0 0 value 20 0 0 0
"${BT}" map update pinned "${METRIC_PIN}" key 2 0 0 0 value 30 0 0 0
"${BT}" map update pinned "${METRIC_PIN}" key 3 0 0 0 value 40 0 0 0
"${BT}" map update pinned "${METRIC_PIN}" key 4 0 0 0 value 50 0 0 0

#------------------------------------------------------------
# 8. Encap route on n1 (in-transit encap of client traffic to h2)
#    size 20 = 5 node data words (h=5), gobsize 16 = 4 payload words
#------------------------------------------------------------
ip netns exec n1 "${P_IP}" -6 route add fdcc::2/128 \
    encap ioam6 mode encap tundst fcff::5 \
    trace prealloc type 0x800000 ns ${NS_ID} size 20 gobsize 16 \
    dev v12a

#------------------------------------------------------------
# 9. Decap on n5: End.DT6 with table main (forwards to h2)
#------------------------------------------------------------
ip netns exec n5 ip -6 route add fcff::5/128 \
    encap seg6local action End.DT6 table main dev v45b

# Debug: leave the topology up and skip the run.
if [ "${1:-}" = "setup-only" ]; then
    trap - EXIT
    echo "setup done, topology left up"
    exit 0
fi

#------------------------------------------------------------
# 10. Run: ping h1 -> h2, then read the gob_recv map
#------------------------------------------------------------
set +e
ip netns exec h1 ping -6 -c 3 -i 0.3 -W 2 -I fdcc::1 fdcc::2
PING=$?
sleep 1

echo "===== gob_recv map (what each node received from the previous one) ====="
"${BT}" -j map dump pinned "${RECV_PIN}" > /tmp/recv.json 2>/dev/null
"${BT}" map dump pinned "${RECV_PIN}"

#------------------------------------------------------------
# 11. Verdict
#------------------------------------------------------------
FAIL=0
[ "$PING" -ne 0 ] && { echo "PING h1->h2 FAILED"; FAIL=1; }

RECV_OUT=$(python3 - <<'PYEOF'
import json, sys
try:
    d = json.load(open('/tmp/recv.json'))
except Exception as e:
    print("RECV parse error:", e); print("RECV_MAP=FAIL"); sys.exit(0)

# expected block received by each node id: (min,max,sum,count)
exp = {2:(10,10,10,1), 3:(10,20,30,2), 4:(10,30,60,3), 5:(10,40,100,4)}
got = {}
for e in d:
    # bpftool -j gives raw byte lists in key/value and decoded ints under
    # "formatted"; use the latter when present.
    f = e.get('formatted', e)
    k = int(f['key'])
    v = f['value']
    got[k] = (int(v['min']), int(v['max']), int(v['sum']), int(v['count']))

ok = True
if got.get(1) not in (None, (0, 0, 0, 0)):
    print("FAIL node 1: expected empty, got", got.get(1)); ok = False
else:
    print("OK   node 1: empty (degenerate)")
for k in (2, 3, 4, 5):
    if got.get(k) != exp[k]:
        print(f"FAIL node {k}: got {got.get(k)} expected {exp[k]}"); ok = False
    else:
        print(f"OK   node {k}: {got[k]}")
print("RECV_MAP=PASS" if ok else "RECV_MAP=FAIL")
PYEOF
)
echo "$RECV_OUT"
grep -q 'RECV_MAP=PASS' <<<"$RECV_OUT" || FAIL=1

echo "===== VERDICT ====="
if [ "$FAIL" -eq 0 ]; then
    echo "GOB_DEMO_5NODE_RECV=PASS"
else
    echo "GOB_DEMO_5NODE_RECV=FAIL"
fi
