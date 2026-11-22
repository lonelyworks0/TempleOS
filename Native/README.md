# Native TempleOS on ARM64 Linux

`TempleOS-Linux-arm64-native` is a single executable that runs HolyC from
this repository as aarch64 machine code. The window is TempleOS's 640×480,
16-color desktop. QEMU is not part of the process.

The user-facing description, the list of what runs, the gaps, and the
roadmap are in [Standalone/README.md](../Standalone/README.md#native-aarch64).
This file is how the executable is built and how the pieces fit together.

## Build

On the machine that should run it (aarch64 for the release binary):

```sh
# cmake, a C compiler, SDL2 headers, patchelf, zip, Go 1.22+, python3
Native/build.sh out/TempleOS-Linux-arm64-native
```

The script matches `uname -m`. On x86_64 it writes
`TempleOS-Linux-x64-native`, which is the same runtime with the x86-64
backend, used to develop the port. The published asset is the aarch64 one,
built on the `ubuntu-24.04-arm` job in
[`.github/workflows/standalone.yml`](../.github/workflows/standalone.yml).

That job builds the executable, boots it under Xvfb, and checks the
framebuffer:

- 640×480
- mostly TempleOS white and blue (the desktop)
- red pixels from this tree's `Demo/Graphics/Box.HC`, which the running
  compiler has just translated to native code

It also checks that the inner ELF's machine is AArch64, and it runs
`/Native/Bench.HC`.

```sh
out/TempleOS-Linux-arm64-native --self-test screen.ppm
out/TempleOS-Linux-arm64-native -c /Native/Bench.HC
```

## What the build does

1. Compiles the vendored Aiwnios C runtime
   (`Native/third_party/aiwnios`) for the host CPU. The aarch64 code
   generator is `c/arm_backend.c`. Register `x28` is reserved as the HolyC
   frame register (`-ffixed-x28`).
2. Runs `aiwnios -b`. That uses a small compiler linked into the C program
   to compile `Src/FULL_PACKAGE.HC` into `HCRT2.BIN`, native machine code
   for the kernel services, the HolyC compiler, DolDoc, and the window
   manager.
3. Builds a drive image (Aiwnios's `AiwniosPack` format, a RedSea RAM disk
   plus `HCRT2.BIN` appended to the ELF). The drive holds `Src/` from
   Aiwnios and `Adam/`, `Apps/`, `Compiler/`, `Demo/`, `Doc/`, `Kernel/`,
   `Misc/`, and the home files from this repository.
4. Bundles the SDL2 shared libraries the ELF needs, the way
   `Standalone/package/linux.sh` bundles QEMU, and wraps them in a small Go
   program. The first launch unpacks to `~/.local/share/templeos-native`.

glibc is the one on the build machine. Release builds use Ubuntu 24.04
(glibc 2.39), which loads on newer glibc, including 2.43.

## Provenance

Aiwnios is by nrootconauto and contributors:

- https://github.com/aiwnios/Aiwnios
- zlib license, copied to `Native/third_party/aiwnios/LICENSE`
- commit recorded in `Native/third_party/UPSTREAM_COMMIT`

Local changes on top of that commit, so the runtime boots this tree and
can be tested headless:

- `c/windows.c` titles the window TempleOS, and `--self-test` writes the
  640×480 framebuffer to a PPM and checks the desktop colors plus the red
  cube from `Demo/Graphics/Box.HC`
- `c/main.c` adds `--self-test` and a 180s alarm so a hung boot fails
- `c/sound.c` keeps going when the machine has no audio device
- `Src/FULL_PACKAGE.HC` and `Src/KernelA.HH` declare the self-test hooks
- `c/CMakeLists.txt` passes `-fcf-protection` only on x86-64, because
  aarch64 gcc rejects it

argtable3 (BSD-3-clause) and isocline (MIT) are the copies Aiwnios vendors.
SDL2 (zlib) comes from the OS that runs the build. TempleOS is public
domain. Notices are unpacked to `runtime/share/doc/` inside the data
directory.

## Layout

```
Native/build.sh                 host build of the single executable
Native/bench.HC                 counting loop, packed as /Native/Bench.HC
Native/launcher/                Go unpacker, same shape as Standalone/launcher
Native/ppm2png.py               PPM to PNG for the CI screenshot
Native/third_party/aiwnios/     zlib-licensed HolyC compiler and runtime
```

The QEMU apps under `Standalone/` are unchanged.
