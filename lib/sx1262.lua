-- sx1262: the chip, over whatever carries its transfers.
--
-- Sans-io in the same sense lib/ble is: new(wire) takes something with
-- xfer/reset/irq and everything here is the command set on top. The
-- radio's own registers are the only state.

local M = {}

-- opcodes, from the datasheet's command table
local C = {
	SETSTANDBY = 0x80,
	SETTX = 0x83,
	SETRX = 0x82,
	SETRFFREQ = 0x86,
	SETPKTTYPE = 0x8a,
	SETTXPARAMS = 0x8e,
	SETMODPARAMS = 0x8b,
	SETPKTPARAMS = 0x8c,
	SETBUFBASE = 0x8f,
	SETPACONFIG = 0x95,
	SETDIOIRQ = 0x08,
	GETIRQ = 0x12,
	CLRIRQ = 0x02,
	GETRXBUFSTATUS = 0x13,
	GETPKTSTATUS = 0x14,
	GETSTATUS = 0xc0,
	GETERR = 0x17,
	CLRERR = 0x07,
	WRITEBUF = 0x0e,
	READBUF = 0x1e,
	WRITEREG = 0x0d,
	READREG = 0x1d,
	SETDIO2RF = 0x9d,
	SETDIO3TCXO = 0x97,
	CALIBRATE = 0x89,
	CALIBIMAGE = 0x98,
	SETREGULATOR = 0x96,
}

-- the interrupt bits, of which two matter here
M.IRQ_TXDONE = 0x0001
M.IRQ_RXDONE = 0x0002
M.IRQ_TIMEOUT = 0x0200
M.IRQ_CRCERR = 0x0040
M.IRQ_HEADERERR = 0x0020

-- 32MHz over 2^25: the step every frequency is counted in
local FSTEP = 32000000.0 / 33554432.0

local Radio = {}

Radio.__index = Radio

function M.new(wire)
	return setmetatable({ wire = wire }, Radio)
end

