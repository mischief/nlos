#ifndef _MATH_H
#define _MATH_H

#define HUGE_VAL	(__builtin_huge_val())
#define NAN		(__builtin_nan(""))
#define INFINITY	(__builtin_inf())

/* expanded inline by gcc (sse2/sse4.1); c99 inline definitions,
 * external symbols emitted by src/libc/math.c
 */
inline double fabs(double x)  { return __builtin_fabs(x); }
inline double sqrt(double x)  { return __builtin_sqrt(x); }
inline double floor(double x) { return __builtin_floor(x); }
inline double ceil(double x)  { return __builtin_ceil(x); }

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
