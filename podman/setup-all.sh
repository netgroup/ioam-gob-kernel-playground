#!/bin/bash

# Check if the script is run as root
if [ "$EUID" -ne 0 ]; then
	echo "Error: This script must be run as root." >&2
	exit 1
fi

# GOLDEN_IMAGE is read inside the container by helper-init.sh (it decides whether
# create-image.sh builds a shared golden base). Environment variables set on the
# host do NOT cross into the container on their own, so forward it explicitly:
# without this -e, `GOLDEN_IMAGE=1 ./setup-all.sh` silently builds a non-golden
# image.
podman run \
	-it \
	--privileged \
	--rm \
	--replace \
	--name ioam-kernel-builder \
	-e GOLDEN_IMAGE \
	-v ../:/opt/kernel-playground \
	-t localhost/ioam-kernel-builder \
	bash -c "cd /opt/kernel-playground/podman && ./helper-init.sh"
