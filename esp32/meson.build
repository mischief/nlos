# The esp32 test suite, as a meson project of its own.
#
# Separate from the top-level meson.build on purpose. That file builds a
# kernel; this platform's kernel is built by ESP-IDF's cmake, because
# IDF's link is generated linker fragments, section placement,
# keep-lists, init arrays, an app descriptor and a bootloader image --
# not a list of libraries meson could be handed. Folding an
# "if platform == esp32" through a thousand lines that all assume they
# are producing an image would put every working platform at risk to
# gain nothing; a sibling project costs one directory and touches
# nothing.
#
# What IS shared is the source list: tools/sources.lua, which
# main/CMakeLists.txt reads and the top-level meson.build reads too.
# That is the seam that matters, and it is already in place.
#
#   meson setup build-esp32 esp32/
#   meson test -C build-esp32
#
# Requires idf.py on PATH (source $IDF_PATH/export.sh first) and
# Espressif's qemu; tools/boottest-esp32.lua explains how to get it.

project('luaos-esp32', version: '0.1',
  meson_version: '>= 1.1',
  # no compilers: nothing here is built by meson.
  default_options: [])

lua_interp = find_program('lua5.4', 'lua')
idf = find_program('idf.py', required: false)

if not idf.found()
  # Not an error: a checkout without IDF should still configure, so that
  # `meson test` on the other platforms is unaffected by this one being
  # unavailable. Say why rather than silently registering nothing.
  warning('idf.py not found -- source $IDF_PATH/export.sh to enable ' +
    'the esp32 tests. Configuring with none registered.')
endif

boottest = files('../tools/boottest-esp32.lua')

# What fits under the emulator, which is now all four boot tests.
#
# qemu-esp32s3 emulates no PSRAM in either mode, so the guest has only
# its internal SRAM, and cons + power + the payload are three procs at
# ~50KB apiece before a test allocates anything. Three of these four
# used to die in `require` with "not enough memory"; what bought the
# room was src/platform/esp32/param.h, since procv and portv at the
# shared 4096/32768 were 144KB of .bss on a 32-bit target.
#
# Do not read a bare `1..N` with no results as a pass -- that is what a
# payload that died after tap.plan() looks like, and it is how three of
# these were once mistaken for passing. The harness counts N results
# after the plan rather than trusting the plan alone.
#
# The next lever, if a test ever outgrows this again, is precompiled
# stripped bytecode: `luac -s` measured 11703 resident bytes per chunk
# against 14894 from source, and loads 16x faster, at the cost of the
# debugger's line numbers.
esp32_tests = [
  'generator',
  'chanstress',
  'channel',
  'sync',
]

if idf.found()
  foreach t : esp32_tests
    test('esp32-' + t, lua_interp,
      args: [boottest, files('../test/boot/test_' + t + '.lua')],
      # One build directory, rebuilt per test because the payload is
      # embedded rather than injected -- two of these at once would
      # race over it.
      is_parallel: false,
      protocol: 'tap',
      timeout: 300)
  endforeach
endif
