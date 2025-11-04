#!/usr/bin/env bash
#======================================================================
# Linear IPv6 topology with IOAM-6 and IOAM-namespace configuration.
#
# Nodes (network namespaces): alfa, athos, porthos, aramis, beta
#
# Extra routes:
#   athos   -> fc00::d6/128 via dc01::2 (dev athos-porthos)
#   porthos -> fc00::d6/128 via dc02::2 (dev porthos-aramis)
#
# IOAM-6 IDs (sysctl -wq) + enable on each interface that got an ID
#   athos   : node-wide = 1   iface IDs 101 / 102
#   porthos : node-wide = 2   iface IDs 201 / 202
#   aramis  : node-wide = 3   iface IDs 301 / 302
#
# IOAM-namespace (per-namespace):
#   athos   -> data 0xdeadbee0
#   porthos -> data 0xdeadbee1
#   aramis  -> data 0xdeadbee2
#
# Encapsulation route on athos (IOAM-6):
#   ip -6 route add db22::22/64 encap ioam6 mode encap tundst fc00::d6 \
#       trace prealloc type 0x800000 ns 123 size 12 dev athos-porthos
#
# Default IPv6 routes for edge hosts:
#   alfa -> default via db11::1 (neighbor athos)
#   beta -> default via db22::1 (neighbor aramis)
#
# Requirements: ip (iproute2) and tmux
# Run as root (or with sudo)
#=================================================================

#-------------------------------------------------------------------
# 0. Global settings - abort on error, echo every command
#-------------------------------------------------------------------
set -euo pipefail
set -x

readonly SESSION="ioam6"

#-------------------------------------------------------------------
# 1. Clean-up - delete namespaces, veth interfaces and tmux session
#-------------------------------------------------------------------
cleanup() {
    echo "=== Cleaning up network namespaces, veth devices and tmux session ==="
    tmux kill-session -t "${SESSION}" 2>/dev/null || true

    for ns in alfa athos porthos aramis beta; do
        ip netns delete "$ns" 2>/dev/null || true
    done

    for dev in \
        alfa-athos athos-alfa \
        athos-porthos porthos-athos \
        porthos-aramis aramis-porthos \
        aramis-beta beta-aramis; do
        ip link del "$dev" 2>/dev/null || true
    done
}

# Do a cleanup before running the script, ALWAYS
cleanup
trap cleanup EXIT

#-------------------------------------------------------------------
# 2. Create namespaces and bring up loopback
#-------------------------------------------------------------------
for ns in alfa athos porthos aramis beta; do
    ip netns add "$ns"
    ip netns exec "$ns" ip link set lo up
done

#-------------------------------------------------------------------
# 3. Create veth pairs (named for readability)
#-------------------------------------------------------------------
# alfa <-> athos
ip link add alfa-athos type veth peer name athos-alfa
ip link set alfa-athos netns alfa
ip link set athos-alfa netns athos

# athos <-> porthos
ip link add athos-porthos type veth peer name porthos-athos
ip link set athos-porthos netns athos
ip link set porthos-athos netns porthos

# porthos <-> aramis
ip link add porthos-aramis type veth peer name aramis-porthos
ip link set porthos-aramis netns porthos
ip link set aramis-porthos netns aramis

# aramis <-> beta
ip link add aramis-beta type veth peer name beta-aramis
ip link set aramis-beta netns aramis
ip link set beta-aramis netns beta

#-------------------------------------------------------------------
# 4. Assign IPv6 addresses and bring interfaces up
#-------------------------------------------------------------------
# alfa -> athos
ip netns exec alfa   ip addr add db11::2/64 dev alfa-athos
ip netns exec alfa   ip link set dev alfa-athos up

# athos -> alfa
ip netns exec athos  ip addr add db11::1/64 dev athos-alfa
ip netns exec athos  ip link set dev athos-alfa up

# athos -> porthos
ip netns exec athos  ip addr add dc01::1/64 dev athos-porthos
ip netns exec athos  ip link set dev athos-porthos up

# porthos -> athos
ip netns exec porthos ip addr add dc01::2/64 dev porthos-athos
ip netns exec porthos ip link set dev porthos-athos up

# porthos -> aramis
ip netns exec porthos ip addr add dc02::1/64 dev porthos-aramis
ip netns exec porthos ip link set dev porthos-aramis up

# aramis -> porthos
ip netns exec aramis ip addr add dc02::2/64 dev aramis-porthos
ip netns exec aramis ip link set dev aramis-porthos up

