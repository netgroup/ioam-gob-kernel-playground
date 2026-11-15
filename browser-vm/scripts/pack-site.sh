#!/bin/bash
# Runs in the qemu-wasm build container (it has emscripten, python3, npm).
# Packs kernel + disk + BIOS into one emscripten package, compresses it
# with gzip, splits it into parts below the 100 MiB limit of a git push,
# and assembles the web site in /work/site.
set -o pipefail

die() { echo "pack-site: $*" >&2; exit 1; }

Q=/work/build/qemu
SITE=/work/site
PART_SIZE=${PART_SIZE:-50M}
T=/work/build/pack

# $SITE is a mount point: empty it, do not remove it.
rm -rf $T && find $SITE -mindepth 1 -delete && mkdir -p $T/pack $SITE/data $SITE/vendor ||
	die "cannot prepare $SITE"
cp /work/build/kernel/arch/x86/boot/bzImage /work/build/guest/disk.ext4 $Q/*.bin $T/pack/ ||
	die "missing input: run the kernel, qemu and guest steps first"

cd $T || die "no $T"
/emsdk/upstream/emscripten/tools/file_packager.py qemu-system-x86_64.data \
	--preload $T/pack@/pack > $SITE/load.js 2> file_packager.log || { cat file_packager.log; die "file_packager failed"; }
SIZE=$(stat -c %s qemu-system-x86_64.data)
gzip -9 -n -c qemu-system-x86_64.data > qemu.data.gz || die "gzip failed"
GZ=$(stat -c %s qemu.data.gz)
split -b "$PART_SIZE" -d -a 3 qemu.data.gz $SITE/data/qemu.data.gz. || die "split failed"
python3 - "$SIZE" "$GZ" $SITE/data <<'PY' || die "manifest failed"
import json, os, sys
size, gz, d = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
parts = sorted(f for f in os.listdir(d) if f.startswith('qemu.data.gz.'))
json.dump({'size': size, 'gz_size': gz, 'parts': parts}, open(os.path.join(d, 'manifest.json'), 'w'))
print('package %d bytes, gzip %d bytes, %d parts' % (size, gz, len(parts)))
PY

cp $Q/qemu-system-x86_64 $SITE/out.js || die "copy failed"
cp $Q/qemu-system-x86_64.wasm $Q/qemu-system-x86_64.worker.js $SITE/ || die "copy failed"
cp /bvm/web/index.html /bvm/web/module.js $SITE/ || die "copy of the page failed"

# Third-party browser code, at fixed versions.
mkdir -p $T/npm && cd $T/npm || die "no npm dir"
npm pack -q "xterm@$XTERM_VERSION" "xterm-pty@$XTERM_PTY_VERSION" \
	"xterm-addon-fit@$XTERM_FIT_VERSION" \
	"coi-serviceworker@$COI_VERSION" > /dev/null 2>&1 || die "npm pack failed"
for t in *.tgz; do mkdir -p "x/$t" && tar -xzf "$t" -C "x/$t" || die "untar $t failed"; done
cp "x/xterm-$XTERM_VERSION.tgz/package/lib/xterm.js" \
	"x/xterm-$XTERM_VERSION.tgz/package/css/xterm.css" $SITE/vendor/ || die "xterm missing"
cp "x/xterm-pty-$XTERM_PTY_VERSION.tgz/package/index.js" $SITE/vendor/xterm-pty.js || die "xterm-pty missing"
cp "x/xterm-addon-fit-$XTERM_FIT_VERSION.tgz/package/lib/xterm-addon-fit.js" $SITE/vendor/ ||
	die "xterm-addon-fit missing"
cp "x/coi-serviceworker-$COI_VERSION.tgz/package/coi-serviceworker.js" $SITE/ || die "coi-serviceworker missing"
cp /work/src/SOURCES.txt $SITE/SOURCES.txt
# GitHub Pages: serve the files as they are, no Jekyll build.
touch $SITE/.nojekyll

rm -rf $T
cd $SITE && find . -type f -printf '%10s  %p\n' | sort -k2
echo "site total: $(du -sb $SITE | cut -f1) bytes"
