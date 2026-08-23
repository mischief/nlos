-- SPDX-License-Identifier: ISC
local out = (#arg > 0 and table.concat(arg, " ") or "y") .. "\n"
while true do
	io.write(out)
end
