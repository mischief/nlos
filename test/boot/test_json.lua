local json = require("json")
local tap = require("tap")

tap.plan(16)

-- ---- decode: scalars ----
tap.is(json.decode("42"), 42, "integer")
tap.is(json.decode("-1.5e2"), -150.0, "float with exponent")
tap.is(json.decode('"hi"'), "hi", "string")
tap.is(json.decode("true"), true, "true")
tap.is(json.decode("false"), false, "false")
tap.is(json.decode("null"), json.null, "null maps to the sentinel")

-- ---- decode: escapes ----
tap.is(json.decode('"a\\nb"'), "a\nb", "\\n escape")
tap.is(json.decode('"\\u0041"'), "A", "\\u escape (BMP)")

-- ---- decode: structure ----
local o = json.decode('{"a":1,"b":[2,3]}')
tap.is(o.a, 1, "object member")
tap.is(o.b[2], 3, "nested array member")
tap.is(#json.decode("[]"), 0, "empty array")

-- ---- decode: malformed input returns nil+reason, never throws ----
local bad = {
	{ "{", "unterminated object" },
	{ '"abc', "unterminated string" },
	{ "[1,]", "trailing comma" },
	{ "{'a':1}", "single-quoted key" },
	{ "", "empty input" },
	{ "{} extra", "trailing garbage" },
}
local allnil = true
for _, case in ipairs(bad) do
	local v, err = json.decode(case[1])
	if v ~= nil or type(err) ~= "string" then
		allnil = false
		tap.diag("expected nil+reason for " .. case[2])
	end
end
tap.ok(allnil, "malformed input returns nil + reason, never throws")

-- ---- encode ----
tap.is(json.encode(42), "42", "encode number")
tap.is(json.encode("a\nb"), '"a\\nb"', "encode escapes newline")
tap.is(json.encode(json.EMPTY_ARRAY), "[]", "encode empty-array sentinel")

-- ---- roundtrip ----
local src = { jsonrpc = "2.0", id = 7, result = { ok = true, xs = { 1, 2, 3 } } }
local back = json.decode(json.encode(src))
tap.ok(back.jsonrpc == "2.0" and back.id == 7 and back.result.ok == true and
    back.result.xs[3] == 3, "roundtrip preserves a jsonrpc-shaped value")

tap.done()
