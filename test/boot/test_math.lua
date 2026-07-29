-- the libm floor: everything lua's math library calls through to.
-- worth its own test because the implementations are per-arch and
-- wildly different in kind -- x86_64 hands the work to x87 in a few
-- instructions each, aarch64 has no transcendental instruction at all
-- and computes them from series in src/aarch64/math.c. this asserts
-- the two agree with mathematics rather than with each other.
local tap = require("tap")

tap.plan(26)

local pi = 3.141592653589793

-- relative where it means anything, absolute near zero
local function near(got, want, name, tol)
	tol = tol or 1e-12
	local scale = math.abs(want)
	local err = math.abs(got - want)

	if scale > 1 then
		err = err / scale
	end
	if err > tol then
		tap.diag(("%s: got %.17g, want %.17g (err %.3g)"):format(
		    name, got, want, err))
	end
	return tap.ok(err <= tol, name)
end

-- ---- the ones that are single instructions everywhere ----
tap.is(math.floor(-2.5), -3, "floor rounds toward -inf")
tap.is(math.ceil(-2.5), -2, "ceil rounds toward +inf")
near(math.sqrt(2), 1.4142135623730951, "sqrt 2")
tap.is(math.abs(-3.25), 3.25, "abs")

-- ---- fmod: exact, and signed like the dividend ----
tap.is(math.fmod(7.5, 2), 1.5, "fmod keeps the remainder exact")
tap.is(math.fmod(-7.5, 2), -1.5, "fmod takes the sign of x")
tap.is(math.fmod(3, 8), 3, "fmod with |x| < |y| is x")

-- ---- exp/log ----
near(math.exp(1), 2.718281828459045, "exp 1 is e")
near(math.exp(0), 1, "exp 0")
near(math.log(2.718281828459045), 1, "log e")
near(math.log(1), 0, "log 1 is exactly 0", 0)
near(math.log(1024, 2), 10, "log base 2")
near(math.log(1000, 10), 3, "log base 10")
-- the round trip over a wide range is the real test of the argument
-- reduction, not any single value
local worst = 0
for _, x in ipairs({1e-8, 0.5, 1, 7, 1e3, 1e8, 1e17}) do
	local err = math.abs(math.exp(math.log(x)) - x) / x
	worst = math.max(worst, err)
end
tap.ok(worst < 1e-12, ("exp(log(x)) round trips (worst %.3g)"):format(worst))

-- ---- pow ----
tap.is(2^10, 1024.0, "an exact power of two stays exact")
near(10^3, 1000, "10^3")
near(2^0.5, 1.4142135623730951, "fractional exponent")
near((-2)^3, -8, "negative base, odd integer exponent")

-- ---- trig ----
near(math.sin(pi / 6), 0.5, "sin pi/6")
near(math.cos(pi / 3), 0.5, "cos pi/3")
near(math.tan(pi / 4), 1, "tan pi/4")
-- the pythagorean identity across quadrants catches a reduction that is
-- subtly wrong in a way single values can miss
worst = 0
for i = -20, 20 do
	local x = i * 0.7
	local s, c = math.sin(x), math.cos(x)

	worst = math.max(worst, math.abs(s * s + c * c - 1))
end
tap.ok(worst < 1e-12, ("sin^2 + cos^2 = 1 (worst %.3g)"):format(worst))

-- ---- inverse trig, including the quadrant logic ----
near(math.asin(0.5), pi / 6, "asin 0.5")
near(math.acos(0.5), pi / 3, "acos 0.5")
near(math.atan(1), pi / 4, "atan 1")
near(math.atan(1, -1), 3 * pi / 4, "atan2 in the second quadrant")

tap.done()
