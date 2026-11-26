#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
#
# Build what the IOAM GOB v3 lab on Kathara needs, from a commit of the
# playground, and test it. The kernel, the image and the program are built
# with Docker, where Kathara looks for the image. See README.md.
#
# Usage: ./build.sh [step...]          (no step: all)
#
#   sources  export from the playground commit the GOB kernel tree
#            (kernel/linux) with the bpf_printk patch of kernel/, iproute2
#            and the GOB program (src/c), at the commits it records
#   kernel   the GOB UML kernel, with uml-kernel/build.sh of kathara-uml-lab:
#            its base, trace and net fragments and kernel/gob.fragment
#   image    the image of the GOB nodes, with the kernel in it (long the
#            first time: it builds LLVM), ghcr.io/netgroup/kathara-uml-gob:<tag>,
#            where the tag is the release and the commit of the kernel;
#            lab/lab.conf must name that image
#   program  lab/shared/ioam6_gob_recv.o, the GOB program, against the BTF
#            of the kernel of the image, in a container of the image
#   all      the four steps above, in this order
#   test     tests/check-gob.sh, where Kathara and the image are (not part
#            of all)
#   publish  push the image to ghcr.io, after docker login ghcr.io, as an OCI
#            index with its platform and a description for the package
#            page: Kathara reads the platforms of an image before it pulls
#            it, and Docker gives none for an OCI image manifest (not part
#            of all)
#   clean    remove $WORK (not part of all)
#
# Everything is written under $WORK (default: kathara/out), but the
# program, which goes to lab/shared. The Kathara of kathara-uml-lab/kathara
# runs the lab. Only sources needs the git trees of the playground: the
# other steps can run on a copy of kathara/ with its out.

HERE=$(cd "$(dirname "$0")" && pwd)

# Configuration (environment variables).
REPO=${REPO:-$(cd "$HERE/.." && pwd)}	# the playground
REF=${REF:-HEAD}			# commit to build from
WORK=${WORK:-$HERE/out}			# everything built goes here
CLANG_JOBS=${CLANG_JOBS:-8}		# jobs of the LLVM build

LAB=$HERE/kathara-uml-lab
IMAGE_REPO=ghcr.io/netgroup/kathara-uml-gob
PATCH=$HERE/kernel/0001-bpf-Build-bpf_trace_printk-without-BPF_EVENTS.patch

die()
{
	echo "build.sh: $*" >&2
	exit 1
}

step()
{
	echo
	echo "=== $(date +%T) $*"
}

# The commit that the playground commit records for a submodule.
submodule_sha()
{
	git -C "$REPO" ls-tree "$REF_SHA" "$1" | awk '$2 == "commit" { print $3 }'
}

# Exports into dest the submodule at path, at the commit of the playground
# commit, or only the paths given of it.
export_submodule()
{
	local path=$1 dest=$2 sha

	shift 2
	sha=$(submodule_sha "$path")
	if [ -z "$sha" ]; then
		die "$path is not a submodule at $REF"
	fi
	if [ "$(git -C "$REPO/$path" rev-parse --show-toplevel 2>/dev/null)" != "$(cd "$REPO/$path" && pwd -P)" ] ||
		! git -C "$REPO/$path" cat-file -e "$sha^{commit}" 2>/dev/null; then
		die "$path: commit $sha missing, run: git -C $REPO submodule update --init $path, or set REPO"
	fi
	rm -rf "$dest"
	mkdir -p "$dest" || die "cannot create $dest"
	git -C "$REPO/$path" archive "$sha" "$@" | tar -x -C "$dest" || die "$path: archive failed"
	echo "$path $sha $(git -C "$REPO/$path" log -1 --format=%s "$sha")"
}

do_sources()
{
	step "sources (REF=$REF)"
	REF_SHA=$(git -C "$REPO" rev-parse --verify "$REF^{commit}") || die "bad REF $REF"
	{
		echo "playground $REF_SHA $(git -C "$REPO" log -1 --format=%s "$REF_SHA")"
		export_submodule kernel/linux "$WORK/src/linux"
		export_submodule iproute2 "$WORK/image/iproute2"
		# What bpftool and the libbpf headers need of the kernel tree.
		export_submodule kernel/linux "$WORK/image/linux" tools kernel/bpf include scripts >/dev/null
	} > "$WORK/SOURCES.txt" || die "sources failed"
	patch -s -d "$WORK/src/linux" -p1 < "$PATCH" || die "the bpf_printk patch does not apply"
	echo "patch $(basename "$PATCH")" >> "$WORK/SOURCES.txt"
	rm -rf "$WORK/src/c"
	mkdir -p "$WORK/src/c" || die "cannot create $WORK/src/c"
	git -C "$REPO" archive "$REF_SHA" src/c/ioam6_gob_recv.bpf.c | tar -x -C "$WORK/src/c" --strip-components=2 ||
		die "the GOB program: archive failed"
	cat "$WORK/SOURCES.txt"
}

do_kernel()
{
	step "kernel"
	bash "$LAB/uml-kernel/build.sh" --src "$WORK/src/linux" \
		--fragment "$LAB/uml-kernel/trace.fragment" --fragment "$LAB/uml-kernel/net.fragment" \
		--fragment "$HERE/kernel/gob.fragment" --out "$WORK/kernel" > "$WORK/logs/kernel.log" 2>&1 ||
		{ tail -20 "$WORK/logs/kernel.log"; die "kernel failed, see $WORK/logs/kernel.log"; }
	# build.sh does not know where a tree given with --src comes from.
	sed -i "s|^source: .*|source: $(grep '^kernel/linux ' "$WORK/SOURCES.txt" | cut -d' ' -f2), $(basename "$PATCH")|" \
		"$WORK/kernel/BUILD-INFO"
	cat "$WORK/kernel/BUILD-INFO"
}

