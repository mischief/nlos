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
    ${LUAOS_ROOT}/src/platform/esp32/fs.c
    ${LUAOS_ROOT}/src/platform/esp32/idf_shim.c
    ${LUAOS_ROOT}/src/platform/esp32/kbd.c
    ${LUAOS_ROOT}/src/platform/esp32/font.c
    ${LUAOS_ROOT}/src/platform/esp32/lcd.c
    ${LUAOS_ROOT}/src/platform/esp32/main.c
    ${LUAOS_ROOT}/src/platform/esp32/vfs.c
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
            esp_lcd
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
    lib/stdout.lua
    lib/ps.lua
    lib/tap.lua
    lib/sync/once.lua
    lib/sync/sema.lua
    lib/sync/lock.lua
    task/cons.lua
    task/power.lua
    task/fb.lua
)

set(embed_args /boot/esp32.lua=${LUAOS_PAYLOAD})
set(embed_deps ${LUAOS_PAYLOAD})
foreach(f ${EMBED_FILES})
    list(APPEND embed_args /${f}=${LUAOS_ROOT}/${f})
    list(APPEND embed_deps ${LUAOS_ROOT}/${f})
endforeach()

add_custom_command(
    OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/embedfs.c
    COMMAND ${LUA_EXE} ${LUAOS_ROOT}/tools/gen_embedfs.lua
            ${CMAKE_CURRENT_BINARY_DIR}/embedfs.c ${embed_args}
    DEPENDS ${embed_deps} ${LUAOS_ROOT}/tools/gen_embedfs.lua
    VERBATIM)
add_custom_target(embedfs DEPENDS ${CMAKE_CURRENT_BINARY_DIR}/embedfs.c)
add_dependencies(${COMPONENT_LIB} embedfs)
