-- The SSH binary packet protocol, RFC 4253 section 6, with exactly one
-- cipher: chacha20-poly1305@openssh.com.
--
-- Sans-io: a connection is a pair of closures, `read(n)` returning
-- exactly n bytes or nil, and `write(s)`. Randomness arrives the same
-- way, as `rand(n)`. Nothing here knows what a socket is, which is what
-- lets the same code run over TCP, over a serial line, and over a pipe in
-- a test.
--
-- The cipher's shape, from OpenSSH's PROTOCOL.chacha20poly1305:
--
--   * 512 bits of key material become two ChaCha20 keys. The FIRST 256
--     bits are K_2, which encrypts the payload; the SECOND are K_1, which
--     encrypts the 4-byte length on its own. Getting that order backwards
--     is the classic way to fail this handshake.
--   * The nonce is the packet sequence number, big-endian, in the low 8
--     bytes -- OpenSSH uses original-ChaCha's 64-bit IV, which in RFC 8439
--     layout is four zero bytes followed by the sequence number.
--   * Block 0 of K_2 yields the Poly1305 key; the payload starts at block
--     1. The tag covers the encrypted length and the encrypted payload.
--   * The length field is authenticated but not part of the padded
--     region, so padding is computed over the padding byte and payload
--     alone.

local chacha20 = require "crypto.chacha20"
local poly1305 = require "crypto.poly1305"
local util = require "crypto.util"

local M = {}

local spack, sunpack = string.pack, string.unpack

-- RFC 4253 6.1 allows 35000 bytes of payload; anything beyond that is a
-- peer trying to make us allocate.
local MAX_PACKET = 35000
local BLOCK = 8

local P = {}
P.__index = P

function M.new(conn)
  return setmetatable({
    read = assert(conn.read, "packet: need read"),
    write = assert(conn.write, "packet: need write"),
    rand = assert(conn.rand, "packet: need rand"),
    trace = conn.trace,
    send_seq = 0,
    recv_seq = 0,
  }, P)
end

-- Install keys: 64 bytes in each direction, named by which way they run
-- rather than by role, so the two ends pass the same pair swapped.
function P:setkeys(outkey, inkey)
  self.out_k2 = outkey:sub(1, 32)
  self.out_k1 = outkey:sub(33, 64)
  self.in_k2 = inkey:sub(1, 32)
  self.in_k1 = inkey:sub(33, 64)
end

-- Strict kex (kex-strict-*-v00@openssh.com): the sequence numbers reset
-- at NEWKEYS. This is the Terrapin fix and the reason a prefix of
-- injected packets cannot shift the transcript.
function P:resetseq()
  self.send_seq, self.recv_seq = 0, 0
end

local function nonce(seq)
  return "\0\0\0\0" .. spack(">I8", seq)
end

function P:sendpkt(payload)
  local padlen = BLOCK - ((1 + #payload) % BLOCK)
  if self.out_k2 == nil then
    -- Unencrypted, the length field counts toward the padded region.
    padlen = BLOCK - ((5 + #payload) % BLOCK)
  end
  if padlen < 4 then padlen = padlen + BLOCK end

  local plain = spack(">B", padlen) .. payload .. self.rand(padlen)
  local out

  if self.out_k2 == nil then
    out = spack(">I4", #plain) .. plain
  else
    local n = nonce(self.send_seq)
    local enclen = chacha20.xor(self.out_k1, 0, n, spack(">I4", #plain))
    local ct = chacha20.xor(self.out_k2, 1, n, plain)
    local polykey = chacha20.block(self.out_k2, 0, n):sub(1, 32)
    out = enclen .. ct .. poly1305.auth(polykey, enclen .. ct)
  end

  self.send_seq = (self.send_seq + 1) & 0xffffffff
  if self.trace then self.trace("send", payload:byte(1), #payload) end
  return self.write(out)
end

function P:recvpkt()
  local n = nonce(self.recv_seq)

  local enclen, err = self.read(4)
  if not enclen then return nil, err or "eof" end

  local len
  if self.in_k2 == nil then
    len = sunpack(">I4", enclen)
  else
    len = sunpack(">I4", chacha20.xor(self.in_k1, 0, n, enclen))
  end

  -- Bound the length before reading it, not after. The padded region
  -- includes the 4-byte length field when there is no cipher and excludes
  -- it when the cipher is this AEAD, so the two cases round differently.
  -- Written as an if rather than `a and b or c`: with the cipher
  -- installed and the length misaligned, that idiom falls through to the
  -- third arm and applies the unencrypted rule, so len % 8 == 4 was
  -- accepted too. The AEAD tag still had to verify, so nothing could be
  -- forged through it, but the check was not the one described.
  local aligned
  if self.in_k2 then
    aligned = len % BLOCK == 0
  else
    aligned = (len + 4) % BLOCK == 0
  end
  if len < 8 or len > MAX_PACKET or not aligned then
    return nil, ("bad packet length %d"):format(len)
  end

  local body
  body, err = self.read(len + (self.in_k2 and 16 or 0))
  if not body then return nil, err or "eof" end

  local plain
  if self.in_k2 == nil then
    plain = body
  else
    local ct, tag = body:sub(1, len), body:sub(len + 1)
    local polykey = chacha20.block(self.in_k2, 0, n):sub(1, 32)
    if not util.ct_eq(tag, poly1305.auth(polykey, enclen .. ct)) then
      return nil, "packet authentication failed"
    end
    plain = chacha20.xor(self.in_k2, 1, n, ct)
  end

  local padlen = plain:byte(1)
  if padlen < 4 or padlen > len - 1 then return nil, "bad padding" end

  self.recv_seq = (self.recv_seq + 1) & 0xffffffff

  local payload = plain:sub(2, len - padlen)
  if self.trace then self.trace("recv", payload:byte(1), #payload) end
  return payload
end

M.MAX_PACKET = MAX_PACKET

return M
