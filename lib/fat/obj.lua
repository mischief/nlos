-- The filesystem object's metatable, on its own so that the layers can
-- each hang their methods off it without requiring one another.
--
-- blk.lua puts the sector cache here, fat.lua the allocation table,
-- dir.lua directory entries, fsops.lua the file semantics, vol.lua the
-- geometry. They form a stack with one cycle in it -- growing a
-- directory allocates a cluster, and the allocator writes through the
-- same cache the directory reads -- which is the cycle a shared object
-- dissolves and an import graph cannot.

local Fs = {}
Fs.__index = Fs
return Fs
