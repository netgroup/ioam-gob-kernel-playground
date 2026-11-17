#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
	echo "Error: This script must be run as root." >&2
	exit 1
fi

UPLINK_BR=${UPLINK_BR:-br0}   # host bridge that reaches the LAN (override: UPLINK_BR=name ./run-detach.sh)
GUEST_BR=br-gob        # bridge inside the container, where the QEMU taps attach
VETH_H=veth-gob        # host side of the pair
VETH_C=veth-gob-c      # container side

podman run \
	--rm -d --replace \
	--privileged \
	--hostname ioam-builder \
	--name ioam-kernel-builder \
	-v ../:/opt/kernel-playground \
	-it localhost/ioam-kernel-builder

CPID=$(podman inspect -f '{{.State.Pid}}' ioam-kernel-builder)
[ -n "${CPID}" ] || { echo "error: cannot get container pid"; exit 1; }

ip link del "${VETH_H}" 2>/dev/null || true      # leftovers from a previous run

ip link add "${VETH_H}" type veth peer name "${VETH_C}"
if ip link show "${UPLINK_BR}" &>/dev/null; then
	ip link set "${VETH_H}" master "${UPLINK_BR}"
	UPLINK_DESC="'${UPLINK_BR}' (host) via ${VETH_H}/${VETH_C}"
else
	# No uplink bridge on this host: go on without it. The guest bridge is still
	# created, so guests started with "run.sh -u" work and bridged guests reach
	# each other, but not the LAN. To add the uplink later:
	#   ip link set ${VETH_H} master <bridge>
	echo "warning: bridge '${UPLINK_BR}' not found on the host: '${GUEST_BR}' has no uplink" >&2
	UPLINK_DESC="no uplink (${VETH_H} is not attached to a bridge)"
fi
ip link set "${VETH_H}" up
ip link set "${VETH_C}" netns "${CPID}"

nsenter -t "${CPID}" -n ip link add "${GUEST_BR}" type bridge
nsenter -t "${CPID}" -n ip link set "${GUEST_BR}" up
nsenter -t "${CPID}" -n ip link set "${VETH_C}" master "${GUEST_BR}"
nsenter -t "${CPID}" -n ip link set "${VETH_C}" up

echo "container up: '${GUEST_BR}' (in container) <-> ${UPLINK_DESC}"
