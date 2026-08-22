-- lora: the one proc holding the radio, serving it over a port.
--
--	{op="config", freq=, sf=, bw=, cr=, power=, sync=, preamble=}
--	{op="send", data=}	{op="recv"}	{op="listen"}
--
-- lib/sx1262 is the chip; this watches DIO1 so no client has to.

local sys = require("los.sys")
local thread = require("los.thread")
local wire = require("los.platform.lora")
local sx = require("sx1262")

local radio = sx.new(wire)

-- what the machine listens on when nobody has said otherwise. The US
-- band, and the slowest of the common settings: this is a default to
-- be talked out of, not a policy.
local conf = {
	freq = 906875000,
	sf = 11,
	bw = 250,
	cr = 5,
	power = 22,
	sync = 0x12,
	preamble = 16,
	-- the module has a temperature-compensated oscillator on DIO3.
	-- A board with a plain crystal wants this nil: waiting for an
	-- oscillator that is not there is what XOSC_START_ERR means.
	tcxo = 1.8,
}

local queue = {}	-- what arrived and nobody has asked for yet
local listening = false

-- every configuration goes through here, since the order is the part
-- that matters: the tcxo before the calibration that depends on it,
-- and the calibration before any frequency is believed.
local function configure()
	wire.reset()
	radio:standby(true)
	if conf.tcxo then
		radio:tcxo(conf.tcxo, 10)
	end
	-- after the oscillator is settled and before anything is judged:
	-- what is latched here was raised while it was still starting
	radio:clearerrors()
	radio:calibrate()
	thread.sleep(20)
	radio:standby(true)
	radio:rfswitch(true)
	radio:cmd(0x8a, string.char(1))		-- packet type: lora
	radio:calibimage(conf.freq / 1000000)
	radio:frequency(conf.freq)
	radio:modem(conf.sf, conf.bw, conf.cr)
	radio:packet(conf.preamble, true, 255, true, false)
	radio:syncword(conf.sync)
	radio:power(conf.power)
	radio.preamble = conf.preamble

	local err = radio:errors() or 0

	if err ~= 0 then
		sys.log(("lora: device errors %04x"):format(err))
	end
	return err == 0
end

local function listen()
	radio:listen()
	listening = true
end

-- the radio half: DIO1 goes high when a packet is done either way, and
-- what it was is in the interrupt status.
local function pump()
	while true do
		if wire.irq() then
			local st = radio:irq() or 0

			radio:clearirq()
			if (st & sx.IRQ_RXDONE) ~= 0 then
				local data, rssi, snr = radio:read()

				if data then
					queue[#queue + 1] = { data = data,
					    rssi = rssi, snr = snr }
				end
				-- continuous receive stays in receive, but
				-- a crc error drops it
				if not listening then
					listen()
				end
			elseif (st & sx.IRQ_TXDONE) ~= 0 then
				listen()
			elseif st ~= 0 then
				sys.log(("lora: irq %04x"):format(st))
				listen()
			end
		end
		thread.sleep(5)
	end
end

local function serve()
	local me = sys.SELF

	while true do
		local m = thread.recv(me)

		if type(m) ~= "table" then
			goto continue
		end

		-- a right that arrives is a copy, and this proc holds it
		-- until it says otherwise. A client that polls -- which is
		-- what listening is -- fills all 512 in a minute
		-- otherwise, and the task dies rather than the caller.
		local reply = m.reply and m.reply.__right
		local function answer(msg)
			if reply then
				sys.send(reply, msg)
			end
		end

		if m.op == "config" then
			for _, k in ipairs({ "freq", "sf", "bw", "cr", "power",
			    "sync", "preamble" }) do
				if m[k] then
					conf[k] = m[k]
				end
			end

			local ok = configure()

			listen()
			answer({ ok = ok, conf = conf })
		elseif m.op == "send" then
			listening = false

			local ok, why = radio:send(m.data or "")

			answer({ ok = ok and true or nil,
				    err = why })
		elseif m.op == "recv" then
			local got = table.remove(queue, 1)

			answer({ ok = got })
		elseif m.op == "listen" then
			listen()
			answer({ ok = true })
		elseif m.op == "status" then
			local mode, cmd = radio:status()

			answer({ ok = { mode = mode, cmd = cmd, conf = conf,
			    waiting = #queue } })
		else
			answer({ err = "no such op: " .. tostring(m.op) })
		end

		if reply then
			sys.close(reply)
		end

		::continue::
	end
end

if not configure() then
	sys.log("lora: the radio would not configure")
end
listen()

thread.spawn(pump)
thread.spawn(serve)
thread.run()
