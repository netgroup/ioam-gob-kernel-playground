#!/bin/bash

# Check if the script is run as root
if [ "$EUID" -ne 0 ]; then
	echo "Error: This script must be run as root." >&2
	exit 1
fi

podman run \
	--rm \
	-d \
	--replace \
	--privileged \
	--name ioam-kernel-builder \
	-v ../:/opt/kernel-playground \
	-v $HOME/.ssh/id_ed25519:/root/.ssh/id_ed25519:ro \
	-it localhost/ioam-kernel-builder
