#ifndef _STDIO_H
#define _STDIO_H

#include <stddef.h>
#include <stdarg.h>

#define EOF	(-1)
#define BUFSIZ	512

typedef struct _FILE FILE;

extern FILE *stdin, *stdout, *stderr;

/* real output paths */
size_t	fwrite(const void *ptr, size_t size, size_t nmemb, FILE *f);
int	fprintf(FILE *f, const char *fmt, ...);
int	fflush(FILE *f);
int	fputs(const char *s, FILE *f);

int	snprintf(char *buf, size_t n, const char *fmt, ...);
int	vsnprintf(char *buf, size_t n, const char *fmt, va_list ap);

/* stubs until a filesystem exists (lauxlib references these) */
FILE	*fopen(const char *path, const char *mode);
FILE	*freopen(const char *path, const char *mode, FILE *f);
int	fclose(FILE *f);
size_t	fread(void *ptr, size_t size, size_t nmemb, FILE *f);
char	*fgets(char *s, int size, FILE *f);
int	getc(FILE *f);
int	ungetc(int c, FILE *f);
int	feof(FILE *f);
int	ferror(FILE *f);
void	clearerr(FILE *f);

#endif
