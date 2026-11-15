#!/usr/bin/env python3
"""Adapt the qemu-wasm build Dockerfile so that podman 4.9 can build it.

Usage: adapt-qemu-dockerfile.py <upstream Dockerfile> <output dir>
                                <emsdk digest> <ubuntu snapshot> <xterm 4 version>

Changes, each one checked so that an upstream change is noticed:
  1. FROM emscripten/... becomes FROM docker.io/emscripten/... (podman wants
     fully qualified image names when no search registry is configured).
  2. zlib is downloaded from the GitHub release: zlib.net keeps only the
     latest release, and zlib-1.3.1.tar.xz is gone from it.
  3. The nested heredocs (RUN <<EOF with cat <<'EOT' inside) become files
     plus COPY: the buildah of podman 4.9 fails on them.
  4. COPY --link becomes COPY: buildah does not support --link.
For a reproducible build:
  5. the emsdk image is pinned by digest;
  6. apt uses snapshot.ubuntu.com at a fixed date;
  7. npm installs xterm at a fixed version (xterm-pty asks for ^4.16.0).
"""
import os
import re
import sys


def main():
    src, out, emsdk_digest, snapshot, xterm4 = sys.argv[1:6]
    text = open(src).read()

    text, n = re.subn(r'^FROM emscripten/', 'FROM docker.io/emscripten/', text, flags=re.M)
    if n == 0:
        sys.exit('adapt: no "FROM emscripten/" line found')

    old = 'https://zlib.net/zlib-$ZLIB_VERSION.tar.xz'
    new = 'https://github.com/madler/zlib/releases/download/v$ZLIB_VERSION/zlib-$ZLIB_VERSION.tar.xz'
    if text.count(old) != 1:
        sys.exit('adapt: zlib URL not found')
    text = text.replace(old, new)

    pat = re.compile(r"RUN <<EOF\ncat <<'EOT' > (\S+)\n(.*?)\nEOT\nEOF\n", re.S)
    count = 0

    def heredoc(m):
        nonlocal count
        count += 1
        dest, body = m.group(1), m.group(2)
        name = 'heredoc-%d-%s' % (count, os.path.basename(dest))
        with open(os.path.join(out, name), 'w') as f:
            f.write(body + '\n')
        return 'COPY %s %s\n' % (name, dest)

    text = pat.sub(heredoc, text)
    if count != 3:
        sys.exit('adapt: expected 3 nested heredocs, found %d' % count)
    if '<<' in text:
        sys.exit('adapt: a heredoc is left')

    text, n = re.subn(r'^COPY --link ', 'COPY ', text, flags=re.M)
    if n == 0:
        sys.exit('adapt: no "COPY --link" found')

    old = 'FROM docker.io/emscripten/emsdk:$EMSDK_VERSION_QEMU AS build-base'
    if text.count(old) != 1:
        sys.exit('adapt: emsdk FROM line not found')
    text = text.replace(old, 'FROM docker.io/emscripten/emsdk:$EMSDK_VERSION_QEMU@%s AS build-base'
                        % emsdk_digest)

    old = 'RUN apt-get update && apt-get install -y \\\n'
    if text.count(old) != 1:
        sys.exit('adapt: apt-get line of build-base not found')
    snap = ("RUN sed -i -E 's#http://(archive|security)\\.ubuntu\\.com/ubuntu/?#"
            "https://snapshot.ubuntu.com/ubuntu/%s/#' /etc/apt/sources.list && \\\n"
            "    ! grep -E '^deb http://' /etc/apt/sources.list\n" % snapshot)
    text = text.replace(old, snap + old)

    old = 'RUN npm i xterm-pty@v0.10.1'
    if text.count(old) != 1:
        sys.exit('adapt: npm line not found')
    text = text.replace(old, 'RUN npm i xterm-pty@0.10.1 xterm@%s' % xterm4)

    with open(os.path.join(out, 'Dockerfile'), 'w') as f:
        f.write(text)
    print('adapt: Dockerfile written to %s' % out)


if __name__ == '__main__':
    main()
