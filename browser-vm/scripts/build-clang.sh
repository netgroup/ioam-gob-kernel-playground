#!/bin/bash
# Runs in the builder container. Builds a static clang with only the BPF
# backend: about 90 MB, against about 250 MB for a distribution clang with
# its LLVM libraries.
set -o pipefail

die() { echo "build-clang: $*" >&2; exit 1; }

V=${LLVM_VERSION:-19.1.7}
S=/work/src/llvm-project-$V.src
B=/work/build/clang-bpf/build
O=/work/build/clang-bpf/out
JOBS=${CLANG_JOBS:-10}

if [ ! -d $S ]; then
	T=/work/src/llvm-project-$V.src.tar.xz
	curl -fsSL -o $T https://github.com/llvm/llvm-project/releases/download/llvmorg-$V/llvm-project-$V.src.tar.xz ||
		die "download of LLVM $V failed"
	echo "$LLVM_SHA256  $T" | sha256sum -c - || die "LLVM tarball: wrong sha256"
	tar -xJf $T -C /work/src && rm -f $T || die "extract of LLVM failed"
fi

mkdir -p $B && cd $B || die "no build dir"
# Release, not MinSizeRel: 90 MB instead of 50 MB, but clang compiles the
# demo program in about 65-96 s instead of 115 s in the browser VM.
cmake -G Ninja $S/llvm \
	-DCMAKE_BUILD_TYPE=Release \
	-DLLVM_ENABLE_PROJECTS=clang \
	-DLLVM_TARGETS_TO_BUILD=BPF \
	-DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBXML2=OFF \
	-DLLVM_ENABLE_Z3_SOLVER=OFF -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_LIBEDIT=OFF \
	-DLLVM_ENABLE_LIBPFM=OFF -DLLVM_ENABLE_FFI=OFF -DLLVM_ENABLE_BINDINGS=OFF \
	-DCLANG_ENABLE_STATIC_ANALYZER=OFF -DCLANG_ENABLE_ARCMT=OFF \
	-DCLANG_PLUGIN_SUPPORT=OFF -DLLVM_ENABLE_PLUGINS=OFF \
	-DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF \
	-DLLVM_INCLUDE_DOCS=OFF -DCLANG_INCLUDE_TESTS=OFF -DCLANG_INCLUDE_DOCS=OFF \
	-DLLVM_BUILD_LLVM_DYLIB=OFF -DLLVM_LINK_LLVM_DYLIB=OFF \
	-DLLVM_PARALLEL_LINK_JOBS=1 \
	-DCMAKE_EXE_LINKER_FLAGS="-static -Wl,--gc-sections" \
	-DCMAKE_C_FLAGS="-ffunction-sections -fdata-sections" \
	-DCMAKE_CXX_FLAGS="-ffunction-sections -fdata-sections" > $B/cmake.log 2>&1 ||
	{ tail -30 $B/cmake.log; die "cmake failed"; }
ninja -j"$JOBS" clang > $B/ninja.log 2>&1 || { tail -30 $B/ninja.log; die "ninja failed"; }

rm -rf $O && mkdir -p $O/bin $O/lib
cp $B/bin/clang-${V%%.*} $O/bin/clang && strip $O/bin/clang || die "install failed"
cp -r $B/lib/clang $O/lib/ || die "install of the clang headers failed"
ls -l $O/bin/clang
$O/bin/clang --version | head -1
$O/bin/clang -print-targets | grep -q 'bpf ' || die "no BPF target"
