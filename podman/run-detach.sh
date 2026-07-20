#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
	echo "Error: This script must be run as root." >&2
	exit 1
fi

UPLINK_BR=br0          # bridge on this VM, reaches the lab LAN
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
ip link set "${VETH_H}" master "${UPLINK_BR}"
ip link set "${VETH_H}" up
ip link set "${VETH_C}" netns "${CPID}"

nsenter -t "${CPID}" -n ip link add "${GUEST_BR}" type bridge
nsenter -t "${CPID}" -n ip link set "${GUEST_BR}" up
nsenter -t "${CPID}" -n ip link set "${VETH_C}" master "${GUEST_BR}"
nsenter -t "${CPID}" -n ip link set "${VETH_C}" up

echo "container up: '${GUEST_BR}' (in container) <-> '${UPLINK_BR}' (host) via ${VETH_H}/${VETH_C}"
