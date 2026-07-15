#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* stdio over the platform layer:
 *   stdout/stderr -> efi console (console.c)
 *   stdin         -> efi keyboard, echoing, cr->lf
 *   files         -> esp via simple filesystem protocol (fs.c)
 */

extern void console_write(const char *s, size_t n);
extern int console_getchar(void);

#include "fs.h"
#include "platform.h"

#define T_STDIN		0
#define T_STDOUT	1
#define T_STDERR	2
#define T_FILE		3

struct _FILE {
	int tag;
	void *fsf;	/* fs.c handle for T_FILE */
	int eof;
	int err;
	int ungot;	/* one pushed-back char or EOF */
};

static FILE stdfiles[3] = {
	{ T_STDIN, 0, 0, 0, EOF },
	{ T_STDOUT, 0, 0, 0, EOF },
	{ T_STDERR, 0, 0, 0, EOF },
};

FILE *stdin = &stdfiles[0];
FILE *stdout = &stdfiles[1];
FILE *stderr = &stdfiles[2];

FILE *
fopen(const char *path, const char *mode)
{
	FILE *f;
	void *fsf;
	int write = (*mode == 'w' || *mode == 'a');

	fsf = fs_open(path, write);
	if (!fsf)
		return 0;
	f = malloc(sizeof *f);
	if (!f) {
		fs_close(fsf);
		return 0;
	}
	f->tag = T_FILE;
	f->fsf = fsf;
	f->eof = 0;
	f->err = 0;
	f->ungot = EOF;
	if (*mode == 'a')
		fs_seek(fsf, 0, SEEK_END);
	return f;
}

FILE *
freopen(const char *path, const char *mode, FILE *f)
{
	(void)path;
	(void)mode;
	(void)f;
	return 0;	/* only used for stdin scripts; not supported */
}

int
fclose(FILE *f)
{
	if (!f || f->tag != T_FILE)
		return EOF;
	fs_close(f->fsf);
	free(f);
	return 0;
}

size_t
fread(void *ptr, size_t size, size_t nmemb, FILE *f)
{
	size_t want = size * nmemb;
	long got;
	char *p = ptr;

	if (want == 0)
		return 0;
	if (f->tag == T_STDIN) {
		size_t i;

		for (i = 0; i < want; i++) {
			int c = getc(f);

			if (c == EOF)
				break;
			p[i] = c;
		}
		return size ? i / size : 0;
	}
	if (f->tag != T_FILE)
		return 0;
	if (f->ungot != EOF && want > 0) {
		*p++ = f->ungot;
		f->ungot = EOF;
		want--;
		got = fs_read(f->fsf, p, want);
		if (got < 0) {
			f->err = 1;
			return 0;
		}
		got++;
	} else {
		got = fs_read(f->fsf, p, want);
		if (got < 0) {
			f->err = 1;
			return 0;
		}
	}
	if ((size_t)got < want)
		f->eof = 1;
	return size ? (size_t)got / size : 0;
}

size_t
fwrite(const void *ptr, size_t size, size_t nmemb, FILE *f)
{
	size_t n = size * nmemb;

	switch (f->tag) {
	case T_STDOUT:
	case T_STDERR:
		console_write(ptr, n);
		return nmemb;
	case T_FILE: {
		long w = fs_write(f->fsf, ptr, n);

		if (w < 0) {
			f->err = 1;
			return 0;
		}
		return size ? (size_t)w / size : 0;
	}
	}
	return 0;
}

int
getc(FILE *f)
{
	unsigned char c;

	if (f->ungot != EOF) {
		int r = f->ungot;

		f->ungot = EOF;
		return r;
	}
	switch (f->tag) {
	case T_STDIN:
		return console_getchar();
	case T_FILE: {
		long got = fs_read(f->fsf, &c, 1);

		if (got == 1)
			return c;
		if (got == 0)
			f->eof = 1;
		else
			f->err = 1;
		return EOF;
	}
	}
	return EOF;
}

int
ungetc(int c, FILE *f)
{
	if (c == EOF || f->ungot != EOF)
		return EOF;
	f->ungot = (unsigned char)c;
	f->eof = 0;
	return c;
}

char *
fgets(char *s, int size, FILE *f)
{
	int i = 0;

	if (size <= 1)
		return 0;
	while (i < size - 1) {
		int c = getc(f);

		if (c == EOF)
			break;
		s[i++] = c;
		if (c == '\n')
			break;
	}
	if (i == 0)
		return 0;
	s[i] = 0;
	return s;
}

int
fputs(const char *s, FILE *f)
{
	return fwrite(s, 1, strlen(s), f) ? 0 : EOF;
}

int
fseek(FILE *f, long offset, int whence)
{
	if (f->tag != T_FILE)
		return -1;
	f->ungot = EOF;
	f->eof = 0;
	return fs_seek(f->fsf, offset, whence);
}

long
ftell(FILE *f)
{
	long pos;

	if (f->tag != T_FILE)
		return -1;
	pos = fs_tell(f->fsf);
	if (pos >= 0 && f->ungot != EOF)
		pos--;
	return pos;
}

int
fflush(FILE *f)
{
	if (f && f->tag == T_FILE)
		return fs_flush(f->fsf);
	return 0;
}

int
feof(FILE *f)
{
	return f->eof;
}

int
ferror(FILE *f)
{
	return f->err;
}

void
clearerr(FILE *f)
{
	f->eof = 0;
	f->err = 0;
}

int
setvbuf(FILE *f, char *buf, int mode, size_t size)
{
	(void)f;
	(void)buf;
	(void)mode;
	(void)size;
	return 0;	/* unbuffered anyway */
}

FILE *
tmpfile(void)
{
	return 0;
}

int
fprintf(FILE *f, const char *fmt, ...)
{
	char buf[1024];
	va_list ap;
	int n;

	va_start(ap, fmt);
	n = vsnprintf(buf, sizeof buf, fmt, ap);
	va_end(ap);
	if (n > (int)sizeof buf - 1)
		n = sizeof buf - 1;
	fwrite(buf, 1, n, f);
	return n;
}

int
snprintf(char *buf, size_t n, const char *fmt, ...)
{
	va_list ap;
	int r;

	va_start(ap, fmt);
	r = vsnprintf(buf, n, fmt, ap);
	va_end(ap);
	return r;
}
