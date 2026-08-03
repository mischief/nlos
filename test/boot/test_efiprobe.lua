-- los.efi.locate: ask the firmware what protocols it actually has.
-- needs NET=1, since the SNP control only exists with a NIC.
local efi = require("los.efi")
local tap = require("tap")

tap.plan(5)

-- control: SNP is the protocol our net stack is built on, so a zero
-- here means the probe itself is broken, not that the firmware is bare.
-- it is also the one net protocol we expect to survive snp_init, which
-- disconnects the firmware's own drivers from the NIC handle -- the
-- tcp4 and udp4 service bindings this used to check are gone with them.
tap.ok(efi.locate("a19832b9-ac25-11d3-9a2d-0090273fc14d") > 0,
    "finds SimpleNetwork (control)")

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
