/* a disk, which here is a file named with -d: whole-disk sectors and a
 * capacity, with lib/gpt.lua and the filesystems above it unchanged.
 * pread and pwrite are synchronous, so nothing here yields -- a driver
 * whose device answers later has to, and this one does not.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "blk.h"
#include "hosted.h"

static int blkfd = -1;
static unsigned long long blk_sectors;
static int blk_ro;

int
blk_open(const char *path)
{
	struct stat st;
	int fd = open(path, O_RDWR);

	if (fd < 0) {
		fd = open(path, O_RDONLY);
		if (fd < 0)
			return -1;
		blk_ro = 1;
	}
	if (fstat(fd, &st) != 0) {
		close(fd);
		return -1;
	}
	blkfd = fd;
	blk_sectors = (unsigned long long)st.st_size / BLK_SECTOR;
	return 0;
}

int
blk_present(void)
{
	return blkfd >= 0 && blk_sectors > 0;
}

int
blk_readonly(void)
{
	return blk_ro;
}

unsigned long long
blk_capacity(void)
{
	return blk_sectors;
}

/* a short read past the end of a sparse image is not an error to the
 * caller: a disk reads zeros where nothing was written, and a file that
 * was never extended there is the same disk.
 */
int
blk_read(unsigned long long lba, void *buf, unsigned long n)
{
	char *p = buf;
	off_t off = (off_t)lba * BLK_SECTOR;

	if (!blk_present() || lba + n / BLK_SECTOR > blk_sectors)
		return -1;
	while (n > 0) {
		ssize_t r = pread(blkfd, p, n, off);

		if (r < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		if (r == 0) {
			memset(p, 0, n);
			return 0;
		}
		p += r;
		off += r;
		n -= (unsigned long)r;
	}
	return 0;
}

int
blk_write(unsigned long long lba, const void *buf, unsigned long n)
{
	const char *p = buf;
	off_t off = (off_t)lba * BLK_SECTOR;

	if (!blk_present() || blk_ro ||
	    lba + n / BLK_SECTOR > blk_sectors)
		return -1;
	while (n > 0) {
		ssize_t w = pwrite(blkfd, p, n, off);

		if (w < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		p += w;
		off += w;
		n -= (unsigned long)w;
	}
	return 0;
}
