#!/usr/bin/env bash
#=============================================================
# GOB demo (received-from-previous-node) - INTERACTIVE tmux.
#
# Same topology, eBPF programs and logic as gob-demo-5node-recv-auto.sh
# (which is kept untouched):
#
#   h1 -- n1 -- n2 -- n3 -- n4 -- n5 -- h2
#         encap                  decap
#         GOB1  GOB2  GOB3  GOB4  GOB5   (ioam6_gob_recv_nN)
#
# Every node records into the shared gob_recv map, under its own id, the
# whole GOB block {min,max,sum,count} it received from the previous node.
#
# This script sets the topology up WITHOUT the n1 encap route (that is
# toggled live with gob-encap), installs a plain fallback route so the
# network still works with the encap off (no IOAM, no GOB), generates the
# control helpers and opens a tmux dashboard.
#
# Modes:
#   (no arg)     set up + generate helpers + open the tmux dashboard
#   test         set up + generate helpers + run a non-interactive check
#   setup-only   set up + generate helpers, leave everything up, no tmux
#
# Control helpers (generated under /mnt/scripts/gob-demo-bin, thin wrappers
# over the same bpftool/ip commands the -auto test uses):
#   gob-metric set nN V | get nN     change/read a node metric X
#   gob-encap  on | off              install/remove the n1 IOAM+GOB encap
#   gob-ping   [count]               h1 pings h2
#   gob-recv-show                    formatted view of the gob_recv map
#
# IMPORTANT: gobschema add MUST run through nsenter --net.
#=============================================================

set -euo pipefail

readonly BPF_OBJ="/mnt/shared/ioam6_gob_recv.bpf.o"
readonly P_IP="/mnt/iproute2/ip/ip"
readonly BT="/mnt/shared/bpftool"
readonly NS_ID=123
readonly GOBSCHEMA_ID=0xAA
readonly METRIC_PIN="/sys/fs/bpf/tc/globals/gob_metric"
readonly RECV_PIN="/sys/fs/bpf/tc/globals/gob_recv"
readonly BINDIR="/mnt/scripts/gob-demo/bin"
readonly SESSION="gobdemo"
readonly MODE="${1:-tmux}"

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
    tmux kill-session -t "${SESSION}" 2>/dev/null || true
    for ns in h1 n1 n2 n3 n4 n5 h2; do
        ip netns delete "$ns" 2>/dev/null || true
    done
    rm -f "${METRIC_PIN}" "${RECV_PIN}" 2>/dev/null || true
}
cleanup

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
# 3. Forwarding
#------------------------------------------------------------
for ns in n1 n2 n3 n4 n5; do
    ip netns exec "$ns" sysctl -wq net.ipv6.conf.all.forwarding=1
done

#------------------------------------------------------------
# 4. Routing
#------------------------------------------------------------
# tunnel path toward the SID fcff::5 on n5 (used when encap is on)
ip -n n1 route add fcff::5/128 via fd12::2 dev v12a
ip -n n2 route add fcff::5/128 via fd23::3 dev v23a
ip -n n3 route add fcff::5/128 via fd34::4 dev v34a
ip -n n4 route add fcff::5/128 via fd45::5 dev v45a

# plain fallback path toward h2 (fdcc::2), used when the encap is off.
# On n1 it is metric 200; gob-encap on installs the encap route at metric
# 100 which then wins.
ip -n h1 route add fdcc::2/128 via fd01::2 dev e01a
ip -n n1 route add fdcc::2/128 via fd12::2 dev v12a metric 200
ip -n n2 route add fdcc::2/128 via fd23::3 dev v23a
ip -n n3 route add fdcc::2/128 via fd34::4 dev v34a
ip -n n4 route add fdcc::2/128 via fd45::5 dev v45a
ip -n n5 route add fdcc::2/128 via fd56::6 dev e56a

# return path h2 -> h1 (always plain)
ip -n h2 route add fdcc::1/128 via fd56::5 dev e56b
ip -n n5 route add fdcc::1/128 via fd45::4 dev v45b
ip -n n4 route add fdcc::1/128 via fd34::3 dev v34b
ip -n n3 route add fdcc::1/128 via fd23::2 dev v23b
ip -n n2 route add fdcc::1/128 via fd12::1 dev v12b
ip -n n1 route add fdcc::1/128 via fd01::1 dev e01b

# decap on n5: End.DT6 (table main) forwards the inner packet to h2.
# Always installed; only the n1 encap is toggled by gob-encap.
ip netns exec n5 ip -6 route add fcff::5/128 \
    encap seg6local action End.DT6 table main dev v45b

#------------------------------------------------------------
# 5. IOAM ids + enable + namespace + per-node GOB program
#------------------------------------------------------------
ip netns exec n1 sysctl -wq net.ipv6.ioam6_id=1
ip netns exec n2 sysctl -wq net.ipv6.ioam6_id=2
ip netns exec n3 sysctl -wq net.ipv6.ioam6_id=3
ip netns exec n4 sysctl -wq net.ipv6.ioam6_id=4
ip netns exec n5 sysctl -wq net.ipv6.ioam6_id=5

