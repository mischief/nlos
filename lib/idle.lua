-- artificial memory-floor baseline: bare minimum requires, then
-- block forever on a port nobody ever sends to. spawn this via
-- sys.spawn to see raw per-proc overhead in `ps`, with nothing else
-- (ninep, drivers, etc) contributing to mem_used/mem_peak.
local sys = require("los.sys")
local thread = require("los.thread")

thread.recv(sys.newport())
