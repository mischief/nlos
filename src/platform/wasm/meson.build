# the wasm machine: one module, its imports and the tree inside it.

kernel_src += files(
  'blk.c',
  'clock.c',
  'console.c',
  'drivers.c',
  'fb.c',
  'fs.c',
  'main.c',
  'malloc.c',
  'mem.c',
  'pmm.c',
  'smp.c',
  'ws.c',
)

# the tree, carried in the module, because there is nothing else here to
# be a root. The list is tools/embedtree.lua's rather than a literal:
# a curated one would be a second place to forget a new module.
wasm_embed = run_command(lua_interp, files('../../../tools/embedtree.lua'),
  meson.project_source_root(),
  check: true).stdout().strip().split('\n')

embed_args = [
  '/etc/services.lua=' + meson.project_source_root() /
    'machine/wasm/services.lua',
  '/etc/dio.lua=' + meson.project_source_root() / 'machine/wasm/dio.lua',
]
embed_inputs = []
foreach f : wasm_embed
  embed_args += '/' + f + '=' + meson.project_source_root() / f
  embed_inputs += files('../../../' + f)
endforeach
embed_args += '/VERSION.app=' + version_txt.full_path()

kernel_src += custom_target('embedfs.c',
  output: 'embedfs.c',
  input: embed_inputs + files('../../../machine/wasm/services.lua',
    '../../../machine/wasm/dio.lua'),
  command: [lua_interp, files('../../../tools/gen_embedfs.lua'), '@OUTPUT@'] +
    embed_args,
  depends: version_txt,
)

# no entry point: the embedder calls boot(), which main.c exports by
# name. __heap_base is the linker's, and mem.c needs it named to be
# able to grow the memory above it.
luaos_wasm = executable('luaos',
  kernel_src + libc_src + arch_src,
  include_directories: inc,
  c_args: plat_args + hardening_args,
  link_with: lua_lib,
  link_args: [
    '-nostdlib',
    '-Wl,--no-entry',
    '-Wl,--export=__heap_base',
  ],
  name_suffix: 'wasm',
  build_by_default: true,
)

# `ninja -C build-wasm wasm` serves the page with the two headers
# SharedArrayBuffer needs, and rebuilds the module first. Optional
# because the machine itself needs no engine to build.
node_prog = find_program('node', 'nodejs', required: false)
if node_prog.found()
  run_target('wasm',
    command: [node_prog, files('../../../machine/wasm/serve.js'),
      '8000', luaos_wasm],
    depends: luaos_wasm,
  )
  # the same module in a terminal, with no screen and no panel.
  run_target('wasm-console',
    command: [node_prog, files('../../../machine/wasm/run.js'), luaos_wasm],
    depends: luaos_wasm,
  )
endif
