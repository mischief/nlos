-- prelude: loaded into every proc before its chunk runs.
-- blocking-looking sugar over the kernel's tryrecv/block.

-- every proc: handle 0 = own receive port. proc 0 also: handle 1 = keyboard.
los.SELF = 0
los.KBD = 1

function recv(h)
	while true do
		local ok, msg = los.tryrecv(h)
		if ok then
			return msg
		end
		los.block(h)
	end
end

-- line editor over the keyboard port (proc 0 only)
function readline(prompt)
	if prompt then
		io.write(prompt)
	end
	local buf = {}
	while true do
		local c = recv(los.KBD)
		if c == "\r" or c == "\n" then
			io.write("\n")
			return table.concat(buf)
		elseif c == "\4" then -- ctrl-d
			if #buf == 0 then
				return nil
			end
		elseif c == "\8" or c == "\127" then -- backspace
			if #buf > 0 then
				table.remove(buf)
				io.write("\8 \8")
			end
		elseif #c == 1 and c >= " " then
			buf[#buf + 1] = c
			io.write(c)
		end
	end
end
