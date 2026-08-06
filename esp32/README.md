# lua-os on esp32

The ESP32-S3 port: a LilyGo T-Deck, an M5Stack Cardputer, or the
emulator. This directory is the ESP-IDF project that builds it.

## Why there are three build systems

The top level builds efi and microvm with meson. This platform is built
by ESP-IDF's cmake instead, because IDF's link is not a list of
libraries: it is generated linker fragments, section placement,
keep-lists, init arrays, an app descriptor and a second-stage bootloader
image. Reproducing that in a meson cross file is a bet that loses on
every IDF version bump.

So the layers are:

| | |
|---|---|
| `main/CMakeLists.txt` | builds the firmware, through ESP-IDF |
| `meson.build` (here) | runs the boot tests under the emulator |
| `../tools/sources.lua` | the source lists both cmake and meson read |

The last one is what keeps the two builds together. A kernel source
added there appears in both; a source added to one build file only would
break the other platform silently, which has happened.

`main/CMakeLists.txt` also holds `EMBED_FILES`, the Lua frozen into the
image. That list is what has to exist before a namespace can be mounted.
Everything else lives on the flash filesystem below.

## Prerequisites

ESP-IDF v6.1, on `PATH`:

    . $IDF_PATH/export.sh

Built and tested against v6.1-beta1. The radio driver reaches
`esp_private/wifi.h`, which moved in 6.0, so an IDF older than that
needs the include changed.

`export.sh` refuses if the system `python3` is not the version IDF built
its virtualenv against. Either re-run IDF's `install.sh`, or put a
matching `python3` earlier on `PATH` for the session.

The boot tests additionally want Espressif's qemu, which is not upstream
qemu -- upstream has no esp32 machine:

    python3 $IDF_PATH/tools/idf_tools.py install qemu-xtensa

## Building

The board is a build-time choice, so each target gets its own build
directory. `sdkconfig.defaults` is the T-Deck; the others layer over it.

    # T-Deck: ESP32-S3-WROOM-1 N16R8, 16MB flash, 8MB octal PSRAM
    idf.py -B build-tdeck build

    # Cardputer: 8MB flash, no PSRAM
    idf.py -B build-cardputer \
        -DSDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.cardputer" build

    # ESP32-C5 devkit: RISC-V, 16MB flash, 8MB PSRAM, no peripherals
    idf.py -B build-c5 -DSDKCONFIG=build-c5.sdkconfig -DIDF_TARGET=esp32c5 \
        -DSDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.c5" build

    # emulator
    idf.py -B build-qemu \
        -DSDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.qemu" build

A second chip family costs a board file and nothing else. The C5 is
RISC-V where the T-Deck is xtensa, and src/platform/esp32 is written
against IDF's API rather than a processor -- IDF brings the toolchain,
the FreeRTOS port and newlib. `platform_arch` reports which it is.

`-DSDKCONFIG` matters once a second target exists. idf.py keeps one
`sdkconfig` beside the project and pins the target in it, so a build
directory for another chip fails to configure until it is given a
sdkconfig of its own.

The C5 devkit has two USB sockets. The console here is UART0, which is
the one behind a serial bridge; the chip's own USB link is the other.
An image built for one socket is silent on the other, and silence looks
the same as a board that failed to boot.

`SDKCONFIG_DEFAULTS` is read only when a build directory has no
`sdkconfig` yet. Changing it later does nothing; delete the directory.

The console is where the targets genuinely disagree. The T-Deck's is the
native USB-Serial-JTAG, which is the `/dev/ttyACM` port. The emulator
has no such peripheral and needs UART0, which is what `sdkconfig.qemu`
sets -- an image built for the board boot-loops there with no output at
all, not even from the bootloader.

## The flash filesystem

`bin/` is not in the firmware. Programs live on the `luafs` partition,
so a new one is an upload rather than a rebuild. The layout is in
`partitions.csv`:

| partition | offset | size |
|---|---|---|
| `nvs` | `0x9000` | 24K |
| `phy_init` | `0xf000` | 4K |
| `factory` | `0x10000` | 3M |
| `luafs` | `0x310000` | 2M |

Build an image with the programs and the config in it. This one runs
from the top of the tree, since that is where `bin/` and `etc/` are:

    lua5.4 tools/mkfatimg.lua esp32/luafs.img 2M bin/=/bin etc/=/etc

The sector is 4096 bytes, matching the flash erase block, so a sector
write is one erase and one program. The tool reopens the image and
checks it before exiting.

A board with no image flashed still boots to a prompt, and every command
on it is unknown. That is the same bargain the other platforms make with
their EFI system partition.

## Flashing

    idf.py -B build-tdeck -p /dev/ttyACM0 flash

or, to write the filesystem alongside the firmware:

    python -m esptool --chip esp32s3 -p /dev/ttyACM0 -b 460800 \
        write-flash --flash-mode dio --flash-size 16MB --flash-freq 80m \
        0x0 build-tdeck/bootloader/bootloader.bin \
        0x8000 build-tdeck/partition_table/partition-table.bin \
        0x10000 build-tdeck/luaos.bin \
        0x310000 luafs.img

The firmware and the filesystem are independent. Reflashing `0x10000`
alone keeps whatever is on `luafs`, and reflashing `0x310000` alone
replaces the programs without touching the kernel. Reflashing the
filesystem does remove anything written on the board, `/etc/wifi.lua`
included.

## Tests

The boot tests are a meson project of their own, run under the emulator:

    meson setup build-esp32 esp32/
    meson test -C build-esp32

They register nothing when `idf.py` is absent, so a checkout without IDF
still configures.

What runs here is the arch-blind logic -- threads, channels, the
scheduler, the serializer. The emulator has no PSRAM in either mode, so
the guest has about 210KB of internal SRAM and runs out during a third
proc's requires. Anything that spawns procs belongs on real hardware.

The payload is chosen at build time, since there is no fw_cfg to inject
one into a finished image. Each test therefore rebuilds the image, which
is why they share one build directory and do not run in parallel.

## Networking

The radio hands up 802.3 frames and the IP stack above it is the same
Lua the other platforms run: `task/eth.lua`, then `ip`, then `tcp4`,
with `dhcpd` acquiring the lease and serving it as `/net`. There is no
lwip in the image.

The network to join is `/etc/wifi.lua` on the filesystem:

    return { ssid = "...", psk = "..." }

`bin/wifi.lua` writes that file. The boot payload reads it and joins.
