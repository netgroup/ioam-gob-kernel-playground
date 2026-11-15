#!/bin/bash
# Runs in the qemu-wasm build container (emsdk). /qemu is the qemu-wasm
# source (writable: meson downloads subprojects into it).
#
# The flags are the ones of the qemu-wasm README, without -g: the .wasm
# goes from about 41 MB to about 12 MB.
set -o pipefail

die() { echo "build-qemu: $*" >&2; exit 1; }

O=/work/build/qemu
EXTRA_CFLAGS="-O3 -Wno-error=unused-command-line-argument -matomics -mbulk-memory -DNDEBUG -DG_DISABLE_ASSERT -D_GNU_SOURCE -sASYNCIFY=1 -pthread -sPROXY_TO_PTHREAD=1 -sFORCE_FILESYSTEM -sALLOW_TABLE_GROWTH -sTOTAL_MEMORY=2300MB -sWASM_BIGINT -sMALLOC=mimalloc --js-library=/build/node_modules/xterm-pty/emscripten-pty.js -sEXPORT_ES6=1 -sASYNCIFY_IMPORTS=ffi_call_js"

cd /build || die "no /build"
emconfigure /qemu/configure --static --target-list=x86_64-softmmu --cpu=wasm32 --cross-prefix= \
	--without-default-features --enable-system --with-coroutine=fiber --enable-virtfs \
	--extra-cflags="$EXTRA_CFLAGS" --extra-cxxflags="$EXTRA_CFLAGS" \
	--extra-ldflags="-sEXPORTED_RUNTIME_METHODS=getTempRet0,setTempRet0,addFunction,removeFunction,TTY,FS" ||
	die "configure failed"
emmake make -j"$(nproc)" qemu-system-x86_64 || die "make failed"

rm -rf $O && mkdir -p $O
cp qemu-system-x86_64 qemu-system-x86_64.wasm qemu-system-x86_64.worker.js $O/ || die "copy failed"
cp /qemu/pc-bios/bios-256k.bin /qemu/pc-bios/vgabios-stdvga.bin \
	/qemu/pc-bios/kvmvapic.bin /qemu/pc-bios/linuxboot_dma.bin $O/ || die "copy of the BIOS failed"
ls -l $O
