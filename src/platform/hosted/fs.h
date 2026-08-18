#ifndef FS_H
#define FS_H

/* the C loader's file source: a host directory, named with -r and
 * served as /. Paths arriving here are absolute in the guest and are
 * joined onto that root, so nothing above this file knows where the
 * tree really sits.
 */
#include <stddef.h>

struct fs_dirent {
	char name[256];
	unsigned long long size;
	int isdir;
};

/* `root` is a host path; fails only if it is not a directory. Read-only
 * unless `writable` -- a second lock outside the disk capability,
 * because this platform serves a working copy and a proc that writes
 * into it edits the tree you are working in.
 */
int	fs_init(const char *root, int writable);

/* is the embedded tree the whole filesystem? True when fs_init was
 * given no root, which is --no-host-fs.
 */
int	fs_embedded(void);

/* the guest path resolved against the root, into `buf`. Public so the
 * fopen wrapper can route luaL_loadfile the same way.
 */
int	fs_hostpath(const char *path, char *buf, size_t n);

void	*fs_open(const char *path, int write);
long	fs_read(void *f, void *buf, long n);
long	fs_write(void *f, const void *buf, long n);
int	fs_seek(void *f, long pos, int whence);
long	fs_tell(void *f);
int	fs_flush(void *f);
void	fs_close(void *f);

/* readdir returns 1 on an entry, 0 at end of directory, -1 on error;
 * stat returns 0 on success. `f` must be a handle on a directory for
 * readdir -- callers check with fs_stat first.
 */
int	fs_readdir(void *f, struct fs_dirent *ent);
int	fs_stat(void *f, struct fs_dirent *ent);

#endif
