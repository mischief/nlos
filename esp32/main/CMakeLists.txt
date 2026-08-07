# The lua-os component: the arch-blind kernel, vanilla lua, and the
# esp32 platform layer.
#
# The first two lists come from tools/sources.lua, which meson reads for
# the same groups. Adding a kernel source therefore updates both builds
# at once, which is the only thing standing between this platform and
# the silent rot that broke the microvm link once already.
#
# src/libc is NOT built here: IDF brings newlib, and a second libc in
# the same image would be two definitions of every symbol. That is a
# real divergence from the other three platforms -- src/libc stops being
# exercised on this one -- and it is the price of taking IDF's runtime.

set(LUAOS_ROOT ${CMAKE_CURRENT_LIST_DIR}/../..)

find_program(LUA_EXE NAMES lua5.4 lua REQUIRED)

function(luaos_sources group out)
    execute_process(
        COMMAND ${LUA_EXE} ${LUAOS_ROOT}/tools/sources.lua ${group}
        OUTPUT_VARIABLE raw
        RESULT_VARIABLE rc
        OUTPUT_STRIP_TRAILING_WHITESPACE)
    if(NOT rc EQUAL 0)
        message(FATAL_ERROR "tools/sources.lua ${group} failed: ${rc}")
    endif()
    string(REPLACE "\n" ";" paths "${raw}")
    set(prefixed "")
    foreach(p ${paths})
        list(APPEND prefixed ${LUAOS_ROOT}/${p})
    endforeach()
    set(${out} ${prefixed} PARENT_SCOPE)
endfunction()

luaos_sources(kernel KERNEL_SRC)
luaos_sources(lua LUA_SRC)

set(PLATFORM_SRC
    ${LUAOS_ROOT}/src/platform/esp32/blk.c
    ${LUAOS_ROOT}/src/platform/esp32/console.c
    ${LUAOS_ROOT}/src/platform/esp32/drivers.c
    ${LUAOS_ROOT}/src/platform/esp32/flashblk.c
    ${LUAOS_ROOT}/src/platform/esp32/fs.c
    ${LUAOS_ROOT}/src/platform/esp32/idf_shim.c
    ${LUAOS_ROOT}/src/platform/esp32/kbd.c
    ${LUAOS_ROOT}/src/platform/esp32/lcd.c
    ${LUAOS_ROOT}/src/platform/esp32/tdeck.c
    ${LUAOS_ROOT}/src/platform/esp32/ball.c
    ${LUAOS_ROOT}/src/platform/esp32/touch.c
    ${LUAOS_ROOT}/src/platform/esp32/main.c
    ${LUAOS_ROOT}/src/platform/esp32/vfs.c
    ${LUAOS_ROOT}/src/platform/esp32/wifi.c
    ${LUAOS_ROOT}/src/platform/esp32/machine.c
)

# esp_psram is required explicitly, not because anything calls it yet
# but because IDF only sources Kconfig for components in the dependency
# graph: without it CONFIG_SPIRAM is an unknown symbol and any PSRAM
# setting in sdkconfig.defaults is dropped with a warning and a
# successful build. On a board whose whole memory argument is the 8MB,
# that failure is silent and expensive.
idf_component_register(
    SRCS ${KERNEL_SRC} ${LUA_SRC} ${PLATFORM_SRC} ${CMAKE_CURRENT_BINARY_DIR}/embedfs.c
    INCLUDE_DIRS
        ${LUAOS_ROOT}/src
        ${LUAOS_ROOT}/src/platform/esp32
        ${LUAOS_ROOT}/lua
        ${CMAKE_CURRENT_BINARY_DIR}
    REQUIRES esp_psram esp_timer driver vfs esp_driver_usb_serial_jtag
            esp_lcd esp_partition
            # the radio: esp_wifi for the driver, nvs_flash because it
            # keeps its calibration there and will not start without
            # one, esp_event for the association callbacks. Not
            # esp_netif or lwip -- the frames go to lib/ip4.lua, and a
            # second network stack in the image is what that avoids.
            esp_wifi nvs_flash esp_event
            sdmmc esp_driver_sdspi esp_driver_spi esp_driver_gpio
)

# lua's own hook for injecting a header: it redefines LUA_EXTRASPACE and
# the luai_userstate* macros so the kernel can walk every lua_State a
# proc owns. lua/ stays vanilla.
target_compile_definitions(${COMPONENT_LIB} PRIVATE LUA_USER_H="coreg.h")

