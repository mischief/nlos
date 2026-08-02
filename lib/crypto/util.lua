-- Byte-array helpers shared by the crypto modules.
--
-- The ports below are transliterations of C reference code that indexes
-- plain u8 arrays, so a byte string becomes a 0-based table of integers
-- for the duration and turns back into a string at the boundary. Keeping
-- the indices identical to the C is worth more here than idiomatic Lua:
-- a transcription bug in a field routine is invisible in every test that
-- is not a known-answer test.

local M = {}

local byte, char, rep, concat = string.byte, string.char, string.rep, table.concat

-- string -> 0-based table of bytes
function M.tobytes(s, t)
  t = t or {}
  for i = 1, #s do t[i - 1] = byte(s, i) end
  return t
end

-- 0-based table of bytes -> string
function M.frombytes(t, n)
  n = n or (#t + 1)
  local out = {}
  for i = 0, n - 1 do out[i + 1] = char(t[i] & 0xff) end
  return concat(out)
end

function M.zeros(n)
  local t = {}
  for i = 0, n - 1 do t[i] = 0 end
  return t
end

function M.hex(s)
  return (s:gsub(".", function(c) return ("%02x"):format(byte(c)) end))
end

function M.unhex(h)
  h = h:gsub("[^%x]", "")
  return (h:gsub("%x%x", function(b) return char(tonumber(b, 16)) end))
end

-- Constant-time string equality. No early return, no length-dependent
-- branch beyond the length itself, which is never secret here.
function M.ct_eq(a, b)
  if #a ~= #b then return false end
  local d = 0
  for i = 1, #a do d = d | (byte(a, i) ~ byte(b, i)) end
  return d == 0
end

function M.zerostr(n)
  return rep("\0", n)
end

return M
