#ifndef _STRING_H
#define _STRING_H

#include <stddef.h>

void	*memcpy(void *dst, const void *src, size_t n);
void	*memmove(void *dst, const void *src, size_t n);
void	*memset(void *s, int c, size_t n);
int	memcmp(const void *a, const void *b, size_t n);
void	*memchr(const void *s, int c, size_t n);

size_t	strlen(const char *s);
int	strcmp(const char *a, const char *b);
int	strncmp(const char *a, const char *b, size_t n);
int	strcoll(const char *a, const char *b);
char	*strcpy(char *dst, const char *src);
char	*strncpy(char *dst, const char *src, size_t n);
char	*strcat(char *dst, const char *src);
char	*strchr(const char *s, int c);
char	*strrchr(const char *s, int c);
char	*strpbrk(const char *s, const char *accept);
size_t	strspn(const char *s, const char *accept);
size_t	strcspn(const char *s, const char *reject);
char	*strstr(const char *haystack, const char *needle);
char	*strerror(int errnum);

#endif
