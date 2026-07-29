/* transcendentals in software, for every arch with no instruction for
 * them -- which is every arch here except x86_64.
 *
 * x86_64 gets these from x87 in a few instructions each (src/x86_64/
 * math.c); aarch64 has nothing above fsqrt and riscv64 nothing above
 * fsqrt.d, so the same "slow, small, correct enough" bargain is paid
 * here in series expansions instead. everything below is written
 * against the same target as the x87 versions: good to about a unit in
 * the last place over the ranges lua actually asks for, and honestly
 * worse outside them.
 *
 * this is portable C and so deliberately not under src/<arch>/: it was
 * aarch64's math.c verbatim until riscv64 wanted the identical file.
 * What stays per-arch is the rounding floor underneath it --
 * fabs/sqrt/floor/ceil/round, which aarch64 gets from builtins and
 * riscv64 has to supply itself. See include/math.h.
 */

#include <math.h>

#define LN2	6.93147180559945286227e-01	/* ln 2 */
#define LOG2E	1.44269504088896338700e+00	/* 1/ln 2 */
#define LN10	2.30258509299404590109e+00	/* ln 10 */
#define SQRTH	7.07106781186547572737e-01	/* sqrt(1/2) */
#define TWO_PI_	6.36619772367581382433e-01	/* 2/pi */
#define PIO2	1.57079632679489655800e+00	/* pi/2 */
#define PIO6	5.23598775598298815659e-01	/* pi/6 */
#define SQRT3	1.73205080756887719318e+00
#define TANPI12	2.67949192431122695801e-01	/* tan(pi/12) */

/* pi/2 in three pieces. the first two have their low bits zeroed (21
 * significant bits each), so n*P1 and n*P2 are exact products for any
 * integer |n| < 2^32 and the reduction below loses nothing to rounding
 * until the argument itself is that large. together they carry ~95 bits
 * of pi/2, against the 53 a single double would.
 */
#define P1	1.57079601287841796875e+00
#define P2	3.13916416416759602726e-07
#define P3	6.22337217189661338378e-14

/* beyond this the quadrant index no longer fits the exactness argument
 * above and the answer would be noise dressed up as a number.
 */
#define TRIG_MAX 6.0e9

double
fmod(double x, double y)
{
	if (y == 0.0 || __builtin_isnan(x) || __builtin_isnan(y) ||
	    __builtin_isinf(x))
		return NAN;
	if (__builtin_isinf(y))
		return x;

	double ax = __builtin_fabs(x), ay = __builtin_fabs(y);

	if (ax < ay)
		return x;

	/* subtract shifted copies of |y|, most significant first. every
	 * subtraction is exact (the operands are within a factor of two
	 * of each other), so the result is the true remainder.
	 */
	int ex, ey;

	frexp(ax, &ex);
	frexp(ay, &ey);
	for (int k = ex - ey; k >= 0; k--) {
		double d = ldexp(ay, k);

		if (d <= ax)
			ax -= d;
	}
	return x < 0.0 ? -ax : ax;
}

/* 2^x. split off the nearest integer, then exp() the remainder, which
 * is at most 0.347 in magnitude -- the taylor series is exact to well
 * under an ulp there by the u^13 term.
 */
static double
exp2_(double x)
{
	if (__builtin_isnan(x))
		return x;
	if (x > 1024.0)
		return HUGE_VAL;
	if (x < -1075.0)
		return 0.0;

	double n = __builtin_floor(x + 0.5);
	double u = (x - n) * LN2;
	double s = 1.0, t = 1.0;

	for (int i = 1; i <= 13; i++) {
		t = t * u / i;
		s += t;
	}
	return ldexp(s, (int)n);
}

/* ln(x) = e*ln2 + 2*atanh((m-1)/(m+1)) with m in [sqrt(1/2), sqrt(2)),
 * where the atanh series converges on |s| <= 0.1716. returns the second
 * term and hands back e; the callers differ only in how they scale.
 */
static double
log_parts(double x, int *ep)
{
	double m = frexp(x, ep);

	if (m < SQRTH) {
		m *= 2.0;
		(*ep)--;
	}

	double s = (m - 1.0) / (m + 1.0);
	double s2 = s * s, t = s, sum = s;

	for (int i = 3; i <= 25; i += 2) {
		t *= s2;
		sum += t / i;
	}
	return 2.0 * sum;
}

/* the three logs share every special case; only the scaling differs */
static int
log_special(double x, double *out)
{
	if (__builtin_isnan(x) || (__builtin_isinf(x) && x > 0.0)) {
		*out = x;
		return 1;
	}
	if (x < 0.0) {
		*out = NAN;
		return 1;
	}
	if (x == 0.0) {
		*out = -HUGE_VAL;
		return 1;
	}
	return 0;
}

