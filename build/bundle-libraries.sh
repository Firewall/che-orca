#!/bin/bash
# Copy the UBI shared libraries that the given programs and libraries load into LIBDIR,
# with the licenses of the packages that own them.
# Usage: bundle-libraries.sh LIBDIR LICENSEDIR PATH...
# Each PATH is an ELF file or a directory scanned for ELF files. Pass libraries that are
# loaded with dlopen() explicitly, because ldd cannot see them.
set -euo pipefail

libdir="$1"
licensedir="$2"
shift 2

# Every glibc-based workspace image provides these, and they must match its glibc.
is_system_library() {
  case "$1" in
    ld-linux*.so* | libc.so.* | libm.so.* | libmvec.so.* | libpthread.so.* | libdl.so.* | \
      librt.so.* | libresolv.so.* | libutil.so.* | libanl.so.* | libnss_*.so.* | \
      libthread_db.so.* | libBrokenLocale.so.* | libgcc_s.so.* | libstdc++.so.*)
      return 0 ;;
  esac
  return 1
}

is_elf() {
  [ "$(head -c 4 "$1" 2>/dev/null | od -An -c | tr -d ' ')" = '177ELF' ]
}

roots=()
for path in "$@"; do
  if [ -d "$path" ]; then
    while IFS= read -r -d '' file; do
      is_elf "$file" && roots+=("$file")
    done < <(find "$path" -type f -print0)
  else
    # Keep the soname path, such as libgtk-3.so.0, which is the name the loader looks up.
    roots+=("$path")
  fi
done

declare -A needed=()
missing=0
for root in "${roots[@]}"; do
  # Explicit roots outside the bundle, such as dlopen()ed libraries, are bundled themselves.
  case "$root" in
    "$libdir"/* | /orca/*) ;;
    *) needed["$root"]=1 ;;
  esac
  while read -r name _ resolved _; do
    if [ "$resolved" = "not" ]; then
      echo "$root: $name not found" >&2
      missing=1
    elif [ -n "$resolved" ] && [ "${resolved#/}" != "$resolved" ]; then
      needed["$resolved"]=1
    fi
  done < <(ldd "$root" 2>/dev/null | grep '=>' || true)
done
[ "$missing" -eq 0 ] || exit 1

mkdir -p "$libdir" "$licensedir"
for library in "${!needed[@]}"; do
  # Orca's own libraries already sit next to the files that load them.
  case "$library" in "$libdir"/* | /orca/*) continue ;; esac
  name="$(basename "$library")"
  is_system_library "$name" && continue
  cp -L "$library" "$libdir/$name"
  package="$(rpm -qf --qf '%{NAME}\n' "$(readlink -f "$library")" 2>/dev/null | head -1)" || continue
  if [ -d "/usr/share/licenses/$package" ] && [ ! -d "$licensedir/$package" ]; then
    cp -r "/usr/share/licenses/$package" "$licensedir/$package"
  fi
done
