#!/usr/bin/env lua5.4
-- lib/geometry.lua on the host. The identities are the test: a
-- rotation preserves length, a frame round-trips, and a satellite
-- placed from a bearing is seen again at that bearing.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" .. package.path

local g = require("geometry")

local count, failed = 0, 0

local function ok(cond, name)
	count = count + 1
	if cond then
		io.write(("ok %d - %s\n"):format(count, name))
	else
		failed = failed + 1
		io.write(("not ok %d - %s\n"):format(count, name))
	end
end

local function near(got, want, eps, name)
	ok(type(got) == "number" and math.abs(got - want) < eps,
	    ("%s (got %s, want ~%s)"):format(name, tostring(got),
	    tostring(want)))
end

-- ---- vectors ----

local a = g.Vec3(1, 2, 3)
local b = g.Vec3(4, 5, 6)

near(g.dotvec3(a, b), 32, 1e-9, "the dot product")

local c = g.crossvec3(a, b)

near(c.x, -3, 1e-9, "the cross product x")
near(c.y, 6, 1e-9, "and y")
near(c.z, -3, 1e-9, "and z")
near(g.dotvec3(c, a), 0, 1e-9, "a cross is perpendicular to its left")
near(g.dotvec3(c, b), 0, 1e-9, "and to its right")
near(g.vec3len(g.normvec3(b)), 1, 1e-12, "normvec3 gives a unit vector")

-- ---- rotation ----

local p = g.Pt3(1, 0, 0)
local z = g.Vec3(0, 0, 1)
local q = g.qrotate(p, z, math.pi / 2)

near(q.x, 0, 1e-9, "a quarter turn about z sends x to y (x)")
near(q.y, 1, 1e-9, "and y")
near(g.vec3len(g.qrotate(b, g.normvec3(a), 1.2345)), g.vec3len(b), 1e-9,
    "a rotation preserves length")

-- four quarter turns is where it started
local r = p

for _ = 1, 4 do
	r = g.qrotate(r, z, math.pi / 2)
end
near(r.x, 1, 1e-9, "four quarter turns come back")
near(r.y, 0, 1e-9, "on both axes")

-- ---- the sphere ----

-- a ray up the x axis through a unit sphere at the origin
local n1, n2 = g.lineXsphere(g.Pt3(-5, 0, 0), g.Pt3(5, 0, 0),
    g.Pt3(0, 0, 0), 1, false)

near(n1.x, -1, 1e-9, "a secant enters at -1")
near(n2.x, 1, 1e-9, "and leaves at 1")
ok(g.lineXsphere(g.Pt3(-5, 5, 0), g.Pt3(5, 5, 0), g.Pt3(0, 0, 0), 1,
    false) == nil, "a line that misses returns nothing")

-- ---- frames ----

local rf = g.horizon(0, 0)

near(rf.p.x, g.RE, 1e-6, "(0N, 0E) is out the x axis")
near(rf.p.y, 0, 1e-6, "with no y")
near(rf.p.z, 0, 1e-6, "and no z")
near(rf.bz.x, 1, 1e-12, "up there is +x")
near(rf.by.z, 1, 1e-12, "north there is +z")
near(rf.bx.y, 1, 1e-12, "east there is +y")

-- the north pole is up the z axis
local np = g.geodetic(90, 0)

near(np.z, g.RE, 1e-6, "the pole is one radius up z")

-- into a frame and back out again
local there = g.geodetic(48.1173, 11.5167)
local local_ = g.rframexform3(there, rf)
local back = g.invrframexform3(local_, rf)

near(back.x, there.x, 1e-6, "a frame round-trips x")
near(back.y, there.y, 1e-6, "and y")
near(back.z, there.z, 1e-6, "and z")

-- ---- satellites ----

-- straight overhead: the same bearing whatever azimuth is given, and
-- exactly one orbit radius from the centre
local up = g.skypoint(rf, 0, 90)

near(g.vec3len(up), g.GPSORBIT, 1, "an overhead satellite is in orbit")
near(up.y, 0, 1e-3, "and directly above the observer (y)")
near(up.z, 0, 1e-3, "and (z)")

-- one on the horizon due north, seen from (0N, 0E): it must be in
-- orbit, and north of the observer rather than south
local north = g.skypoint(rf, 0, 0)

near(g.vec3len(north), g.GPSORBIT, 1, "a horizon satellite is in orbit")
ok(north.z > 0, "due north of the equator is +z")

local east = g.skypoint(rf, 90, 0)

ok(east.y > 0, "due east is +y")
near(g.vec3len(east), g.GPSORBIT, 1, "and also in orbit")

-- and the round trip: place one from a bearing, then ask what bearing
-- it is at. This is the property the plot rests on.
for _, t in ipairs({ { 0, 10 }, { 45, 30 }, { 137, 5 }, { 300, 70 } }) do
	local az, el = t[1], t[2]
	local s = g.skypoint(rf, az, el)
	local v = g.rframexform3(s, rf)
	local gotaz = math.deg(math.atan(v.x, v.y)) % 360
	local gotel = math.deg(math.atan(v.z,
	    math.sqrt(v.x * v.x + v.y * v.y)))

	near(gotaz, az, 1e-3, ("az %d comes back"):format(az))
	near(gotel, el, 1e-3, ("el %d comes back"):format(el))
end

io.write(("1..%d\n"):format(count))
os.exit(failed == 0 and 0 or 1)
