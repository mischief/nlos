#ifndef _STDLIB_H
#define _STDLIB_H

#include <stddef.h>

#define EXIT_SUCCESS	0
#define EXIT_FAILURE	1

void	*malloc(size_t n);
void	*calloc(size_t nmemb, size_t size);
void	*realloc(void *p, size_t n);
void	free(void *p);

double	strtod(const char *s, char **end);

int	abs(int x);
long	labs(long x);

char	*getenv(const char *name);

_Noreturn void abort(void);
_Noreturn void exit(int status);

#endif
