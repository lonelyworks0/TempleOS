# TempleOS as a desktop app

Run TempleOS on Windows, macOS, or Linux like any other program. Download one
file, double-click it (or run it), and TempleOS boots in a window. You don't
install a virtual machine or set one up, and you don't run an installer
inside TempleOS.

The Windows and macOS apps were originally published by
[noisyloop](https://github.com/noisyloop/TempleOS).

| Platform | Download | What it is |
|---|---|---|
| Windows 10/11 (x64) | `TempleOS-Windows-x64.exe` | A single portable `.exe`. |
| macOS 12+ (Apple Silicon) | `TempleOS-macOS-arm64.dmg` | `TempleOS.app`; drag it to Applications. |
| macOS 12+ (Intel) | `TempleOS-macOS-x64.dmg` | Same, for Intel Macs. |
| Linux x86_64 | `TempleOS-Linux-x64` | A single portable executable. |
| Linux aarch64 | `TempleOS-Linux-arm64` | Same, for 64-bit ARM. TempleOS is x86-64, so this build emulates it. |
| Linux aarch64, native | `TempleOS-Linux-arm64-native` | HolyC compiled to ARM machine code. No PC emulator. See [Native aarch64](#native-aarch64). |

The builds come from the [Standalone apps workflow](../.github/workflows/standalone.yml):
each run's artifacts, and a GitHub release for every `v*` tag.

## How it works

TempleOS is a bare-metal x86-64 operating system: it runs in ring 0, drives
the hardware directly and owns the page tables and interrupts. It can't run
as a normal process, so each app carries a private, trimmed-down copy of
[QEMU](https://www.qemu.org/) and starts it with the PC TempleOS expects
(IDE disk, standard VGA, PS/2 keyboard and mouse, PC speaker). Nothing else
has to be installed or configured. On Linux the executable still uses the
system's C library and OpenGL driver, which a desktop install already has.

The TempleOS inside is built from this repository:

1. `mkiso.py` writes a bootable TempleOS RedSea ISO from this source tree.
   It reimplements TempleOS's own `RedSeaISO()` (`::/Adam/Opt/Boot/DskISORedSea.HC`)
   so it runs on any host, using `boot/BootDVD.asm`, a NASM port of the
   El Torito loader in `::/Adam/Opt/Boot/BootDVD.HC`.
2. `mkdisk.py` boots that ISO with `autoinstall/Once.HC` and lets TempleOS's
   own installer (`::/Misc/OSInstall.HC`) set up drives C: and D: and compile
   its kernel, unattended. It then swaps TempleOS's boot menu, which waits
   for a key forever, for `boot/MBR.asm`, which boots C: directly.
3. `launcher/` is a small Go program, the app itself. On first launch it
   copies the installed disk to your user data folder. Each later launch
   boots that copy, so whatever you do inside TempleOS persists.

On Windows and Linux the launcher, QEMU and the disk are one self-extracting
executable. The first run unpacks the runtime to `%LOCALAPPDATA%\TempleOS` on
Windows, or to `~/.local/share/templeos` on Linux (`$XDG_DATA_HOME/templeos`
when that is set).

## Using it

- **Windows:** run `TempleOS-Windows-x64.exe`. SmartScreen may warn about an
  unrecognized app because the build isn't code-signed. Choose *More info >
  Run anyway*.
- **macOS:** open the `.dmg` and drag `TempleOS.app` to Applications. The app
  is ad-hoc signed, not notarized. On first launch macOS will refuse to open
  it. Open *System Settings > Privacy & Security* and click *Open Anyway*.
  Or run `xattr -dr com.apple.quarantine /Applications/TempleOS.app`.
- **Linux:** `chmod +x TempleOS-Linux-x64` and run it. It needs a graphical
  session (X11 or Wayland) and glibc 2.39 or newer (Ubuntu 24.04, Debian 13,
  and later releases). Use the x86_64 build on a PC. The aarch64 build is
  for ARM machines; it emulates TempleOS's PC, so it is slower. Release
  builds are made on Ubuntu 24.04. A binary you build yourself runs where
  glibc is at least as new as on the build machine.
- Click in the window to give TempleOS the mouse. Press **Ctrl+Alt+G**
  (Windows and Linux) or **Ctrl+Option+G** (macOS) to get it back.
- Your TempleOS disk lives in `%LOCALAPPDATA%\TempleOS\TempleOS.qcow2` on
  Windows, `~/Library/Application Support/TempleOS/TempleOS.qcow2` on macOS,
  or `~/.local/share/templeos/TempleOS.qcow2` on Linux. To start over, run
  the app with `-reset`.
- On Linux, with no usable sound device, TempleOS still starts, without
  the PC speaker.

Command-line flags (all optional):

```
TempleOS [-reset] [-memory MiB] [-cpus N] [-fullscreen] [-accel tcg|kvm|hvf|whpx]
         [-data DIR] [-- extra QEMU args]
```

Speed: the apps use QEMU's emulator (TCG). TempleOS is small enough that
this is comfortably fast. Hardware acceleration is opt-in because it is
unreliable with TempleOS: `-accel hvf` on Intel Macs currently crashes
QEMU during boot, and `-accel whpx` on Windows needs the optional Windows
Hypervisor Platform feature. On Linux the launcher uses KVM when
`/dev/kvm` is available.

## Building

Linux (or WSL) builds the TempleOS images. It needs `python3`, `nasm`,
`qemu-system-x86` and `qemu-utils`. Self-testing the Linux launcher also
needs `qemu-system-gui`, because the window is SDL:

```sh
python3 Standalone/mkiso.py -o dist/TempleOS.ISO      # bootable live ISO
python3 Standalone/mkdisk.py -o dist/TempleOS.qcow2   # installed disk (~2 min)
```

Then package on the target OS (Go 1.22+):

```sh
# Windows, MSYS2 UCRT64 shell with mingw-w64-ucrt-x86_64-qemu and zip:
Standalone/package/windows.sh dist/TempleOS.qcow2 out/TempleOS.exe
# macOS, with `brew install qemu dylibbundler`:
Standalone/package/macos.sh dist/TempleOS.qcow2 out/TempleOS.dmg
# Linux, with qemu-system-x86, qemu-system-gui, patchelf, zip and xvfb.
# The executable matches the machine you build on (x86_64 or aarch64):
Standalone/package/linux.sh dist/TempleOS.qcow2 out/TempleOS
```

`TempleOS -self-test 120s` boots the disk headless and checks that TempleOS
reaches its desktop. CI runs it on every platform. On Linux the launcher
also works without packaging: put `TempleOS.qcow2` next to the binary, and it
uses the system QEMU.

## Native aarch64

`TempleOS-Linux-arm64-native` runs on 64-bit ARM Linux (glibc 2.39 or newer,
including Omarchy and other Arch-based systems with glibc 2.43). Download
it from the same `v*` release as the other apps, `chmod +x` it, and run it.
The first launch unpacks a private runtime into
`$XDG_DATA_HOME/templeos-native` or `~/.local/share/templeos-native`.
Nothing else has to be installed. The window is 640×480 and uses TempleOS's
16-color palette. Click the window for the keyboard. The PC-emulator builds
use **Ctrl+Alt+G** to release the mouse; this build uses the normal desktop
focus rules.

```
TempleOS-Linux-arm64-native [-data DIR] [-reset] [--self-test FILE.ppm]
                            [-c FILE.HC] [-t DIR]
```

`-reset` unpacks the runtime again. `--self-test` boots the desktop,
compiles `/Demo/Graphics/Box.HC` from this tree, writes the framebuffer,
and exits 0 when that picture is the TempleOS desktop. `-c` runs a HolyC
file with no window. `/Native/Bench.HC` times a counting loop.

### How it works

TempleOS's own compiler emits x86-64, and `Kernel/` is a ring-0 kernel: it
owns the page tables, the interrupt table, the BIOS, and VGA. That kernel
cannot be loaded into a Linux process, and it cannot execute on an ARM CPU
until every one of those pieces is rewritten. This build does not do that.

It uses [Aiwnios](https://github.com/aiwnios/Aiwnios) (zlib license, by
nrootconauto and contributors; the vendored commit is recorded in
`Native/third_party/UPSTREAM_COMMIT`). Aiwnios is a HolyC compiler and
runtime with an aarch64 backend. A small C program hosts the HolyC: memory,
tasks, the keyboard, the mouse, and a 640×480 8-bit framebuffer drawn with
SDL2. The HolyC compiler's code generator calls that backend, which writes
aarch64 instructions into executable memory and runs them. On an arm64
machine those instructions run on the CPU. QEMU is not in the process.

At build time the runtime compiles its hosted kernel, compiler, and Adam
(the window manager, DolDoc, and graphics) into `HCRT2.BIN`. The executable
also carries a drive image containing:

- `Src/`, the hosted kernel and compiler the runtime executes
- `Adam/`, `Apps/`, `Compiler/`, `Demo/`, `Doc/`, `Kernel/`, `Misc/`, and
  the home files from **this** repository

The terminal's opening document is this tree's `Doc/Start.DD`. Programs are
started the TempleOS way, for example:

```
Cd("/Demo/Graphics");
#include "Lines";
```

`Native/build.sh` produces the executable on the machine it is run on.
GitHub Actions runs that script on `ubuntu-24.04-arm` and then
`--self-test`. See [Native/README.md](../Native/README.md) for the build.

### What runs as native ARM code

- The HolyC compiler. Source is parsed by the hosted compiler and emitted
  as aarch64. `--self-test` compiles this tree's `Demo/Graphics/Box.HC`
  and the red wireframe cube in the screenshot is that program.
- The hosted kernel services the desktop needs: tasks, the window manager,
  DolDoc, the 16-color graphics library, the keyboard, and the mouse.
- Apps, demos, and documents from this tree whose HolyC stays in the
  language: graphics demos built from `GrLine` and friends, DolDoc tools,
  and most of `Apps/` and `Demo/` that do not contain x86 assembly or talk
  to hardware ports.
- `Doc/` from this tree, including the startup screen.

### What does not run as native ARM code yet

- `Kernel/` as a kernel. The files are on the drive and can be read. They
  are not the code that is executing. The executing kernel is the hosted
  port under `Native/third_party/aiwnios/Src`, which is derived from
  TempleOS and modified so that code generation and hardware access go
  through the C runtime. Stock `Kernel/*.HC` still contains x86 assembly
  and ring-0 operations.
- The stock compiler backend in `Compiler/` (x86-64 opcodes and the x86
  assembler). The compiler that is actually running is the hosted one.
- Demos and lectures written in x86 assembly (`Demo/Asm/`, parts of
  `Demo/Lectures/` and `Demo/MultiCore/`). The runtime has its own ARM64
  assembler, and it does not accept TempleOS x86 syntax.
- Port I/O (`InU8`/`OutU8` and the VGA, ATA, and PC-speaker drivers). Those
  entry points are omitted on aarch64. Sound, when a device is available,
  is a tone played through SDL, not the PC speaker.
- Booting from the BIOS, installing to a RedSea hard disk, and the
  CD/DVD/ISO tools in `Adam/Opt/Boot` and `Misc/OSInstall.HC`. There is no
  virtual PC.
- A persistent home directory. The built-in drive is a RAM disk (the
  prompt shows `B:`). Edits are discarded when the process exits. `-t DIR`
  mounts a host directory instead, which is how a persistent drive will
  work; seeding that directory from the built-in image is a later phase.
- The large autocomplete dictionary (`ACDefs.DATA`). Symbol completion
  from the hosted sources still runs. The English word list is not in the
  download.
- Sprites this repository already lost. The damage is described under
  [Damaged sprite data](#damaged-sprite-data-in-this-tree) and it affects
  this build the same way: some games draw incomplete pictures.

`TempleOS-Linux-arm64` (the QEMU build) still runs the real ring-0 kernel,
including the x86 assembler and the hardware drivers, by emulating a PC.
Use that build when the program under test depends on those pieces.

### Roadmap

1. **Persist the drive.** Copy the built-in image into the data directory
   on first launch and write changes back, the way the QEMU apps keep
   `TempleOS.qcow2`.
2. **Compile this tree's Adam on the hosted runtime.** Replace the x86
   `asm` blocks and the VGA port calls in `Adam/` with shims so the window
   manager and DolDoc that execute are this tree's sources, with a small
   patch set, instead of the hosted fork.
3. **Cover the assembler demos.** Either accept TempleOS x86 `asm` blocks
   by translating them, or document an ARM dialect and move the demos that
   can move.
4. **Bring more of `Kernel/` across** as HolyC: simulated interrupts, a
   block-device shim for RedSea, and the multicore demos on host threads.
5. **A bare-metal aarch64 kernel** (page tables, exception vectors, a
   framebuffer) is a separate project. The desktop does not need it.

## Third-party software

Each app ships a private copy of [QEMU](https://www.qemu.org/). QEMU is free
software under the GNU General Public License, version 2. Its source is at
<https://www.qemu.org/download/> and <https://gitlab.com/qemu-project/qemu>.

The Linux executable is the unmodified Ubuntu QEMU package, plus the shared
libraries that package links against. glib is LGPL-2.1, SDL2 is available
under the zlib license, and SeaBIOS (the PC firmware QEMU runs) is LGPL.
The first launch unpacks copyright files, a copy of GPL-2, and the exact
package versions into `runtime/share/doc/` of the runtime directory named
above. The matching source is the Ubuntu source package for that version
(`apt-get source qemu`, and the library packages listed in
`bundled-from.txt`). OpenGL comes from the driver installed on the machine.

The Windows build uses the MSYS2 mingw-w64 QEMU package, and the macOS build
uses Homebrew's QEMU. Those are GPL builds of QEMU as well. Source for them
is published by MSYS2, Homebrew, and the QEMU project.

TempleOS itself is public domain.

The native aarch64 executable also includes
[Aiwnios](https://github.com/aiwnios/Aiwnios), a HolyC compiler and runtime
by nrootconauto and contributors, under the zlib license. The license text
is unpacked into the runtime directory as `share/doc/AIWNIOS-LICENSE`, next
to the notices for argtable3 (BSD-3-clause), isocline (MIT), and SDL2
(zlib). SDL2 is the window and audio library and is bundled as a shared
library from the Ubuntu build machine. Aiwnios is vendored at the commit in
`Native/third_party/UPSTREAM_COMMIT`.

## Damaged sprite data in this tree

Many DolDoc files in this repository have bytes missing from the binary
data after their text: sprites, and the debug info in `Kernel/Kernel.MAP`
and `Compiler/Compiler.MAP`. Every historical version of these files in git
has the same problem, so the damage predates this tooling. TempleOS reacts
by pausing 3 seconds for each missing piece ("Bin Not Found"). For
Kernel.MAP alone that would add about half an hour to every boot.

`mkiso.py` works around this in the image only; the files in the repository
are not changed. It keeps the binary entries that are still intact. For lost
ones, it removes the debug-info reference from `$LK` links and turns sprite
menu items into text items. The sprites themselves can't be recovered, so
some demos and games that draw them won't work. Pass `--no-repair` to
copy the files exactly as they are.
