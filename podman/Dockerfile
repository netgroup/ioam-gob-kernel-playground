# Use the Ubuntu 24.04 base image
FROM ubuntu:24.04

# Replace sources.list with the specified mirror
RUN sed -i 's|http://archive.ubuntu.com/ubuntu/|http://ubuntu.mirror.garr.it/ubuntu/|g' \
	/etc/apt/sources.list.d/ubuntu.sources

# Update package lists
RUN apt-get clean && apt-get update

# Set environment variables to avoid prompts during build
ENV DEBIAN_FRONTEND=noninteractive

# Install any packages or dependencies here
RUN apt-get install -y \
	autotools-dev \
	bc \
	binutils-dev \
	build-essential \
	bison \
	cmake \
	debhelper \
	debhelper-compat \
	debootstrap \
	fakeroot \
	flex \
	gcc-multilib \
	g++ \
	gdb \
	gpg \
	git \
	gnupg \
	init \
	iproute2 \
	iputils-ping \
	kmod \
	libcap-dev \
	libcap-ng-dev \
	libcurl4-openssl-dev \
	libdw-dev \
	libelf-dev \
	libgcrypt20-dev \
	liblz4-dev \
	libmnl-dev \
	libnl-3-dev \
	libnl-nf-3-dev \
	libnl-route-3-dev \
	libpcre2-dev \
	libssl-dev \
	libudev-dev \
	lsb-release \
	net-tools \
	pahole \
	pkg-config \
	qemu-system-x86 \
	rsync \
	sparse \
	systemd \
	software-properties-common \
	tmux \
	tcpdump \
	universal-ctags \
	vim \
	wget \
	xz-utils \
	zlib1g-dev

# install latest llvm for ebpf
RUN mkdir -p /opt/llvm && cd /opt/llvm && \
	wget https://apt.llvm.org/llvm.sh && \
	chmod +x llvm.sh && \
	./llvm.sh all && \
	wget https://raw.githubusercontent.com/ShangjinTang/dotfiles/05ef87daae29475244c276db5d406b58c52be445/linux/ubuntu/22.04/bin/update-alternatives-clang && \
	chmod +x update-alternatives-clang && \
	sed -i 's/sudo//g' update-alternatives-clang && \
	./update-alternatives-clang

# update cache for dynamic libraries
RUN ldconfig

# Cleanup package cache to reduce image size
RUN apt-get clean

#ENTRYPOINT ["/sbin/init"]
CMD ["/sbin/init"]
