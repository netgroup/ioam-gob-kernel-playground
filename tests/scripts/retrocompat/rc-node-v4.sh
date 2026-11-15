#!/usr/bin/env bash
#=============================================================
# rc-node-v4.sh - GOB test bench for the v4 kernel, one node per guest.
#
# Derived from rc-node.sh (backward-compatibility test of the default
# mode on the v3 kernel). It adds the namespace-implied mode of the GOB
# (draft-mayer-bpm-ioam-gob-00): no GOB trailer, G bit unset, size and
# schema bound to the IOAM namespace.
#
# Runs INSIDE a guest (QEMU VM), as root. Path in the guest:
#   /mnt/scripts/retrocompat/rc-node-v4.sh
#
# Topology: four guests on one isolated L2 segment (bridge br-rc in the
# builder container), IPv4 192.168.77.0/25 for management only.
#
#   h1 --veth-- rcA ----- rcS ----- rcB --veth-- h2      path "via S"
#               GOB      stock      GOB
#   h1 --veth-- rcA ----- rcG ----- rcB --veth-- h2      path "via G" (control)
#               GOB       GOB       GOB
#
#   rcA  192.168.77.11  fd77::11  ioam id 1  v4 kernel, metric 10, encap
#   rcS  192.168.77.12  fd77::12  ioam id 2  stock kernel (no GOB patches)
#   rcB  192.168.77.13  fd77::13  ioam id 3  v4 kernel, metric 30, decap
#   rcG  192.168.77.14  fd77::14  ioam id 2  v4 kernel, metric 20 (control)
#
#   h1 (netns in rcA) fdcc::1, h2 (netns in rcB) fdcc::2.
#   rcA encapsulates h1 -> h2 traffic in transit (ioam6 mode encap,
#   tundst = SID fcff::3 on rcB, node data + GOB); rcB does End.DT6 and
#   forwards to h2.
#
# GOB mode (second argument of "setup", default: implied), shown for the
# agg16 profile:
#   implied  ip ioam namespace set 123 gobschema 0xAA gobimplied 16
#            route: ... size 20 gobimplied 16   (no trailer, G bit unset)
#   default  ip ioam namespace set 123 gobschema 0xAA
#            route: ... size 20 gobsize 16      (trailer, G bit set)
# The stock node (rcS) takes no mode: it is set up with rc-node.sh, or
# with "setup S" here, which is the same thing.
#
# GOB profile (which eBPF program and which GOB layout; default: agg16):
#   agg16  ioam6_gob_recv.bpf.o, schema 0xAA, 16 octets {min,max,sum,count}
#   acc4   ioam6_gob_acc4.bpf.o, schema 0xBB, 4 octets (running sum of the
#          metric); this program also uses ctx->len, ctx->schema and the
#          gob_load_bytes/gob_store_bytes kfuncs
# The profile in use is remembered in /run/rc-node-v4.profile.
#
# Expected on rcB with agg16 (gob_recv map, key 3 = block received by node
# 3), in both modes:
#   via S: min 10 max 10 sum 10 count 1   (the stock node did not touch the GOB)
#   via G: min 10 max 20 sum 30 count 2   (control: a GOB-aware node folds 20)
# Expected on rcB with acc4 (gob_acc4 map, key 3), in both modes:
#   via S: recv 10 sent 40                (the stock node did not touch the GOB)
#   via G: recv 30 sent 60                (control: a GOB-aware node adds 20)
#   and: len 4, schema 187, oob -14 (-EFAULT), readback = sent, wider 0, err 0
# Expected node data at rcB (ip ioam monitor): node ids 1, 2, 3 on both paths.
# Expected on the wire with 20 octets of node data:
#   agg16 implied  IOAM option length 46, last octet of the trace header 0x00
#   agg16 default  IOAM option length 50, last octet of the trace header 0x01,
#                  last word of the option = GOB trailer (0x04 0x0000aa)
#   acc4  implied  IOAM option length 34, last octet of the trace header 0x00
#   acc4  default  IOAM option length 38, last octet of the trace header 0x01,
#                  last word of the option = GOB trailer (0x01 0x0000bb)
#
# Usage:
#   rc-node-v4.sh build-ip                 build ip in /mnt/iproute2 (needs it read-write)
#   rc-node-v4.sh setup A|G|B [implied|default]   configure this guest for its role
#   rc-node-v4.sh setup S                  configure the stock middle node
#   rc-node-v4.sh mode implied|default     (on rcA, rcG, rcB) switch the GOB mode of a
#                                          node that is already set up, without a reboot
#   rc-node-v4.sh profile agg16|acc4 [implied|default]
#                                          (on rcA, rcG, rcB) switch the GOB profile of a
#                                          node that is already set up, without a reboot
#   rc-node-v4.sh via S|G                  (on rcA and rcB) choose the middle node
#   rc-node-v4.sh monitor [secs]           (on rcB) start ip ioam monitor + tcpdump
#   rc-node-v4.sh ping                     (on rcA) ping h1 -> h2
#   rc-node-v4.sh show                     (on rcB) print the map of the profile, node
#                                          data, capture
#   rc-node-v4.sh info                     print kernel, addresses, routes, ioam state
#=============================================================

