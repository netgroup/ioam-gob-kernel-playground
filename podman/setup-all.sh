#!/bin/bash

# Check if the script is run as root
if [ "$EUID" -ne 0 ]; then
	echo "Error: This script must be run as root." >&2
	exit 1
fi

podman run \
	-it \
	--privileged \
	--rm \
	--replace \
	--name kernel-builder \
	-v ../:/opt/kernel-playground \
	-t localhost/kernel-builder \
	bash -c "cd /opt/kernel-playground/podman && ./helper-init.sh"
