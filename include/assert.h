#ifndef _ASSERT_H
#define _ASSERT_H

_Noreturn void __assert_fail(const char *expr, const char *file, int line);

#ifdef NDEBUG
#define assert(c) ((void)0)
#else
#define assert(c) ((c) ? (void)0 : __assert_fail(#c, __FILE__, __LINE__))
#endif

#endif
