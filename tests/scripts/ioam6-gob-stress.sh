#!/bin/bash

IPP=/mnt/iproute2/ip/ip

while true; do
	${IPP} ioam gobschema del 77 &>/dev/null || true
	v=$(((RANDOM % 15) + 1))
	sleep ${v}

	${IPP} ioam gobschema add 77 object /mnt/shared/netprog.bpf.o section ioam6_cntv3
	${IPP} ioam namespace set 123 gobschema 77

	w=$(((RANDOM % 15) + 1))
	sleep ${w}

	printf "%d/%d." ${v} ${w}
done
