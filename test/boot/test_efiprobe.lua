-- los.efi.locate: ask the firmware what protocols it actually has.
-- needs NET=1, since the tcp4/udp4 controls only exist with a NIC.
local efi = require("los.efi")
local tap = require("tap")

tap.plan(6)

-- controls: these are the drivers our net stack is built on, so a zero
-- here means the probe itself is broken, not that the firmware is bare.
tap.ok(efi.locate("00720665-67eb-4a99-baf7-d3c33a1c7cc9") > 0,
    "finds tcp4 service binding (control)")
tap.ok(efi.locate("83f01464-99bd-45e5-b383-af6305d8e9e6") > 0,
    "finds udp4 service binding (control)")

-- GOP is present in every OVMF build and on real hardware; it is the
-- protocol any future graphics work would use.
tap.ok(efi.locate("9042a9de-23dc-4a38-96fb-7aded080516a") > 0,
    "finds GraphicsOutput")

-- a well-formed guid nobody publishes must be 0, not an error
tap.is(efi.locate("00000000-0000-0000-0000-000000000000"), 0,
    "unpublished guid reports zero handles")

-- malformed input is an error, not a wrong answer
tap.ok(not pcall(efi.locate, "not-a-guid"), "rejects a malformed guid")
tap.ok(not pcall(efi.locate, "9042a9de23dc4a3896fb7aded080516a"),
    "rejects a guid with no dashes")

tap.done()
