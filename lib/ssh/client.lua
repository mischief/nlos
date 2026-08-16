-- The client half of the protocol: banner, kex, userauth, one session
-- channel. Sans-io like everything else: `conn` supplies read(n),
-- write(s), rand(n) and readline(), the last because the banner is the
-- one part of SSH that is a line rather than a frame.

local wire = require "ssh.wire"
local msg = require "ssh.msg"
local packet = require "ssh.packet"
local kex = require "ssh.kex"
local keys = require "ssh.keys"
local ed25519 = require "crypto.ed25519"

local M = {}

M.VERSION = "SSH-2.0-luassh_0.1"

-- How many packets a peer may make us hold while we wait for one it owes
-- us. Its window bounds the channel data; this bounds the rest.
local QUEUE_MAX = 512

local C = {}
C.__index = C

function M.new(conn)
  return setmetatable({
    conn = conn,
    pkt = packet.new(conn),
    nextchan = 0,
  }, C)
end

local function fail(err) return nil, err end

--------------------------------------------------------------------------
-- transport

-- RFC 4253 4.2: the server may send any number of non-version lines
-- first. Only the line starting "SSH-" is the version, and only that line
-- goes into the exchange hash.
function C:banner()
  local ok, err = self.conn.write(M.VERSION .. "\r\n")
  if not ok then return fail(err) end

  for _ = 1, 64 do
    local line
    line, err = self.conn.readline()
    if not line then return fail(err or "eof reading server banner") end
    line = line:gsub("\r$", "")
    if line:sub(1, 4) == "SSH-" then
      if line:sub(1, 8) ~= "SSH-2.0-" and line:sub(1, 8) ~= "SSH-1.99" then
        return fail("server speaks " .. line)
      end
      -- Kept for the exchange hash, initial and rekey alike: RFC 4253
      -- 9.1 builds H from the banners, and a rekey must reuse these
      -- rather than re-read the wire.
      self.v_c, self.v_s = M.VERSION, line
      return true
    end
    if self.on_banner then self.on_banner(line) end
  end
  return fail("too many lines before the server version")
end

-- Messages a peer may send at any moment, none of which are ours to act
-- on. Returns true if it swallowed the packet.
function C:transport_msg(payload)
  local t = payload:byte(1)
  if t == msg.IGNORE or t == msg.DEBUG or t == msg.EXT_INFO
     or t == msg.UNIMPLEMENTED or t == msg.USERAUTH_BANNER then
    if t == msg.USERAUTH_BANNER and self.on_banner then
      local r = wire.reader(payload)
      r:byte()
      self.on_banner((r:string() or ""):gsub("\r?\n$", ""))
    end
    return true
  end
  if t == msg.GLOBAL_REQUEST then
    -- OpenSSH sends hostkeys-00@openssh.com right after auth. We want
    -- none of it, but a want_reply request must be answered or the
    -- server waits.
    local r = wire.reader(payload)
    r:byte()
    r:string()
    if r:boolean() then
      self.pkt:sendpkt(string.char(msg.REQUEST_FAILURE))
    end
    return true
  end
  if t == msg.DISCONNECT then
    local r = wire.reader(payload)
    r:byte()
    local code = r:uint32()
    self.disconnect = ("server disconnected (%d): %s")
      :format(code or 0, r:string() or "")
    return true
  end
  return false
end

-- Read one packet off the wire, past anything that is not the caller's
-- business: transport noise is consumed, and a KEXINIT is answered
-- rather than returned -- handing one to pump(), expect() or data()
-- leaves the server waiting for a reply while it queues all we send.
-- A KEXINIT arriving mid-exchange belongs to rekey()'s own reads, which
-- go to recvpkt. May return a packet the rekey queued on its way.
-- `fresh` says the queue has already been searched by the caller, so
-- taking from it here would hand back what that caller just declined --
-- and recv_until defers it again, which is the same packet cycling from
-- the front of the queue to the back until the cap trips.
function C:recv_wire(fresh)
  while true do
    local ok, err = self:rekey_if_owed()
    if not ok then return fail(err) end

    -- An exchange run just now queued what was in flight during it, and
    -- that queue comes before another read: the packet this caller is
    -- waiting for may be sitting in it, and nothing more need arrive.
    if not fresh and self.pending and self.pending[1] then
      return table.remove(self.pending, 1)
    end

    local payload
    payload, err = self.pkt:recvpkt()
    if not payload then return fail(err) end
    if not self:transport_msg(payload) then
      if payload:byte(1) ~= msg.KEXINIT or self.rekeying then
        return payload
      end
      local rok, rerr = self:rekey(payload)
      if not rok then return fail(rerr or "rekey failed") end
    end
    if self.disconnect then return fail(self.disconnect) end
  end