ip netns exec n2 sysctl -wq net.ipv6.conf.v12b.ioam6_enabled=1
ip netns exec n3 sysctl -wq net.ipv6.conf.v23b.ioam6_enabled=1
ip netns exec n4 sysctl -wq net.ipv6.conf.v34b.ioam6_enabled=1
ip netns exec n5 sysctl -wq net.ipv6.conf.v45b.ioam6_enabled=1

for i in 1 2 3 4 5; do
    ip netns exec n$i ip ioam namespace add ${NS_ID}
    nsenter --net=/var/run/netns/n$i "${P_IP}" ioam gobschema add ${GOBSCHEMA_ID} \
        object "${BPF_OBJ}" section ioam6_gob_recv_n$i
    nsenter --net=/var/run/netns/n$i "${P_IP}" ioam namespace set ${NS_ID} \
        gobschema ${GOBSCHEMA_ID}
done

#------------------------------------------------------------
# 6. Initial metrics X: n1=10 n2=20 n3=30 n4=40 n5=50
#------------------------------------------------------------
"${BT}" map update pinned "${METRIC_PIN}" key 0 0 0 0 value 10 0 0 0
"${BT}" map update pinned "${METRIC_PIN}" key 1 0 0 0 value 20 0 0 0
"${BT}" map update pinned "${METRIC_PIN}" key 2 0 0 0 value 30 0 0 0
"${BT}" map update pinned "${METRIC_PIN}" key 3 0 0 0 value 40 0 0 0
"${BT}" map update pinned "${METRIC_PIN}" key 4 0 0 0 value 50 0 0 0

#------------------------------------------------------------
# 7. Make the standalone control helpers reachable by short name.
#    They live in ${BINDIR} (versioned next to this launcher), no
#    generation needed.
#------------------------------------------------------------
export PATH="${BINDIR}:${PATH}"

#------------------------------------------------------------
# 8. Mode dispatch
#------------------------------------------------------------
if [ "${MODE}" = "setup-only" ]; then
    echo "setup done, helpers in ${BINDIR}, topology left up"
    exit 0
fi

if [ "${MODE}" = "test" ]; then
    set +e
    echo "=== encap ON, one ping, check gob_recv ==="
    gob-encap on
    gob-ping 3 >/dev/null 2>&1; P1=$?
    gob-recv-show
    echo "=== encap OFF, one ping, network must still work, gob_recv unchanged ==="
    gob-encap off
    gob-ping 3 >/dev/null 2>&1; P2=$?
    echo "ping encap-on rc=$P1  ping encap-off rc=$P2"
    if [ "$P1" -eq 0 ] && [ "$P2" -eq 0 ]; then
        echo "GOB_DEMO_TMUX_CORE=PASS"
    else
        echo "GOB_DEMO_TMUX_CORE=FAIL"
    fi
    exit 0
fi

#------------------------------------------------------------
# 9. tmux dashboard: top row = 5 node metrics, bottom = received | control
#------------------------------------------------------------
# Build with stable pane ids (%N) to avoid pane-index guessing.
top=$(tmux new-session -d -s "${SESSION}" -x 210 -y 50 -P -F '#{pane_id}')
tmux set -g mouse on
# bottom band (fixed 15 lines): received (left) + control (right, wider)
bot=$(tmux split-window -v -l 15 -P -F '#{pane_id}' -t "${top}")
ctl=$(tmux split-window -h -p 45 -P -F '#{pane_id}' -t "${bot}")
# top band split into five equal columns n1..n5
n2=$(tmux split-window -h -p 80 -P -F '#{pane_id}' -t "${top}")
n3=$(tmux split-window -h -p 75 -P -F '#{pane_id}' -t "${n2}")
n4=$(tmux split-window -h -p 66 -P -F '#{pane_id}' -t "${n3}")
n5=$(tmux split-window -h -p 50 -P -F '#{pane_id}' -t "${n4}")

# top panes -> per-node metric watchers (each pane gets BINDIR on PATH first)
i=1
for p in "${top}" "${n2}" "${n3}" "${n4}" "${n5}"; do
    tmux send-keys -t "${p}" "export PATH=${BINDIR}:\$PATH" C-m
    tmux send-keys -t "${p}" \
        "watch -t -n1 \"echo n${i}  metric X:; gob-metric get n${i}\"" C-m
    i=$((i + 1))
done
# bottom-left -> received view
tmux send-keys -t "${bot}" "export PATH=${BINDIR}:\$PATH" C-m
tmux send-keys -t "${bot}" "watch -t -n1 gob-recv-show" C-m
# bottom-right -> control shell + cheat-sheet
tmux send-keys -t "${ctl}" "export PATH=${BINDIR}:\$PATH" C-m
tmux send-keys -t "${ctl}" \
    "clear; echo 'CONTROL panel'; \
     echo 'type  gob-help  for the list of commands'; \
     echo; echo 'quick start:  gob-encap on ; gob-ping'" C-m

echo "tmux session '${SESSION}' ready. Attach with: tmux attach -t ${SESSION}"
echo "(detach with Ctrl-b d; run '$0 clean' or kill the session to tear down)"
