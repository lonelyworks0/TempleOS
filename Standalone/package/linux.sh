#!/usr/bin/env bash
# Build a single-file TempleOS Linux executable: the launcher with a private
# QEMU and the installed TempleOS disk embedded. Run on Linux with
# qemu-system-x86, qemu-system-gui, patchelf, zip, xvfb and Go on PATH.
# Builds for the host CPU (x86_64 or aarch64).
#
# Usage: linux.sh TempleOS.qcow2 OUT
set -euo pipefail
export LC_ALL=C

disk=$(realpath "$1")
out=$(realpath -m "$2")
here=$(cd "$(dirname "$0")/.." && pwd)
for tool in qemu-system-x86_64 patchelf zip go xvfb-run readelf; do
  command -v "$tool" >/dev/null || { echo "linux.sh: $tool is required" >&2; exit 1; }
done

stage=$(mktemp -d)
payload=$here/launcher/payload.zip
cleanup() { rm -rf "$stage"; rm -f "$payload"; }
trap cleanup EXIT
rt=$stage/runtime
mkdir -p "$rt/bin" "$rt/lib/qemu" "$rt/lib/gio-modules" "$rt/share/qemu" "$rt/share/doc"
# Keep the empty GIO module dir in the zip. An empty directory is how the
# launcher stops bundled libgio from loading the host's modules.
touch "$rt/lib/gio-modules/.keep"

cp "$(command -v qemu-system-x86_64)" "$rt/bin/qemu-system-x86_64"
chmod u+w "$rt/bin/qemu-system-x86_64"