end

-- The next packet in order, queue first.
--
-- `pending` exists because the server is entitled to interleave channel
-- traffic with the reply we are waiting for -- a window adjust arrives
-- before CHANNEL_SUCCESS as a matter of course. Anything a caller is not
-- ready for is queued rather than dropped, and pump() drains it here.
function C:recv()
  if self.pending and self.pending[1] then
    return table.remove(self.pending, 1)
  end
  return self:recv_wire()
end

-- The first packet whose type is in `keep`, queueing the rest in order
-- for recv(). The queue is searched before the wire is read, so what
-- landed there while an exchange ran is answered rather than waited for
-- again. The cap is on how much a peer can make us hold while it stalls.
function C:recv_until(keep)
  for _ = 1, QUEUE_MAX do
    if self.pending then
      for i, p in ipairs(self.pending) do
        if keep[p:byte(1)] then return table.remove(self.pending, i) end
      end
    end

    local payload, err = self:recv_wire(true)
    if not payload then return fail(err) end
    if keep[payload:byte(1)] then return payload end
    self:defer(payload)
  end
  return fail("too many packets while waiting for a reply")
end

-- What recv_until is during an exchange: rekey() owns the KEXINIT it is
-- answering and must not re-enter, and the wire is the only source
-- because the queue is what this is filling.
function C:recv_kex(keep)
  for _ = 1, QUEUE_MAX do
    if self.pending then
      for i, p in ipairs(self.pending) do
        if keep[p:byte(1)] then return table.remove(self.pending, i) end
      end
    end

    local payload, err = self.pkt:recvpkt()
    if not payload then return fail(err) end
    local t = payload:byte(1)
    if keep[t] then return payload end

    -- Strict kex, the half the sequence reset does not cover: nothing may
    -- be injected into an exchange. Channel traffic still runs through,
    -- because it is not injected into the transcript -- the exchange hash
    -- covers the KEXINITs and nothing that passes between them.
    if t == msg.IGNORE or t == msg.DEBUG or t == msg.UNIMPLEMENTED
       or t == msg.EXT_INFO then
      return fail("unexpected " .. (msg.name[t] or t) .. " during key exchange")
    end

    if not self:transport_msg(payload) then self:defer(payload) end
    if self.disconnect then return fail(self.disconnect) end
  end
  return fail("too many packets during key exchange")
end

-- Rekey once the packet layer says the sequence numbers have run far
-- enough, on whichever of the two paths reaches it first. Nothing to do
-- before the first exchange, and nothing to do inside one.
function C:rekey_if_owed()
  if self.rekeying or not self.session_id then return true end
  if not self.pkt:need_rekey() then return true end
  return self:rekey(nil, true)
end

function C:send(payload)
  local ok, err = self:rekey_if_owed()
  if not ok then return fail(err) end
  return self.pkt:sendpkt(payload)
end

