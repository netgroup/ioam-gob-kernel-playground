#!/bin/bash
# Runs in the builder container. Builds the GOB kernel (bzImage), bpftool
# from the same tree, and vmlinux.h from the kernel BTF.
set -o pipefail

die() { echo "build-kernel: $*" >&2; exit 1; }

S=/work/src/linux
O=/work/build/kernel
B=/work/build/bpftool
FRAG=/bvm/kernel/gob-web.fragment
JOBS=${KERNEL_JOBS:-16}

mkdir -p $O $B
cp /work/src/qemu-wasm/examples/x86_64/image/linux_x86_config $O/.config || die "no base config"
make -C $S O=$O olddefconfig >/dev/null || die "olddefconfig failed"
$S/scripts/kconfig/merge_config.sh -m -O $O $O/.config $FRAG >/dev/null || die "merge_config failed"
make -C $S O=$O olddefconfig >/dev/null || die "olddefconfig failed"

# Every option of the fragment must have stuck.
bad=0
while IFS== read -r k v; do
	case "$k" in CONFIG_*) ;; *) continue ;; esac
	got=$(grep -E "^$k=|^# $k is not set" $O/.config)
	if [ "$v" = n ]; then
		# off: "is not set", or absent because a dependency is off
		case "$got" in "# $k is not set"|"") continue ;; esac
		want="# $k is not set"
	else
		want="$k=$v"
	fi
	[ "$got" = "$want" ] || { echo "CONFIG MISMATCH: want '$want' got '$got'"; bad=1; }
done < $FRAG
[ $bad = 0 ] || die "config mismatch"

make -C $S O=$O -j"$JOBS" bzImage || die "kernel build failed"
make -C $S/tools/bpf/bpftool OUTPUT=$B/ -j"$JOBS" >/dev/null || die "bpftool build failed"
$B/bpftool btf dump file $O/vmlinux format c > /work/build/vmlinux.h || die "vmlinux.h failed"
grep -q 'struct bpf_ioam6_trace_gob_ctx {' /work/build/vmlinux.h ||
	die "vmlinux.h has no struct bpf_ioam6_trace_gob_ctx: is this a GOB kernel?"

ls -l $O/arch/x86/boot/bzImage $B/bpftool /work/build/vmlinux.h
$B/bpftool version | head -1
