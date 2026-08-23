-- SPDX-License-Identifier: ISC
local path = (arg[1] or ""):gsub("/+$", "")
print(path:match("^(.*)/[^/]+$") or ".")
