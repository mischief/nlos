-- mcp: minimal Model Context Protocol server -- JSON-RPC 2.0 over
-- plain HTTP POST, built entirely on http.serve + our own json.lua
-- codec. no C JSON library (no cjson): same reasoning as every other
-- protocol in this repo (dns, 9p, http itself) being hand-rolled in
-- plain lua, no third-party deps.
--
-- v1 scope: initialize + tools/list + tools/call. no resources, no
-- prompts, no streaming/SSE transport -- one request in, one JSON
-- response out, same shape http.lua already has.

local http = require("http")
local json = require("json")

local M = {}

local PROTOCOL_VERSION = "2024-11-05"

local function rpc_result(id, result)
	return { jsonrpc = "2.0", id = id, result = result }
end

local function rpc_error(id, code, message)
	return { jsonrpc = "2.0", id = id,
	    error = { code = code, message = message } }
end

-- tools: array of {name=, description=, inputSchema=(optional),
-- handler=function(arguments) -> string}. a handler that errors
-- becomes a real MCP tool error result (isError=true), not a crashed
-- connection or server -- same isolation http.lua already gives
-- ordinary handlers.
function M.serve(tcp, port, tools, onready)
	local byname = {}

	for _, t in ipairs(tools) do
		byname[t.name] = t
	end

	local function dispatch(req)
		local id = req.id

		if req.method == "initialize" then
			return rpc_result(id, {
				protocolVersion = PROTOCOL_VERSION,
				capabilities = { tools = {} },
				serverInfo = { name = "lua-os", version = "0.1" },
			})
		elseif req.method == "notifications/initialized" then
			return nil	-- a notification: no response at all
		elseif req.method == "tools/list" then
			local list = {}

			for _, t in ipairs(tools) do
				list[#list + 1] = {
					name = t.name,
					description = t.description or "",
					inputSchema = t.inputSchema or
					    { type = "object", properties = {} },
				}
			end
			return rpc_result(id, { tools = list })
		elseif req.method == "tools/call" then
			local params = req.params or {}
			local tool = byname[params.name]

			if not tool then
				return rpc_error(id, -32602,
				    "unknown tool: " .. tostring(params.name))
			end

			local args = params.arguments or {}
			local ok, text = pcall(tool.handler, args)

			if not ok then
				return rpc_result(id, { isError = true,
				    content = { { type = "text",
				        text = "error: " .. tostring(text) } } } )
			end
			return rpc_result(id, { content = {
			    { type = "text", text = tostring(text) } } })
		else
			return rpc_error(id, -32601,
			    "method not found: " .. tostring(req.method))
		end
	end

	-- onready is forwarded to http.serve: it fires once the listener
	-- is genuinely accepting, which is the only reliable "up" signal
	-- (dhcp has to land first, and serve never returns on success).
	return http.serve(tcp, port, function(httpreq)
		if httpreq.method ~= "POST" then
			return { status = 405, body = "POST only" }
		end

		local rpcreq, err = json.decode(httpreq.body or "")

		if not rpcreq then
			return { status = 400, body = "bad json: " .. tostring(err) }
		end
		-- valid json is not necessarily a json-rpc request: "5" and
		-- "[]" both decode fine. everything below indexes this, so
		-- reject a non-object here rather than throwing on .id.
		if type(rpcreq) ~= "table" then
			return { status = 400, body = "not a json-rpc object" }
		end

		local ok, resp = pcall(dispatch, rpcreq)

		if not ok then
			resp = rpc_error(rpcreq.id, -32603, tostring(resp))
		end
		if resp == nil then
			-- a notification (e.g. notifications/initialized):
			-- json-rpc says no response body at all.
			return { status = 204 }
		end
		return { status = 200,
		    headers = { ["Content-Type"] = "application/json" },
		    body = json.encode(resp) }
	end, onready)
end

return M
