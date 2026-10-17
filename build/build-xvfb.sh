#!/bin/bash
# Build Xvfb and the X libraries that UBI 9 does not ship, installed under PREFIX.
# Orca's headless browser pages need an X display, and UBI has no X server package.
set -euo pipefail

prefix="${1:?Usage: build-xvfb.sh PREFIX}"
src=/tmp/x11-src
mkdir -p "$src"

X=https://www.x.org/releases/individual

fetch() {
  local url="$1" sha256="$2" archive
  archive="$src/$(basename "$url")"
  curl -fsSL -o "$archive" "$url"
  echo "$sha256  $archive" | sha256sum -c -
  tar -xf "$archive" -C "$src"
}

build_autotools() {
  local dir="$1"
  shift
  (cd "$src/$dir" &&
    ./configure --prefix="$prefix" --libdir="$prefix/lib" --disable-static "$@" &&
    make -j"$(nproc)" &&
    make install)
}

build_meson() {
  local dir="$1"
  shift
  (cd "$src/$dir" &&
    meson setup build --prefix="$prefix" --libdir=lib --buildtype=release "$@" &&
    ninja -C build install)
}

# The X.Org tarballs are signed by their release managers; these hashes are of the verified files.
fetch "$X/lib/xtrans-1.6.0.tar.xz" faafea166bf2451a173d9d593352940ec6404145c5d1da5c213423ce4d359e92
fetch https://www.cairographics.org/releases/pixman-0.42.2.tar.gz ea1480efada2fd948bc75366f7c349e1c96d3297d09a3fe62626e38e234a625e
fetch "$X/lib/libfontenc-1.1.9.tar.xz" 9d8392705cb10803d5fe1d27d236cbab3f664e26841ce01916bbbe430cf273e2
fetch "$X/lib/libXfont2-2.0.9.tar.xz" f042a370666815e7b941e9b7019024755bd1c6c2954afbfa515af378251799e2
fetch "$X/lib/libxkbfile-1.2.0.tar.xz" 7f71884e5faf56fb0e823f3848599cf9b5a9afce51c90982baeb64f635233ebf
fetch "$X/app/xkbcomp-1.5.0.tar.xz" 2ac31f26600776db6d9cd79b3fcd272263faebac7eb85fb2f33c7141b8486060
fetch "$X/xserver/xorg-server-21.1.25.tar.xz" 6ad4e3c7b59a309b32c92e5c15ce1267110f9e13f1ac78da62361a628da1a0eb

export PKG_CONFIG_PATH="$prefix/lib/pkgconfig:$prefix/share/pkgconfig"
# Resolve bundled libraries from the volume without LD_LIBRARY_PATH. DT_RPATH, unlike
# DT_RUNPATH, also applies to the dependencies of those libraries.
export LDFLAGS="-Wl,-rpath,$prefix/lib -Wl,--disable-new-dtags"

build_autotools xtrans-1.6.0
# pixman 0.42 is the last release that builds without meson 1.3, which UBI 9 lacks.
build_autotools pixman-0.42.2 --disable-gtk --disable-libpng
build_autotools libfontenc-1.1.9
build_autotools libXfont2-2.0.9 --disable-devel-docs
build_meson libxkbfile-1.2.0
# The release tarball includes the generated parser, so bison is not needed.
build_autotools xkbcomp-1.5.0 --with-xkb-config-root="$prefix/share/X11/xkb"
build_meson xorg-server-21.1.25 \
  -Dxorg=false -Dxephyr=false -Dxnest=false -Dxwin=false -Dxquartz=false -Dxvfb=true \
  -Dglamor=false -Dglx=false -Ddri1=false -Ddri2=false -Ddri3=false -Ddrm=false \
  -Dudev=false -Dudev_kms=false -Dsystemd_logind=false -Dhal=false -Dpciaccess=false \
  -Dxselinux=false -Dlibunwind=false -Dsecure-rpc=false -Dxdmcp=false -Dxdm-auth-1=false \
  -Dlisten_tcp=false -Ddocs=false -Ddevel-docs=false -Dsha1=libcrypto \
  -Dxkb_dir="$prefix/share/X11/xkb" -Dxkb_bin_dir="$prefix/bin" -Dxkb_output_dir=/tmp \
  -Ddefault_font_path=built-ins

# Keyboard layouts come from UBI's xkeyboard-config data package.
mkdir -p "$prefix/share/X11"
cp -r /usr/share/X11/xkb "$prefix/share/X11/"

for dir in xtrans-1.6.0 pixman-0.42.2 libfontenc-1.1.9 libXfont2-2.0.9 libxkbfile-1.2.0 xkbcomp-1.5.0 xorg-server-21.1.25; do
  install -D -m 644 "$src/$dir/COPYING" "$prefix/share/licenses/${dir%-*}/COPYING"
done

# Keep only what runs: drop headers, development files, and documentation.
rm -rf "$prefix/include" "$prefix/lib/pkgconfig" "$prefix/share/pkgconfig" \
  "$prefix/share/aclocal" "$prefix/share/doc" "$prefix/share/man" "${prefix:?}/var"
find "$prefix/lib" -name '*.la' -delete
rm -rf "$src"
