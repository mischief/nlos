#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <math.h>
#include <errno.h>

int errno;

/* platform layer provides these (efi land) */
extern _Noreturn void platform_abort(const char *why);

_Noreturn void
abort(void)
{
	platform_abort("abort()");
}

_Noreturn void
exit(int status)
{
	(void)status;
	platform_abort("exit()");
}

_Noreturn void
__assert_fail(const char *expr, const char *file, int line)
{
	(void)expr;
	(void)file;
	(void)line;
	platform_abort("assertion failed");
}

char *
getenv(const char *name)
{
	(void)name;
	return 0;
}

int
abs(int x)
{
	return x < 0 ? -x : x;
}

long
labs(long x)
{
	return x < 0 ? -x : x;
}

/* decimal-only strtod; lua handles hex floats itself (lobject.c).
 * mantissa gathered in a uint64, scaled by powers of ten.
 * not correctly rounded to the last ulp; fine for now.
 */
double
strtod(const char *s, char **end)
{
	const char *p = s;
	unsigned long long mant = 0;
	int exp10 = 0, esign = 1, e = 0;
	int sign = 1, digits = 0, any = 0;
	double r;

	while (isspace(*p))
		p++;
	if (*p == '+' || *p == '-')
		sign = (*p++ == '-') ? -1 : 1;

	for (; isdigit(*p); p++) {
		any = 1;
		if (digits < 19) {
			mant = mant * 10 + (*p - '0');
			digits++;
		} else
			exp10++;
	}
	if (*p == '.') {
		p++;
		for (; isdigit(*p); p++) {
			any = 1;
			if (digits < 19) {
				mant = mant * 10 + (*p - '0');
				digits++;
				exp10--;
			}
		}
	}
	if (!any) {
		if (end)
			*end = (char *)s;
		return 0.0;
	}
	if (*p == 'e' || *p == 'E') {
		const char *ep = p + 1;

		if (*ep == '+' || *ep == '-')
			esign = (*ep++ == '-') ? -1 : 1;
		if (isdigit(*ep)) {
			for (; isdigit(*ep); ep++)
				if (e < 100000)
					e = e * 10 + (*ep - '0');
			p = ep;
			exp10 += esign * e;
		}
	}

	/* powers of ten up to 1e22 are exactly representable in a double;
	 * scaling with this table keeps round decimals exact (1e6 must be
	 * 1000000.0, not pow()'s 999999.99999999984 -- lua for-loops with
	 * float limits lose an iteration otherwise).
	 */
	static const double p10[] = {
		1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10,
		1e11, 1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19,
		1e20, 1e21, 1e22,
	};

	r = (double)mant;
	if (exp10 > 0) {
		while (exp10 >= 22) {
			r *= 1e22;
			exp10 -= 22;
		}
		r *= p10[exp10];
	} else if (exp10 < 0) {
		while (exp10 <= -22) {
			r /= 1e22;
			exp10 += 22;
		}
		r /= p10[-exp10];
	}
	/* r is the non-negative magnitude (sign applied on return), so this
	 * catches overflow of either sign. flag underflow to zero too.
	 */
	if (r == HUGE_VAL)
		errno = ERANGE;
	else if (r == 0.0 && mant != 0)
		errno = ERANGE;
	if (end)
		*end = (char *)p;
	return sign < 0 ? -r : r;
}
