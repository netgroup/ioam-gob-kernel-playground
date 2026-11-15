#!/bin/bash
# Runs in the builder container. /repo is the playground (read-only),
# /work the work directory.
#
# Exports, from the playground commit $REF:
#   - kernel/linux and iproute2, at the commits recorded as submodules;
#   - the GOB demo scripts and the eBPF source.
# Clones qemu-wasm at $QEMU_WASM_COMMIT (only that, with QEMU_ONLY=1).
set -o pipefail

die() { echo "fetch-sources: $*" >&2; exit 1; }

S=/work/src
mkdir -p $S

submodule_sha() {
	git -C /repo ls-tree "$REF" "$1" | awk '$2 == "commit" { print $3 }'
}

export_submodule() {
	local path=$1 dest=$2 sha
	sha=$(submodule_sha "$path")
	[ -n "$sha" ] || die "$path is not a submodule at $REF"
	git -C "/repo/$path" cat-file -e "$sha^{commit}" 2>/dev/null ||
		die "$path: commit $sha missing, run: git submodule update --init $path"
	rm -rf "$dest" && mkdir -p "$dest"
	git -C "/repo/$path" archive "$sha" | tar -x -C "$dest" || die "$path: archive failed"
	echo "$path $sha $(git -C "/repo/$path" log -1 --format=%s "$sha")"
}

fetch_qemu_wasm() {
	if [ "$(git -C $S/qemu-wasm rev-parse HEAD 2>/dev/null)" != "$QEMU_WASM_COMMIT" ]; then
		rm -rf $S/qemu-wasm
		git clone -q https://github.com/ktock/qemu-wasm.git $S/qemu-wasm || die "qemu-wasm clone failed"
		git -C $S/qemu-wasm checkout -q "$QEMU_WASM_COMMIT" || die "qemu-wasm checkout failed"
	fi
	echo "qemu-wasm $(git -C $S/qemu-wasm log -1 --format='%H %s')"
}

# The images step needs only qemu-wasm, to build its emsdk image.
if [ "${QEMU_ONLY:-0}" = 1 ]; then
	fetch_qemu_wasm
	exit
fi

REF_SHA=$(git -C /repo rev-parse --verify "$REF^{commit}") || die "bad REF $REF"
{
	echo "playground $REF_SHA $(git -C /repo log -1 --format=%s "$REF_SHA")"
	export_submodule kernel/linux $S/linux
	export_submodule iproute2 $S/iproute2
} > $S/SOURCES.txt || exit 1

rm -rf $S/demo && mkdir -p $S/demo
git -C /repo archive "$REF_SHA" tests/scripts/gob-demo src/c/ioam6_gob_recv.bpf.c |
	tar -x -C $S/demo || die "demo files: archive failed"

fetch_qemu_wasm >> $S/SOURCES.txt || exit 1

cat $S/SOURCES.txt
