# Image for the GOB nodes of the lab: kathara/base with the iproute2 of
# GOB (ip ioam ... gobschema), the bpftool and the libbpf headers of the
# GOB kernel tree, which know the IOAM6_GOB program type, and a static
# clang with only the BPF backend, to build GOB programs inside a node.
# build.sh builds it ("image" step), with as context the sources that the
# "sources" step exports from the playground commit: iproute2/ and the
# parts of the GOB kernel tree that bpftool needs, linux/. Three stages on
# Debian 12, as kathara/base. The clang stage builds LLVM: CLANG_JOBS
# gives it more jobs.

ARG LLVM_VERSION=19.1.7
ARG LLVM_SHA256=82401fea7b79d0078043f7598b835284d6650a75b93e64b6f761ea7b63097501

# clang with only the BPF backend, static and stripped.
FROM docker.io/library/debian:bookworm-slim AS clang
ARG LLVM_VERSION
ARG LLVM_SHA256
ARG CLANG_JOBS=8
RUN apt-get update && apt-get install -y --no-install-recommends \
		cmake ninja-build g++ python3 curl ca-certificates xz-utils && \
	rm -rf /var/lib/apt/lists/*
RUN curl -fsSL -o /llvm.tar.xz \
		https://github.com/llvm/llvm-project/releases/download/llvmorg-$LLVM_VERSION/llvm-project-$LLVM_VERSION.src.tar.xz && \
	echo "$LLVM_SHA256  /llvm.tar.xz" | sha256sum -c - && \
	tar -xJf /llvm.tar.xz -C / && rm /llvm.tar.xz
RUN cmake -S /llvm-project-$LLVM_VERSION.src/llvm -B /build -G Ninja \
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
		-DCMAKE_CXX_FLAGS="-ffunction-sections -fdata-sections" && \
	ninja -C /build -j"$CLANG_JOBS" clang && \
	mkdir -p /opt/clang-bpf/bin /opt/clang-bpf/lib && \
	cp /build/bin/clang-${LLVM_VERSION%%.*} /opt/clang-bpf/bin/clang && \
	strip /opt/clang-bpf/bin/clang && \
	cp -r /build/lib/clang /opt/clang-bpf/lib/ && \
	/opt/clang-bpf/bin/clang -print-targets | grep -q 'bpf ' && \
	rm -rf /build /llvm-project-$LLVM_VERSION.src

# The iproute2 of GOB, and bpftool and the libbpf headers of the GOB
# kernel tree.
FROM docker.io/library/debian:bookworm-slim AS tools
RUN apt-get update && apt-get install -y --no-install-recommends \
		gcc make pkg-config bison flex \
		libelf-dev libmnl-dev libcap-dev zlib1g-dev libbpf-dev libssl-dev python3 && \
	rm -rf /var/lib/apt/lists/*
COPY iproute2 /iproute2
COPY linux /linux
RUN cd /iproute2 && ./configure --prefix=/usr && make -j"$(nproc)" && \
	make install DESTDIR=/out SBINDIR=/usr/sbin
RUN make -C /linux/tools/bpf/bpftool -j"$(nproc)" && \
	install -D -m 0755 /linux/tools/bpf/bpftool/bpftool /out/usr/sbin/bpftool && \
	make -C /linux/tools/lib/bpf install_headers prefix=/usr DESTDIR=/out

FROM docker.io/kathara/base
RUN apt-get update && apt-get install -y --no-install-recommends \
		libelf1 libmnl0 libcap2 zlib1g libbpf1 libssl3 && \
	rm -rf /var/lib/apt/lists/*
COPY --from=tools /out/ /
COPY --from=clang /opt/clang-bpf /opt/clang-bpf
RUN ln -s /opt/clang-bpf/bin/clang /usr/local/bin/clang && \
	ip -V && bpftool version && clang --version | head -1
