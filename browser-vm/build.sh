#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
#
# Build the IOAM GOB v3 browser VM and test it. Every step runs in a podman
# container. See README.md.
#
# Usage: ./build.sh [step...]          (no step: all)
#
#   images   build the builder and qemu-wasm images, pull Playwright
#   sources  export kernel, iproute2 and the demo from the playground commit
#   kernel   GOB kernel, bpftool, vmlinux.h
#   clang    static BPF-only clang (long: LLVM)
#   qemu     qemu-system-x86_64 compiled to WebAssembly
#   guest    guest disk image (ext4)
#   pack     web site in $WORK/site
#   test     self test in headless Chromium (about 6 minutes)
#   test-quick  boot and a few commands in headless Chromium (about 1 minute,
#            for changes to the page; not part of all, not enough to publish)
#   all      every step above, in this order
#   serve    serve $WORK/site on http://127.0.0.1:$PORT (not part of all)
#   clean    remove $WORK, podman storage included (not part of all)
#   publish  push $WORK/site to the gh-pages branch of $PAGES_REPO, replacing
#            it (not part of all; runs on the host, with your git credentials)
#
# Everything is written under $WORK (default: browser-vm/out), the podman
# storage and the temporary files of podman included.

HERE=$(cd "$(dirname "$0")" && pwd)