double
log(double x)
{
	double r;
	int e;

	if (log_special(x, &r))
		return r;
	r = log_parts(x, &e);
	return e * LN2 + r;
}

double
log2(double x)
{
	double r;
	int e;

	if (log_special(x, &r))
		return r;
	r = log_parts(x, &e);
	return e + r * LOG2E;
}

double
log10(double x)
{
	double r;
	int e;

	if (log_special(x, &r))
		return r;
	r = log_parts(x, &e);
	return (e * LN2 + r) / LN10;
}

double
exp(double x)
{
	return exp2_(x * LOG2E);
}

double
pow(double x, double y)
{
	if (y == 0.0)
		return 1.0;
	if (x == 0.0)
		return y > 0.0 ? 0.0 : HUGE_VAL;
	if (x < 0.0) {
		if (y != __builtin_floor(y))
			return NAN;

		double r = exp2_(y * log2(-x));

		return fmod(y, 2.0) != 0.0 ? -r : r;
	}
	return exp2_(y * log2(x));
}

/* sin/cos of a reduced argument, |r| <= pi/4 */
static double
sinpoly(double r)
{
	double r2 = r * r, t = r, s = r;

	for (int i = 3; i <= 17; i += 2) {
		t *= -r2 / ((double)i * (i - 1));
		s += t;
	}
	return s;
}

static double
cospoly(double r)
{
	double r2 = r * r, t = 1.0, s = 1.0;

	for (int i = 2; i <= 18; i += 2) {
		t *= -r2 / ((double)i * (i - 1));
		s += t;
	}
	return s;
}

/* r = x - n*(pi/2) in three exact steps; *q is the quadrant */
static double
trig_reduce(double x, int *q)
{
	double n = __builtin_round(x * TWO_PI_);

	*q = (int)((long long)n & 3);
	return ((x - n * P1) - n * P2) - n * P3;
}

double
sin(double x)
{
	int q;

	if (__builtin_isnan(x) || __builtin_fabs(x) > TRIG_MAX)
		return NAN;

	double r = trig_reduce(x, &q);

	switch (q) {
	case 0:	return sinpoly(r);
	case 1:	return cospoly(r);
	case 2:	return -sinpoly(r);
	default: return -cospoly(r);
	}
}

double
cos(double x)
{
	int q;

	if (__builtin_isnan(x) || __builtin_fabs(x) > TRIG_MAX)
		return NAN;

	double r = trig_reduce(x, &q);

	switch (q) {
	case 0:	return cospoly(r);
	case 1:	return -sinpoly(r);
	case 2:	return -cospoly(r);
	default: return sinpoly(r);
	}
}

double
tan(double x)
{
	int q;

	if (__builtin_isnan(x) || __builtin_fabs(x) > TRIG_MAX)
		return NAN;

	double r = trig_reduce(x, &q);
	double s = sinpoly(r), c = cospoly(r);

	return (q & 1) ? -c / s : s / c;
}

/* atan on |u| <= tan(pi/12); the series costs 12 terms there */
static double
atanpoly(double u)
{
	double u2 = u * u, t = u, s = u;

	for (int i = 3; i <= 25; i += 2) {
		t *= -u2;
		s += t / i;
	}
	return s;
}

/* atan on [0, 1], folding [tan(pi/12), 1] down with
 * atan(t) = pi/6 + atan((t*sqrt3 - 1)/(t + sqrt3))
 */
static double
atan01(double t)
{
	if (t <= TANPI12)
		return atanpoly(t);
	return PIO6 + atanpoly((t * SQRT3 - 1.0) / (t + SQRT3));
}

double
atan(double x)
{
	if (__builtin_isnan(x))
		return x;

	double ax = __builtin_fabs(x);
	double r = ax > 1.0 ? PIO2 - atan01(1.0 / ax) : atan01(ax);

	return x < 0.0 ? -r : r;
}

double
atan2(double y, double x)
{
	if (__builtin_isnan(x) || __builtin_isnan(y))
		return NAN;
	if (x == 0.0 && y == 0.0)
		return 0.0;
	if (x == 0.0)
		return y > 0.0 ? PIO2 : -PIO2;

	double r = atan(y / x);

	if (x > 0.0)
		return r;
	return y >= 0.0 ? r + 2.0 * PIO2 : r - 2.0 * PIO2;
}

double
asin(double x)
{
	return atan2(x, __builtin_sqrt(1.0 - x * x));
}

double
acos(double x)
{
	return atan2(__builtin_sqrt(1.0 - x * x), x);
}
