#ifndef HOSTED_BLK_H
#define HOSTED_BLK_H

/* raw block i/o over a host file. */

#define BLK_SECTOR 512

/* the most one read or write moves, which bounds the buffer a request
 * allocates. The same figure every platform's driver uses, so a client
 * tuned against one behaves the same here.
 */
#define BLK_MAXIO 65536

int	blk_open(const char *path);	/* 0 ok */
int	blk_present(void);
int	blk_readonly(void);		/* the file would not open for write */
unsigned long long blk_capacity(void);	/* sectors */
int	blk_read(unsigned long long lba, void *buf, unsigned long n);
int	blk_write(unsigned long long lba, const void *buf, unsigned long n);

#endif
