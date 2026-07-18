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
	-it localhost/ioam-kernel-builder
