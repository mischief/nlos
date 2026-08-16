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
-- key is optional: a model served on the LAN wants no bearer, and
-- sending an empty one is worse than sending none.
function M.new(opts)
	if not opts then
		return nil, "llm: no options"
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

	local host = self.url:match("^https?://([^/:]+)")
	local opts = { rand = self.rand }

	-- only where the scheme asks for it: requiring tlstcp loads the
	-- whole handshake and the crypto under it, which is over a second
	-- on a board, and a plain http endpoint never touches any of it.
	if self.url:match("^https://") then
		opts.verify = self.verify or require("tlstcp").tofu(host)
	end

	local c, err = http.connect(self.net, self.dns, self.url, opts)

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
			["Authorization"] = self.key and
			    ("Bearer " .. self.key) or nil,
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

-- the parts of one kind, across every output item. The spec's output is
-- a list of items and each carries a list of content parts, so what a
-- caller wants is a kind rather than an item.
local function parts(res, kind)
	if type(res) ~= "table" or type(res.output) ~= "table" then
		return nil
	end

	local out = {}

	for _, item in ipairs(res.output) do
		if type(item.content) == "table" then
			for _, p in ipairs(item.content) do
				if type(p) == "table" and p.type == kind and
				    p.text then
					out[#out + 1] = p.text
				end
			end
		end
	end
	if #out == 0 then
		return nil
	end
	return table.concat(out)
end

-- the answer: output_text and nothing else. By type rather than by
-- "has a text field", because a reasoning model emits a reasoning item
-- whose parts carry text too, and taking everything puts the model's
-- thinking in front of its answer. A local Qwen does that where
-- gpt-5.4-mini did not, so one endpoint alone would not have shown it.
function M.text(res)
	return parts(res, "output_text")
end

-- what the model thought on the way, where it says so.
function M.reasoning(res)
	return parts(res, "reasoning_text")
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