# The search paths come in as a force-included header rather than -D,
# because LUA_PATH_DEFAULT contains a semicolon and cmake splits those
# into separate definitions -- see the header for the full story.
target_compile_options(${COMPONENT_LIB} PRIVATE
    -include ${LUAOS_ROOT}/src/platform/esp32/prefix.h)

# The boot payload and the libs it needs before a namespace exists,
# frozen into the image exactly as microvm does it -- there is no disk
# here to read them from.
#
# LUAOS_PAYLOAD is what a test harness varies. There is no fw_cfg on
# this machine, so unlike every other platform the payload cannot be
# injected at boot: it is chosen at build time and the image is rebuilt
# per test. Whatever it points at is embedded as /boot/esp32.lua, so
# src/platform/esp32/main.c's BOOT_PAYLOAD stays one constant path.
set(LUAOS_PAYLOAD "${LUAOS_ROOT}/boot/esp32.lua"
    CACHE FILEPATH "lua chunk proc 0 runs; a test payload replaces it")

# What the machine needs before it can read a file, and nothing above
# that. Everything else lives on the luafs partition and is loaded from
# there, the way a unix kernel carries an initramfs only until the real
# root is mounted.
#
# Three things pin a file here.
#
# The bootstrap itself: lib/thread.lua (the C preload reads it by path),
# console + power, and the chain that mounts the flash -- dev, srv,
# blkfs, blksrv, lib/fat, fatfs, fatsrv. None of these can come off the
# volume they are what opens.
#
# A namespace: ns, chan, mnt, nsio, romfs. A spawned proc resolves
# require through its namespace, but the modules that install one are
# found before it exists, so they are found here.
#
# A driver the kernel spawns: cons, power, blksrv, fb, and the whole
# network stack -- eth, ip, tcp4, dhcpd and the libs under them. These
# procs are started by spawn_init before init runs and are given no
# namespace, so their require goes to the ambient search path, which on
# this platform is this set. Moving them to the partition means making
# them services that init starts, which is a change to how a device
# capability is handed out, not a change to this list.
#
# tap and sync are here for the boot tests: a test payload replaces
# init and runs under qemu with no partition flashed at all.
set(EMBED_FILES
    lib/thread.lua
    lib/stdout.lua
    lib/log.lua
    lib/console.lua
    lib/tap.lua
    lib/sync/once.lua
    lib/sync/sema.lua
    lib/sync/lock.lua
    task/cons.lua
    task/power.lua
    task/fb.lua

    # the block device and what it needs to be served. Only the T-Deck
    # has a card, and only that board starts blksrv -- esp_blk_present
    # is a stub elsewhere -- but EMBED_FILES is one list for the
    # platform, and flash is the abundant thing here.
    lib/dev.lua
    lib/srv.lua
    # the pointer's file, which task/mousesrv.lua needs. That proc is
    # spawned before any namespace exists, so what it requires must be
    # in the image rather than on the volume.
    lib/mousefs.lua
    lib/blkfs.lua
    task/blksrv.lua

    # the filesystem on the flash partition, and so a bootstrap
    # dependency: nothing can be read off luafs until this is running,
    # which includes every program in /bin. gefs/io.lua is here for its
    # device wrapper over a seekable handle, which is what lib/fat
    # opens the volume on -- none of the rest of gefs comes with it.
    lib/fat.lua
    lib/fat/obj.lua
    lib/fat/dat.lua
    lib/fat/pack.lua
    lib/fat/blk.lua
    lib/fat/fat.lua
    lib/fat/dir.lua
    lib/fat/fsops.lua
    lib/fat/vol.lua
    lib/fat/check.lua
    lib/fat/ram.lua
    lib/gefs/io.lua
    lib/fatfs.lua
    task/fatsrv.lua

    # and what a client needs to mount it, which is also what a spawned
    # proc adopts a namespace with. Not lib/ninep.lua -- that is the 9p
    # wire, and a local dev backend is reached by message.
    lib/chan.lua
    lib/ns.lua
    lib/mnt.lua
    lib/nsio.lua
    lib/romfs.lua
    # a namespace served as one backend, which is how blksrv offers two
    # flash partitions on one port and how fatsrv serves both volumes as
    # one tree. Two partitions cost a mount point here rather than two
    # more procs.
    lib/nsfs.lua

    # the network, from the wire up. The radio hands up 802.3 frames
    # and everything above them is the same Lua the other platforms
    # run: eth, then ip, then tcp, with dhcpd acquiring the lease and
    # serving it as /net. Measured at about 676KB of heap for the four
    # procs together, which is why this is a board with PSRAM.
    lib/ether.lua
    lib/ethwire.lua
    lib/arp.lua
    lib/ip4.lua
    lib/icmp.lua
    lib/udp4.lua
    lib/tcp4.lua
    lib/tcb.lua
    lib/inet.lua
    lib/dhcp.lua
    lib/caps.lua
    task/eth.lua
    task/ip.lua
    task/tcp4.lua
    task/dhcpd.lua
)

