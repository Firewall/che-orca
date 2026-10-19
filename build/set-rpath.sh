#!/bin/bash
# Point programs at the bundled libraries without LD_LIBRARY_PATH, which would leak into the
# terminals Orca starts.
# Usage: set-rpath.sh LIBDIR EXECUTABLE...
# Each executable gets LIBDIR as DT_RPATH, which also applies to every library it loads unless
# that library declares its own search path. Bundled libraries that do get LIBDIR instead.
set -euo pipefail

libdir="$1"
shift

for executable in "$@"; do
  rpath="$(patchelf --print-rpath "$executable")"
  patchelf --force-rpath --set-rpath "${rpath:+$rpath:}$libdir" "$executable"
done

for library in "$libdir"/*.so*; do
  rpath="$(patchelf --print-rpath "$library")"
  if [ -n "$rpath" ] && [ "$rpath" != "$libdir" ]; then
    patchelf --force-rpath --set-rpath "$libdir" "$library"
  fi
done
