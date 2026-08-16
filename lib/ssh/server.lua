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

-- How many packets a peer may make us hold while we wait for one it owes
-- us. Its window bounds the channel data; this bounds the rest.
local QUEUE_MAX = 512

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
    -- Channel traffic that arrives on the wire while a rekey is waiting
    -- for its half of the exchange. recv() drains it next, so the
    -- embedder's loop sees no gap in the stream.
    kexqueue = {},
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

  -- Kept for the exchange hash, initial and rekey alike: RFC 4253 9.1
  -- builds H from the banners, and a rekey must reuse these rather than
  -- re-read the wire.
  self.v_c, self.v_s = line, M.VERSION
  return true
end

function S:transport_msg(payload)
  local t = payload:byte(1)
  if t == msg.IGNORE or t == msg.DEBUG or t == msg.UNIMPLEMENTED
     or t == msg.EXT_INFO then
    -- Not during the initial exchange. Strict kex requires that anything
    -- unexpected there ends the connection, and these are precisely the
    -- messages a peer is otherwise free to insert at any point -- which
    -- is what Terrapin used to move the sequence number. Resetting the
    -- counters at NEWKEYS is the half of the countermeasure that does
    -- the work, and it is done; refusing the injection outright is the
    -- other half, and without it the two ends can still be made to
    -- disagree about how many packets went by.
    if self.inkex then
      return true, "unexpected " .. (msg.name[t] or t) .. " during key exchange"
    end
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
  -- Packets a rekey queued on its way through come out here first, in
  -- order: the embedder's loop sees no gap in the stream.
  if self.kexqueue[1] then
    return table.remove(self.kexqueue, 1)
  end

  while true do
    local payload, err = self.pkt:recvpkt()
    if not payload then return fail(err) end

    local handled, reject = self:transport_msg(payload)
    if reject then return fail(reject) end
    if not handled then return payload end
    if self.closed then return fail(self.closed) end
  end
end

--------------------------------------------------------------------------
-- key exchange

