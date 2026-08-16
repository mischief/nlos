-- llm: one turn against an OpenAI-shaped Responses endpoint.
--
--	local c = llm.new({ net = ..., dns = ..., rand = ...,
--	    url = "https://api.openai.com/v1", key = ..., model = ... })
--	local text, err = c:say("what is 2+2")

-- stateful = true holds the conversation on the server and sends one
-- turn plus the id of the last, which is what keeps a long chat off a
-- small machine: a transcript grows without bound and an id does not.
-- Verified against api.openai.com; llama.cpp answers 400 and says it
-- does not support previous_response_id, so it is opt-in.

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
		-- the server keeps the conversation and each turn names the
		-- last. Not every endpoint has it -- llama.cpp answers 400,
		-- saying so -- which is why it is asked for rather than
		-- assumed.
		stateful = opts.stateful,
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

-- say(input) -> text, response -- one turn of a conversation.
--
-- Where the client was made stateful, the server is holding the
-- conversation and what goes up is this turn plus the id of the last
-- one. That is the whole of why it matters here: a transcript kept in
-- this proc grows without limit, and an id does not.
function Client:say(input, extra)
	local e = extra

	if self.stateful and self.last then
		e = { previous_response_id = self.last }
		for k, v in pairs(extra or {}) do
			e[k] = v
		end
	end

	local res, err = self:ask(input, e)

	if not res then
		return nil, err
	end
	self.last = res.id
	return M.text(res) or "", res
end

-- start again, forgetting what the server is holding. The conversation
-- is still there; this stops referring to it.
function Client:reset()
	self.last = nil
end

-- what the server is holding, if anything: an id, and the whole of what
-- a stateful client has to keep across turns.
function Client:mark()
	return self.last
end

return M
