-- A TLS 1.3 client connection over a byte stream, sans-io.
--
-- tls/client.lua produces the handshake messages and the traffic
-- secrets. tls/record.lua protects one record. This file holds the two
-- together: it buffers a partial record, it decides which key opens
-- what, and it says which bytes the caller must send. The caller owns
-- the socket.
--
--   local c = conn.new { rand = rand, server_name = "example.com",
--                        insecure = true }
--   send(c:start())
--   -- for each chunk that arrives:
--   local out, err = c:recv(chunk)
--   if out ~= "" then send(out) end
--   local data = c:read()          -- application data, "" if none
--   send(c:write("GET / HTTP/1.0\r\n\r\n"))
--
-- One cipher suite, one group, no resumption and no 0-RTT. A
-- NewSessionTicket goes to the caller's `on_ticket` and is dropped
-- without one. A KeyUpdate is answered, and `key_update` sends one.
--
-- Three fields say how the connection ended. `sent_close` is our
-- close_notify and `peer_closed` is theirs; the two directions are
-- independent, and `closed` is either of them. `error` is the first
-- failure, and it is final: every later call reports it again. A
-- failure the peer is owed an alert for also sets `alert`, which is a
-- record to send before the socket goes.
--
-- The connection is not authenticated unless the caller supplies
-- `verify`; see tls/client.lua.

local client = require "tls.client"
local record = require "tls.record"
local wire = require "tls.wire"
local hello = require "tls.hello"

local M = {}

local schar = string.char

local NEW_SESSION_TICKET = 4
local KEY_UPDATE = 24

local CERTIFICATE_REQUEST = 13

local ALERT_WARNING = 1
local ALERT_FATAL = 2

local ALERT_CLOSE_NOTIFY = 0
local ALERT_UNEXPECTED_MESSAGE = 10
local ALERT_BAD_RECORD_MAC = 20
local ALERT_RECORD_OVERFLOW = 22
local ALERT_ILLEGAL_PARAMETER = 47
local ALERT_USER_CANCELED = 90

-- A server's flight is a certificate chain and little else, so the cap
-- is tens of kilobytes rather than a record limit. It exists because a
-- peer can otherwise stream handshake bytes that never complete a
-- flight, and every byte of them is buffered.
local MAX_HANDSHAKE = 65536

local C = {}
C.__index = C

-- new{ rand, server_name, alpn, verify, insecure, on_ticket }
--
-- on_ticket(body) is called for each NewSessionTicket, with the message
-- body as it arrived. Without it a ticket is dropped: nothing here
-- resumes a connection, so a ticket is only worth what a caller can do
-- with it.
function M.new(opts)
  return setmetatable({
    tls = client.new {
      rand = assert(opts.rand, "tls: needs rand"),
      server_name = opts.server_name,
      alpn = opts.alpn,
      verify = opts.verify,
      insecure = opts.insecure,
    },
    on_ticket = opts.on_ticket,
    inbuf = "",                         -- record bytes, not yet whole
    hsbuf = "",                         -- handshake bytes, not yet whole
    inbox = {},                         -- plaintext for the caller
    state = "start",
    sent_close = false,                 -- our close_notify
    peer_closed = false,                -- theirs
    closed = false,                     -- either of the two
  }, C)
end

-- A connection that has failed stays failed. Every later call reports
-- the first reason rather than working on a state machine the peer has
-- already broken.
--
-- `desc` is the alert the peer is owed, and `alert` holds the record
-- that carries it until the caller sends it. A failure before any key
-- exists has no record to put it in and is silent, which is what a
-- transport-level close looks like to the peer.
function C:fail(reason, desc)
  if self.error then return nil, self.error end
  self.error = reason
  self.closed = true
  if desc and self.tx then
    self.alert = self.tx:seal(record.ALERT, schar(ALERT_FATAL, desc)) or ""
  end
  return nil, self.error
end

-- The ClientHello.
function C:start()
  local ch = self.tls:client_hello()
  self.state = "wait_server_hello"
  return record.plain(record.HANDSHAKE, ch)
end

function C:read()
  if #self.inbox == 0 then return "" end
  local s = table.concat(self.inbox)
  self.inbox = {}
  return s
end

