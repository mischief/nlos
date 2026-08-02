-- The server half: banner, kex, userauth, and a channel layer that
-- reports events rather than running anything.
--
-- Sans-io, and sans-process too. This module never spawns a shell, never
-- opens a pty and never decides what a command means. It hands the
-- embedder events and takes bytes back:
--
--     local s = server.new(conn, {
--       hostkey_seed = seed,
--       authorized = function(user, pk) ... end,
--     })
--     assert(s:handshake())
--     for ev in s:events() do
--       if ev.type == "exec" then ... s:data(ev.chan, output) ... end
--     end
--
-- That split is the whole point. On a POSIX host the embedder forks a
-- process and selects over pipes; on lua-os it spawns an isolated proc
-- and wires the channel to a console port, exactly as lib/webterm.lua
-- does for a browser. Neither arrangement can be expressed as a blocking
-- call inside this file, so this file does not try.
--
-- What it does own, because the protocol owns it: sequence numbers,
-- padding, the exchange hash, the signature, the authentication decision
-- and window accounting. Those must not be reimplemented per embedder.

local wire = require "ssh.wire"
local msg = require "ssh.msg"
local packet = require "ssh.packet"
local kex = require "ssh.kex"
local ed25519 = require "crypto.ed25519"

local M = {}

M.VERSION = "SSH-2.0-luassh_0.1"

local WINDOW = 2 * 1024 * 1024
local MAXPACKET = 32768

local S = {}
S.__index = S

