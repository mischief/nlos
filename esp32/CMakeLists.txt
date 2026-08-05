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
