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
    ${LUAOS_ROOT}/src/platform/esp32/main.c
    ${LUAOS_ROOT}/src/platform/esp32/vfs.c
    ${LUAOS_ROOT}/src/platform/esp32/wifi.c
    ${LUAOS_ROOT}/src/xtensa/machine.c
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

# Kept short on purpose -- this is what has to exist before a namespace
# can, not the whole tree. tap and sync are here because the boot tests
# require them and there is nowhere else for them to come from.
set(EMBED_FILES
    lib/thread.lua
    lib/console.lua
    lib/stdout.lua
    lib/ps.lua
    lib/tap.lua
    lib/sync/once.lua
    lib/sync/sema.lua
    lib/sync/lock.lua
    task/cons.lua
    task/power.lua
    task/fb.lua
    task/shot.lua

    # the block device and what it needs to be served. Only the T-Deck
    # has a card, and only that board starts blksrv -- esp_blk_present
    # is a stub elsewhere -- but EMBED_FILES is one list for the
    # platform, and flash is the abundant thing here.
    lib/dev.lua
    lib/srv.lua
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
    lib/dhcpc.lua
    lib/dns.lua
    lib/dnsc.lua
    lib/ntp.lua
    task/eth.lua
    task/ip.lua
    task/tcp4.lua
    task/dhcpd.lua

    # and what a CLIENT needs to mount it. Without these blksrv runs
    # and nothing can open a file on it: require("ns") fails on the
    # board. Not lib/ninep.lua -- that is the 9p wire, and a local dev
    # backend is reached by message.
    lib/chan.lua
    lib/ns.lua
    lib/mnt.lua

    # the panel as a terminal: fbcons is the second binding of
    # lib/console.lua, and dos/prog/draw/caps are what a program needs
    # to be run from a prompt on it.
    lib/romfs.lua
    lib/nsio.lua
    lib/svc.lua
    lib/proc.lua
    lib/log.lua
    etc/services.lua
    lib/fbcons.lua
    task/fbterm.lua
    task/fbsh.lua
    lib/caps.lua
    lib/prog.lua
    lib/draw.lua
    lib/dos.lua
)

# bin/ is not here. The programs live on the luafs partition, built by
# tools/mkfatimg.lua and flashed separately, so a new one is an upload
# rather than a rebuild. What that costs is that a board with an empty
# or unflashed partition has no programs at all -- the prompt comes up
# and every name is unknown -- which is the same bargain the other
# platforms make with their EFI system partition.

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
# traceback names a chunk and not a line. Hence a short always-list plus
# an opt-in for the rest, rather than doing it to everything by default.
find_program(LUAC_EXE NAMES luac5.4 luac REQUIRED)

set(PRECOMPILED lib/zmodem.lua)
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