# aramis -> beta
ip netns exec aramis ip addr add db22::1/64 dev aramis-beta
ip netns exec aramis ip link set dev aramis-beta up

# beta -> aramis
ip netns exec beta   ip addr add db22::2/64 dev beta-aramis
ip netns exec beta   ip link set dev beta-aramis up

#-------------------------------------------------------------------
# 5. Enable IPv6 forwarding (all nodes act as routers)
#-------------------------------------------------------------------
for ns in alfa athos porthos aramis beta; do
    ip netns exec "$ns" sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
done

#-------------------------------------------------------------------
# 6. IOAM-6 IDs + enable IOAM-6 on the interfaces that got an ID
#-------------------------------------------------------------------
# athos
ip netns exec athos sysctl -wq net.ipv6.ioam6_id=1
ip netns exec athos sysctl -wq net.ipv6.conf.athos-alfa.ioam6_id=101
ip netns exec athos sysctl -wq net.ipv6.conf.athos-porthos.ioam6_id=102
ip netns exec athos sysctl -wq net.ipv6.conf.athos-alfa.ioam6_enabled=1
ip netns exec athos sysctl -wq net.ipv6.conf.athos-porthos.ioam6_enabled=1

# porthos
ip netns exec porthos sysctl -wq net.ipv6.ioam6_id=2
ip netns exec porthos sysctl -wq net.ipv6.conf.porthos-athos.ioam6_id=201
ip netns exec porthos sysctl -wq net.ipv6.conf.porthos-aramis.ioam6_id=202
ip netns exec porthos sysctl -wq net.ipv6.conf.porthos-athos.ioam6_enabled=1
ip netns exec porthos sysctl -wq net.ipv6.conf.porthos-aramis.ioam6_enabled=1

# aramis
ip netns exec aramis sysctl -wq net.ipv6.ioam6_id=3
ip netns exec aramis sysctl -wq net.ipv6.conf.aramis-porthos.ioam6_id=301
ip netns exec aramis sysctl -wq net.ipv6.conf.aramis-beta.ioam6_id=302
ip netns exec aramis sysctl -wq net.ipv6.conf.aramis-porthos.ioam6_enabled=1
ip netns exec aramis sysctl -wq net.ipv6.conf.aramis-beta.ioam6_enabled=1

#-------------------------------------------------------------------
# 7. IOAM-namespace data (per-namespace)
#-------------------------------------------------------------------
ip netns exec athos   ip ioam namespace add 123 data 0xdeadbee0
ip netns exec porthos ip ioam namespace add 123 data 0xdeadbee1
ip netns exec aramis  ip ioam namespace add 123 data 0xdeadbee2

#-------------------------------------------------------------------
# 8. Add the two special routes (plain IPv6)
#-------------------------------------------------------------------
ip netns exec athos   ip -6 route add fc00::d6/128 via dc01::2 dev athos-porthos
ip netns exec porthos ip -6 route add fc00::d6/128 via dc02::2 dev porthos-aramis

#-------------------------------------------------------------------
# 9. Encapsulation route on athos (IOAM-6)
#-------------------------------------------------------------------
ip netns exec athos ip -6 route add db22::22/64 \
    encap ioam6 mode encap tundst fc00::d6 \
    trace prealloc type 0x800000 ns 123 size 12 \
    dev athos-porthos

#-------------------------------------------------------------------
# 10. Default IPv6 routes for edge hosts
#-------------------------------------------------------------------
# alfa -> default via its neighbour (athos)
ip netns exec alfa ip -6 route add default via db11::1 dev alfa-athos

# beta -> default via its neighbour (aramis)
ip netns exec beta ip -6 route add default via db22::1 dev beta-aramis

#-------------------------------------------------------------------
# 11. Start tmux (one window per node, mouse enabled)
#-------------------------------------------------------------------

# Create a detached tmux session; first window will be called "alfa".
tmux new-session -d -s "${SESSION}" -n "alfa" ip netns exec alfa bash

# Populate the windows each runs a shell inside its own namespace
tmux new-window -t "${SESSION}" -n "athos" ip netns exec athos bash
tmux new-window -t "${SESSION}" -n "porthos" ip netns exec porthos bash
tmux new-window -t "${SESSION}" -n "aramis" ip netns exec aramis bash
tmux new-window -t "${SESSION}" -n "beta" ip netns exec beta bash

# Enable mouse support for the whole session.
tmux set -g mouse on

# Attach to the session you start in window 0 (alfa)
tmux attach -t "$SESSION"
