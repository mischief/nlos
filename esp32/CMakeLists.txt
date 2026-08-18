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
# It is part of all, not of flash alone. The two partitions are one
# system, and a build that reports success having made half of it is
# how an image goes stale without anyone noticing.
#
# The cost is that mkfatimg needs los.so, which meson builds for the
# host: checked below, where it is an error a message can fix.

file(READ "${CMAKE_CURRENT_SOURCE_DIR}/partitions.csv" luafs_table)
if(NOT luafs_table MATCHES
        "\nluafs,[ \t]*data,[ \t]*fat,[ \t]*(0x[0-9a-fA-F]+),[ \t]*(0x[0-9a-fA-F]+)")
    message(FATAL_ERROR "no luafs row in partitions.csv")
endif()
math(EXPR luafs_size "${CMAKE_MATCH_2}")

set(luafs_root "${CMAKE_CURRENT_SOURCE_DIR}/..")

# los.so is the host build of los.buf, which lib/fat holds its sectors
# in. Checked while configuring rather than when the image is built, so
# it is not a failure at the end of a long compile.
set(LUAOS_HOSTLIB "${luafs_root}/build" CACHE PATH
    "directory holding the host build of los.so, for mkfatimg")
if(NOT EXISTS "${LUAOS_HOSTLIB}/los.so")
    message(FATAL_ERROR
        "${LUAOS_HOSTLIB}/los.so not found -- mkfatimg needs the host "
        "build of los.buf to make the luafs image.\n"
        "  meson setup build && ninja -C build los.so\n"
        "Or point -DLUAOS_HOSTLIB=<dir> at a build directory that has one.")
endif()

# CONFIGURE_DEPENDS: a new program is missing from the board otherwise,
# and the build still reports success.
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

get_property(luafs_version GLOBAL PROPERTY LUAOS_VERSION_TXT)

set(luafs_img "${CMAKE_BINARY_DIR}/luafs.img")
add_custom_command(OUTPUT "${luafs_img}"
    COMMAND ${CMAKE_COMMAND} -E env "LUAOS_HOSTLIB=${LUAOS_HOSTLIB}"
        "${LUA_EXE}" tools/mkfatimg.lua "${luafs_img}" "${luafs_size}"
        --exclude-from "${luafs_skip}"
        bin/=/bin lib/=/lib task/=/task etc/=/etc
        # what this board runs. The path is /etc/services.lua on every
        # machine, so the build picks the list and the boot payload
        # reads one name -- see machine/.
        machine/esp32/services.lua=/etc/services.lua
        # the build's revision, which the kernel and the embedded tree
        # also carry. Flashing this partition without the other is what
        # makes them disagree, and bin/rev is what says so.
        "${luafs_version}=/VERSION.fs"
    DEPENDS "${luafs_root}/tools/mkfatimg.lua" "${luafs_skip}"
        ${luafs_sources} "${luafs_version}"
    WORKING_DIRECTORY "${luafs_root}"
    VERBATIM)
add_custom_target(luafs ALL DEPENDS "${luafs_img}")

# The first argument is the flash target, not the executable: IDF holds
# the image list as a property on the target that flashes it.
esptool_py_flash_to_partition(flash "luafs" "${luafs_img}")
add_dependencies(flash luafs)
