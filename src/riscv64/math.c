/* riscv64's rounding floor: floor, ceil and round.
 *
 * every other arch here gets these from one instruction -- sse4.1
 * roundsd on x86_64, frintm/frintp/frinta on aarch64 -- so
 * include/math.h can define them as inline wrappers over the builtin.
 * the riscv D extension has no round-to-integral at all. That is Zfa,
 * which qemu has but ratified silicon mostly does not, and requiring it
 * to run a lua interpreter is a bad trade. so gcc answers
 * __builtin_floor with a call to floor(), the wrappers would be calling
 * themselves, and these are real functions instead. everything above
 * them -- the transcendentals in src/libc/softmath.c -- is shared with
 * aarch64 unchanged.
 *
 * fabs.d and fsqrt.d do exist, so fabs and sqrt stay inline. sqrt needs
 * -fno-math-errno to stay that way (see meson.build), or gcc keeps a
 * call to sqrt() on the negative-argument path for errno's sake.
 */

#include <math.h>
#include <stdint.h>

union dbits {
	double d;
	uint64_t u;
};

/* round toward zero, by clearing the fraction bits outright. an
 * exponent of 52 or more means every bit is already integral -- which
 * covers inf and nan too, and is why they fall out of the callers
 * correctly without a test. below an exponent of 0 there is no integer
 * part at all, and the sign has to be carried by hand so that
 * trunc(-0.3) is -0.0 rather than +0.0.
 */
static double
trunc_(double x)
{
	union dbits b = { .d = x };
	int e = (int)((b.u >> 52) & 0x7ff) - 1023;

	if (e >= 52)
		return x;
	if (e < 0)
		return (b.u >> 63) ? -0.0 : 0.0;
	b.u &= ~((UINT64_C(1) << (52 - e)) - 1);
	return b.d;
}

double
floor(double x)
{
	double t = trunc_(x);

	return t > x ? t - 1.0 : t;
}

double
ceil(double x)
{
	double t = trunc_(x);

	return t < x ? t + 1.0 : t;
}

/* to nearest, halfway away from zero -- c99's round, not rint's
 * banker's rounding. softmath.c's argument reduction wants exactly
 * this. inf survives because x - x is nan there and neither test takes.
 */
double
round(double x)
{
	double t = trunc_(x);
	double f = x - t;

	if (f >= 0.5)
		return t + 1.0;
	if (f <= -0.5)
		return t - 1.0;
	return t;
}
