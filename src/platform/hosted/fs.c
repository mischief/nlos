/* the C loader's file source: one host directory, served as /.
 * task/espsrv.lua serves it through los.fs, so the directory named with
 * -r becomes the root namespace and the tree runs from a working copy
 * with no image to build. Every path is joined onto that root, and
 * __wrap_fopen below joins luaL_loadfile's the same way.
 */

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "embedfs.h"
#include "fs.h"
#include "kernel.h"

/* this file's own opens are already host paths, so they take the real
 * one -- the wrapper below would root them a second time.
 */
FILE *__real_fopen(const char *path, const char *mode);
FILE *__real_fopen64(const char *path, const char *mode);

/* one bound for every path here, and it is a frame rather than a limit
 * anyone will reach: a host path is the root plus a guest path, and a
 * guest path is a module name.
 */
#define ROOTMAX 512
#define PATHMAX 1536

static char rootdir[ROOTMAX];
static int writable;

struct fs_handle {
	FILE *f;		/* a regular file, else null */
	DIR *d;			/* a directory, else null */
	const struct embedfile *e;	/* set when f is over embedded bytes */
	char path[PATHMAX];	/* the host path, for stat */
};

/* whether a host directory is being served at all. A null root is
 * --no-host-fs: the embedded tree is the whole filesystem, and every
 * path below resolves against it instead.
 */
int
fs_embedded(void)
{
	return rootdir[0] == '\0';
}

static const struct embedfile *
find_embed(const char *path)
{
	while (*path == '/')
		path++;
	for (size_t i = 0; i < embedfs_nfiles; i++) {
		const char *p = embedfs_files[i].path;

		while (*p == '/')
			p++;
		if (strcmp(p, path) == 0)
			return &embedfs_files[i];
	}
	return NULL;
}

int
fs_init(const char *root, int rw)
{
	struct stat st;
	char *real;

	writable = rw;
	if (!root) {
		rootdir[0] = '\0';	/* the embedded tree, and nothing else */
		return 0;
	}
	if (stat(root, &st) != 0 || !S_ISDIR(st.st_mode))
		return -1;
	real = realpath(root, NULL);
	if (!real)
		return -1;
	if (snprintf(rootdir, sizeof rootdir, "%s", real) >= (int)sizeof rootdir) {
		free(real);
		return -1;
	}
	free(real);
	return 0;
}

/* is any component of `path` a ".."? ns.lua resolves those long before
 * a path reaches this file, so one arriving here is either a bug or an
 * attempt to leave the root, and both answers are no.
 */
static int
has_parent_step(const char *path)
{
	for (const char *p = path; *p; p++) {
		if (p[0] != '.' || p[1] != '.')
			continue;
		if (p != path && p[-1] != '/')
			continue;
		if (p[2] == '\0' || p[2] == '/')
			return 1;
	}
	return 0;
}

/* a guest path against the root. A leading slash is the guest's root
 * and not the host's; anything else is relative to it. A symlink inside
 * the root that points outside is still followed, which is the limit of
 * what this checks.
 */
int
fs_hostpath(const char *path, char *buf, size_t n)
{
	if (!path || has_parent_step(path))
		return -1;
	while (*path == '/')
		path++;
	if (*path == '\0')
		return snprintf(buf, n, "%s", rootdir) < (int)n ? 0 : -1;
	return snprintf(buf, n, "%s/%s", rootdir, path) < (int)n ? 0 : -1;
}

void *
fs_open(const char *path, int write)
{
	char host[PATHMAX];
	struct stat st;

	if (write && !writable)
		return NULL;

	if (fs_embedded()) {
		const struct embedfile *e = find_embed(path);
		struct fs_handle *eh;

		if (!e || write)
			return NULL;
		eh = calloc(1, sizeof *eh);
		if (!eh)
			return NULL;
		/* fmemopen does not copy: the bytes are in .rodata and
		 * outlive every handle over them.
		 */
		eh->f = fmemopen((void *)e->data, e->len, "rb");
		eh->e = e;
		if (eh->f)
			return eh;
		free(eh);
		return NULL;
	}

	if (fs_hostpath(path, host, sizeof host) != 0)
		return NULL;

	struct fs_handle *h = calloc(1, sizeof *h);

	if (!h)
		return NULL;
	snprintf(h->path, sizeof h->path, "%s", host);

	/* a directory opens as one, so fs_readdir has something to read
	 * and fs_stat can say which it is. fopen on a directory succeeds
	 * on linux and every read from it fails.
	 */
	if (!write && stat(host, &st) == 0 && S_ISDIR(st.st_mode)) {
		h->d = opendir(host);
		if (h->d)
			return h;
		free(h);
		return NULL;
	}

	h->f = __real_fopen64(host, write ? "wb+" : "rb");
	if (h->f)
		return h;
	free(h);
	return NULL;
}