function C:defer(payload)
  self.pending = self.pending or {}
  self.pending[#self.pending + 1] = payload
end

-- Wait for one of `want`, queueing anything else for pump().
function C:expect(want)
  return self:recv_until(want)
end

--------------------------------------------------------------------------
-- key exchange

-- The key exchange, initial and rekey: RFC 4253 9.1, same exchange both
-- times. `i_s` is the server's KEXINIT where one is already in hand, as
-- on a server-led rekey; `lead` says whether ours goes out before
-- reading it or in reply. A rekey keeps the session_id and the banners,
-- and pins its host key against the first exchange's rather than asking
-- verify_host again. That is the whole difference between the two.
function C:rekey(i_s, lead)
  if self.rekeying then
    return fail("rekey already in progress")
  end
  self.rekeying = true

  -- No hybrid on this side yet: it needs ML-KEM KeyGen and Decaps,
  -- which a server never performs and which are therefore not written.
  local i_c = kex.kexinit(self.conn.rand, "client", { hybrid = false })

  -- Every exit clears the flag, and there are several of them, so the
  -- failures go through one place.
  local function bail(errmsg)
    self.rekeying = false
    return fail(errmsg)
  end

  local ok, err

  if lead then
    ok, err = self:send(i_c)
    if not ok then return bail(err) end
  end

  if not i_s then
    i_s, err = self:recv_kex { [msg.KEXINIT] = true }
    if not i_s then return bail(err) end
  end
  if i_s:byte(1) ~= msg.KEXINIT then
    return bail("expected KEXINIT")
  end

  if not lead then
    ok, err = self:send(i_c)
    if not ok then return bail(err) end
  end

  local opts
  opts, err = kex.check(i_s, "client", { hybrid = false })
  if not opts then return bail(err) end

  -- Strict kex is the Terrapin fix, required of the server on the
  -- initial exchange: this client has no legacy to support. A rekey
  -- cannot require it -- OpenSSH drops the flag from its rekey proposal
  -- -- so a conforming peer offers none there. The sequence reset at
  -- NEWKEYS does the Terrapin work either way, and is done below.
  if self.session_id == nil and not opts.strict then
    return bail("server does not support " .. kex.STRICT_S)
  end

  local res
  res, err = kex.client {
    sendpkt = function(p) return self:send(p) end,
    -- Channel traffic in flight at the moment of the rekey is not part
    -- of the exchange; read past it rather than failing on it. The
    -- client's one read here is for the reply.
    recvpkt = function()
      return self:recv_kex { [msg.KEX_ECDH_REPLY] = true }
    end,
    rand = self.conn.rand,
    v_c = self.v_c, v_s = self.v_s, i_c = i_c, i_s = i_s,
    session_id = self.session_id,
    verify_host = self.session_id and
      function(hk)
        -- The rekey's host key is the server signing H with the key it
        -- already is. If it differs, the connection is not the one we
        -- thought it was, and there is no prompt that fixes that.
        if hk ~= self.hostkey then
          return nil, "host key changed during rekey"
        end
        return true
      end or
      (self.verify_host or function() return true end),
  }
  if not res then return bail(err) end

  ok, err = self:send(string.char(msg.NEWKEYS))
  if not ok then return bail(err) end

  local payload
  payload, err = self:recv_kex { [msg.NEWKEYS] = true }
  if not payload then return bail(err) end
  if payload:byte(1) ~= msg.NEWKEYS then return bail("expected NEWKEYS") end

  self.pkt:setkeys(res.keys.c2s, res.keys.s2c)
  self.pkt:resetseq()                  -- strict kex
  self.session_id = self.session_id or res.session_id
  self.hostkey = res.hostkey
  self.rekeying = false

  return true
end

-- The initial exchange, as a named step: we lead.
function C:kex()
  return self:rekey(nil, true)
end

--------------------------------------------------------------------------
-- authentication

function C:service(name)
  local w = wire.writer():byte(msg.SERVICE_REQUEST):string(name)
  local ok, err = self:send(w:tostring())
  if not ok then return fail(err) end

  local payload
  payload, err = self:recv()
  if not payload then return fail(err) end
  if payload:byte(1) ~= msg.SERVICE_ACCEPT then
    return fail("service " .. name .. " refused")
  end
  return true
end

local SERVICE = "ssh-connection"
local METHOD = "publickey"
local ALG = "ssh-ed25519"

-- The request body, shared by the probe and the signed form. The
-- signature covers this with the session id in front, RFC 4252 7.
local function userauth_body(user, signed, blob)
  return wire.writer()
    :byte(msg.USERAUTH_REQUEST)
    :string(user)
    :string(SERVICE)
    :string(METHOD)
    :boolean(signed)
    :string(ALG)
    :string(blob)
    :tostring()
end

function C:auth_publickey(user, seed, pk)
  local blob = keys.blob(pk)

  -- Probe first: it costs a round trip and saves signing with a key the
  -- server will not accept.
  local ok, err = self:send(userauth_body(user, false, blob))
  if not ok then return fail(err) end

  local payload
  payload, err = self:recv()
  if not payload then return fail(err) end

  local t = payload:byte(1)
  if t == msg.USERAUTH_SUCCESS then return true end
  if t == msg.USERAUTH_FAILURE then
    local r = wire.reader(payload)
    r:byte()
    local methods = r:namelist()
    return fail(("server rejected our key; it will accept: %s")
      :format(table.concat(methods or {}, ", ")))
  end
  if t ~= msg.USERAUTH_PK_OK then
    return fail("unexpected reply to publickey probe: " ..
                (msg.name[t] or tostring(t)))
  end

  local body = userauth_body(user, true, blob)
  local tosign = wire.writer():string(self.session_id):raw(body):tostring()
  local sig = ed25519.sign(seed, tosign)
  local sigblob = wire.writer():string(ALG):string(sig):tostring()

  ok, err = self:send(body .. wire.writer():string(sigblob):tostring())
  if not ok then return fail(err) end

  payload, err = self:recv()
  if not payload then return fail(err) end
  if payload:byte(1) == msg.USERAUTH_SUCCESS then return true end
  if payload:byte(1) == msg.USERAUTH_FAILURE then
    return fail("authentication failed")
  end
  return fail("unexpected reply to publickey: " ..
              (msg.name[payload:byte(1)] or tostring(payload:byte(1))))
end

--------------------------------------------------------------------------
-- one session channel

local WINDOW = 2 * 1024 * 1024
local MAXPACKET = 32768

function C:session()
  local id = self.nextchan
  self.nextchan = id + 1

  local w = wire.writer()
    :byte(msg.CHANNEL_OPEN):string("session")
    :uint32(id):uint32(WINDOW):uint32(MAXPACKET)
  local ok, err = self:send(w:tostring())
  if not ok then return fail(err) end

  local payload
  payload, err = self:expect { [msg.CHANNEL_OPEN_CONFIRMATION] = true,
                               [msg.CHANNEL_OPEN_FAILURE] = true }
  if not payload then return fail(err) end

  local r = wire.reader(payload)
  local t = r:byte()
  if t == msg.CHANNEL_OPEN_FAILURE then
    r:uint32()
    local code = r:uint32()
    return fail(("channel open failed (%d): %s")
      :format(code or 0, r:string() or ""))
  end
  if t ~= msg.CHANNEL_OPEN_CONFIRMATION then
    return fail("unexpected reply to channel open")
  end

  r:uint32()                                   -- our id, echoed
  local peer = r:uint32()
  local window = r:uint32()
  local maxpacket = r:uint32()

  return {
    id = id, peer = peer,
    window = window, maxpacket = maxpacket,
    ourwindow = WINDOW,
  }
end

function C:exec(ch, command)
  local w = wire.writer()
    :byte(msg.CHANNEL_REQUEST):uint32(ch.peer)
    :string("exec"):boolean(true):string(command)
  local ok, err = self:send(w:tostring())
  if not ok then return fail(err) end

  local payload
  payload, err = self:expect { [msg.CHANNEL_SUCCESS] = true,
                               [msg.CHANNEL_FAILURE] = true }
  if not payload then return fail(err) end
  if payload:byte(1) == msg.CHANNEL_FAILURE then return fail("exec refused") end
  return true
end

-- A terminal on the channel, before the shell is started: the server
-- lays out its output against these, and a program there asks for them
-- by ioctl. The modes string is empty, which RFC 4254 8 allows and
-- means "whatever you have" -- speeds and special characters are the
-- serial line's business and there is no serial line here.
function C:pty(ch, cols, rows, term)
  local w = wire.writer()
    :byte(msg.CHANNEL_REQUEST):uint32(ch.peer)
    :string("pty-req"):boolean(true)
    :string(term or "vt100")
    :uint32(cols or 80):uint32(rows or 24)
    :uint32(0):uint32(0)                  -- pixels: unknown, and unused
    :string("")
  local ok, err = self:send(w:tostring())
  if not ok then return fail(err) end

  local payload
  payload, err = self:expect { [msg.CHANNEL_SUCCESS] = true,
                               [msg.CHANNEL_FAILURE] = true }
  if not payload then return fail(err) end
  if payload:byte(1) == msg.CHANNEL_FAILURE then
    return fail("pty refused")
  end
  return true
end

-- The user's login shell, rather than one command. What `ssh host` with
-- no arguments asks for.
function C:shell(ch)
  local w = wire.writer()
    :byte(msg.CHANNEL_REQUEST):uint32(ch.peer)
    :string("shell"):boolean(true)
  local ok, err = self:send(w:tostring())
  if not ok then return fail(err) end

  local payload
  payload, err = self:expect { [msg.CHANNEL_SUCCESS] = true,
                               [msg.CHANNEL_FAILURE] = true }
  if not payload then return fail(err) end
  if payload:byte(1) == msg.CHANNEL_FAILURE then
    return fail("shell refused")
  end
  return true
end

-- Tell the server the terminal changed size. No reply is asked for:
-- RFC 4254 6.7 says window-change never carries one.
function C:winch(ch, cols, rows)
  return self:send(wire.writer()
    :byte(msg.CHANNEL_REQUEST):uint32(ch.peer)
    :string("window-change"):boolean(false)
    :uint32(cols):uint32(rows):uint32(0):uint32(0):tostring())
end

-- Send on a channel, respecting both the peer's window and its maximum
-- packet. A subsystem -- 9P, sftp -- is bidirectional, so this is not
-- optional the way it is for a bare exec.
function C:data(ch, data)
  local off = 1
  while off <= #data do
    while ch.window <= 0 do
      -- Out of window: the only thing that can grant more is the peer, so
      -- read until it does.
      local payload, err = self:recv_until { [msg.CHANNEL_WINDOW_ADJUST] = true }
      if not payload then return fail(err) end
      local r = wire.reader(payload)
      r:byte(); r:uint32()
      ch.window = ch.window + (r:uint32() or 0)
    end

    local n = math.min(#data - off + 1, ch.maxpacket, ch.window)
    local w = wire.writer():byte(msg.CHANNEL_DATA):uint32(ch.peer)
                           :string(data:sub(off, off + n - 1))
    local ok, err = self:send(w:tostring())
    if not ok then return fail(err) end

    ch.window = ch.window - n
    off = off + n
  end
  return true
end

function C:eof(ch)
  return self:send(wire.writer():byte(msg.CHANNEL_EOF)
                                :uint32(ch.peer):tostring())
end

-- Ask for a subsystem rather than a command: this is where 9P attaches.
function C:subsystem(ch, name)
  local w = wire.writer()
    :byte(msg.CHANNEL_REQUEST):uint32(ch.peer)
    :string("subsystem"):boolean(true):string(name)
  local ok, err = self:send(w:tostring())
  if not ok then return fail(err) end

  local payload
  payload, err = self:expect { [msg.CHANNEL_SUCCESS] = true,
                               [msg.CHANNEL_FAILURE] = true }
  if not payload then return fail(err) end
  if payload:byte(1) == msg.CHANNEL_FAILURE then
    return fail("subsystem " .. name .. " refused")
  end
  return true
end

-- Pump the channel until the far end closes. `out(data, stream)` is called
-- with "stdout" or "stderr". Returns the exit status.
function C:pump(ch, out)
  local status = 0

  while true do
    local payload, err = self:recv()
    if not payload then
      -- A clean close is a close packet, not an EOF. Anything else is a
      -- truncated session and must not look like success.
      if ch.closed then return status end
      return fail(err)
    end

    local r = wire.reader(payload)
    local t = r:byte()

    if t == msg.CHANNEL_DATA then
      r:uint32()
      local data = r:string() or ""
      out(data, "stdout")
      ch.ourwindow = ch.ourwindow - #data
    elseif t == msg.CHANNEL_EXTENDED_DATA then
      r:uint32()
      local which = r:uint32()
      local data = r:string() or ""
      out(data, which == 1 and "stderr" or "stdout")
      ch.ourwindow = ch.ourwindow - #data
    elseif t == msg.CHANNEL_WINDOW_ADJUST then
      r:uint32()
      ch.window = ch.window + (r:uint32() or 0)
    elseif t == msg.CHANNEL_REQUEST then
      r:uint32()
      local what = r:string()
      local want_reply = r:boolean()
      if what == "exit-status" then
        status = r:uint32() or 0
      elseif what == "exit-signal" then
        status = 128
      end
      if want_reply then
        self:send(wire.writer():byte(msg.CHANNEL_FAILURE)
                               :uint32(ch.peer):tostring())
      end
    elseif t == msg.CHANNEL_EOF then
      ch.eof = true
    elseif t == msg.CHANNEL_CLOSE then
      ch.closed = true
      self:send(wire.writer():byte(msg.CHANNEL_CLOSE)
                             :uint32(ch.peer):tostring())
      return status
    end

    -- Give the window back before it runs out, or the server stops
    -- talking and both ends wait forever.
    if ch.ourwindow < WINDOW // 2 then
      local add = WINDOW - ch.ourwindow
      self:send(wire.writer():byte(msg.CHANNEL_WINDOW_ADJUST)
                             :uint32(ch.peer):uint32(add):tostring())
      ch.ourwindow = WINDOW
    end
  end
end

function C:disconnect_now(reason)
  self:send(wire.writer()
    :byte(msg.DISCONNECT):uint32(11)      -- BY_APPLICATION
    :string(reason or ""):string(""):tostring())
end

return M