# Display, audio and the TCG accelerator are loadable modules. Copy only
# the ones this app uses so GTK and the other front ends stay out.
moddir=""
for d in /usr/lib/*/qemu /usr/lib/qemu; do
  if [ -d "$d" ] && compgen -G "$d/*.so" >/dev/null; then
    moddir=$d
    break
  fi
done
if [ -n "$moddir" ]; then
  shopt -s nullglob
  for mod in "$moddir"/accel-tcg-*.so "$moddir"/ui-sdl.so \
             "$moddir"/ui-opengl.so "$moddir"/audio-sdl.so; do
    cp -a "$mod" "$rt/lib/qemu/"
    chmod u+w "$rt/lib/qemu/$(basename "$mod")"
  done
  shopt -u nullglob
fi

# Libraries the dynamic linker must take from the host: glibc, and the
# OpenGL driver, which has to match the running machine.
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

echo "linux.sh: copying QEMU libraries"
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

echo "linux.sh: setting library paths"
patchelf --set-rpath '$ORIGIN/../lib' "$rt/bin/qemu-system-x86_64"
shopt -s nullglob
for so in "$rt/lib/"*.so*; do
  patchelf --set-rpath '$ORIGIN' "$so"
done
for so in "$rt/lib/qemu/"*.so; do
  patchelf --set-rpath '$ORIGIN/..' "$so"
done
shopt -u nullglob

verify_closure() {
  local f=$1 line path base
  while IFS= read -r line; do
    if [[ "$line" == *"not found"* ]]; then
      echo "linux.sh: missing dependency for $f: $line" >&2
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
      echo "linux.sh: $f depends on $path, outside the bundle" >&2
      return 1
    fi
  done < <(ldd "$f")
}
verify_closure "$rt/bin/qemu-system-x86_64"
for so in "$rt"/lib/*.so* "$rt"/lib/qemu/*.so; do
  [ -f "$so" ] || continue
  verify_closure "$so"
done

copy_fw() {
  local name=$1 d
  for d in /usr/share/qemu /usr/share/seabios; do
    if [ -f "$d/$name" ]; then
      cp "$d/$name" "$rt/share/qemu/$name"
      return 0
    fi
  done
  return 1
}
for fw in bios.bin bios-256k.bin vgabios-stdvga.bin kvmvapic.bin \
          linuxboot.bin linuxboot_dma.bin multiboot.bin multiboot_dma.bin \
          pvh.bin; do
  copy_fw "$fw" || true
done
for fw in bios-256k.bin vgabios-stdvga.bin; do
  if [ ! -f "$rt/share/qemu/$fw" ]; then
    echo "linux.sh: missing firmware $fw (looked in /usr/share/qemu and /usr/share/seabios)" >&2
    exit 1
  fi
done
if [ -d /usr/share/qemu/keymaps ]; then
  cp -a /usr/share/qemu/keymaps "$rt/share/qemu/"
fi

doc=$rt/share/doc
{
  echo "This runtime contains unmodified binaries of QEMU and the shared"
  echo "libraries it links against, copied from the OS that built it."
  echo "QEMU is free software under the GNU General Public License, version 2."
  echo "Source code: https://www.qemu.org/download/ and https://gitlab.com/qemu-project/qemu"
  echo
  echo "The other libraries keep their own licenses. glib is LGPL-2.1."
  echo "SDL2 is available under the zlib license. SeaBIOS, the PC firmware"
  echo "QEMU runs, is LGPL."
  echo
  echo "On Ubuntu, the matching source is the source package for the version"
  echo "recorded below, for QEMU and for each library package named in"
  echo "bundled-from.txt:"
  echo "  apt-get source qemu"
  echo
  qemu-system-x86_64 --version || true
  echo
  if command -v dpkg-query >/dev/null; then
    dpkg-query -W -f '${Package} ${Version}\n' \
      qemu-system-x86 qemu-system-gui qemu-system-common qemu-system-data seabios \
      2>/dev/null || true
  fi
} > "$doc/QEMU-SOURCE.txt"
if [ -f "$doc/bundled-from.txt" ]; then
  sort -u "$doc/bundled-from.txt" -o "$doc/bundled-from.txt"
fi
[ -f /usr/share/common-licenses/GPL-2 ] && cp /usr/share/common-licenses/GPL-2 "$doc/GPL-2"
[ -f /usr/share/doc/qemu-system-x86/copyright ] && cp /usr/share/doc/qemu-system-x86/copyright "$doc/qemu-copyright.txt"
[ -f /usr/share/doc/seabios/copyright ] && cp /usr/share/doc/seabios/copyright "$doc/seabios-copyright.txt"

echo "linux.sh: checking the private QEMU"
# No LD_LIBRARY_PATH: the binaries have to find their libraries through
# the rpath just set. Hide the distro modules and firmware so a missing
# file cannot be papered over by the system copy.
empty=$(mktemp -d)
iso_rc=0
unshare_cmd=(unshare --user --map-root-user --mount)
if ! unshare --user --map-root-user --mount true 2>/dev/null; then
  unshare_cmd=(sudo unshare --mount)
fi
"${unshare_cmd[@]}" bash -c '
set -euo pipefail
empty=$1 moddir=$2 rt=$3 qemu=$4
if [ -n "$moddir" ]; then
  mount --bind "$empty" "$moddir"
fi
if [ -d /usr/share/seabios ]; then mount --bind "$empty" /usr/share/seabios; fi
if [ -d /usr/share/qemu ]; then mount --bind "$empty" /usr/share/qemu; fi
export QEMU_MODULE_DIR="$rt/lib/qemu"
export GIO_MODULE_DIR="$rt/lib/gio-modules"
unset LD_LIBRARY_PATH
help=$("$qemu" -display help 2>&1 || true)
echo "$help" | grep -qw sdl || { echo "$help" >&2; echo "linux.sh: private QEMU has no sdl display" >&2; exit 1; }
audio=$("$qemu" -audiodev help 2>&1 || true)
echo "$audio" | grep -qw sdl || { echo "$audio" >&2; echo "linux.sh: private QEMU has no sdl audio" >&2; exit 1; }
set +e
timeout 8s "$qemu" -L "$rt/share/qemu" -machine pc -m 32 -accel tcg \
  -display none -vga std -nodefaults -serial null -monitor null >/tmp/templeos-linux-iso.txt 2>&1
rc=$?
set -e
if [ "$rc" != 124 ]; then
  cat /tmp/templeos-linux-iso.txt >&2 || true
  echo "linux.sh: private QEMU did not stay up without system files (exit $rc)" >&2
  exit 1
fi
' bash "$empty" "$moddir" "$rt" "$rt/bin/qemu-system-x86_64"

echo "linux.sh: checking the SDL window"
set +e
xvfb-run -a timeout 15s env -u LD_LIBRARY_PATH \
  QEMU_MODULE_DIR="$rt/lib/qemu" \
  GIO_MODULE_DIR="$rt/lib/gio-modules" \
  "$rt/bin/qemu-system-x86_64" \
  -L "$rt/share/qemu" -machine pc -m 32 -accel tcg \
  -display sdl,gl=off -nodefaults -serial null -monitor null \
  >/tmp/templeos-linux-sdl.txt 2>&1
rc=$?
set -e
if [ "$rc" != 124 ]; then
  cat /tmp/templeos-linux-sdl.txt >&2 || true
  echo "linux.sh: SDL window did not stay open (exit $rc)" >&2
  exit 1
fi

cp "$disk" "$stage/TempleOS.qcow2"
echo "linux.sh: embedding payload"
(cd "$stage" && zip -qr -9 "$payload" runtime TempleOS.qcow2)
mkdir -p "$(dirname "$out")"
(
  cd "$here/launcher"
  CGO_ENABLED=0 go build -tags payload -trimpath -ldflags "-s -w" -o "$out" .
)
chmod +x "$out"
du -h "$out"
