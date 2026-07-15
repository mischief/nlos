#include <string.h>

void *
memcpy(void *dst, const void *src, size_t n)
{
	unsigned char *d = dst;
	const unsigned char *s = src;

	while (n--)
		*d++ = *s++;
	return dst;
}

void *
memmove(void *dst, const void *src, size_t n)
{
	unsigned char *d = dst;
	const unsigned char *s = src;

	if (d < s) {
		while (n--)
			*d++ = *s++;
	} else {
		d += n;
		s += n;
		while (n--)
			*--d = *--s;
	}
	return dst;
}

void *
memset(void *p, int c, size_t n)
{
	unsigned char *s = p;

	while (n--)
		*s++ = (unsigned char)c;
	return p;
}

int
memcmp(const void *pa, const void *pb, size_t n)
{
	const unsigned char *a = pa, *b = pb;

	for (; n; n--, a++, b++)
		if (*a != *b)
			return *a - *b;
	return 0;
}

void *
memchr(const void *p, int c, size_t n)
{
	const unsigned char *s = p;

	for (; n; n--, s++)
		if (*s == (unsigned char)c)
			return (void *)s;
	return 0;
}

size_t
strlen(const char *s)
{
	const char *p = s;

	while (*p)
		p++;
	return p - s;
}

int
strcmp(const char *a, const char *b)
{
	for (; *a && *a == *b; a++, b++)
		;
	return (unsigned char)*a - (unsigned char)*b;
}

int
strncmp(const char *a, const char *b, size_t n)
{
	if (n == 0)
		return 0;
	for (; --n && *a && *a == *b; a++, b++)
		;
	return (unsigned char)*a - (unsigned char)*b;
}

int
strcoll(const char *a, const char *b)
{
	return strcmp(a, b);	/* C locale only */
}

char *
strcpy(char *dst, const char *src)
{
	char *d = dst;

	while ((*d++ = *src++))
		;
	return dst;
}

char *
strncpy(char *dst, const char *src, size_t n)
{
	char *d = dst;

	for (; n && *src; n--)
		*d++ = *src++;
	while (n--)
		*d++ = 0;
	return dst;
}

char *
strcat(char *dst, const char *src)
{
	strcpy(dst + strlen(dst), src);
	return dst;
}

char *
strchr(const char *s, int c)
{
	for (;; s++) {
		if (*s == (char)c)
			return (char *)s;
		if (*s == 0)
			return 0;
	}
}

char *
strrchr(const char *s, int c)
{
	const char *last = 0;

	for (;; s++) {
		if (*s == (char)c)
			last = s;
		if (*s == 0)
			return (char *)last;
	}
}

char *
strpbrk(const char *s, const char *accept)
{
	for (; *s; s++)
		if (strchr(accept, *s))
			return (char *)s;
	return 0;
}

size_t
strspn(const char *s, const char *accept)
{
	const char *p = s;

	while (*p && strchr(accept, *p))
		p++;
	return p - s;
}

size_t
strcspn(const char *s, const char *reject)
{
	const char *p = s;

	while (*p && !strchr(reject, *p))
		p++;
	return p - s;
}

char *
strstr(const char *haystack, const char *needle)
{
	size_t n = strlen(needle);

	if (n == 0)
		return (char *)haystack;
	for (; *haystack; haystack++)
		if (*haystack == *needle && !strncmp(haystack, needle, n))
			return (char *)haystack;
	return 0;
}

char *
strerror(int errnum)
{
	(void)errnum;
	return "unknown error";
}
