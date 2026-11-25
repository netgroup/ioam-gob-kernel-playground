#!/bin/bash
# Makes this device a GOB node, from its startup file: attaches the section
# for this node of the GOB program ioam6_gob_recv.o, which build.sh builds
# from src/c/ioam6_gob_recv.bpf.c of the playground, to IOAM namespace NS
# through a GOB schema, and gives the node its metric, which the program
# folds into the GOB of each packet. The device runs on the GOB UML kernel
# and on the image kathara-uml/gob. Each step is logged to
# /var/log/gob-node.log.
#
#   gob-node.sh <node id> <metric>
#
# The program records in its map gob_recv, under the node id, the GOB
# that the node received from the previous one:
#
#   bpftool map dump pinned /sys/fs/bpf/tc/globals/gob_recv

HERE=$(cd "$(dirname "$0")" && pwd)
PROGRAM=$HERE/ioam6_gob_recv.o
NS=123
SCHEMA=0xAA
LOG=/var/log/gob-node.log
MAPS=/sys/fs/bpf/tc/globals

# A command, logged with its output; exits if it fails.
run()
{
	echo "+ $*" >> "$LOG"
	if ! "$@" >> "$LOG" 2>&1; then
		echo "gob-node: failed: $*" | tee -a "$LOG" >&2
		exit 1
	fi
}

# The 4 bytes of a u32 in host order (little endian), as bpftool takes a
# key or a value.
le32_bytes()
{
	local n=$1

	echo "$((n & 255)) $((n >> 8 & 255)) $((n >> 16 & 255)) $((n >> 24 & 255))"
}

if [ $# != 2 ]; then
	echo "usage: $0 <node id> <metric>" >&2
	exit 1
fi
node=$1
metric=$2

run sysctl -w net.ipv6.ioam6_id="$node"
run ip ioam namespace add "$NS"
run ip ioam gobschema add "$SCHEMA" object "$PROGRAM" section "ioam6_gob_recv_n$node"
run ip ioam namespace set "$NS" gobschema "$SCHEMA"
# shellcheck disable=SC2046 # the bytes of the key and of the value
run bpftool map update pinned "$MAPS/gob_metric" key $(le32_bytes $((node - 1))) value $(le32_bytes "$metric")
echo "gob-node: node $node ready, metric $metric" >> "$LOG"
