#!/bin/bash
# Runs in the qemu-native container. Boots the browser VM image with
# native QEMU (KVM if /dev/kvm is usable, else TCG), with the same kernel
# command line as the page in ?test=1, and checks the markers of the self
# test of gob-init on the serial console. It checks the logic of the
# guest, not the page: run the browser test before publishing.
set -o pipefail

die() { echo "test-native: $*" >&2; exit 1; }

LOG=/work/logs/test-native-serial.log
TIMEOUT=${NATIVE_TIMEOUT:-900}
ACCEL="-accel tcg"
if [ -c /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
	ACCEL="-accel kvm -cpu host"
fi
echo "accelerator: $ACCEL"

rm -f $LOG
qemu-system-x86_64 $ACCEL -m 512M -smp 1 -display none -monitor none \
	-serial file:$LOG -nic none \
	-drive if=virtio,format=raw,file=/work/build/guest/disk.ext4,snapshot=on \
	-kernel /work/build/kernel/arch/x86/boot/bzImage \
	-append "console=ttyS0,115200n8 root=/dev/vda rw rootwait init=/sbin/gob-init loglevel=4 gobtest=1 gobtest_clang=1 gobterm=120x40" &
QPID=$!

start=$(date +%s)
while kill -0 $QPID 2>/dev/null; do
	grep -q 'GOBTEST3_END' $LOG 2>/dev/null && break
	[ $(( $(date +%s) - start )) -ge "$TIMEOUT" ] && { echo "timeout after ${TIMEOUT}s"; break; }
	sleep 1
done
elapsed=$(( $(date +%s) - start ))
kill $QPID 2>/dev/null; wait $QPID 2>/dev/null

has() { grep -q -- "$1" $LOG; }
count() { grep -c -- "$1" $LOG; }
bad=0
check() { if eval "$2"; then echo "OK   $1"; else echo "FAIL $1"; bad=1; fi; }
check "demo PASS twice" '[ "$(count GOB_DEMO_5NODE_RECV=PASS)" = 2 ]'
check "no demo FAIL" '! has GOB_DEMO_5NODE_RECV=FAIL'
check "demo exit 0 (first run)" 'has "GOBTEST_END rc=0"'
check "clang build exit 0" 'has "CLANGTEST_END rc=0"'
check "demo exit 0 (with the object built in the VM)" 'has "GOBTEST2_END rc=0"'
check "interactive demo exit 0" 'has "GOBTEST3_END rc=0"'
check "interactive demo: node 5 got 10 | 70 | 140 | 4 after n3=70" \
	'tr -s " " < $LOG | grep -q "^ 5 | 10 | 70 | 140 | 4 |"'
grep -E '^CLANGTEST_END' $LOG
echo "BROWSER_VM_NATIVE_TEST=$([ $bad = 0 ] && echo PASS || echo FAIL) (${elapsed}s, $ACCEL)"
exit $bad
