-- Where the window, the hash chains and the decode tables live.
--
-- A Lua table of numbers costs 16 bytes a byte: a 32 KiB window is half
-- a megabyte. On lua-os `los.buf` holds real bytes and costs what it
-- says. Both are indexed alike -- the buffer ones are proxies whose
-- metamethods do the reading -- so the code above stays one path. A
-- proxy costs a C call a byte, so use `copy` and `str` where a run of
-- bytes moves at once: that is where a buffer wins its keep back.

local M = {}

local char, unpack, concat = string.char, table.unpack, table.concat

local ok, buf = pcall(require, "los.buf")
M.native = ok and type(buf) == "table" and buf.new ~= nil

-- `n` slots of 16 bits, indexed 0 .. n-1, nil where nothing is stored.
-- Values are positions in a window and never zero.
function M.words(n)
  if not M.native then return {} end
  local b = buf.new(2 * n)
  return setmetatable({}, {
    __index = function(_, i)
      local v = b:u16le(2 * i + 1)
      if v ~= 0 then return v end
    end,
    __newindex = function(_, i, v)
      b:setu16le(2 * i + 1, v or 0)
    end,
  })
end

-- The same, for slots that are read whether or not they were written, so
-- zero is a value and an unset slot reads as zero rather than as nil.
-- Second return value zeroes the lot.
function M.rawwords(n)
  if not M.native then
    local t = {}
    local function clear()
      for i = 0, n - 1 do t[i] = 0 end
    end
    clear()
    return t, clear
  end
  local b = buf.new(2 * n)
  return setmetatable({}, {
    __index = function(_, i) return b:u16le(2 * i + 1) end,
    __newindex = function(_, i, v) b:setu16le(2 * i + 1, v) end,
  }), function() b:fill(0) end
end

-- `n` bytes, indexed 1 .. n, and the bulk operations on them: a range as
-- a string, a run copied inside the store, and a run copied in from a
-- string. `copy` never has to handle overlap: its caller cuts a repeat
-- into runs that do not.
function M.bytes(n)
  if not M.native then
    local t = {}
    return t, {
      str = function(i, j)
        local out, k = {}, 0
        for a = i, j, 1024 do
          local z = a + 1023
          if z > j then z = j end
          k = k + 1
          out[k] = char(unpack(t, a, z))
        end
        return concat(out, "", 1, k)
      end,
      copy = function(dst, src, len)
        for k = 0, len - 1 do t[dst + k] = t[src + k] end
      end,
      put = function(dst, s, from, to)
        for k = from, to do
          t[dst] = s:byte(k)
          dst = dst + 1
        end
      end,
    }
  end

  local b = buf.new(n)
  return setmetatable({}, {
    __index = function(_, i) return b:u8(i) end,
    __newindex = function(_, i, v) b:setu8(i, v) end,
  }), {
    str = function(i, j) return b:sub(i, j) end,
    copy = function(dst, src, len) b:copy(dst, b, src, src + len - 1) end,
    put = function(dst, s, from, to) b:copy(dst, s, from, to) end,
  }
end

return M
