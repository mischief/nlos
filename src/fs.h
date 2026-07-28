#ifndef FS_H
#define FS_H

/* one directory entry, flattened out of EFI_FILE_INFO. name is ascii;
 * see fs.c on why.
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