# What is not here: the programs in bin/, the shell and the terminal
# above it, the panel console, the http client, the pager, and the
# machine's own /etc/services.lua. All of that is on the luafs
# partition, built by tools/mkfatimg.lua and flashed separately, so a
# change to any of it is an upload rather than a rebuild.
#
# What that costs is that a board with an empty or unflashed partition
# reaches the lua repl on the serial line and stops there -- no
# programs, no panel terminal, no services at all. That is the deal a
# separate root makes, and the repl is enough to flash one.
#
# A file that exists in both places is worse than a file in neither:
# the partition is mounted before the image and silently wins, so an
# image rebuild leaves the old copy in charge. Keep this list and the
# image disjoint.

# Some modules ship as stripped bytecode rather than source.
#
# Loading from source needs the source, the parser's state and the
# resulting prototypes live at once, and that peak is what fails first
# on a board with no PSRAM: lib/zmodem.lua is 27595 bytes and require
# answered "not enough memory" with 62KB free. luac -s is 12716 and
# skips the parser entirely. Measured more generally at 11703 resident
# bytes per chunk against 14894, and about 16x faster to load.
#
# Portable because the header says so: host and guest are both Lua 5.4.8
# and both are 4-byte instructions, 8-byte integers, 8-byte numbers.
# Bytecode does not encode pointer width, which is the only thing that
# differs between them.
#
# The cost is the debugger's line numbers in these modules, so a
# traceback names a chunk and not a line, which is why this is opt-in
# rather than done to everything by default.
#
# It applies to the embedded set alone. A module on the luafs partition
# is read as source through the namespace, so the saving is available
# only to what the image carries.
find_program(LUAC_EXE NAMES luac5.4 luac REQUIRED)

set(PRECOMPILED "")
if(CONFIG_LUAOS_PRECOMPILE)
    list(APPEND PRECOMPILED ${EMBED_FILES})
    list(REMOVE_DUPLICATES PRECOMPILED)
endif()

set(embed_args /boot/esp32.lua=${LUAOS_PAYLOAD})
set(embed_deps ${LUAOS_PAYLOAD})

foreach(f ${PRECOMPILED})
    string(REPLACE "/" "_" flat ${f})
    set(out ${CMAKE_CURRENT_BINARY_DIR}/${flat}c)
    add_custom_command(
        OUTPUT ${out}
        COMMAND ${LUAC_EXE} -s -o ${out} ${LUAOS_ROOT}/${f}
        DEPENDS ${LUAOS_ROOT}/${f}
        VERBATIM)
    list(APPEND embed_args /${f}=${out})
    list(APPEND embed_deps ${out})
endforeach()

foreach(f ${EMBED_FILES})
    if(NOT ${f} IN_LIST PRECOMPILED)
        list(APPEND embed_args /${f}=${LUAOS_ROOT}/${f})
        list(APPEND embed_deps ${LUAOS_ROOT}/${f})
    endif()
endforeach()

add_custom_command(
    OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/embedfs.c
    COMMAND ${LUA_EXE} ${LUAOS_ROOT}/tools/gen_embedfs.lua
            ${CMAKE_CURRENT_BINARY_DIR}/embedfs.c ${embed_args}
    DEPENDS ${embed_deps} ${LUAOS_ROOT}/tools/gen_embedfs.lua
    VERBATIM)
add_custom_target(embedfs DEPENDS ${CMAKE_CURRENT_BINARY_DIR}/embedfs.c)
add_dependencies(${COMPONENT_LIB} embedfs)
