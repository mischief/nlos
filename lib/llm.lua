-- llm: one turn against an OpenAI-shaped Responses endpoint.
--
--	local c = llm.new({ net = ..., dns = ..., rand = ...,
--	    url = "https://api.openai.com/v1", key = ..., model = ... })
--	local text, err = c:say("what is 2+2")

-- Stateless: every request carries the whole input, and nothing is kept
-- on the server. previous_response_id exists in the spec and would let
-- a client send one turn instead of all of them -- worth having on a
-- machine this size, and a separate thing from getting a turn to work.

-- The connection is held between turns. A handshake is seconds on a
-- board and milliseconds of that is the network, so a client that
-- reconnected per turn would spend most of its life shaking hands.

local json = require("json")
local http = require("http")

local M = {}

local Client = {}

Client.__index = Client

-- new(opts) -> client
--
--   net, dns, rand   what lib/http and lib/tlstcp need
--   url              the API root, without a trailing slash
--   key              the bearer token
--   model            what to ask
function M.new(opts)
	if not opts or not opts.key then
		return nil, "llm: no api key"
	end
	return setmetatable({
		net = opts.net,
		dns = opts.dns,
		rand = opts.rand,
		url = opts.url or "https://api.openai.com/v1",
		key = opts.key,
		model = opts.model or "gpt-5.4-mini",
		verify = opts.verify,
	}, Client)
end

-- the connection, opened once and kept. Reopened where the far end has
-- closed it, since a server may hang up between turns and a client that
-- treated that as an error would be wrong about a working connection.
function Client:conn()
	if self.c and self.c:alive() then
		return self.c
	end

	local host = self.url:match("^https?://([^/]+)")
	local verify = self.verify or
	    require("tlstcp").tofu(host:match("^[^:]+"))
	local c, err = http.connect(self.net, self.dns, self.url,
	    { rand = self.rand, verify = verify })

	if not c then
		return nil, err
	end
	self.c = c
	return c
end

function Client:close()
	if self.c then
		self.c:close()
		self.c = nil
	end
end

-- ask(input) -> response table, or nil plus why.
--
-- input is the spec's: a string, or a list of items. What comes back is
-- the decoded body, so a caller wanting more than the text has it.
function Client:ask(input, extra)
	local c, cerr = self:conn()

	if not c then
		return nil, cerr
	end

	local req = { model = self.model, input = input }

	for k, v in pairs(extra or {}) do
		req[k] = v
	end

	local body = json.encode(req)
	local path = self.url:match("^https?://[^/]+(/.*)$") or ""
	local res, rerr = c:request({
		method = "POST",
		path = path .. "/responses",
		headers = {
			["Authorization"] = "Bearer " .. self.key,
			["Content-Type"] = "application/json",
			-- asked for outright: a streamed answer arrives as
			-- events this cannot yet read, and a server that
			-- chose to stream would look like a broken reply.
			["Accept"] = "application/json",
		},
		body = body,
	})

	if not res then
		return nil, rerr
	end

	local ok, decoded = pcall(json.decode, res.body)

	if not ok or type(decoded) ~= "table" then
		return nil, ("status %d, and the body is not json: %s")
		    :format(res.status, res.body:sub(1, 120))
	end
	if res.status ~= 200 then
		local e = decoded.error

		return nil, ("status %d: %s"):format(res.status,
		    (type(e) == "table" and e.message) or res.body:sub(1, 200))
	end
	return decoded
end

-- the assistant's text, pulled out of the output items. The spec's
-- output is a list of items, each with a list of content parts, and
-- what a caller usually wants is the text of the ones that carry it.
function M.text(res)
	if type(res) ~= "table" or type(res.output) ~= "table" then
		return nil
	end

	local parts = {}

	for _, item in ipairs(res.output) do
		if type(item.content) == "table" then
			for _, p in ipairs(item.content) do
				if type(p) == "table" and p.text then
					parts[#parts + 1] = p.text
				end
			end
		end
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts)
end

-- say(input) -> text -- the whole of a simple turn.
function Client:say(input, extra)
	local res, err = self:ask(input, extra)

	if not res then
		return nil, err
	end
	return M.text(res) or "", res
end

return M