# The value of a line "key: value" of the BUILD-INFO of the kernel.
build_info()
{
	sed -n "s/^$1: //p" "$WORK/kernel/BUILD-INFO"
}

# The tag of the image: the release of the kernel in it and the first 12
# characters of its commit, as 6.18.0-rc1-494d8b67e580.
image_tag()
{
	local release source

	if [ ! -f "$WORK/kernel/BUILD-INFO" ]; then
		die "no kernel in $WORK/kernel: build.sh kernel"
	fi
	release=$(build_info release)
	source=$(build_info source)
	echo "$release-${source:0:12}"
}

# The images that lab/lab.conf gives its GOB nodes, one per line.
lab_images()
{
	sed -n 's/^n[0-9]*\[image\]="\(.*\)"$/\1/p' "$HERE/lab/lab.conf" | sort -u
}

do_image()
{
	local tag image revision

	tag=$(image_tag) || exit 1
	image=$IMAGE_REPO:$tag
	step "image $image ($CLANG_JOBS jobs for LLVM)"
	# The lab runs on this image only if lab.conf names it.
	if [ "$(lab_images)" != "$image" ]; then
		die "lab/lab.conf names $(lab_images | tr '\n' ' ')instead of $image: set n1 to n5[image] to it"
	fi
	revision=$(awk '$1 == "playground" { print $2 }' "$WORK/SOURCES.txt")
	mkdir -p "$WORK/image/kernel" || die "cannot create $WORK/image/kernel"
	cp "$WORK/kernel/linux" "$WORK/image/kernel/linux" || die "cannot copy the kernel into the image context"
	docker build -t "$image" --build-arg CLANG_JOBS="$CLANG_JOBS" --build-arg VERSION="$tag" \
		--build-arg REVISION="$revision" -f "$HERE/image/Dockerfile" "$WORK/image" > "$WORK/logs/image.log" 2>&1 ||
		{ tail -20 "$WORK/logs/image.log"; die "image failed, see $WORK/logs/image.log"; }
	tail -3 "$WORK/logs/image.log"
}

do_program()
{
	local image

	image=$IMAGE_REPO:$(image_tag) || exit 1
	step "program"
	# As the user, so that the files written in lab/shared are the user's.
	# shellcheck disable=SC2016 # expanded in the container
	docker run --rm --user "$(id -u):$(id -g)" -v "$WORK/src/c:/src:ro" -v "$HERE/lab/shared:/shared" "$image" \
		bash -c '
		bpftool btf dump file /usr/lib/kathara-uml/linux format c > /tmp/vmlinux.h &&
		clang -O2 -g -target bpf -I/tmp -c /src/ioam6_gob_recv.bpf.c -o /tmp/ioam6_gob_recv.bpf.o &&
		bpftool gen object /shared/ioam6_gob_recv.o /tmp/ioam6_gob_recv.bpf.o &&
		cp /src/ioam6_gob_recv.bpf.c /shared/' || die "program failed"
	ls -l "$HERE/lab/shared/ioam6_gob_recv.o"
}

# The description of the image on its package page.
image_description()
{
	local tag=$1

	echo "IOAM GOB v3 node for Kathara: kathara/base with the GOB UML kernel ${tag%-*} (${tag##*-}), which Kathara" \
		"runs the node on, the iproute2 of GOB, bpftool and a BPF-only clang." \
		"The lab is kathara/ in netgroup/ioam-gob-kernel-playground."
}

do_publish()
{
	local tag image digest

	tag=$(image_tag) || exit 1
	image=$IMAGE_REPO:$tag
	step "publish $image"
	docker push "$image" > "$WORK/logs/publish.log" 2>&1 ||
		{ tail -5 "$WORK/logs/publish.log"; die "push failed (docker login ghcr.io first?), see $WORK/logs/publish.log"; }
	digest=$(sed -n 's/.*: digest: \(sha256:[0-9a-f]*\) size.*/\1/p' "$WORK/logs/publish.log" | tail -1)
	if [ -z "$digest" ]; then
		die "no digest in the output of the push, see $WORK/logs/publish.log"
	fi
	# The tag becomes an index of the manifest just pushed.
	docker buildx imagetools create -t "$image" \
		--annotation "index:org.opencontainers.image.description=$(image_description "$tag")" \
		"$IMAGE_REPO@$digest" >> "$WORK/logs/publish.log" 2>&1 ||
		{ tail -5 "$WORK/logs/publish.log"; die "the index failed, see $WORK/logs/publish.log"; }
	echo "$image: index of $digest"
}

do_test()
{
	step "test"
	bash "$HERE/tests/check-gob.sh"
}

do_clean()
{
	step "clean"
	case "$WORK" in
	/ | "$HOME" | "$REPO" | "$HERE")
		die "WORK=$WORK: will not remove it"
		;;
	esac
	rm -rf "$WORK" || die "cannot remove $WORK"
}

if [ ! -f "$LAB/uml-kernel/build.sh" ]; then
	die "no kathara-uml-lab: git -C $REPO submodule update --init --recursive kathara/kathara-uml-lab"
fi
mkdir -p "$WORK/logs" "$WORK/src" "$WORK/image" || die "cannot create $WORK"

steps=("$@")
if [ ${#steps[@]} = 0 ] || [ "${steps[*]}" = all ]; then
	steps=(sources kernel image program)
fi
for s in "${steps[@]}"; do
	case "$s" in
	sources | kernel | image | program | test | publish | clean)
		"do_$s"
		;;
	*)
		die "unknown step $s (see the top of $0)"
		;;
	esac
done
