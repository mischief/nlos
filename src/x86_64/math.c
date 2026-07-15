/* x86_64 transcendentals via x87. slow, small, correct enough.
 * sqrt/fabs/floor/ceil come from sse builtins (see include/math.h).
 */

#include <math.h>

double
fmod(double x, double y)
{
	double r;

	__asm__ volatile (
	    "fldl	%2\n\t"
	    "fldl	%1\n\t"
	    "1:\n\t"
	    "fprem\n\t"
	    "fnstsw	%%ax\n\t"
	    "testb	$0x04, %%ah\n\t"	/* C2: reduction incomplete */
	    "jnz	1b\n\t"
	    "fstp	%%st(1)\n\t"
	    "fstpl	%0"
	    : "=m" (r) : "m" (x), "m" (y) : "ax");
	return r;
}

/* 2^x via f2xm1/fscale (x split into int + frac parts) */
static double
exp2_(double x)
{
	double r;

	__asm__ (
	    "fldl	%1\n\t"
	    "fld	%%st(0)\n\t"
	    "frndint\n\t"			/* st0 = int, st1 = x */
	    "fxch	%%st(1)\n\t"		/* st0 = x, st1 = int */
	    "fsub	%%st(1), %%st(0)\n\t"	/* st0 = frac */
	    "f2xm1\n\t"
	    "fld1\n\t"
	    "faddp\n\t"				/* 2^frac */
	    "fscale\n\t"			/* * 2^int */
	    "fstp	%%st(1)\n\t"
	    "fstpl	%0"
	    : "=m" (r) : "m" (x));
	return r;
}

/* y*log2(x) via fyl2x; x must be > 0 */
static double
yl2x(double y, double x)
{
	double r;

	__asm__ (
	    "fldl	%1\n\t"
	    "fldl	%2\n\t"
	    "fyl2x\n\t"
	    "fstpl	%0"
	    : "=m" (r) : "m" (y), "m" (x));
	return r;
}

double
log2(double x)
{
	return yl2x(1.0, x);
}

double
log(double x)
{
	return yl2x(0.69314718055994530942, x);	/* ln 2 */
}

double
log10(double x)
{
	return yl2x(0.30102999566398119521, x);	/* log10 2 */
}

double
exp(double x)
{
	return exp2_(x * 1.4426950408889634074);	/* log2 e */
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

		return __builtin_fmod(y, 2.0) != 0.0 ? -r : r;
	}
	return exp2_(y * log2(x));
}

double
sin(double x)
{
	double r;

	__asm__ ("fldl %1\n\tfsin\n\tfstpl %0" : "=m" (r) : "m" (x));
	return r;
}

double
cos(double x)
{
	double r;

	__asm__ ("fldl %1\n\tfcos\n\tfstpl %0" : "=m" (r) : "m" (x));
	return r;
}

double
tan(double x)
{
	double r;

	__asm__ (
	    "fldl	%1\n\t"
	    "fptan\n\t"
	    "fstp	%%st(0)\n\t"	/* fptan pushes 1.0 */
	    "fstpl	%0"
	    : "=m" (r) : "m" (x));
	return r;
}

/* atan2(y, x) via fpatan */
double
atan2(double y, double x)
{
	double r;

	__asm__ (
	    "fldl	%1\n\t"
	    "fldl	%2\n\t"
	    "fpatan\n\t"
	    "fstpl	%0"
	    : "=m" (r) : "m" (y), "m" (x));
	return r;
}

double
atan(double x)
{
	return atan2(x, 1.0);
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
