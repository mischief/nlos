# the wasm machine: one module, its imports and the tree inside it.

kernel_src += files(
  '../../../src/platform/wasm/clock.c',
  '../../../src/platform/wasm/console.c',
  '../../../src/platform/wasm/drivers.c',
  '../../../src/platform/wasm/fs.c',
  '../../../src/platform/wasm/main.c',
  '../../../src/platform/wasm/malloc.c',
  '../../../src/platform/wasm/mem.c',
  '../../../src/platform/wasm/pmm.c',
  '../../../src/platform/wasm/smp.c',
)

# the tree, carried in the module, because there is nothing else here to
# be a root. The list is tools/embedtree.lua's rather than a literal:
# a curated one would be a second place to forget a new module.
wasm_embed = run_command(lua_interp, files('../../../tools/embedtree.lua'),
  meson.project_source_root(),
  check: true).stdout().strip().split('\n')

embed_args = ['/etc/services.lua=' + meson.project_source_root() /
    'machine/wasm/services.lua']
embed_inputs = []
foreach f : wasm_embed
  embed_args += '/' + f + '=' + meson.project_source_root() / f
  embed_inputs += files('../../../' + f)
endforeach
embed_args += '/VERSION.app=' + version_txt.full_path()

kernel_src += custom_target('embedfs.c',
  output: 'embedfs.c',
  input: embed_inputs + files('../../../machine/wasm/services.lua'),
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
