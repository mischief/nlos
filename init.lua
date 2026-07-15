-- lua-os init (proc 0): spawn a demo service, then repl

print(("%s on %s (fw rev 0x%x)"):format(_VERSION, los.firmware,
    los.firmware_revision))
print("mach-lite kernel. procs are isolated lua states; talk via ports.")
print("try: pid, srv = los.spawn(code) / los.send(srv, msg) / recv(port)")
print("")

-- demo: echo service in its own lua state
local _, echo = los.spawn([[
	while true do
		local m = recv(los.SELF)
		if type(m) == "table" and m.reply then
			-- transferred rights arrive as {__right = handle}
			los.send(m.reply.__right,
			    { echoed = m.text, from = "echo-proc" })
		end
	end
]])

-- prove round trip: make a reply port, send, block on answer
local replyport = los.newport()
los.send(echo, { text = "kernel says hi", reply = { __right = replyport } })
local answer = recv(replyport)
print(("echo service answered: %q (from %s)"):format(answer.echoed,
    answer.from))
print("")

-- repl
local function evaluate(line)
	local chunk, err = load("return " .. line, "=repl")
	if not chunk then
		chunk, err = load(line, "=repl")
	end
	return chunk, err
end

while true do
	local line = readline("> ")
	if line == nil then
		break
	end
	if #line > 0 then
		local chunk, err = evaluate(line)
		while not chunk and err and err:sub(-5) == "<eof>" do
			local more = readline(">> ")
			if more == nil then
				break
			end
			line = line .. "\n" .. more
			chunk, err = load(line, "=repl")
		end
		if chunk then
			local res = table.pack(pcall(chunk))
			if res[1] then
				if res.n > 1 then
					print(table.unpack(res, 2, res.n))
				end
			else
				print("error: " .. tostring(res[2]))
			end
		else
			print(err)
		end
	end
end

print("init exiting. bye.")
