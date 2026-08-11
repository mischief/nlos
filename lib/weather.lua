-- weather: a forecast from wttr.in, as fields.
--
--	local w, err = weather.get{ net =, dns =, rand =, where = }
--	w.place, w.cond, w.temp, w.feels, w.humidity, w.wind,
--	w.pressure, w.precip

-- The server does the shaping. Its json answer is 39KB, against a
-- display showing a temperature and a word, so this asks for one line
-- of the fields it wants and splits it.

-- Omitting the location is deliberate: wttr.in reads it from the source
-- address. That is the ISP's view of where the machine is, so `place`
-- is reported rather than assumed to be right.

-- Holds no capability. The caller passes what the shell lent it, the
-- way lib/http does, so a program with no network is refused here
-- rather than failing somewhere further in.

local http = require("http")
local tlstcp = require("tlstcp")

local M = {}

M.HOST = "wttr.in"

-- The fields, in the order the format below asks for them. `|` cannot
-- appear in any of them, which is what makes one line splittable.
local FIELDS = {
	"place", "cond", "temp", "feels", "humidity", "wind",
	"pressure", "precip",
}

-- %l location, %C condition as words rather than an emoji a panel font
-- cannot draw, then the numbers. Percent-encoded: this is a query.
local FORMAT = "%l%7C%C%7C%t%7C%f%7C%h%7C%w%7C%P%7C%p"

function M.url(where)
	return "https://" .. M.HOST .. "/" .. (where or "") ..
	    "?format=" .. FORMAT
end

-- opts: net (the tcp capability), dns, rand, where
function M.get(opts)
	opts = opts or {}
	if not opts.net then
		return nil, "no network capability"
	end
	if not opts.rand then
		return nil, "no entropy, and https needs some"
	end

	-- trust on first use unless the caller brought its own decision
	local verify = opts.verify

	if not verify and not opts.insecure then
		verify = tlstcp.tofu(M.HOST, opts.onnew)
	end

	local res, err = http.get(opts.net, opts.dns, M.url(opts.where),
	    { rand = opts.rand, verify = verify,
	      insecure = opts.insecure })

	if not res then
		return nil, err
	end
	if res.status ~= 200 then
		return nil, "wttr.in answered " .. tostring(res.status)
	end

	local line = (res.body or ""):match("^[^\r\n]*")

	if not line or line == "" then
		return nil, "an empty answer"
	end

	local w = {}
	local from = 1

	for i = 1, #FIELDS do
		local bar = line:find("|", from, true)
		local part = line:sub(from, (bar or 0) - 1)

		if not bar then
			part = line:sub(from)
		end
		-- wttr.in pads a short condition with a space
		w[FIELDS[i]] = (part:gsub("^%s+", ""):gsub("%s+$", ""))
		if not bar then
			break
		end
		from = bar + 1
	end

	if not w.temp then
		return nil, "not a reading: " .. line:sub(1, 40)
	end
	w.line = line
	return w
end

return M
