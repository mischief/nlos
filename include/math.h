#ifndef _MATH_H
#define _MATH_H

#define HUGE_VAL	(__builtin_huge_val())
#define NAN		(__builtin_nan(""))
#define INFINITY	(__builtin_inf())

/* expanded inline by gcc; c99 inline definitions, external symbols
 * emitted by src/libc/math.c
 */
inline double fabs(double x)  { return __builtin_fabs(x); }
inline double sqrt(double x)  { return __builtin_sqrt(x); }

/* rounding to integral is one instruction on x86_64 (sse4.1 roundsd)
 * and on aarch64 (frintm/frintp), but not on riscv64: its D extension
 * has none, so gcc answers the builtin with a call and these wrappers
 * would be calling themselves. real functions there, in
 * src/riscv64/math.c -- along with round, which gets no wrapper because
 * nothing names it: src/libc/softmath.c reaches it via the builtin.
 * wasm has floor and ceil as instructions but rounds ties to even, so
 * round alone is a real function there.
 */
#if defined(__riscv)
double	floor(double x);
double	ceil(double x);
double	round(double x);
#else
inline double floor(double x) { return __builtin_floor(x); }
inline double ceil(double x)  { return __builtin_ceil(x); }
#if defined(__wasm__)
double	round(double x);
#endif
#endif

double	fmod(double x, double y);
double	pow(double x, double y);
double	exp(double x);
double	log(double x);
double	log2(double x);
double	log10(double x);
double	sin(double x);
double	cos(double x);
double	tan(double x);
double	asin(double x);
double	acos(double x);
double	atan(double x);
double	atan2(double y, double x);
double	frexp(double x, int *e);
double	ldexp(double x, int e);

#endif
