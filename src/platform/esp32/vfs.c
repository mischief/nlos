/* the embedded set, published to newlib as a read-only filesystem.
 *
 * The other three platforms do not need this: they compile
 * src/libc/stdio.c, whose fopen calls fs_open directly, so lua's
 * luaL_loadfile reaches the embedded files with nothing in between.
 * Here newlib is IDF's and its fopen goes to IDF's VFS, which has never
 * heard of embedfs -- so every driver task and the boot payload failed
 * to load with "No such file or directory", an errno string that is the
 * giveaway that the request never reached this tree at all.
 *
 * Registering here rather than replacing fopen is the smaller move: it
 * puts the embedded files where every consumer already looks, so
 * luaL_loadfile, require's path searcher and a later io.open all work
 * without any of them knowing. It is also the only one available --
 * defining our own fopen would collide with newlib's, exactly as
 * console_write collided with esp_stdio's.
 *
 * One prefix per top-level directory, because IDF matches a VFS by
 * path prefix and hands the callback the REMAINDER. The registered
 * prefix comes back as the context so the full path can be put together
 * again, which is what embed_load wants.
 */

#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <string.h>
#include <sys/stat.h>

#include <esp_vfs.h>

#include "lua.h"
#include "lauxlib.h"

#include "embedfs.h"
#include "esp32.h"
#include "fs.h"

#define MAXOPEN 8

struct vfd {
	int used;
	const char *data;
	size_t len;
	size_t pos;
};

static struct vfd fds[MAXOPEN];

/* prefix + remainder, into a buffer big enough for the paths the embed
 * set can hold. Long ones are refused rather than truncated: a
 * truncated path that happens to match another file is worse than a
 * miss.
 */
static int
fullpath(const char *prefix, const char *rest, char *out, size_t n)
{
	size_t a = strlen(prefix), b = strlen(rest);

	if (a + b + 1 > n)
		return -1;
	memcpy(out, prefix, a);
	memcpy(out + a, rest, b);
	out[a + b] = 0;
	return 0;
}

static int
vfs_open(void *ctx, const char *path, int flags, int mode)
{
	char full[128];
	char *buf;
	size_t len;

	(void)mode;

	/* read-only, and says so rather than pretending: an embedded file
	 * has nowhere to put a write.
	 */
	if ((flags & O_ACCMODE) != O_RDONLY) {
		errno = EROFS;
		return -1;
	}

	if (fullpath((const char *)ctx, path, full, sizeof full) != 0) {
		errno = ENAMETOOLONG;
		return -1;
	}

	/* Point at the embedded bytes; do NOT copy them. embed_load hands
	 * out a malloc'd duplicate, and lua opens every module twice --
	 * once for readable(), once to load it -- so a 44KB module cost
	 * 88KB of heap per require and the third open of it failed for
	 * want of memory, reported as "no such file". The data is const
	 * and memory-mapped from flash, so a pointer is both correct and
	 * free.
	 */
	const struct embedfile *e = NULL;

	for (size_t i = 0; i < embedfs_nfiles; i++) {
		if (strcmp(embedfs_files[i].path, full) == 0) {
			e = &embedfs_files[i];
			break;
		}
	}
	if (!e) {
		errno = ENOENT;
		return -1;
	}
	buf = (char *)e->data;
	len = e->len;

	for (int i = 0; i < MAXOPEN; i++) {
		if (fds[i].used)
			continue;
		fds[i].used = 1;
		fds[i].data = buf;
		fds[i].len = len;
		fds[i].pos = 0;
		return i;
	}
	errno = EMFILE;
	return -1;
}

static ssize_t
vfs_read(void *ctx, int fd, void *dst, size_t size)
{
	(void)ctx;

	if (fd < 0 || fd >= MAXOPEN || !fds[fd].used) {
		errno = EBADF;
		return -1;
	}

	struct vfd *f = &fds[fd];
	size_t left = f->len - f->pos;

	if (size > left)
		size = left;
	memcpy(dst, f->data + f->pos, size);
	f->pos += size;
	return (ssize_t)size;
}

static int
vfs_close(void *ctx, int fd)
{
	(void)ctx;

	if (fd < 0 || fd >= MAXOPEN || !fds[fd].used) {
		errno = EBADF;
		return -1;
	}
	fds[fd].data = NULL;
	fds[fd].used = 0;
	return 0;
}

