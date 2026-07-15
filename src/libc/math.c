/* portable bit-twiddling math; transcendentals live in src/<arch>/math.c */

#include <math.h>
#include <stdint.h>

union dbits {
	double d;
	uint64_t u;
};

double
frexp(double x, int *e)
{
	union dbits b = { .d = x };
	int exp = (b.u >> 52) & 0x7ff;

	*e = 0;
	if (exp == 0x7ff || x == 0.0)
		return x;	/* inf, nan, zero */
	if (exp == 0) {		/* subnormal: normalize first */
		b.d = x * 0x1p64;
		exp = (b.u >> 52) & 0x7ff;
		*e = -64;
	}
	*e += exp - 1022;
	b.u = (b.u & ~(0x7ffULL << 52)) | (1022ULL << 52);
	return b.d;
}

double
ldexp(double x, int n)
{
	union dbits b;

	/* scale in chunks so intermediate factors stay representable */
	while (n > 1023) {
		x *= 0x1p1023;
		n -= 1023;
	}
	while (n < -1022) {
		x *= 0x1p-1022;
		n += 1022;
	}
	b.u = (uint64_t)(n + 1023) << 52;
	return x * b.d;
}

/* out-of-line symbols for the inline-header functions, in case gcc
 * decides to emit real calls (built with the header inlines suppressed)
 */
#define EMIT(name) \
	double __luaos_##name(double x) asm(#name); \
	double __luaos_##name(double x) { return __builtin_##name(x); }

EMIT(fabs)
EMIT(sqrt)
EMIT(floor)
EMIT(ceil)
