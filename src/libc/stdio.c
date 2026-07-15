#include <stdio.h>
#include <string.h>

/* console-only stdio. FILE is just a tag; the platform layer
 * (src/console.c) does the actual efi output.
 */

extern void console_write(const char *s, size_t n);

struct _FILE {
	int tag;
};

static FILE files[3] = { { 0 }, { 1 }, { 2 } };

FILE *stdin = &files[0];
FILE *stdout = &files[1];
FILE *stderr = &files[2];

size_t
fwrite(const void *ptr, size_t size, size_t nmemb, FILE *f)
{
	size_t n = size * nmemb;

	if (f == stdout || f == stderr) {
		console_write(ptr, n);
		return nmemb;
	}
	return 0;
}

int
fputs(const char *s, FILE *f)
{
	return fwrite(s, 1, strlen(s), f) ? 0 : EOF;
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
fflush(FILE *f)
{
	(void)f;
	return 0;
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

/* no filesystem yet: everything below fails cleanly */

FILE *
fopen(const char *path, const char *mode)
{
	(void)path;
	(void)mode;
	return 0;
}

FILE *
freopen(const char *path, const char *mode, FILE *f)
{
	(void)path;
	(void)mode;
	(void)f;
	return 0;
}

int
fclose(FILE *f)
{
	(void)f;
	return EOF;
}

size_t
fread(void *ptr, size_t size, size_t nmemb, FILE *f)
{
	(void)ptr;
	(void)size;
	(void)nmemb;
	(void)f;
	return 0;
}

char *
fgets(char *s, int size, FILE *f)
{
	(void)s;
	(void)size;
	(void)f;
	return 0;
}

int
getc(FILE *f)
{
	(void)f;
	return EOF;
}

int
ungetc(int c, FILE *f)
{
	(void)c;
	(void)f;
	return EOF;
}

int
feof(FILE *f)
{
	(void)f;
	return 1;
}

int
ferror(FILE *f)
{
	(void)f;
	return 0;
}

void
clearerr(FILE *f)
{
	(void)f;
}
