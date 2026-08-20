/* the one rounding mode wasm has no instruction for: f64.nearest is
 * ties-to-even, and softmath.c wants c99's ties-away-from-zero. fabs,
 * sqrt, floor, ceil and trunc are all builtins emitted inline.
 * inf survives because x - x is nan there and neither test takes.
 */

#include "math.h"

double
round(double x)
{
	double t = __builtin_trunc(x);
	double f = x - t;

	if (f >= 0.5)
		return t + 1.0;
	if (f <= -0.5)
		return t - 1.0;
	return t;
}