-- The first packet whose type is in `keep`. The rest is queued in order
-- for recv(): a peer may keep sending channel data until it processes
-- the exchange, and none of that is part of the exchange hash. The
-- queue is read before the wire, so a KEXINIT that landed there when
-- both ends opened a rekey at once is answered rather than waited for
-- again. The cap bounds what a stalling peer can make us hold.
function S:recv_until(keep)
  for _ = 1, QUEUE_MAX do
    for i, p in ipairs(self.kexqueue) do
      if keep[p:byte(1)] then return table.remove(self.kexqueue, i) end
    end

    local payload, err = self.pkt:recvpkt()
    if not payload then return nil, err end
    if keep[payload:byte(1)] then return payload end

    local handled, reject = self:transport_msg(payload)
    if reject then return nil, reject end
    if handled then
      if self.closed then return nil, self.closed end
    else
      self.kexqueue[#self.kexqueue + 1] = payload
    end
  end
  return nil, "too many packets during key exchange"
end

-- True once the packet layer has run far enough that the sequence
-- numbers must be reset. See ssh.packet need_rekey.
function S:need_rekey()
  return self.session_id ~= nil and not self.rekeying and self.pkt:need_rekey()
end

-- Run the owed exchange, leading it. Nothing to do before the first one.
function S:rekey_if_owed()
  if not self:need_rekey() then return true end
  return self:kex(nil, true)
end

-- The key exchange, initial and rekey. Same exchange both times, RFC
-- 4253 9.1: both KEXINITs go into the hash along with the banners
-- banner() parked in v_c and v_s, the ECDH roles follow the role rather
-- than the initiator, and the session_id stays what it was. `i_c` is the
-- client's KEXINIT when one is in hand already; `lead` says whether ours
-- goes out before reading it or in reply to it.
function S:kex(i_c, lead)
  if self.rekeying then
    return fail("rekey already in progress")
  end
  self.rekeying = true

  -- Set for the whole of the exchange, and cleared once NEWKEYS has
  -- been seen in both directions: see transport_msg for what it
  -- changes and why the window is exactly this one.
  self.inkex = true

  -- The hybrid is on unless the embedder turns it off. A server can do
  -- ML-KEM with encapsulation alone, which is the cheap half.
  local opts = { hybrid = self.conf.hybrid ~= false }
  local i_s = kex.kexinit(self.conn.rand, "server", opts)

  -- Every exit clears both flags, and there are several of them, so the
  -- failures go through one place.
  local function bail(errmsg)
    self.inkex = false
    self.rekeying = false
    return fail(errmsg)
  end

  local ok, err

  if lead then
    ok, err = self:send(i_s)
    if not ok then return bail(err) end
  end

  if not i_c then
    i_c, err = self:recv_until { [msg.KEXINIT] = true }
    if not i_c then return bail(err) end
  end

  if i_c:byte(1) ~= msg.KEXINIT then
    return bail("expected KEXINIT")
  end

  if not lead then
    ok, err = self:send(i_s)
    if not ok then return bail(err) end
  end

  -- No `local` here: this must be the offer built above, not a fresh
  -- nil. Shadowing it means check() is told we support nothing.
  opts, err = kex.check(i_c, "server", opts)
  if not opts then return bail(err) end

  -- Strict kex is required of the initial exchange: a client without it
  -- has no legacy to support, so refuse rather than negotiating down to
  -- the framing Terrapin broke. A rekey cannot require it -- OpenSSH
  -- drops the flag from its rekey proposal (kex.c, kex_input_newkeys) --
  -- so a conforming peer offers no strict flag there. The sequence reset
  -- at NEWKEYS applies to the rekey either way, and is done below.
  if self.session_id == nil and not opts.strict then
    return bail("client does not support " .. kex.STRICT_C)
  end

  local res
  res, err = kex.server {
    sendpkt = function(p) return self:send(p) end,
    -- Channel traffic in flight at the moment of the rekey is not part
    -- of the exchange; read past it rather than failing on it.
    recvpkt = function()
      return self:recv_until { [msg.KEX_ECDH_INIT] = true }
    end,
    rand = self.conn.rand,
    v_c = self.v_c, v_s = self.v_s, i_c = i_c, i_s = i_s,
    hybrid = opts.hybrid,
    hostkey_seed = self.hostkey_seed,
    hostkey_pub = self.hostkey_pub,
    session_id = self.session_id,
  }
  if not res then return bail(err) end

  ok, err = self:send(string.char(msg.NEWKEYS))
  if not ok then return bail(err) end

  local payload
  payload, err = self:recv_until { [msg.NEWKEYS] = true }
  if not payload then return bail(err) end
  if payload:byte(1) ~= msg.NEWKEYS then
    return bail("expected NEWKEYS")
  end

  -- The server's outgoing direction is server-to-client; the same pair,
  -- swapped relative to the client.
  self.pkt:setkeys(res.keys.s2c, res.keys.c2s)
  self.pkt:resetseq()
  self.session_id = self.session_id or res.session_id
  self.inkex = false
  self.rekeying = false

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
  ok, err = self:kex(nil, true)
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
  -- The read path is the only one that may block, so it is where an owed
  -- rekey is run. An embedder that writes for a long time without coming
  -- back here should ask need_rekey() itself.
  local ok, kerr = self:rekey_if_owed()
  if not ok then
    self:disconnect("rekey failed")
    return fail(kerr)
  end

  local payload, err = self:recv()
  if not payload then
    if self.closed then return nil, nil end
    return fail(err)
  end

  local r = wire.reader(payload)
  local t = r:byte()

  -- A peer asking to rekey, RFC 4253 9.1: it sent its KEXINIT and waits
  -- for ours, so answer with the exchange and swallow the packet.
  -- Anything arriving inside that exchange which is not part of it is
  -- refused by transport_msg, as in the initial one. A KEXINIT reaching
  -- here while we are already mid-exchange belongs to the read inside
  -- kex, and passes through rather than re-entering.
  if t == msg.KEXINIT then
    -- No re-key re-entry check here: kex() has one, and it fails loudly
    -- rather than the way a falsy return would, which events() reads as
    -- a clean end of session.
    local ok, err = self:kex(payload, false)
    if not ok then
      self:disconnect("rekey failed")
      return nil, err or "rekey failed"
    end
    -- An event rather than a bare true: the caller of step() indexes
    -- the result, and an embedder may want to know a rekey happened.
    return { type = "rekey" }
  end

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

    elseif what == "window-change" then
      -- RFC 4254 6.7, and it never wants a reply. A session that only
      -- reads the size at pty-req lays out its next screen against the
      -- window the client had when it connected.
      local cols, rows = r:uint32(), r:uint32()

      return { type = "winch", chan = ch, cols = cols, rows = rows }

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