-- write(data) -> the records to send. Data longer than one record is
-- split; RFC 8446 5.1 gives the limit.
function C:write(data)
  if self.error then return nil, self.error end
  -- RFC 8446 6.1: a close_notify ends this side's write side.
  if self.sent_close then return nil, "tls: the write side is closed" end
  if not self.tx or self.state ~= "established" then
    return nil, "tls: connection is not established"
  end
  local out, off = {}, 1
  repeat
    local chunk = data:sub(off, off + record.MAX_PLAINTEXT - 1)
    local rec = self.tx:seal(record.APPLICATION_DATA, chunk)
    -- A key that has sealed every record it may needs a KeyUpdate, and
    -- that is the caller's to send: sending it here would change the
    -- key under a caller that has not asked.
    if not rec then return self:fail "tls: the write key is exhausted" end
    out[#out + 1] = rec
    off = off + record.MAX_PLAINTEXT
  until off > #data
  return table.concat(out)
end

-- key_update(request_peer) -> the KeyUpdate record to send.
--
-- RFC 8446 4.6.3. The write key changes immediately after the message,
-- so the message itself travels under the old one. `request_peer` asks
-- the peer to change its own key as well; the read key changes when
-- its answer arrives, not here.
function C:key_update(request_peer)
  if self.error then return nil, self.error end
  if self.state ~= "established" then
    return nil, "tls: connection is not established"
  end

  local body = request_peer and "\1" or "\0"
  local rec = self.tx:seal(record.HANDSHAKE, wire.handshake(KEY_UPDATE, body))
  if not rec then return self:fail "tls: the write key is exhausted" end
  self.tx = self.tx:update()
  return rec
end

-- close() -> a close_notify alert. The caller then shuts the socket.
--
-- This closes the write side only. The read side stays open, so a peer
-- that is still sending is still read: RFC 8446 6.1 makes the two
-- directions independent.
function C:close()
  if self.sent_close or self.error or not self.tx then return "" end
  self.sent_close = true
  self.closed = true
  return self.tx:seal(record.ALERT,
                      schar(ALERT_WARNING, ALERT_CLOSE_NOTIFY)) or ""
end

-- The offset one past the Finished message, or nil while the server's
-- flight is incomplete.
local function flight_end(buf)
  local off = 1
  while off <= #buf do
    local m, next_off = wire.read_handshake(buf, off)
    if not m then return nil end
    if m.type == hello.FINISHED then return next_off end
    off = next_off
  end
  return nil
end

function C:handshake_flight()
  local stop = flight_end(self.hsbuf)
  if not stop then return "" end

  local fin, err = self.tls:server_flight(self.hsbuf:sub(1, stop - 1))
  if not fin then return self:fail(err, ALERT_ILLEGAL_PARAMETER) end
  self.hsbuf = self.hsbuf:sub(stop)

  -- The dummy ChangeCipherSpec goes immediately before this flight and
  -- nowhere else, since no early data is offered (RFC 8446 D.4). The
  -- client's Finished then goes under the handshake key. Both
  -- directions move to the application keys after it.
  local out = record.plain(record.CHANGE_CIPHER_SPEC, "\1") ..
              record.new(self.tls.c_hs):seal(record.HANDSHAKE, fin)
  self.rx = record.new(self.tls.s_ap)
  self.tx = record.new(self.tls.c_ap)
  self.state = "established"
  self.alpn = self.tls.selected_alpn
  return out
end

-- A handshake message that arrives after the handshake, RFC 8446 4.6.
function C:post_handshake()
  local out = {}
  while true do
    local m, next_off = wire.read_handshake(self.hsbuf)
    if not m then break end
    self.hsbuf = self.hsbuf:sub(next_off)

    if m.type == KEY_UPDATE then
      self.rx = self.rx:update()
      -- update_requested is 1. The answer updates our own key and asks
      -- for nothing in return, so it cannot start a loop.
      if m.body:byte(1) == 1 then
        local rec = self.tx:seal(record.HANDSHAKE,
                                 wire.handshake(KEY_UPDATE, "\0"))
        if not rec then return self:fail "tls: the write key is exhausted" end
        out[#out + 1] = rec
        self.tx = self.tx:update()
      end
    elseif m.type == NEW_SESSION_TICKET then
      if self.on_ticket then self.on_ticket(m.body) end
    elseif m.type == CERTIFICATE_REQUEST then
      -- RFC 8446 4.6.2: post-handshake authentication is only for a
      -- client that offered the extension, and this one does not.
      return self:fail("tls: post-handshake authentication was not offered",
                       ALERT_UNEXPECTED_MESSAGE)
    else
      return self:fail(("tls: unexpected handshake message %d")
        :format(m.type), ALERT_UNEXPECTED_MESSAGE)
    end
  end
  return table.concat(out)
end

function C:handle(ctype, body)
  if ctype == record.ALERT then
    local level, desc = body:byte(1, 2)
    -- RFC 8446 6.1. close_notify ends the peer's write side, and
    -- everything after it is ignored. user_canceled is advisory and a
    -- close_notify follows it.
    if desc == ALERT_CLOSE_NOTIFY then
      self.peer_closed = true
      self.closed = true
      return ""
    end
    if desc == ALERT_USER_CANCELED then return "" end
    return self:fail(("tls: alert %d, level %d")
      :format(desc or -1, level or -1))
  elseif ctype == record.APPLICATION_DATA then
    if self.state ~= "established" then
      return self:fail("tls: application data before the handshake finished",
                       ALERT_UNEXPECTED_MESSAGE)
    end
    self.inbox[#self.inbox + 1] = body
    return ""
  elseif ctype == record.HANDSHAKE then
    if #self.hsbuf + #body > MAX_HANDSHAKE then
      return self:fail("tls: handshake flight too long",
                       ALERT_RECORD_OVERFLOW)
    end
    self.hsbuf = self.hsbuf .. body
    if self.state == "established" then return self:post_handshake() end
    return self:handshake_flight()
  end
  return self:fail(("tls: unexpected content type %d"):format(ctype),
                   ALERT_UNEXPECTED_MESSAGE)
end

-- The dummy ChangeCipherSpec, dropped without further processing. It
-- is a record of the handshake and has no meaning after it.
function C:change_cipher_spec(body)
  if body ~= "\1" then
    return self:fail("tls: a ChangeCipherSpec that is not the dummy one",
                     ALERT_UNEXPECTED_MESSAGE)
  end
  if self.state == "established" then
    return self:fail("tls: a ChangeCipherSpec after the handshake",
                     ALERT_UNEXPECTED_MESSAGE)
  end
  return ""
end

-- One record, still in the clear: the ServerHello, or a
-- ChangeCipherSpec to ignore.
function C:plaintext_record(ctype, body)
  if ctype == record.CHANGE_CIPHER_SPEC then
    return self:change_cipher_spec(body)
  end
  if ctype == record.ALERT then return self:handle(ctype, body) end
  if ctype ~= record.HANDSHAKE then
    return self:fail(("tls: unexpected content type %d"):format(ctype),
                     ALERT_UNEXPECTED_MESSAGE)
  end

  local ok, err = self.tls:server_hello(body)
  if not ok then return self:fail(err, ALERT_ILLEGAL_PARAMETER) end
  self.rx = record.new(self.tls.s_hs)
  self.state = "wait_server_flight"
  return ""
end

-- recv(bytes) -> the bytes to send in reply, or nil and a reason.
function C:recv(bytes)
  if self.error then return nil, self.error end
  -- RFC 8446 6.1: data after the peer's close_notify is ignored.
  if self.peer_closed then return "" end
  self.inbuf = self.inbuf .. bytes
  local out = {}

  while #self.inbuf >= record.HEADER_LEN and not self.peer_closed do
    local ctype, len = record.parse_header(self.inbuf)
    if len > record.MAX_CIPHERTEXT then
      return self:fail("tls: record too long", ALERT_RECORD_OVERFLOW)
    end
    if #self.inbuf < record.HEADER_LEN + len then break end

    local head = self.inbuf:sub(1, record.HEADER_LEN)
    local body = self.inbuf:sub(record.HEADER_LEN + 1, record.HEADER_LEN + len)
    self.inbuf = self.inbuf:sub(record.HEADER_LEN + len + 1)

    local piece, err
    if not self.rx then
      piece, err = self:plaintext_record(ctype, body)
    elseif ctype == record.CHANGE_CIPHER_SPEC then
      -- The peer's half of compatibility mode, and the one record that
      -- stays in the clear after keys exist. RFC 8446 5 allows it only
      -- until the peer's Finished, only unprotected, and only with the
      -- value 0x01; anything else is an unexpected record.
      piece, err = self:change_cipher_spec(body)
    else
      local plain, inner = self.rx:open(head, body)
      if not plain then
        return self:fail("tls: record does not open", ALERT_BAD_RECORD_MAC)
      end
      piece, err = self:handle(inner, plain)
    end

    if not piece then return nil, err end          -- already latched
    out[#out + 1] = piece
  end

  return table.concat(out)
end

return M