long
fs_read(void *vf, void *buf, long n)
{
	struct fs_handle *h = vf;

	if (!h->f)
		return -1;
	return (long)fread(buf, 1, (size_t)n, h->f);
}

long
fs_write(void *vf, const void *buf, long n)
{
	struct fs_handle *h = vf;

	if (!h->f)
		return -1;
	return (long)fwrite(buf, 1, (size_t)n, h->f);
}

int
fs_seek(void *vf, long pos, int whence)
{
	struct fs_handle *h = vf;

	if (!h->f)
		return -1;
	return fseek(h->f, pos, whence);
}

long
fs_tell(void *vf)
{
	struct fs_handle *h = vf;

	if (!h->f)
		return -1;
	return ftell(h->f);
}

int
fs_flush(void *vf)
{
	struct fs_handle *h = vf;

	if (!h->f)
		return -1;
	return fflush(h->f);
}

void
fs_close(void *vf)
{
	struct fs_handle *h = vf;

	if (!h)
		return;
	if (h->f)
		fclose(h->f);
	if (h->d)
		closedir(h->d);
	free(h);
}

/* one entry: 1 on an entry, 0 at the end, -1 on a handle that is not a
 * directory. . and .. are skipped -- a namespace resolves them above
 * this, and 9P has no use for them.
 */
int
fs_readdir(void *vf, struct fs_dirent *ent)
{
	struct fs_handle *h = vf;
	struct dirent *de;
	char host[PATHMAX];
	struct stat st;

	if (!h->d)
		return -1;
	do {
		de = readdir(h->d);
		if (!de)
			return 0;
	} while (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0);

	memset(ent, 0, sizeof *ent);
	if (snprintf(ent->name, sizeof ent->name, "%s", de->d_name) >=
	    (int)sizeof ent->name)
		return -1;
	if (snprintf(host, sizeof host, "%s/%s", h->path, de->d_name) >=
	    (int)sizeof host)
		return -1;
	if (stat(host, &st) == 0) {
		ent->size = (unsigned long long)st.st_size;
		ent->isdir = S_ISDIR(st.st_mode);
	}
	return 1;
}

int
fs_stat(void *vf, struct fs_dirent *ent)
{
	struct fs_handle *h = vf;
	struct stat st;
	const char *slash, *base;

	if (h->e) {
		slash = strrchr(h->e->path, '/');
		base = slash ? slash + 1 : h->e->path;
		memset(ent, 0, sizeof *ent);
		if (snprintf(ent->name, sizeof ent->name, "%s", base) >=
		    (int)sizeof ent->name)
			return -1;
		ent->size = h->e->len;
		ent->isdir = 0;
		return 0;
	}

	slash = strrchr(h->path, '/');
	base = slash ? slash + 1 : h->path;
	if (stat(h->path, &st) != 0)
		return -1;
	memset(ent, 0, sizeof *ent);
	if (snprintf(ent->name, sizeof ent->name, "%s", base) >=
	    (int)sizeof ent->name)
		return -1;
	ent->size = (unsigned long long)st.st_size;
	ent->isdir = S_ISDIR(st.st_mode);
	return 0;
}

/* every fopen our code links against: luaL_loadfile's and liolib's. The
 * host libc's own calls are not wrapped, so this sees exactly the
 * guest's opens -- rooted like everything else, and gated for write on
 * the disk capability, as src/libc/stdio.c gates the other platforms.
 */
static FILE *
open_rooted(const char *path, const char *mode, FILE *(*real)(const char *,
    const char *))
{
	char host[PATHMAX];

	if (*mode == 'w' || *mode == 'a')
		if (!writable || !kernel_current_has_disk())
			return NULL;

	/* with no directory to serve, require() reads the embedded tree.
	 * fmemopen gives luaL_loadfile an ordinary stream over it.
	 */
	if (fs_embedded()) {
		const struct embedfile *e = find_embed(path);

		if (!e || *mode != 'r')
			return NULL;
		return fmemopen((void *)e->data, e->len, "rb");
	}

	if (fs_hostpath(path, host, sizeof host) != 0)
		return NULL;
	return real(host, mode);
}

/* both spellings, because _FILE_OFFSET_BITS=64 turns every fopen in the
 * translation units above into a call to fopen64, and a wrap of the
 * name nobody references silently does nothing.
 */
FILE *__wrap_fopen(const char *path, const char *mode);
FILE *__wrap_fopen64(const char *path, const char *mode);

FILE *
__wrap_fopen(const char *path, const char *mode)
{
	return open_rooted(path, mode, __real_fopen);
}

FILE *
__wrap_fopen64(const char *path, const char *mode)
{
	return open_rooted(path, mode, __real_fopen64);
}
