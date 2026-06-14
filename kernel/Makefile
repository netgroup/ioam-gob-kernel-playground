
# force to use bash otherwise some built-in do not work
SHELL := /bin/bash

# Determine the number of processors
NUM_JOBS := $(shell nproc)
ARCH := $(shell uname -m)

.PHONY: config kbuild kmodule install

all: config kbuild install kmodule

config:
	@echo "Entering configs folder..."
	@if [ ! -f linux/.config ]; then \
		echo "Copying config file..."; \
		pushd configs && \
			cp -av kernel_618-rc1_net-next-dev-GOB_enabled.config ../linux/.config && \
		popd; \
		pushd linux && \
			make -j$(NUM_JOBS) olddefconfig && \
		popd; \
	else \
		echo "Config file already exists. Skipping copy."; \
	fi

kbuild:
	@echo "Building kernel with $(NUM_JOBS) parallel jobs..."
	cd linux && \
		make -j$(NUM_JOBS) C=1 W=1 2>&1 | tee output.log

install:
	@echo "Entering the tests/vm folder..."
	@if [ ! -f ../tests/vm/bzImage ]; then \
		echo "Linking kernel bzImage in VM folder.."; \
		pushd ../tests/vm && \
			ln -sv ../../kernel/linux/arch/$(ARCH)/boot/bzImage . && \
		popd; \
	else \
		echo "Kernel already soft-linked in VM folder. Skipping linking."; \
	fi

kmodule:
	@echo "Building out-of-tree kernel module with $(NUM_JOBS) parallel jobs..."
	cd modules && make all