set -euo pipefail

readonly P_IP="/mnt/iproute2/ip/ip"
readonly BT="/mnt/shared/bpftool"
readonly NS_ID=123
readonly TRACE_SIZE=20
readonly METRIC_PIN="/sys/fs/bpf/tc/globals/gob_metric"
readonly PROFILE_FILE="/run/rc-node-v4.profile"
readonly SID="fcff::3"
readonly A6="fd77::11" S6="fd77::12" B6="fd77::13" G6="fd77::14"

die() { echo "ERROR: $*" >&2; exit 1; }

# The NIC on the test segment is the one holding the 192.168.77.x address.
find_dev() {
    ip -o -4 addr show scope global | awk '$4 ~ /^192\.168\.77\./ {print $2; exit}'
}

my_role() {
    local a
    a="$(ip -o -6 addr show dev "${DEV}" scope global | awk '{print $4}')"
    case "${a}" in
    *fd77::11/*) echo A ;;
    *fd77::12/*) echo S ;;
    *fd77::13/*) echo B ;;
    *fd77::14/*) echo G ;;
    *) echo none ;;
    esac
}

middle_addr() {
    case "$1" in
    S) echo "${S6}" ;;
    G) echo "${G6}" ;;
    *) die "middle node must be S or G" ;;
    esac
}

# Select the GOB profile: $1 = agg16|acc4, empty = the one in use (agg16 if
# none was recorded). Sets PROFILE, BPF_OBJ, SEC_PREFIX, GOBSCHEMA_ID,
# GOB_SIZE, RECV_PIN.
load_profile() {
    PROFILE="${1:-}"
    if [ -z "${PROFILE}" ]; then
        PROFILE="$(cat "${PROFILE_FILE}" 2>/dev/null || echo agg16)"
    fi
    case "${PROFILE}" in
    agg16)
        BPF_OBJ="/mnt/shared/ioam6_gob_recv.bpf.o"
        SEC_PREFIX="ioam6_gob_recv_n"
        GOBSCHEMA_ID=0xAA
        GOB_SIZE=16
        RECV_PIN="/sys/fs/bpf/tc/globals/gob_recv"
        ;;
    acc4)
        BPF_OBJ="/mnt/shared/ioam6_gob_acc4.bpf.o"
        SEC_PREFIX="ioam6_gob_acc4_n"
        GOBSCHEMA_ID=0xBB
        GOB_SIZE=4
        RECV_PIN="/sys/fs/bpf/tc/globals/gob_acc4"
        ;;
    *) die "GOB profile must be agg16 or acc4" ;;
    esac
}

# true if the GOB schema of the profile is already loaded in the kernel
schema_loaded() {
    local out
    out="$("${P_IP}" ioam gobschema show)"
    grep -Eq "^gobschema $((GOBSCHEMA_ID))( |\$)" <<< "${out}"
}

check_mode() {
    case "$1" in
    implied|default) ;;
    *) die "GOB mode must be implied or default" ;;
    esac
}

# $1 = IPv6 address on the segment, $2 = IOAM node id
common() {
    [ -x "${P_IP}" ] || die "missing ${P_IP} (run: rc-node-v4.sh build-ip on a guest with /mnt/iproute2 read-write)"
    sysctl -wq net.ipv6.conf.all.forwarding=1
    sysctl -wq net.ipv6.conf.all.accept_redirects=0
    sysctl -wq "net.ipv6.conf.${DEV}.accept_redirects=0"
    ip -6 addr replace "$1/64" dev "${DEV}" nodad
    sysctl -wq "net.ipv6.ioam6_id=$2"
    "${P_IP}" ioam namespace add "${NS_ID}"
}

# $1 = node index 1..5 (selects the BPF section and the metric slot),
# $2 = metric, $3 = GOB mode
gob_load() {
    [ -e "${BPF_OBJ}" ] || die "missing ${BPF_OBJ}"
    [ -x "${BT}" ] || die "missing ${BT}"
    if ! schema_loaded; then
        "${P_IP}" ioam gobschema add "${GOBSCHEMA_ID}" \
            object "${BPF_OBJ}" section "${SEC_PREFIX}$1"
    fi
    ns_set_mode "$3"
    "${BT}" map update pinned "${METRIC_PIN}" key "$(($1 - 1))" 0 0 0 value "$2" 0 0 0
}

# Bind the GOB schema to the namespace in the given mode. $1 = GOB mode
ns_set_mode() {
    if [ "$1" = implied ]; then
        # schema and implied size are bound to the namespace together
        "${P_IP}" ioam namespace set "${NS_ID}" gobschema "${GOBSCHEMA_ID}" \
            gobimplied "${GOB_SIZE}"
    else
        # without gobimplied the namespace follows the default mode
        "${P_IP}" ioam namespace set "${NS_ID}" gobschema "${GOBSCHEMA_ID}"
    fi
}

# In-transit encap of h1 -> h2 on rcA: 5 node data words + the GOB.
# implied: no trailer, G bit unset; default: trailer, G bit set. $1 = GOB mode
encap_route() {
    local gob_arg
    if [ "$1" = implied ]; then
        gob_arg="gobimplied"
    else
        gob_arg="gobsize"
    fi
    "${P_IP}" -6 route replace fdcc::2/128 \
        encap ioam6 mode encap tundst "${SID}" \
        trace prealloc type 0x800000 ns "${NS_ID}" size "${TRACE_SIZE}" \
        "${gob_arg}" "${GOB_SIZE}" \
        dev "${DEV}"
}

# Switch the GOB mode of a node that is already set up. The namespace goes
# first: a route with gobimplied is refused unless the namespace already
# implies a GOB of the same size. The encap route is re-created because the
# option layout is fixed when the route is created. $1 = GOB mode
switch_mode() {
    local role
    role="$(my_role)"
    case "${role}" in
    A|G|B) ;;
    *) die "mode is for rcA, rcG and rcB only" ;;
    esac
    ns_set_mode "$1"
    if [ "${role}" = A ]; then
        encap_route "$1"
    fi
}

# Switch the GOB profile of a node that is already set up: load the schema
# of the new profile if needed, bind it to the namespace, re-create the
# encap route. $1 = profile, $2 = GOB mode
switch_profile() {
    local role
    role="$(my_role)"
    load_profile "$1"
    case "${role}" in
    A) gob_load 1 10 "$2"; encap_route "$2" ;;
    G) gob_load 2 20 "$2" ;;
    B) gob_load 3 30 "$2" ;;
    *) die "profile is for rcA, rcG and rcB only" ;;
    esac
    echo "${PROFILE}" > "${PROFILE_FILE}"
}

# $1 = GOB mode
setup_A() {
    common "${A6}" 1
    ip netns add h1
    ip -n h1 link set lo up
    ip link add e01b type veth peer name e01a netns h1
    ip -n h1 addr add fd01::1/64 dev e01a nodad
    ip addr add fd01::2/64 dev e01b nodad
    ip -n h1 addr add fdcc::1/128 dev lo
    ip -n h1 link set e01a up
    ip link set e01b up
    ip -n h1 route add fdcc::2/128 via fd01::2 dev e01a
    ip -6 route replace fdcc::1/128 via fd01::1 dev e01b
    gob_load 1 10 "$1"
    ip -6 route replace "${SID}/128" via "${S6}" dev "${DEV}"
    encap_route "$1"
}

# transit node: $1 = address, $2 = gob (yes|no), $3 = GOB mode
setup_middle() {
    common "$1" 2
    sysctl -wq "net.ipv6.conf.${DEV}.ioam6_enabled=1"
    ip -6 route replace "${SID}/128" via "${B6}" dev "${DEV}"
    ip -6 route replace fdcc::1/128 via "${A6}" dev "${DEV}"
    if [ "$2" = yes ]; then
        gob_load 2 20 "$3"
    fi
}

# $1 = GOB mode
setup_B() {
    common "${B6}" 3
    sysctl -wq "net.ipv6.conf.${DEV}.ioam6_enabled=1"
    ip netns add h2
    ip -n h2 link set lo up
    ip link add e56a type veth peer name e56b netns h2
    ip addr add fd56::5/64 dev e56a nodad
    ip -n h2 addr add fd56::6/64 dev e56b nodad
    ip -n h2 addr add fdcc::2/128 dev lo
    ip link set e56a up
    ip -n h2 link set e56b up
    ip -n h2 route add fdcc::1/128 via fd56::5 dev e56b
    ip -6 route replace fdcc::2/128 via fd56::6 dev e56a
    gob_load 3 30 "$1"
    # decap: End.DT6 with table main, then forward to h2
    "${P_IP}" -6 route replace "${SID}/128" \
        encap seg6local action End.DT6 table main dev "${DEV}"
    ip -6 route replace fdcc::1/128 via "${S6}" dev "${DEV}"
}

cmd="${1:-}"

# build-ip does not need the test segment to be up
if [ "${cmd}" = build-ip ]; then
    [ -d /mnt/iproute2 ] || die "missing /mnt/iproute2"
    touch /mnt/iproute2/.rw-test 2>/dev/null || die "/mnt/iproute2 is read-only: start this guest without --ro-iproute2"
    rm -f /mnt/iproute2/.rw-test
    cd /mnt/iproute2
    echo "building ip in /mnt/iproute2 on $(uname -n), log in /tmp/ip-build.log"
    { ./configure && make -j"$(nproc)"; } > /tmp/ip-build.log 2>&1 \
        || { tail -n 25 /tmp/ip-build.log; die "build failed"; }
    tail -n 3 /tmp/ip-build.log
    ls -la "${P_IP}"
    "${P_IP}" -V
    # "ip ioam help" prints the usage and exits non-zero: with pipefail a
    # plain "ip ... | grep" would fail even when grep finds the keyword.
    help_out="$("${P_IP}" ioam help 2>&1 || true)"
    grep gobimplied <<< "${help_out}" \
        || die "this ip does not know gobimplied"
    exit 0
fi

DEV="$(find_dev)"
[ -n "${DEV}" ] || die "no interface with a 192.168.77.x address: not a test guest"

case "${cmd}" in
setup)
    mode="${3:-implied}"
    check_mode "${mode}"
    load_profile "${4:-agg16}"
    case "${2:-}" in
    A) setup_A "${mode}" ;;
    S) setup_middle "${S6}" no "${mode}"; mode="none (stock node)" ;;
    G) setup_middle "${G6}" yes "${mode}" ;;
    B) setup_B "${mode}" ;;
    *) die "usage: rc-node-v4.sh setup A|S|G|B [implied|default] [agg16|acc4]" ;;
    esac
    echo "${PROFILE}" > "${PROFILE_FILE}"
    echo "setup ${2} done on $(uname -n), kernel $(uname -r), dev ${DEV}, GOB mode ${mode}, profile ${PROFILE}"
    ;;
mode)
    check_mode "${2:-}"
    load_profile ""
    switch_mode "$2"
    echo "GOB mode now $2 on $(uname -n) (role $(my_role), profile ${PROFILE})"
    ;;
profile)
    mode="${3:-implied}"
    check_mode "${mode}"
    switch_profile "${2:-}" "${mode}"
    echo "GOB profile now ${PROFILE}, mode ${mode}, on $(uname -n) (role $(my_role))"
    ;;
via)
    mid="$(middle_addr "${2:-}")"
    case "$(my_role)" in
    A) ip -6 route replace "${SID}/128" via "${mid}" dev "${DEV}" ;;
    B) ip -6 route replace fdcc::1/128 via "${mid}" dev "${DEV}" ;;
    *) die "via is for rcA and rcB only" ;;
    esac
    echo "middle node now ${2} (${mid}) on $(uname -n)"
    ;;
monitor)
    secs="${2:-20}"
    pkill -f 'ioam monitor' 2>/dev/null || true
    rm -f /tmp/rc-mon.txt /tmp/rc-cap.pcap /tmp/rc-cap.log
    nohup stdbuf -oL -eL timeout "${secs}" "${P_IP}" ioam monitor \
        > /tmp/rc-mon.txt 2>&1 < /dev/null &
    # only frames addressed to this node: when the bridge has no entry for
    # the middle node it floods the rcA -> middle frames to rcB as well
    nohup timeout "${secs}" tcpdump -i "${DEV}" -n -U -c 6 -w /tmp/rc-cap.pcap \
        ip6 and dst host "${SID}" and ether dst "$(cat "/sys/class/net/${DEV}/address")" \
        > /tmp/rc-cap.log 2>&1 < /dev/null &
    sleep 1
    echo "monitor and capture started for ${secs} s on $(uname -n)"
    ;;
ping)
    ip netns exec h1 ping -6 -c 3 -i 0.3 -W 2 -I fdcc::1 fdcc::2
    ;;
show)
    load_profile ""
    echo "===== node: $(uname -n), kernel $(uname -r), profile ${PROFILE} ====="
    echo "===== ioam namespace ====="
    "${P_IP}" ioam namespace show
    echo "===== ${RECV_PIN##*/} map (key 3 = what rcB saw) ====="
    "${BT}" map dump pinned "${RECV_PIN}"
    echo "===== ip ioam monitor (node data seen at rcB) ====="
    cat /tmp/rc-mon.txt 2>/dev/null || echo "(no monitor output)"
    echo "===== first captured packet towards ${SID} (frames addressed to this node) ====="
    tcpdump -n -r /tmp/rc-cap.pcap -c 1 -vv -x 2>/dev/null | head -n 30 \
        || echo "(no capture)"
    ;;
info)
    echo "===== $(uname -n): kernel $(uname -r), dev ${DEV}, role $(my_role) ====="
    ip -br addr
    echo "--- ipv6 routes"
    ip -6 route show
    echo "--- ioam"
    sysctl net.ipv6.ioam6_id "net.ipv6.conf.${DEV}.ioam6_enabled"
    "${P_IP}" ioam namespace show
    "${P_IP}" ioam gobschema show
    echo "--- GOB profile: $(cat "${PROFILE_FILE}" 2>/dev/null || echo "agg16 (none recorded)")"
    echo "--- encap route, as seen by the GOB-aware ip"
    "${P_IP}" -6 route show fdcc::2/128 || true
    ;;
*)
    sed -n '2,79p' "$0"
    exit 1
    ;;
esac
