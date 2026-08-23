-- SPDX-License-Identifier: ISC
local path = arg[1] or ""
local suffix = arg[2]
local base = path:match("([^/]+)/*$") or path
if suffix and base:sub(-#suffix) == suffix then
	base = base:sub(1, -#suffix - 1)
end
print(base)
