# the hosted machine: a linux process. Its sources, its link and the
# tree it serves, which is the whole of what makes it a platform.

kernel_src += files(
  '../../../src/platform/hosted/blk.c',
  '../../../src/platform/hosted/clock.c',
  '../../../src/platform/hosted/fb.c',
  '../../../src/platform/hosted/console.c',
  '../../../src/platform/hosted/drivers.c',
  '../../../src/platform/hosted/fs.c',
  '../../../src/platform/hosted/machine.c',
  '../../../src/platform/hosted/main.c',
  '../../../src/platform/hosted/net.c',
  '../../../src/platform/hosted/smp.c',
)

# the tree, carried in the binary, so --no-host-fs has a root. The
# list is tools/embedtree.lua's rather than a literal here because it
# is every lua file under lib, bin and task: a curated list would be a
# second place to forget a new module.
hosted_embed = run_command(lua_interp, files('../../../tools/embedtree.lua'),
  meson.project_source_root(),
  check: true).stdout().strip().split('\n')

embed_args = ['/etc/services.lua=' + meson.project_source_root() /
    'machine/hosted/services.lua']
# the same list twice over: the guest's name for a module is the
# path as written, and the input is that path against the root.
embed_inputs = []
foreach f : hosted_embed
  embed_args += '/' + f + '=' + meson.project_source_root() / f
  embed_inputs += files('../../../' + f)
endforeach
embed_args += '/VERSION.app=' + version_txt.full_path()

kernel_src += custom_target('embedfs.c',
  output: 'embedfs.c',
  input: embed_inputs +
    files('../../../machine/hosted/services.lua'),
  command: [lua_interp, files('../../../tools/gen_embedfs.lua'), '@OUTPUT@'] + embed_args,
  depends: version_txt,
)

# an ordinary program. --wrap=fopen is what keeps luaL_loadfile and
# io.open inside the served root and behind the disk capability; see
# src/platform/hosted/fs.c.
luaos_hosted = executable('luaos-hosted',
  kernel_src,
  include_directories: inc,
  c_args: plat_args + hardening_args,
  link_with: lua_lib,
  dependencies: [cc.find_library('m', required: false), sdl_dep,
    dependency('threads')],
  link_args: ['-Wl,--wrap=fopen', '-Wl,--wrap=fopen64'] +
    (asan_build ? ['-static-libasan'] : []) +
    (tsan_build ? ['-static-libtsan'] : []),
  build_by_default: true,
)

# the tree as it stands, served as /. Nothing is built into an image,
# so an edit under lib/ is live on the next run.
run_target('hosted',
  command: [luaos_hosted, '-r', meson.project_source_root()],
)

# the same binary with no directory behind it, which is what ships.
run_target('hosted-selfcontained',
  command: [luaos_hosted, '--no-host-fs'],
)

