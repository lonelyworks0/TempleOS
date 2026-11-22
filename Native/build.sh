#!/usr/bin/env bash
# Build a single-file native TempleOS for this Linux machine.
# HolyC is compiled to the host CPU. QEMU is not used.
#
# On aarch64 the default output name is TempleOS-Linux-arm64-native.
# On x86_64 it is TempleOS-Linux-x64-native (a development build of the
# same runtime; the release asset is the aarch64 one).
#
# Usage: Native/build.sh [OUTPUT]
set -euo pipefail
export LC_ALL=C

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
aiw=$here/third_party/aiwnios

machine=$(uname -m)
case "$machine" in
  aarch64|arm64) default_name=TempleOS-Linux-arm64-native ;;
  x86_64) default_name=TempleOS-Linux-x64-native ;;
  *) echo "build.sh: unsupported machine $machine" >&2; exit 1 ;;
esac
out=$(realpath -m "${1:-$repo/out/$default_name}")

for tool in cmake patchelf zip go python3 pkg-config; do
  command -v "$tool" >/dev/null || { echo "build.sh: $tool is required" >&2; exit 1; }
done
pkg-config --exists sdl2 || { echo "build.sh: SDL2 development files are required" >&2; exit 1; }

cc=${CC:-cc}
echo "build.sh: compiler $($cc --version | head -1) on $machine"

build=$aiw/build
rm -rf "$build"
mkdir -p "$build"
cmake -S "$aiw" -B "$build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_HCRT=OFF \
  -DCMAKE_C_COMPILER="$cc" \
  -DCMAKE_ASM_FLAGS="-Wa,--noexecstack" \
  -DCMAKE_EXE_LINKER_FLAGS="-z noexecstack"
cmake --build "$build" -j"$(nproc)"

if [ ! -x "$aiw/aiwnios" ]; then
  echo "build.sh: cmake did not produce $aiw/aiwnios" >&2
  exit 1
fi

echo "build.sh: bootstrapping HCRT2.BIN (HolyC kernel and compiler)"
(cd "$aiw" && ./aiwnios -b)
if [ ! -f "$aiw/HCRT2.BIN" ]; then
  echo "build.sh: bootstrap did not write HCRT2.BIN" >&2
  exit 1
fi

work=$(mktemp -d)
stage=$(mktemp -d)
cleanup() { rm -rf "$work" "$stage" "$here/launcher/payload.zip"; }
trap cleanup EXIT

echo "build.sh: assembling the boot drive from this tree"
root=$work/Root
mkdir -p "$root/Src" "$root/Native"
# Hosted kernel/compiler/Adam. These are the sources the runtime executes.
# ACDefs.DATA is the optional English dictionary (tens of megabytes) and is
# not required to boot.
cp -a "$aiw/Src/." "$root/Src/"
rm -f "$root/Src/ACDefs.DATA"
# This repository's own sources, mounted where TempleOS programs look.
for dir in Adam Apps Compiler Demo Doc Kernel Misc 0000Boot; do
  cp -a "$repo/$dir" "$root/$dir"
done
for f in HomeKeyPlugIns.HC HomeLocalize.HC HomeSys.HC HomeWrappers.HC \
         MakeHome.HC Once.HC StartOS.HC PersonalMenu.DD PersonalNotes.DD \
         ReadMe.TXT; do
  cp -a "$repo/$f" "$root/$f"
done
cp -a "$here/bench.HC" "$root/Native/Bench.HC"
# Drop editor and build debris if any slipped in.
find "$root" -name '*.orig' -o -name '*~' -delete || true

cp -a "$aiw/aiwnios" "$work/aiwnios"
cp -a "$aiw/HCRT2.BIN" "$work/HCRT2.BIN"
chmod u+w "$work/aiwnios"
# The packed bytes are this ELF plus the drive image. The rpath has to be
# set before the image is appended, or patchelf will not see a normal ELF.
patchelf --set-rpath '$ORIGIN/../lib' "$work/aiwnios"

cat > "$work/pack.HC" << 'EOF'
AiwniosPack("/Packed.bin","", "/Root");
Exit;
EOF

echo "build.sh: packing the runtime and drive into one ELF"
(cd "$work" && ./aiwnios -t "$work" -c pack.HC)
if [ ! -f "$work/Packed.bin" ]; then
  echo "build.sh: pack did not write Packed.bin" >&2
  exit 1
fi
# AiwniosPack's signature lives in the last 16 bytes. Reject a truncated file.
tail_sig=$(tail -c 16 "$work/Packed.bin" | head -c 8 || true)
if [ "$tail_sig" != "AiwnPack" ]; then
  echo "build.sh: Packed.bin is missing the AiwnPack trailer" >&2
  exit 1
fi

rt=$stage/runtime
mkdir -p "$rt/bin" "$rt/lib" "$rt/share/doc"
cp -a "$work/Packed.bin" "$rt/bin/templeos"
chmod 755 "$rt/bin/templeos"