# Configuration (environment variables).
REPO=${REPO:-$(cd "$HERE/.." && pwd)}	# the playground
REF=${REF:-HEAD}			# commit to build from
WORK=${WORK:-$HERE/out}			# everything built goes here
PODMAN_ROOT=${PODMAN_ROOT:-}		# podman storage, default $WORK/podman-storage
MEM_BUILD=${MEM_BUILD:-12g}		# memory cap of the build containers
MEM_TEST=${MEM_TEST:-8g}		# memory cap of the browser test
KERNEL_JOBS=${KERNEL_JOBS:-16}
CLANG_JOBS=${CLANG_JOBS:-10}
PORT=${PORT:-8000}
PAGES_REPO=${PAGES_REPO:-https://github.com/netgroup/gob-browser-vm.git}

# Pinned inputs: every download of the build is fixed here, so that two
# builds use the same software. Change SNAPSHOT and the digests together.
SNAPSHOT=20261114T000000Z	# snapshot.debian.org and snapshot.ubuntu.com
SOURCE_DATE_EPOCH=1794614400	# 2026-11-14T00:00:00Z: kernel and disk timestamps
DEBIAN_IMAGE=docker.io/library/debian:trixie@sha256:9c6e381421d0f48d1b8133e573f33c185ee16cbf505eda9c4a8a4791b25ea8a6
DEBIAN_SLIM_IMAGE=docker.io/library/debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2
EMSDK_DIGEST=sha256:b6ea0e55fdc95be36427df6df7892d5e5e27f0440cfcf442a55f784aba09a4fa	# emscripten/emsdk:3.1.50
QEMU_WASM_COMMIT=0ef7b4e2814b231705d8371dd7997f5b72e70baf
LLVM_VERSION=19.1.7
LLVM_SHA256=82401fea7b79d0078043f7598b835284d6650a75b93e64b6f761ea7b63097501
XTERM_VERSION=5.3.0		# the page
XTERM_FIT_VERSION=0.8.0		# the page, fits the terminal to the window
XTERM4_VERSION=4.19.0		# in the qemu-wasm image, for xterm-pty
XTERM_PTY_VERSION=0.10.1	# must match the one the qemu-wasm image installs
COI_VERSION=0.1.7
PLAYWRIGHT_IMAGE=mcr.microsoft.com/playwright/python:v1.48.0-noble@sha256:acc6300abda1a16dba3a0d39583c8be53e619a3f23d4a0eeeb8de0a9275c47ac
PLAYWRIGHT_PIP="playwright==1.48.0 greenlet==3.1.1 pyee==12.0.0 typing_extensions==4.12.2"

BUILDER_IMAGE=localhost/gobweb-builder
QEMU_IMAGE=localhost/gobweb-qemu
GUEST_IMAGE=localhost/gobweb-guest

die() { echo "build.sh: $*" >&2; exit 1; }

mkdir -p "$WORK" || die "cannot create $WORK"
WORK=$(cd "$WORK" && pwd)
PODMAN_ROOT=${PODMAN_ROOT:-$WORK/podman-storage}
# Temporary files of podman and buildah (layers being committed, image
# copies) would go to /var/tmp otherwise.
export TMPDIR=$WORK/tmp
mkdir -p "$WORK/logs" "$WORK/src" "$WORK/build" "$WORK/site" "$TMPDIR" "$PODMAN_ROOT" ||
	die "cannot create $WORK"
PM=(podman --root "$PODMAN_ROOT")

step() {
	echo
	echo "=== $(date +%T) $*"
	free -g | awk '/^Mem:/ { print "    host memory available: " $7 " GB" }'
}

# Run a command in a container. Mounted: the work subdirectories (not the
# podman storage), the browser-vm sources read-only, the playground
# read-only.
run_in() {
	local image=$1 mem=$2 d mounts=()
	shift 2
	for d in src build site logs; do
		mounts+=(-v "$WORK/$d:/work/$d:Z")
	done
	for d in scripts kernel web test; do
		mounts+=(-v "$HERE/$d:/bvm/$d:ro,Z")
	done
	"${PM[@]}" run --rm --memory="$mem" --memory-swap="$mem" \
		"${mounts[@]}" -v "$REPO:/repo:ro" \
		-e REF="$REF" -e QEMU_WASM_COMMIT="$QEMU_WASM_COMMIT" \
		-e LLVM_VERSION="$LLVM_VERSION" -e LLVM_SHA256="$LLVM_SHA256" \
		-e KERNEL_JOBS="$KERNEL_JOBS" -e KBUILD_BUILD_TIMESTAMP="$(date -u -d "@$SOURCE_DATE_EPOCH" "+%a %b %e %H:%M:%S UTC %Y")" \
		-e KBUILD_BUILD_USER=gobweb -e KBUILD_BUILD_HOST=gobweb \
		-e CLANG_JOBS="$CLANG_JOBS" -e XTERM_VERSION="$XTERM_VERSION" \
		-e XTERM_PTY_VERSION="$XTERM_PTY_VERSION" -e COI_VERSION="$COI_VERSION" \
		-e XTERM_FIT_VERSION="$XTERM_FIT_VERSION" \
		"$@" "$image" "${CMD[@]}"
}

do_images() {
	step "images"
	"${PM[@]}" build -t $BUILDER_IMAGE -f "$HERE/containers/builder.Containerfile" \
		--build-arg DEBIAN_IMAGE="$DEBIAN_IMAGE" --build-arg SNAPSHOT="$SNAPSHOT" \
		"$HERE/containers" > "$WORK/logs/image-builder.log" 2>&1 ||
		die "builder image failed, see $WORK/logs/image-builder.log"
	# qemu-wasm is needed to make its build image: fetch it first.
	CMD=(bash /bvm/scripts/fetch-sources.sh)
	run_in $BUILDER_IMAGE "$MEM_BUILD" -e QEMU_ONLY=1 > "$WORK/logs/qemu-wasm-fetch.log" 2>&1 ||
		die "qemu-wasm fetch failed, see $WORK/logs/qemu-wasm-fetch.log"
	local ctx=$WORK/build/qemu-image
	rm -rf "$ctx" && mkdir -p "$ctx"
	CMD=(python3 /bvm/scripts/adapt-qemu-dockerfile.py /work/src/qemu-wasm/Dockerfile
		/work/build/qemu-image "$EMSDK_DIGEST" "$SNAPSHOT" "$XTERM4_VERSION")
	run_in $BUILDER_IMAGE 1g || die "adapting the qemu-wasm Dockerfile failed"
	"${PM[@]}" build -t $QEMU_IMAGE "$ctx" > "$WORK/logs/image-qemu.log" 2>&1 ||
		die "qemu-wasm image failed, see $WORK/logs/image-qemu.log"
	"${PM[@]}" pull -q $PLAYWRIGHT_IMAGE > /dev/null || die "pull of $PLAYWRIGHT_IMAGE failed"
	echo "    images ready"
}

do_sources() {
	step "sources (REF=$REF)"
	CMD=(bash /bvm/scripts/fetch-sources.sh)
	run_in $BUILDER_IMAGE "$MEM_BUILD" | tee "$WORK/logs/sources.log"
	[ "${PIPESTATUS[0]}" = 0 ] || die "sources failed"
}

do_kernel() {
	step "kernel"
	CMD=(bash /bvm/scripts/build-kernel.sh)
	run_in $BUILDER_IMAGE "$MEM_BUILD" > "$WORK/logs/kernel.log" 2>&1 ||
		{ tail -20 "$WORK/logs/kernel.log"; die "kernel failed, see $WORK/logs/kernel.log"; }
	tail -4 "$WORK/logs/kernel.log"
}

do_clang() {
	step "clang (LLVM $LLVM_VERSION, BPF only, $CLANG_JOBS jobs)"
	CMD=(bash /bvm/scripts/build-clang.sh)
	run_in $BUILDER_IMAGE "$MEM_BUILD" > "$WORK/logs/clang.log" 2>&1 ||
		{ tail -20 "$WORK/logs/clang.log"; die "clang failed, see $WORK/logs/clang.log"; }
	tail -3 "$WORK/logs/clang.log"
}

do_qemu() {
	step "qemu (WebAssembly)"
	CMD=(bash /bvm/scripts/build-qemu.sh)
	run_in $QEMU_IMAGE "$MEM_BUILD" -v "$WORK/src/qemu-wasm:/qemu:Z" > "$WORK/logs/qemu.log" 2>&1 ||
		{ tail -20 "$WORK/logs/qemu.log"; die "qemu failed, see $WORK/logs/qemu.log"; }
	grep -E 'wasm$' "$WORK/logs/qemu.log"
}

do_guest() {
	step "guest disk"
	local ctx=$WORK/build/guest-ctx
	rm -rf "$ctx" "$WORK/build/guest" && mkdir -p "$ctx/files" "$ctx/src"
	cp "$HERE/guest/Containerfile" "$ctx/" &&
	cp "$HERE/guest/gob-init" "$HERE/guest/motd" "$HERE/guest/Makefile.bpf" \
		"$HERE/containers/apt-snapshot" "$ctx/files/" &&
	cp -a "$WORK/src/iproute2" "$WORK/src/demo" "$ctx/src/" &&
	cp "$WORK/build/bpftool/bpftool" "$WORK/build/vmlinux.h" "$ctx/" &&
	cp -a "$WORK/build/clang-bpf/out" "$ctx/clang-bpf" ||
		die "missing input: run the sources, kernel and clang steps first"
	"${PM[@]}" build --memory="$MEM_BUILD" -t $GUEST_IMAGE \
		--build-arg DEBIAN_IMAGE="$DEBIAN_IMAGE" --build-arg DEBIAN_SLIM_IMAGE="$DEBIAN_SLIM_IMAGE" \
		--build-arg SNAPSHOT="$SNAPSHOT" --build-arg SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
		--output type=local,dest="$WORK/build/guest" "$ctx" > "$WORK/logs/guest.log" 2>&1 ||
		{ tail -20 "$WORK/logs/guest.log"; die "guest failed, see $WORK/logs/guest.log"; }
	grep -E 'guest tree:|disk.ext4$' "$WORK/logs/guest.log"
}

do_pack() {
	step "pack"
	CMD=(bash /bvm/scripts/pack-site.sh)
	run_in $QEMU_IMAGE 4g > "$WORK/logs/pack.log" 2>&1 ||
		{ tail -20 "$WORK/logs/pack.log"; die "pack failed, see $WORK/logs/pack.log"; }
	grep -E '^package|^site total' "$WORK/logs/pack.log"
}

do_test() {
	step "test (headless Chromium)"
	CMD=(bash -c "pip install -q --no-deps --break-system-packages $PLAYWRIGHT_PIP >/dev/null 2>&1 &&
		python3 /bvm/test/run_test.py chromium 1500")
	run_in $PLAYWRIGHT_IMAGE "$MEM_TEST" --shm-size=2g > "$WORK/logs/test.log" 2>&1
	local rc=$?
	grep -E '^\[.{8}\] (OK  |FAIL|timeline|CLANGTEST_END|OBJ |BROWSER_VM_TEST)' "$WORK/logs/test.log"
	[ $rc = 0 ] || die "test failed, see $WORK/logs/test.log and $WORK/logs/test-chromium.screen"
}

do_clean() {
	echo "Removing $WORK"
	# The storage holds files owned by the subordinate uids: remove them
	# from inside the user namespace. Not "podman --root ... unshare",
	# which would mount the storage being removed, and not "podman system
	# reset", which also clears the runtime state shared with the default
	# podman storage of the user.
	podman unshare rm -rf "$WORK" || die "clean failed"
	[ ! -e "$WORK" ] || die "clean failed: $WORK still exists"
}

do_publish() {
	local d=$WORK/publish
	[ -f "$WORK/site/index.html" ] || die "no site: run the pack step first"
	step "publish $WORK/site to $PAGES_REPO (branch gh-pages)"
	# A new one-commit branch each time: the site repository does not grow.
	rm -rf "$d" && mkdir -p "$d" && cp -a "$WORK/site/." "$d/" || die "cannot copy the site"
	# Commit as the playground repository does (its user.name and
	# user.email), not with the global git identity.
	local name email
	name=$(git -C "$REPO" config user.name) && email=$(git -C "$REPO" config user.email) ||
		die "git user.name and user.email are not set for $REPO"
	git -C "$d" init -q -b gh-pages &&
	git -C "$d" config user.name "$name" && git -C "$d" config user.email "$email" &&
	git -C "$d" add -A &&
	git -C "$d" commit -q -s -m "GOB browser VM site" -m "Built from:" -m "$(cat "$d/SOURCES.txt")" ||
		die "commit failed"
	git -C "$d" push -f "$PAGES_REPO" gh-pages || die "push to $PAGES_REPO failed"
	rm -rf "$d"
	echo "    published. The first time, enable Pages in the repository settings:"
	echo "    Pages, Deploy from a branch, gh-pages, / (root)."
}

do_test_quick() {
	step "quick test (headless Chromium)"
	CMD=(bash -c "pip install -q --no-deps --break-system-packages $PLAYWRIGHT_PIP >/dev/null 2>&1 &&
		python3 /bvm/test/quick_test.py")
	run_in $PLAYWRIGHT_IMAGE "$MEM_TEST" --shm-size=2g > "$WORK/logs/test-quick.stdout" 2>&1
	local rc=$?
	grep -E '^\[.{8}\] (OK  |FAIL|shell prompt|python3 -c pass|BROWSER_VM_QUICK_TEST)' "$WORK/logs/test-quick.stdout"
	[ $rc = 0 ] || die "quick test failed, see $WORK/logs/test-quick.log"
}

do_serve() {
	[ -f "$WORK/site/index.html" ] || die "no site: run the pack step first"
	echo "Serving $WORK/site on http://127.0.0.1:$PORT/ (Ctrl-C to stop)"
	"${PM[@]}" run --rm -p "127.0.0.1:$PORT:8000" -v "$WORK/site:/site:ro,Z" \
		$BUILDER_IMAGE python3 -m http.server 8000 -d /site
}

[ $# = 0 ] && set -- all
for s in "$@"; do
	case "$s" in
	all) do_images && do_sources && do_kernel && do_clang && do_qemu &&
		do_guest && do_pack && do_test || exit 1 ;;
	images|sources|kernel|clang|qemu|guest|pack|test|serve|clean|publish) "do_$s" || exit 1 ;;
	test-quick) do_test_quick || exit 1 ;;
	*) die "unknown step '$s'" ;;
	esac
done
echo
echo "=== $(date +%T) done"