-- `conf.hostkey_seed` is the 32-byte Ed25519 seed. `conf.authorized` is
-- called with (user, publickey) and returns true to accept; without it
-- nothing authenticates, which is the safe default rather than the
-- convenient one.
function M.new(conn, conf)
  conf = conf or {}
  local seed = assert(conf.hostkey_seed, "server: need hostkey_seed")
  assert(#seed == 32, "server: hostkey_seed must be 32 bytes")

  return setmetatable({
    conn = conn,
    conf = conf,
    pkt = packet.new(conn),
    hostkey_seed = seed,
    hostkey_pub = conf.hostkey_pub or ed25519.publickey(seed),
    chans = {},
    nextchan = 0,
  }, S)
end

local function fail(err) return nil, err end

--------------------------------------------------------------------------
-- transport

function S:send(payload) return self.pkt:sendpkt(payload) end

function S:banner()
  local ok, err = self.conn.write(M.VERSION .. "\r\n")
  if not ok then return fail(err) end

  -- A client's first line is its version; unlike a server it may not
  -- send anything before it.
  local line
  line, err = self.conn.readline()
  if not line then return fail(err or "eof reading client banner") end
  line = line:gsub("\r$", "")
  if line:sub(1, 4) ~= "SSH-" then return fail("not an SSH client") end
  if line:sub(1, 8) ~= "SSH-2.0-" and line:sub(1, 8) ~= "SSH-1.99" then
    return fail("client speaks " .. line)
  end

  self.v_c, self.v_s = line, M.VERSION
  return true
end

function S:transport_msg(payload)
  local t = payload:byte(1)
  if t == msg.IGNORE or t == msg.DEBUG or t == msg.UNIMPLEMENTED
     or t == msg.EXT_INFO then
    return true
  end
  if t == msg.GLOBAL_REQUEST then
    local r = wire.reader(payload)
    r:byte()
    r:string()
    if r:boolean() then self:send(string.char(msg.REQUEST_FAILURE)) end
    return true
  end
  if t == msg.DISCONNECT then
    local r = wire.reader(payload)
    r:byte()
    local code = r:uint32()
    self.closed = ("client disconnected (%d): %s")
      :format(code or 0, r:string() or "")
    return true
  end
  return false
end

function S:recv()
  while true do
    local payload, err = self.pkt:recvpkt()
    if not payload then return fail(err) end
    if not self:transport_msg(payload) then return payload end
    if self.closed then return fail(self.closed) end
  end
end

--------------------------------------------------------------------------
-- key exchange

function S:kex()
  local i_s = kex.kexinit(self.conn.rand, "server")
  local ok, err = self:send(i_s)
  if not ok then return fail(err) end

  local i_c
  i_c, err = self:recv()
  if not i_c then return fail(err) end

  local opts
  opts, err = kex.check(i_c, "server")
  if not opts then return fail(err) end
  if not opts.strict then
    return fail("client does not support " .. kex.STRICT_C)
  end

  local res
  res, err = kex.server {
    sendpkt = function(p) return self:send(p) end,
    recvpkt = function() return self:recv() end,
    rand = self.conn.rand,
    v_c = self.v_c, v_s = self.v_s, i_c = i_c, i_s = i_s,
    hostkey_seed = self.hostkey_seed,
    hostkey_pub = self.hostkey_pub,
    session_id = self.session_id,
  }
  if not res then return fail(err) end

  ok, err = self:send(string.char(msg.NEWKEYS))
  if not ok then return fail(err) end

  local payload
  payload, err = self:recv()
  if not payload then return fail(err) end
  if payload:byte(1) ~= msg.NEWKEYS then return fail("expected NEWKEYS") end

  -- The server's outgoing direction is server-to-client; the same pair,
  -- swapped relative to the client.
  self.pkt:setkeys(res.keys.s2c, res.keys.c2s)
  self.pkt:resetseq()
  self.session_id = self.session_id or res.session_id

  return true
end

--------------------------------------------------------------------------
-- authentication

local SERVICE = "ssh-connection"
local ALG = "ssh-ed25519"

function S:auth_failure(partial)
  return self:send(wire.writer()
    :byte(msg.USERAUTH_FAILURE)
    :namelist { "publickey" }
    :boolean(partial or false)
    :tostring())
end

-- Reconstruct exactly what the client should have signed, RFC 4252 7:
-- string(session_id) followed by the request with the boolean true.
local function signed_blob(session_id, user, pkblob)
  local body = wire.writer()
    :byte(msg.USERAUTH_REQUEST)
    :string(user)
    :string(SERVICE)
    :string("publickey")
    :boolean(true)
    :string(ALG)
    :string(pkblob)
    :tostring()
  return wire.writer():string(session_id):raw(body):tostring()
end

function S:userauth()
  -- The client must ask for ssh-userauth before anything else.
  local payload, err = self:recv()
  if not payload then return fail(err) end
  if payload:byte(1) ~= msg.SERVICE_REQUEST then
    return fail("expected SERVICE_REQUEST")
  end
  local r = wire.reader(payload)
  r:byte()
  local want = r:string()
  if want ~= "ssh-userauth" then return fail("unknown service " .. tostring(want)) end

  local ok
  ok, err = self:send(wire.writer()
    :byte(msg.SERVICE_ACCEPT):string("ssh-userauth"):tostring())
  if not ok then return fail(err) end

  local authorized = self.conf.authorized

  -- A bounded number of attempts. Unbounded is a free password-guessing
  -- oracle even with only publickey enabled, because each attempt costs
  -- us a signature verification.
  for _ = 1, self.conf.max_auth_tries or 6 do
    payload, err = self:recv()
    if not payload then return fail(err) end
    if payload:byte(1) ~= msg.USERAUTH_REQUEST then
      return fail("expected USERAUTH_REQUEST")
    end

    r = wire.reader(payload)
    r:byte()
    local user = r:string()
    local service = r:string()
    local method = r:string()

    if service ~= SERVICE then
      return fail("unknown service " .. tostring(service))
    end

    if method ~= "publickey" or not authorized then
      -- "none" lands here too, which is how a client learns what we take.
      ok, err = self:auth_failure()
      if not ok then return fail(err) end
      goto continue
    end

    do
      local signed = r:boolean()
      local alg = r:string()
      local pkblob = r:string()
      if not pkblob then return fail("truncated USERAUTH_REQUEST") end

      local pk = alg == ALG and kex.parse_hostkey(pkblob) or nil

      if not pk or not authorized(user, pk) then
        ok, err = self:auth_failure()
        if not ok then return fail(err) end
        goto continue
      end

      if not signed then
        -- The probe. Tell the client the key is acceptable and let it
        -- decide whether to spend a signature.
        ok, err = self:send(wire.writer()
          :byte(msg.USERAUTH_PK_OK):string(alg):string(pkblob):tostring())
        if not ok then return fail(err) end
        goto continue
      end

      local sigblob = r:string()
      local sig = sigblob and kex.parse_signature(sigblob)
      if not sig or
         not ed25519.verify(pk, signed_blob(self.session_id, user, pkblob), sig)
      then
        ok, err = self:auth_failure()
        if not ok then return fail(err) end
        goto continue
      end

      ok, err = self:send(string.char(msg.USERAUTH_SUCCESS))
      if not ok then return fail(err) end
      self.user = user
      self.userkey = pk
      return true
    end

    ::continue::
  end

  self:send(wire.writer():byte(msg.DISCONNECT):uint32(14)
    :string("too many authentication failures"):string(""):tostring())
  return fail("too many authentication failures")
end

function S:handshake()
  local ok, err = self:banner()
  if not ok then return fail(err) end
  ok, err = self:kex()
  if not ok then return fail(err) end
  return self:userauth()
end

--------------------------------------------------------------------------
-- channels: events out, bytes in

local function chan_reply(self, ch, okflag)
  return self:send(wire.writer()
    :byte(okflag and msg.CHANNEL_SUCCESS or msg.CHANNEL_FAILURE)
    :uint32(ch.peer):tostring())
end

-- Give window back before it runs out, or the client stops sending and
-- both ends wait forever.
local function topup(self, ch)
  if ch.ourwindow >= WINDOW // 2 then return end
  local add = WINDOW - ch.ourwindow
  self:send(wire.writer():byte(msg.CHANNEL_WINDOW_ADJUST)
    :uint32(ch.peer):uint32(add):tostring())
  ch.ourwindow = WINDOW
end

-- One protocol step. Returns an event table, or nil plus an error, or
-- nil, nil at a clean end of session.
function S:step()
  local payload, err = self:recv()
  if not payload then
    if self.closed then return nil, nil end
    return fail(err)
  end

  local r = wire.reader(payload)
  local t = r:byte()

  if t == msg.CHANNEL_OPEN then
    local kind = r:string()
    local peer = r:uint32()
    local window = r:uint32()
    local maxpacket = r:uint32()

    if kind ~= "session" then
      self:send(wire.writer():byte(msg.CHANNEL_OPEN_FAILURE)
        :uint32(peer):uint32(3)          -- UNKNOWN_CHANNEL_TYPE
        :string("only session channels"):string(""):tostring())
      return { type = "ignored" }
    end

    local id = self.nextchan
    self.nextchan = id + 1
    local ch = {
      id = id, peer = peer,
      window = window or 0,
      maxpacket = math.min(maxpacket or MAXPACKET, MAXPACKET),
      ourwindow = WINDOW,
    }
    self.chans[id] = ch

    self:send(wire.writer():byte(msg.CHANNEL_OPEN_CONFIRMATION)
      :uint32(peer):uint32(id):uint32(WINDOW):uint32(MAXPACKET):tostring())

    return { type = "open", chan = ch }
  end

  local id = r:uint32()
  local ch = id and self.chans[id]
  if not ch then return { type = "ignored" } end

  if t == msg.CHANNEL_DATA then
    local data = r:string() or ""
    ch.ourwindow = ch.ourwindow - #data
    topup(self, ch)
    return { type = "data", chan = ch, data = data }

  elseif t == msg.CHANNEL_WINDOW_ADJUST then
    ch.window = ch.window + (r:uint32() or 0)
    -- More room: push out whatever was waiting on it. This is the only
    -- place a stalled transfer can resume from.
    local ok, err = self:flush(ch)
    if not ok then return fail(err) end
    return { type = "ignored" }

  elseif t == msg.CHANNEL_EOF then
    return { type = "eof", chan = ch }

  elseif t == msg.CHANNEL_CLOSE then
    if not ch.sent_close then
      self:send(wire.writer():byte(msg.CHANNEL_CLOSE)
        :uint32(ch.peer):tostring())
      ch.sent_close = true
    end
    self.chans[ch.id] = nil
    return { type = "close", chan = ch }

  elseif t == msg.CHANNEL_REQUEST then
    local what = r:string()
    local want_reply = r:boolean()

    if what == "exec" then
      local command = r:string()
      if want_reply then chan_reply(self, ch, true) end
      return { type = "exec", chan = ch, command = command }

    elseif what == "shell" then
      if want_reply then chan_reply(self, ch, true) end
      return { type = "shell", chan = ch }

    elseif what == "subsystem" then
      local name = r:string()
      if want_reply then chan_reply(self, ch, true) end
      return { type = "subsystem", chan = ch, name = name }

    elseif what == "pty-req" then
      local term = r:string()
      local cols, rows = r:uint32(), r:uint32()
      -- Accepted so an interactive client is happy, but there is no
      -- terminal here: line discipline belongs to whatever the embedder
      -- attaches, exactly as it does for lua-os's console.
      if want_reply then chan_reply(self, ch, true) end
      return { type = "pty", chan = ch, term = term, cols = cols, rows = rows }

    else
      -- env, signal, x11-req and the rest: refused, not silently dropped.
      if want_reply then chan_reply(self, ch, false) end
      return { type = "ignored", request = what }
    end
  end

  return { type = "ignored" }
end

-- Iterator form, skipping the events an embedder never cares about.
function S:events()
  return function()
    while true do
      local ev, err = self:step()
      if not ev then
        if err then self.error = err end
        return nil
      end
      if ev.type ~= "ignored" then return ev end
    end
  end
end

--------------------------------------------------------------------------
-- writing back

-- Writes are queued, not blocking.
--
-- The peer's window will run out well before a large transfer finishes --
-- it is 2 MB by default and a file is not -- and the only thing that can
-- grant more is a CHANNEL_WINDOW_ADJUST that arrives on the read path.
-- A blocking write would therefore have to read, which is precisely the
-- thing this module does not own: the embedder's loop does.
--
-- So `data` queues and flushes what fits, `step` flushes again whenever a
-- window adjust arrives, and `pending` reports the backlog so an embedder
-- can stop producing rather than buffer without bound. Ordering is kept
-- by queueing eof, exit-status and close as operations too: an exit sent
-- ahead of the output it describes would be a subtle and rare bug.
local function enqueue(self, ch, op)
  ch.outq = ch.outq or {}
  ch.outq[#ch.outq + 1] = op
  return self:flush(ch)
end

function S:flush(ch)
  local q = ch.outq
  if not q then return true end

  while q[1] do
    local op = q[1]

    if op.kind == "data" or op.kind == "ext" then
      -- An empty write is a no-op, not a stall. Without this it queues an
      -- entry that can never drain, because zero bytes always "fit in
      -- zero window", and everything behind it waits forever.
      if #op.data == 0 then
        table.remove(q, 1)
        goto continue
      end

      -- Respect both limits: the peer's window and its maximum packet.
      local n = math.min(#op.data, ch.maxpacket, ch.window)
      if n <= 0 then return true, #q end          -- blocked, not failed

      local w = wire.writer()
      if op.kind == "ext" then
        w:byte(msg.CHANNEL_EXTENDED_DATA):uint32(ch.peer):uint32(1)
      else
        w:byte(msg.CHANNEL_DATA):uint32(ch.peer)
      end
      w:string(op.data:sub(1, n))

      local ok, err = self:send(w:tostring())
      if not ok then return fail(err) end

      ch.window = ch.window - n
      if n == #op.data then
        table.remove(q, 1)
      else
        op.data = op.data:sub(n + 1)
      end

    elseif op.kind == "eof" then
      local ok, err = self:send(wire.writer():byte(msg.CHANNEL_EOF)
        :uint32(ch.peer):tostring())
      if not ok then return fail(err) end
      table.remove(q, 1)

    elseif op.kind == "exit" then
      local ok, err = self:send(wire.writer()
        :byte(msg.CHANNEL_REQUEST):uint32(ch.peer)
        :string("exit-status"):boolean(false):uint32(op.status):tostring())
      if not ok then return fail(err) end
      table.remove(q, 1)

    elseif op.kind == "close" then
      if not ch.sent_close then
        ch.sent_close = true
        local ok, err = self:send(wire.writer():byte(msg.CHANNEL_CLOSE)
          :uint32(ch.peer):tostring())
        if not ok then return fail(err) end
      end
      table.remove(q, 1)
    end

    ::continue::
  end

  return true, 0
end

-- Bytes still waiting on the peer's window. Zero means everything handed
-- to `data` is on the wire.
function S:pending(ch)
  local n = 0
  for _, op in ipairs(ch.outq or {}) do n = n + #(op.data or "") end
  return n
end

function S:data(ch, s) return enqueue(self, ch, { kind = "data", data = s }) end
function S:extended(ch, s) return enqueue(self, ch, { kind = "ext", data = s }) end
function S:eof(ch) return enqueue(self, ch, { kind = "eof" }) end
function S:exit(ch, status)
  return enqueue(self, ch, { kind = "exit", status = status or 0 })
end
function S:close(ch) return enqueue(self, ch, { kind = "close" }) end

function S:disconnect(reason)
  return self:send(wire.writer()
    :byte(msg.DISCONNECT):uint32(11)
    :string(reason or ""):string(""):tostring())
end

M.WINDOW = WINDOW
M.MAXPACKET = MAXPACKET

return M
