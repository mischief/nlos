#ifndef FS_H
#define FS_H

/* the C loader's file source. On microvm that is the embedded set and
 * nothing else, so a path outside it fails here -- dirs.c and
 * libc/stdio.c already handle fs_open() returning 0. See fs.c on why
 * this is not the whole filesystem: what a proc opens through its
 * namespace, virtio-9p included, never reaches this interface.
 */
struct fs_dirent {
	char name[256];
	unsigned long long size;
	int isdir;
};

int	fs_init(void);
void	*fs_open(const char *path, int write);
long	fs_read(void *f, void *buf, long n);
long	fs_write(void *f, const void *buf, long n);
int	fs_seek(void *f, long pos, int whence);
long	fs_tell(void *f);
int	fs_flush(void *f);
void	fs_close(void *f);

int	fs_readdir(void *f, struct fs_dirent *ent);
int	fs_stat(void *f, struct fs_dirent *ent);

#endif