-- a command and its arguments. The chip answers over the same
-- transfer, so what comes back for `n` extra bytes is the answer.
function Radio:cmd(op, args, want)
	local out = string.char(op) .. (args or "")

	if want and want > 0 then
		out = out .. string.rep("\0", want)
	end

	local back = self.wire.xfer(out)

	if not back then
		return nil, "the chip stayed busy"
	end
	if want and want > 0 then
		return back:sub(#out - want + 1)
	end
	return true
end

function Radio:readreg(addr, n)
	local a = string.char((addr >> 8) & 0xff, addr & 0xff, 0)

	return self:cmd(C.READREG, a, n)
end

function Radio:writereg(addr, data)
	return self:cmd(C.WRITEREG,
	    string.char((addr >> 8) & 0xff, addr & 0xff) .. data)
end

function Radio:standby(rc)
	return self:cmd(C.SETSTANDBY, string.char(rc and 0 or 1))
end

function Radio:status()
	local s = self:cmd(C.GETSTATUS, "", 1)

	if not s then
		return nil
	end

	local b = s:byte(1)

	-- 6:4 is the mode, 3:1 what the last command came to
	return (b >> 4) & 0x7, (b >> 1) & 0x7
end

-- the errors the chip keeps for itself: a calibration that did not
-- converge shows up here and nowhere else.
function Radio:errors()
	local s = self:cmd(C.GETERR, "", 3)

	if not s then
		return nil
	end
	return (s:byte(2) << 8) | s:byte(3)
end

-- The errors latch: one raised before the oscillator was configured
-- stays until this, so a reading taken without clearing first is about
-- the past.
function Radio:clearerrors()
	return self:cmd(C.CLRERR, string.char(0, 0))
end

function Radio:frequency(hz)
	local n = math.floor(hz / FSTEP + 0.5)

	return self:cmd(C.SETRFFREQ, string.pack(">I4", n))
end

-- bandwidth in kHz to the chip's own numbering
local BW = {
	[7.8] = 0x00, [10.4] = 0x08, [15.6] = 0x01, [20.8] = 0x09,
	[31.25] = 0x02, [41.7] = 0x0a, [62.5] = 0x03, [125] = 0x04,
	[250] = 0x05, [500] = 0x06,
}

-- sf, bandwidth in kHz, and the coding rate's denominator (5 to 8).
--
-- The low data rate flag is not a choice: the datasheet requires it
-- wherever a symbol takes longer than 16ms, and getting it wrong is a
-- radio that hears nothing from one that has it right.
function Radio:modem(sf, bwkhz, cr)
	local bw = BW[bwkhz]

	if not bw then
		return nil, "no such bandwidth: " .. tostring(bwkhz)
	end
	if sf < 5 or sf > 12 then
		return nil, "spreading factor out of range"
	end

	local ldro = (1000 * (1 << sf) / bwkhz) > 16.0 and 1 or 0

	self.sf, self.bw, self.cr, self.ldro = sf, bwkhz, cr, ldro
	return self:cmd(C.SETMODPARAMS,
	    string.char(sf, bw, (cr or 5) - 4, ldro))
end

function Radio:packet(preamble, explicit, len, crc, iq)
	self.explicit = explicit
	return self:cmd(C.SETPKTPARAMS, string.pack(">I2", preamble or 8) ..
	    string.char(explicit and 0 or 1, len or 255,
	        crc and 1 or 0, iq and 1 or 0))
end

-- the sync word, as the byte everyone quotes rather than the register
-- pair the chip keeps. 0x12 is private, 0x34 is a public network.
function Radio:syncword(b)
	return self:writereg(0x0740,
	    string.char((b & 0xf0) | 0x04, ((b & 0x0f) << 4) | 0x04))
end

-- the power amplifier, and the power itself. The sx1262's table is
-- fixed by the datasheet for +22dBm and nothing here offers less: an
-- amplifier set for one output and driven at another is out of spec.
function Radio:power(dbm)
	local ok, why = self:cmd(C.SETPACONFIG, string.char(0x04, 0x07, 0x00, 0x01))

	if not ok then
		return nil, why
	end
	if dbm < -9 or dbm > 22 then
		return nil, "power out of range"
	end
	-- 0x04 is the ramp time, 200us, which is what every driver uses
	return self:cmd(C.SETTXPARAMS, string.char(dbm & 0xff, 0x04))
end

-- ---- what a board needs before any of the above ----

-- The module has a TCXO on DIO3 rather than a plain crystal, and it
-- needs its voltage and time to settle before anything is calibrated.
-- A radio configured without this tunes to the wrong frequency and
-- hears nothing, which is the failure that looks like bad wiring.
local TCXO = { [1.6] = 0, [1.7] = 1, [1.8] = 2, [2.2] = 3, [2.4] = 4,
    [2.7] = 5, [3.0] = 6, [3.3] = 7 }

function Radio:tcxo(volts, ms)
	local v = TCXO[volts]

	if not v then
		return nil, "no such tcxo voltage"
	end

	-- the timeout counts in 15.625us steps
	local ticks = math.floor((ms or 5) * 1000 / 15.625)

	return self:cmd(C.SETDIO3TCXO,
	    string.char(v, (ticks >> 16) & 0xff, (ticks >> 8) & 0xff,
	        ticks & 0xff))
end

-- DIO2 drives the antenna switch on every board that has one, which is
-- every board with a sx1262 module rather than a bare chip.
function Radio:rfswitch(on)
	return self:cmd(C.SETDIO2RF, string.char(on and 1 or 0))
end

function Radio:calibrate()
	return self:cmd(C.CALIBRATE, string.char(0x7f))
end

-- the image calibration is per band, and the datasheet's table is in
-- MHz pairs. Only the two bands this radio is sold in are here.
function Radio:calibimage(mhz)
	local lo, hi

	if mhz >= 902 and mhz <= 928 then
		lo, hi = 0xe1, 0xe9
	elseif mhz >= 863 and mhz <= 870 then
		lo, hi = 0xd7, 0xdb
	elseif mhz >= 470 and mhz <= 510 then
		lo, hi = 0x75, 0x81
	elseif mhz >= 430 and mhz <= 440 then
		lo, hi = 0x6b, 0x6f
	else
		return nil, "no image calibration for " .. mhz .. "MHz"
	end
	return self:cmd(C.CALIBIMAGE, string.char(lo, hi))
end

-- ---- interrupts, transmit and receive ----

function Radio:irqmask(mask)
	local m = string.pack(">I2", mask)

	-- the same mask on DIO1, which is the pin the board wired
	return self:cmd(C.SETDIOIRQ, m .. m .. string.pack(">I2", 0) ..
	    string.pack(">I2", 0))
end

function Radio:irq()
	local s = self:cmd(C.GETIRQ, "", 3)

	if not s then
		return nil
	end
	return (s:byte(2) << 8) | s:byte(3)
end

function Radio:clearirq(mask)
	return self:cmd(C.CLRIRQ, string.pack(">I2", mask or 0xffff))
end

function Radio:send(data)
	if #data > 255 then
		return nil, "a packet is 255 bytes at most"
	end

	local ok, why = self:cmd(C.SETBUFBASE, string.char(0, 0))

	if not ok then
		return nil, why
	end
	-- the payload length is a packet parameter, so it is set per
	-- packet and not once
	self:packet(self.preamble or 16, self.explicit, #data, true, false)
	self:cmd(C.WRITEBUF, string.char(0) .. data)
	self:clearirq()
	self:irqmask(M.IRQ_TXDONE | M.IRQ_TIMEOUT)

	-- 0 is no timeout: the chip stays in transmit until it is done
	return self:cmd(C.SETTX, string.char(0, 0, 0))
end

-- listen until something arrives. 0xffffff is the continuous mode the
-- datasheet gives, where the chip stays in receive rather than timing
-- out and having to be told again.
function Radio:listen()
	self:clearirq()
	self:irqmask(M.IRQ_RXDONE | M.IRQ_CRCERR | M.IRQ_HEADERERR)
	return self:cmd(C.SETRX, string.char(0xff, 0xff, 0xff))
end

-- what arrived, if anything did. Answers the payload, then rssi and
-- snr in dB.
function Radio:read()
	local s = self:cmd(C.GETRXBUFSTATUS, "", 3)

	if not s then
		return nil
	end

	local len, at = s:byte(2), s:byte(3)

	if len == 0 then
		return nil
	end

	local data = self:cmd(C.READBUF, string.char(at, 0), len)
	local st = self:cmd(C.GETPKTSTATUS, "", 4)

	if not data or not st then
		return nil
	end

	-- rssi is negative half-dBm; snr is a signed quarter-dB
	local snr = st:byte(3)

	if snr > 127 then
		snr = snr - 256
	end
	return data, -(st:byte(2) / 2), snr / 4
end

return M