is_host_lib() {
  case "$1" in
    libc.so.*|libm.so.*|libdl.so.*|libpthread.so.*|librt.so.*|libresolv.so.*|\
    libutil.so.*|libnsl.so.*|libnss_*.so.*|ld-linux*.so.*|\
    libGL.so.*|libGLX.so.*|libGLdispatch.so.*|libEGL.so.*|libOpenGL.so.*|\
    libvulkan.so.*|libglapi.so.*|libGLESv2.so.*|libGLESv1_CM.so.*)
      return 0
      ;;
  esac
  return 1
}

ldd_paths() {
  ldd "$1" 2>/dev/null | awk '
    /=>/ && $3 ~ /^\// { print $3 }
    $1 ~ /^\// { print $1 }
  ' || true
}

echo "build.sh: bundling shared libraries (SDL2 and its dependencies)"
added=1
while [ "$added" = 1 ]; do
  added=0
  while IFS= read -r -d '' f; do
    while read -r dep; do
      [ -n "$dep" ] && [ -f "$dep" ] || continue
      base=$(basename "$dep")
      if is_host_lib "$base"; then
        continue
      fi
      soname=$(readelf -d "$dep" 2>/dev/null | awk -F'[][]' '/SONAME/ {print $2; exit}')
      [ -n "$soname" ] || soname=$base
      if [ ! -e "$rt/lib/$soname" ]; then
        cp -L "$dep" "$rt/lib/$soname"
        chmod u+w "$rt/lib/$soname"
        if command -v dpkg >/dev/null; then
          dpkg -S "$dep" 2>/dev/null | head -1 >> "$rt/share/doc/bundled-from.txt" \
            || echo "$dep" >> "$rt/share/doc/bundled-from.txt"
        fi
        added=1
      fi
    done < <(ldd_paths "$f")
  done < <(find "$rt/bin" "$rt/lib" -type f -print0)
done

shopt -s nullglob
for so in "$rt/lib/"*.so*; do
  patchelf --set-rpath '$ORIGIN' "$so"
done
shopt -u nullglob

verify_closure() {
  local f=$1 line path base real
  while IFS= read -r line; do
    if [[ "$line" == *"not found"* ]]; then
      echo "build.sh: missing dependency for $f: $line" >&2
      return 1
    fi
    path=$(awk '/=>/ { print $3 }' <<<"$line")
    [ -n "${path:-}" ] && [ "$path" != "not" ] || continue
    real=$(realpath "$path")
    case "$real" in
      "$rt/lib/"*) continue ;;
    esac
    base=$(basename "$real")
    if ! is_host_lib "$base"; then
      echo "build.sh: $f depends on $path, outside the bundle" >&2
      return 1
    fi
  done < <(LD_LIBRARY_PATH="$rt/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ldd "$f")
}
verify_closure "$rt/bin/templeos"
for so in "$rt"/lib/*.so*; do
  [ -f "$so" ] || continue
  verify_closure "$so"
done

doc=$rt/share/doc
cp -a "$aiw/LICENSE" "$doc/AIWNIOS-LICENSE"
cp -a "$aiw/vendor/argtable3/LICENSE" "$doc/argtable3-LICENSE"
cp -a "$aiw/vendor/isocline/LICENSE" "$doc/isocline-LICENSE"
if [ -f "$doc/bundled-from.txt" ]; then
  sort -u "$doc/bundled-from.txt" -o "$doc/bundled-from.txt"
fi
{
  echo "TempleOS native runtime"
  echo
  echo "The HolyC compiler and hosted runtime are Aiwnios, by nrootconauto"
  echo "and contributors, used under the zlib license (AIWNIOS-LICENSE)."
  echo "Upstream: https://github.com/aiwnios/Aiwnios"
  echo "Vendored commit: $(cat "$here/third_party/UPSTREAM_COMMIT" 2>/dev/null || echo unknown)"
  echo
  echo "argtable3 is BSD-3-clause (argtable3-LICENSE)."
  echo "isocline is MIT (isocline-LICENSE)."
  echo "SDL2, bundled as a shared library from the build machine, is"
  echo "zlib-licensed. Source: https://github.com/libsdl-org/SDL"
  echo
  echo "TempleOS itself is public domain."
  echo
  if command -v dpkg-query >/dev/null; then
    dpkg-query -W -f '${Package} ${Version}\n' libsdl2-2.0-0 2>/dev/null || true
  fi
} > "$doc/NOTICE"
if [ -f /usr/share/doc/libsdl2/copyright ]; then
  cp /usr/share/doc/libsdl2/copyright "$doc/sdl2-copyright"
fi

echo "build.sh: embedding payload"
payload=$here/launcher/payload.zip
(cd "$stage" && zip -qr -9 "$payload" runtime)
mkdir -p "$(dirname "$out")"
(
  cd "$here/launcher"
  CGO_ENABLED=0 go build -tags payload -trimpath -ldflags "-s -w" -o "$out" .
)
chmod +x "$out"
echo "build.sh: wrote $out"
du -h "$out"
file "$out"