static off_t
vfs_lseek(void *ctx, int fd, off_t off, int whence)
{
	(void)ctx;

	if (fd < 0 || fd >= MAXOPEN || !fds[fd].used) {
		errno = EBADF;
		return -1;
	}

	struct vfd *f = &fds[fd];
	off_t base = 0;

	switch (whence) {
	case SEEK_SET: base = 0; break;
	case SEEK_CUR: base = (off_t)f->pos; break;
	case SEEK_END: base = (off_t)f->len; break;
	default:
		errno = EINVAL;
		return -1;
	}
	if (base + off < 0) {
		errno = EINVAL;
		return -1;
	}
	f->pos = (size_t)(base + off);
	return (off_t)f->pos;
}

static int
vfs_fstat(void *ctx, int fd, struct stat *st)
{
	(void)ctx;

	if (fd < 0 || fd >= MAXOPEN || !fds[fd].used) {
		errno = EBADF;
		return -1;
	}
	memset(st, 0, sizeof *st);
	st->st_mode = S_IFREG;
	st->st_size = (off_t)fds[fd].len;
	return 0;
}

/* The top-level directories the embed set uses. A file embedded outside
 * these is invisible to fopen, so adding one means adding it here --
 * which is why the list is short and next to the reason.
 */
static const char *const prefixes[] = { "/boot", "/lib", "/task", "/bin" };

void
vfs_embed_register(void)
{
	static const esp_vfs_t vfs = {
		.flags = ESP_VFS_FLAG_CONTEXT_PTR,
		.open_p = vfs_open,
		.read_p = vfs_read,
		.close_p = vfs_close,
		.lseek_p = vfs_lseek,
		.fstat_p = vfs_fstat,
	};

	for (size_t i = 0; i < sizeof prefixes / sizeof prefixes[0]; i++)
		esp_vfs_register(prefixes[i], &vfs, (void *)prefixes[i]);
}

/* ---- los.rom: the embedded set, as data ---- */

/* Every proc can already reach these bytes: require() loads modules
 * from them through luaL_loadfile, below the lua-level io stripping
 * (kernel_strip_io). What this adds is the ability to list them, and
 * to read one without executing it.
 *
 * This grants no authority that require does not. The set is the OS's
 * own lib/, task/ and bin/, fixed at build time, in flash, immutable at
 * runtime. It is data, on the same argument as los.font's glyphs.
 *
 * With it, a namespace can be mounted read-only over the embedded tree
 * in any proc, with no filesystem server behind it. lib/procfs.lua
 * already uses that shape for a local backend.
 */
static int
rom_list(lua_State *L)
{
	lua_createtable(L, (int)embedfs_nfiles, 0);
	for (size_t i = 0; i < embedfs_nfiles; i++) {
		lua_pushstring(L, embedfs_files[i].path);
		lua_rawseti(L, -2, (lua_Integer)i + 1);
	}
	return 1;
}

static const struct embedfile *
rom_find(const char *path)
{
	for (size_t i = 0; i < embedfs_nfiles; i++)
		if (strcmp(embedfs_files[i].path, path) == 0)
			return &embedfs_files[i];
	return 0;
}

/* the whole file. These are source and bytecode measured in kilobytes,
 * so a partial read would buy nothing and add a place to get wrong.
 */
static int
rom_read(lua_State *L)
{
	const char *path = luaL_checkstring(L, 1);
	const struct embedfile *f = rom_find(path);

	if (!f)
		return 0;
	lua_pushlstring(L, (const char *)f->data, f->len);
	return 1;
}

static int
rom_size(lua_State *L)
{
	const char *path = luaL_checkstring(L, 1);
	const struct embedfile *f = rom_find(path);

	if (!f)
		return 0;
	lua_pushinteger(L, (lua_Integer)f->len);
	return 1;
}

static const luaL_Reg romlib[] = {
	{ "list", rom_list },
	{ "read", rom_read },
	{ "size", rom_size },
	{ NULL, NULL }
};

int luaopen_los_rom(lua_State *L);

int
luaopen_los_rom(lua_State *L)
{
	luaL_newlib(L, romlib);
	return 1;
}
