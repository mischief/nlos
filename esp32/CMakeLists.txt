# lua-os on ESP32-S3, built by ESP-IDF.
#
# Why cmake here and meson everywhere else: IDF's link is not a list of
# libraries. It is generated linker fragments placing sections across
# IRAM/flash/RTC, keep-lists, init arrays walked at boot, an app
# descriptor and a separate bootloader image. Reproducing that in a
# meson cross file is a bet that loses on the next IDF release, so this
# platform takes IDF's build rather than only its sources.
#
# The cost of two build systems is two source lists drifting apart, and
# that is what tools/sources.lua exists to prevent -- meson and this
# tree read the same one. See main/CMakeLists.txt.

cmake_minimum_required(VERSION 3.16)

set(EXTRA_COMPONENT_DIRS "")

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(luaos)

# The luafs partition: the rest of the system, which main/CMakeLists.txt
# lists the other half of.
#
# Both numbers come from the partition row -- the offset through IDF,
# the size from the same line here -- because mkfatimg takes the size it
# is told and cannot catch an image written to the wrong offset.
#
# It hangs off flash and not off all: mkfatimg loads lib/fat through
# build/los.so, which meson builds for the host, and a firmware build
# has no reason to need one.

file(READ "${CMAKE_CURRENT_SOURCE_DIR}/partitions.csv" luafs_table)
if(NOT luafs_table MATCHES
        "\nluafs,[ \t]*data,[ \t]*fat,[ \t]*(0x[0-9a-fA-F]+),[ \t]*(0x[0-9a-fA-F]+)")
    message(FATAL_ERROR "no luafs row in partitions.csv")
endif()
math(EXPR luafs_size "${CMAKE_MATCH_2}")

# CONFIGURE_DEPENDS: a new program is missing from the board otherwise,
# and the build still reports success.
set(luafs_root "${CMAKE_CURRENT_SOURCE_DIR}/..")
file(GLOB_RECURSE luafs_sources CONFIGURE_DEPENDS
    "${luafs_root}/bin/*" "${luafs_root}/lib/*"
    "${luafs_root}/task/*" "${luafs_root}/etc/*"
    "${luafs_root}/machine/esp32/*")

# what the firmware image already carries, which this one must not: the
# partition is mounted over the image, so a file in both is the
# partition's copy however old it is. main/CMakeLists.txt publishes the
# list; taking it from there rather than repeating it is what keeps the
# two roots disjoint without anyone remembering to.
#
# file(GENERATE), not file(WRITE): the image depends on this list, so
# adding a file to the firmware has to rebuild the image that must now
# leave it out. GENERATE leaves the timestamp alone when the content
# has not changed, so that dependency does not rebuild the image on
# every configure.
get_property(luafs_embedded GLOBAL PROPERTY LUAOS_EMBED_FILES)
set(luafs_skip "${CMAKE_BINARY_DIR}/luafs.exclude")
string(REPLACE ";" "\n" luafs_skip_text "${luafs_embedded}")
file(GENERATE OUTPUT "${luafs_skip}" CONTENT "${luafs_skip_text}\n")

set(luafs_img "${CMAKE_BINARY_DIR}/luafs.img")
add_custom_command(OUTPUT "${luafs_img}"
    COMMAND "${LUA_EXE}" tools/mkfatimg.lua "${luafs_img}" "${luafs_size}"
        --exclude-from "${luafs_skip}"
        bin/=/bin lib/=/lib task/=/task etc/=/etc
        # what this board runs. The path is /etc/services.lua on every
        # machine, so the build picks the list and the boot payload
        # reads one name -- see machine/.
        machine/esp32/services.lua=/etc/services.lua
    DEPENDS "${luafs_root}/tools/mkfatimg.lua" "${luafs_skip}"
        ${luafs_sources}
    WORKING_DIRECTORY "${luafs_root}"
    VERBATIM)
add_custom_target(luafs DEPENDS "${luafs_img}")

# The first argument is the flash target, not the executable: IDF holds
# the image list as a property on the target that flashes it.
esptool_py_flash_to_partition(flash "luafs" "${luafs_img}")
add_dependencies(flash luafs)
