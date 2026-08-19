# ---- the esp32 boards, built by IDF from here ----
#
# IDF owns that build and cannot be replaced by this one: the Kconfig
# every component compiles against, the FreeRTOS port and the closed
# wifi libraries are all its. What this removes is having to drive two
# build systems by hand.
#
# LUAOS_HOSTLIB is why these hang off meson at all. mkfatimg holds a
# sector in a los.buf, so the luafs image cannot be built without the
# host module -- which is right here, and now gets built first.
#
# run_target rather than custom_target: what IDF's inputs are is IDF's
# business, so these always run and let it decide what is stale. That
# is also why they are not part of all.
esp32_idf = get_option('esp32_idf')

if esp32_idf != ''
  if not lua54_dep.found()
    error('esp32_idf needs the host lua: mkfatimg builds the luafs image')
  endif

  esp32_sh = files('../../../tools/esp32.sh')
  # LUAOS_ESPPORT is only the default: ESPPORT from the caller's
  # environment wins, so two boards are told apart per invocation
  # rather than by reconfiguring.
  esp32_env = {
    'LUAOS_HOSTLIB': meson.current_build_dir(),
    'LUAOS_ESPPORT': get_option('esp32_port'),
  }

  # cardputer is not here: 8MB of flash and no PSRAM, which this does
  # not fit in. The README still says how to build one by hand.
  foreach board : ['tdeck', 'c5', 'freenove', 'qemu']
    run_target('esp32-' + board,
      command: [esp32_sh, esp32_idf, board, 'build'],
      env: esp32_env,
      depends: buf_native_host,
    )

    # the emulator has nothing to flash to
    if board != 'qemu'
      run_target('esp32-' + board + '-flash',
        command: [esp32_sh, esp32_idf, board, 'flash'],
        env: esp32_env,
        depends: buf_native_host,
      )
    endif
  endforeach
endif
