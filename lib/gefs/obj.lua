-- The filesystem object's metatable, on its own so that the layers can
-- each hang their methods off it without requiring one another.
--
-- store.lua puts blocks and arenas here, tree.lua the Bε-tree, snap.lua
-- snapshots and deadlists, fsops.lua the file semantics. They form a
-- stack, but the stack has one cycle in it -- freeing a block consults
-- the snapshot's deadlist, and writing a deadlist allocates a block --
-- which is exactly the cycle a shared object dissolves and an import
-- graph cannot.

local Fs = {}
Fs.__index = Fs
return Fs
