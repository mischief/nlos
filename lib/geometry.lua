-- geometry: points, quaternions and reference frames in three
-- dimensions, after plan9front's libgeometry. The names are theirs: a
-- frame is an origin and three basis vectors, and a rotation is a
-- quaternion sandwich. Every operation allocates, which suits the tens
-- of points a scene holds and not the thousands a raster loop touches.

local M = {}

M.DEG = math.pi / 180

-- ---- Point3 ----

function M.Pt3(x, y, z, w)
	return { x = x, y = y, z = z, w = w or 1 }
end

function M.Vec3(x, y, z)
	return { x = x, y = y, z = z, w = 0 }
end

function M.addpt3(a, b)
	return { x = a.x + b.x, y = a.y + b.y, z = a.z + b.z,
	    w = a.w + b.w }
end

function M.subpt3(a, b)
	return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z,
	    w = a.w - b.w }
end

function M.mulpt3(p, s)
	return { x = p.x * s, y = p.y * s, z = p.z * s, w = p.w * s }
end

function M.divpt3(p, s)
	return { x = p.x / s, y = p.y / s, z = p.z / s, w = p.w / s }
end

function M.dotvec3(a, b)
	return a.x * b.x + a.y * b.y + a.z * b.z
end

function M.crossvec3(a, b)
	return M.Vec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z,
	    a.x * b.y - a.y * b.x)
end

function M.vec3len(v)
	return math.sqrt(M.dotvec3(v, v))
end

function M.normvec3(v)
	local n = M.vec3len(v)

	if n == 0 then
		return M.Vec3(0, 0, 0)
	end
	return M.Vec3(v.x / n, v.y / n, v.z / n)
end

-- ---- Quaternion ----

function M.Quatvec(s, v)
	return { r = s, i = v.x, j = v.y, k = v.z }
end

function M.mulq(q, r)
	local qv = M.Vec3(q.i, q.j, q.k)
	local rv = M.Vec3(r.i, r.j, r.k)
	local t = M.addpt3(M.addpt3(M.mulpt3(rv, q.r), M.mulpt3(qv, r.r)),
	    M.crossvec3(qv, rv))

	return M.Quatvec(q.r * r.r - M.dotvec3(qv, rv), t)
end

function M.invq(q)
	local n = q.r * q.r + q.i * q.i + q.j * q.j + q.k * q.k

	return { r = q.r / n, i = -q.i / n, j = -q.j / n, k = -q.k / n }
end

-- q p q⁻¹, which is the rotation p undergoes
function M.qsandwichpt3(q, p)
	local r = M.mulq(M.mulq(q, M.Quatvec(0, p)), M.invq(q))

	return M.Pt3(r.i, r.j, r.k, p.w)
end

-- turn p about `axis` by θ radians. axis must be a unit vector.
function M.qrotate(p, axis, theta)
	local h = theta / 2

	return M.qsandwichpt3(M.Quatvec(math.cos(h),
	    M.mulpt3(axis, math.sin(h))), p)
end

-- ---- intersections ----

-- Where the line p0->p1 meets the sphere at c of radius r, nearest
-- first. isaray drops what lies behind p0. Returns nothing, one point
-- (a tangent) or two.
function M.lineXsphere(p0, p1, c, r, isaray)
	local u = M.normvec3(M.subpt3(p1, p0))
	-- from p0, where the distances below are measured. libgeometry
	-- takes it from p1 and adds the result to p0, which puts the
	-- answer |p1-p0| away from the sphere it was asked about.
	local dp = M.subpt3(p0, c)
	local udp = M.dotvec3(u, dp)

	if isaray and udp > 0 then
		return nil
	end

	local d = udp * udp - M.dotvec3(dp, dp) + r * r

	if d < 0 then
		return nil
	end
	if d == 0 then
		return M.addpt3(p0, M.mulpt3(u, -udp))
	end

	local s = math.sqrt(d)

	return M.addpt3(p0, M.mulpt3(u, -udp - s)),
	    M.addpt3(p0, M.mulpt3(u, -udp + s))
end

-- ---- RFrame3 ----

-- An origin and three basis vectors. rframexform3 takes a point in the
-- parent frame and gives its coordinates in this one; invrframexform3
-- goes the other way, which is what places a thing known in local
-- coordinates -- a bearing and an elevation -- into the world.
function M.RFrame3(p, bx, by, bz)
	return { p = p, bx = bx, by = by, bz = bz }
end

-- w decides whether the origin is in it, which is what w is for: a
-- Vec3 is a direction and does not move with the frame, a Pt3 does.
-- Differencing two points the size of the earth to recover a unit
-- direction loses the metres a satellite is then placed by.
function M.rframexform3(p, rf)
	local d = p.w ~= 0 and M.subpt3(p, rf.p) or p

	return M.Pt3(M.dotvec3(d, rf.bx), M.dotvec3(d, rf.by),
	    M.dotvec3(d, rf.bz), p.w)
end

function M.invrframexform3(p, rf)
	local v = M.addpt3(M.addpt3(M.mulpt3(rf.bx, p.x),
	    M.mulpt3(rf.by, p.y)), M.mulpt3(rf.bz, p.z))

	if p.w == 0 then
		return M.Vec3(v.x, v.y, v.z)
	end
	return M.Pt3(rf.p.x + v.x, rf.p.y + v.y, rf.p.z + v.z, p.w)
end

-- ---- the earth, as a frame ----

-- Earth-centred and earth-fixed: x through (0N, 0E), z through the
-- north pole. Metres, so a radius and an orbit are the same units.
M.RE = 6371000.0

-- where a latitude and a longitude are, on the sphere
function M.geodetic(lat, lon, alt)
	local p, l = lat * M.DEG, lon * M.DEG
	local r = M.RE + (alt or 0)

	return M.Pt3(r * math.cos(p) * math.cos(l),
	    r * math.cos(p) * math.sin(l), r * math.sin(p))
end

-- the local horizon at a latitude and longitude: east, north and up.
-- A bearing and an elevation are coordinates in this.
function M.horizon(lat, lon)
	local p, l = lat * M.DEG, lon * M.DEG
	local sp, cp, sl, cl = math.sin(p), math.cos(p), math.sin(l),
	    math.cos(l)

	return M.RFrame3(M.geodetic(lat, lon),
	    M.Vec3(-sl, cl, 0),
	    M.Vec3(-sp * cl, -sp * sl, cp),
	    M.Vec3(cp * cl, cp * sl, sp))
end

-- A satellite is a bearing, an angle above the horizon and a distance
-- nobody measured: NMEA gives the first two. The third comes from the
-- orbit -- every GNSS constellation is close enough to circular that
-- the range is where the line of sight leaves a sphere of that radius.
function M.skypoint(rf, az, elev, orbit)
	local a, e = az * M.DEG, elev * M.DEG
	local ce = math.cos(e)
	local dir = M.invrframexform3(M.Vec3(ce * math.sin(a),
	    ce * math.cos(a), math.sin(e)), rf)
	local far = M.Pt3(rf.p.x + dir.x, rf.p.y + dir.y, rf.p.z + dir.z)
	local near, second = M.lineXsphere(rf.p, far,
	    M.Pt3(0, 0, 0), orbit or M.GPSORBIT, false)

	-- the far root: the near one is behind the observer, on the other
	-- side of the earth from where they are looking.
	return second or near
end

-- 20200km up, which is where the GPS constellation is
M.GPSORBIT = M.RE + 20200000.0

return M
