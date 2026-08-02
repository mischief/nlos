-- SSH's wire types, RFC 4251 section 5.
--
-- A writer is a list of chunks; a reader is a string and an offset. Both
-- are deliberately dumb. The one type with a rule worth stating is mpint:
-- two's complement, big-endian, no leading zero bytes except the one that
-- keeps a positive number from looking negative, and empty for zero.

local M = {}

local spack, sunpack = string.pack, string.unpack

--------------------------------------------------------------------------
-- writer

local W = {}
W.__index = W

function M.writer()
  return setmetatable({ n = 0 }, W)
end

function W:raw(s) self.n = self.n + 1; self[self.n] = s; return self end
function W:byte(b) return self:raw(spack(">B", b)) end
function W:boolean(b) return self:raw(b and "\1" or "\0") end
function W:uint32(u) return self:raw(spack(">I4", u)) end
function W:uint64(u) return self:raw(spack(">I8", u)) end
function W:string(s) return self:raw(spack(">s4", s)) end
function W:namelist(t)
  return self:string(type(t) == "table" and table.concat(t, ",") or t)
end

-- A 32-byte little-endian scalar (the X25519 shared secret) as an mpint.
function W:mpint(s)
  s = s:gsub("^\0+", "")
  if s == "" then return self:string "" end
  if s:byte(1) >= 0x80 then s = "\0" .. s end
  return self:string(s)
end

function W:tostring() return table.concat(self, "", 1, self.n) end

--------------------------------------------------------------------------
-- reader
--
-- Every read is bounds-checked and returns nil plus a reason rather than
-- raising: this parses data an unauthenticated peer chose.

local R = {}
R.__index = R

function M.reader(s)
  return setmetatable({ s = s, pos = 1 }, R)
end

function R:remaining() return #self.s - self.pos + 1 end

function R:raw(n)
  if n < 0 or self:remaining() < n then return nil, "short read" end
  local out = self.s:sub(self.pos, self.pos + n - 1)
  self.pos = self.pos + n
  return out
end

function R:byte()
  local s = self:raw(1)
  if not s then return nil, "short read" end
  return s:byte()
end

function R:boolean()
  local b = self:byte()
  if not b then return nil, "short read" end
  return b ~= 0
end

function R:uint32()
  local s = self:raw(4)
  if not s then return nil, "short read" end
  return (sunpack(">I4", s))
end

function R:string()
  local n = self:uint32()
  if not n then return nil, "short read" end
  return self:raw(n)
end

function R:namelist()
  local s = self:string()
  if not s then return nil, "short read" end
  local t = {}
  if s ~= "" then
    for name in s:gmatch "[^,]+" do t[#t + 1] = name end
  end
  return t, s
end

return M
