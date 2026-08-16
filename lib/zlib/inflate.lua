-- DEFLATE decompression, RFC 1951.
--
-- `new` gives a stream, which is what zlib@openssh.com needs: one
-- deflate stream per connection, so the window and the Huffman state
-- outlive the packet. A short read resumes at the symbol it stopped in,
-- and the window is a ring of one match distance, so a stream costs the
-- 32 KiB the format demands and little else.

local store = require "zlib.store"

local M = {}

local byte, sub, concat = string.byte, string.sub, table.concat

local WSIZE = 32768
local MAXMATCH = 258

-- The window is a ring of exactly the distance a match can reach, so
-- nothing is ever moved down. Decoded bytes leave it before the write
-- pointer can lap what has not been handed back.
local DRAINAT = WSIZE - MAXMATCH - 8

-- Thrown when the input ends mid-block. A table, so it cannot be
-- confused with a message from `error`.
local NEED = {}

--------------------------------------------------------------------------
-- bits
--
-- DEFLATE packs bits from the low end of each byte. A Huffman code is the
-- exception: its bits arrive high end first, which `decode` pays for.

-- Fill the accumulator to `n` bits if the input allows, short if not.
local function fill(st, n)
  while st.n < n do
    local b = byte(st.s, st.i)
    if not b then break end
    st.i = st.i + 1
    st.hold = st.hold | (b << st.n)
    st.n = st.n + 8
  end
end

local function getbits(st, n)
  fill(st, n)
  if st.n < n then error(NEED) end
  local v = st.hold & ((1 << n) - 1)
  st.hold = st.hold >> n
  st.n = st.n - n
  return v
end

-- Drop to the next byte boundary and give back the bytes the accumulator
-- has already eaten, so a stored block can be copied with sub().
local function align(st)
  st.i = st.i - (st.n >> 3)
  st.hold, st.n = 0, 0
end

--------------------------------------------------------------------------
-- Huffman

local function reverse(code, len)
  local r = 0
  for _ = 1, len do
    r = (r << 1) | (code & 1)
    code = code >> 1
  end
  return r
end

-- Canonical code from code lengths, `lens[0 .. n-1]`. Two
-- representations: a 9-bit lookup that decodes most symbols in one index,
-- and the counts and symbol order of RFC 1951 3.2.2 for the longer codes.
-- An incomplete code is allowed -- a stream with one distance or none
-- makes one -- but decoding a code it leaves undefined is an error.
local function tree(nsym)
  local symbol = store.rawwords(nsym)
  local fast, clear = store.rawwords(512)
  return { count = {}, symbol = symbol, fast = fast, clear = clear }
end

local function huffman(lens, n, h)
  local count, symbol, fast = h.count, h.symbol, h.fast
  for len = 0, 15 do count[len] = 0 end
  for sym = 0, n - 1 do count[lens[sym]] = count[lens[sym]] + 1 end
  h.clear()
  if count[0] == n then return h end

  local left = 1
  for len = 1, 15 do
    left = (left << 1) - count[len]
    if left < 0 then return nil, "over-subscribed code" end
  end

  local offs, at, next_code = { [1] = 0 }, {}, 0
  for len = 1, 15 do
    offs[len + 1] = offs[len] + count[len]
    next_code = (next_code + count[len - 1]) << 1
    at[len] = next_code
  end

  for sym = 0, n - 1 do
    local len = lens[sym]
    if len ~= 0 then
      symbol[offs[len]] = sym
      offs[len] = offs[len] + 1
      if len <= 9 then
        local r = reverse(at[len], len)
        for i = r, 511, 1 << len do fast[i] = (sym << 4) | len end
      end
      at[len] = at[len] + 1
    end
  end
  return h
end

local function decode(st, h)
  fill(st, 15)
  local v = h.fast[st.hold & 511]
  if v ~= 0 then
    local len = v & 15
    if len > st.n then error(NEED) end
    st.hold = st.hold >> len
    st.n = st.n - len
    return v >> 4
  end
  local code, first, index = 0, 0, 0
  local hold, n = st.hold, st.n
  for len = 1, 15 do
    if n < 1 then error(NEED) end
    code = code | (hold & 1)
    hold = hold >> 1
    n = n - 1
    local count = h.count[len]
    if code - first < count then
      st.hold, st.n = hold, n
      return h.symbol[index + code - first]
    end
    index = index + count
    first = (first + count) << 1
    code = code << 1
  end
  error "bad Huffman code"
end

--------------------------------------------------------------------------
-- the tables of RFC 1951 3.2.5, and the fixed trees of 3.2.6

-- Indexed by symbol - 257.
local lbase = { [0] = 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27,
                31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local lext = { [0] = 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
               3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local dbase = { [0] = 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129,
                193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                8193, 12289, 16385, 24577 }
local dext = { [0] = 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7,
               8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }

local CLORDER = { [0] = 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13,
                  2, 14, 1, 15 }

local fixed_lit, fixed_dist
do
  local lens = {}
  for i = 0, 143 do lens[i] = 8 end
  for i = 144, 255 do lens[i] = 9 end
  for i = 256, 279 do lens[i] = 7 end
  for i = 280, 287 do lens[i] = 8 end
  fixed_lit = huffman(lens, 288, tree(288))
  for i = 0, 31 do lens[i] = 5 end
  fixed_dist = huffman(lens, 32, tree(32))
end

--------------------------------------------------------------------------
-- blocks

local Z = {}
Z.__index = Z

function M.new()
  local w, ops = store.bytes(WSIZE)
  return setmetatable({
    st = { s = "", i = 1, hold = 0, n = 0 },
    w = w, ops = ops,
    wi = 1,          -- where the next byte goes in the ring
    wn = 0,          -- bytes decoded, ever
    emitted = 0,     -- of those, how many the caller has
    pending = {}, np = 0,
    littree = tree(288), disttree = tree(32), cltree = tree(19),
    state = "header",
    mi = 1, mh = 0, mn = 0,   -- where a short read resumes from
    done = false,
  }, Z)
end

-- The dynamic trees of RFC 1951 3.2.7: a Huffman code carries the code
-- lengths of the other two, run-length encoded.
local function dynamic(st, z)
  local hlit = getbits(st, 5) + 257
  local hdist = getbits(st, 5) + 1
  local hclen = getbits(st, 4) + 4

  local cl = {}
  for i = 0, 18 do cl[i] = 0 end
  for i = 0, hclen - 1 do cl[CLORDER[i]] = getbits(st, 3) end
  local clh, err = huffman(cl, 19, z.cltree)
  if not clh then return nil, err end

  local lens, i = {}, 0
  while i < hlit + hdist do
    local sym = decode(st, clh)
    if not sym then return nil, "bad code length code" end
    if sym < 16 then
      lens[i] = sym
      i = i + 1
    else
      local prev, rep = 0, 0
      if sym == 16 then
        if i == 0 then return nil, "repeat with no previous length" end
        prev = lens[i - 1]
        rep = 3 + getbits(st, 2)
      elseif sym == 17 then
        rep = 3 + getbits(st, 3)
      else
        rep = 11 + getbits(st, 7)
      end
      if i + rep > hlit + hdist then return nil, "too many code lengths" end
      for _ = 1, rep do
        lens[i] = prev
        i = i + 1
      end
    end
  end
  if lens[256] == 0 then return nil, "no end-of-block code" end

  local litlens, distlens = {}, {}
  for j = 0, hlit - 1 do litlens[j] = lens[j] end
  for j = 0, hdist - 1 do distlens[j] = lens[hlit + j] end
  local lit
  lit, err = huffman(litlens, hlit, z.littree)
  if not lit then return nil, err end
  local dist
  dist, err = huffman(distlens, hdist, z.disttree)
  if not dist then return nil, err end
  return lit, dist
end

-- Hand the caller what has been decoded since the last call. Two pieces
-- where the run wraps the end of the ring, one otherwise.
local function drain(self)
  local n = self.wn - self.emitted
  if n == 0 then return end
  local first = self.wi - n
  if first < 1 then first = first + WSIZE end
  local last = first + n - 1
  local np, str = self.np, self.ops.str
  if last <= WSIZE then
    self.pending[np + 1] = str(first, last)
    np = np + 1
  else
    self.pending[np + 1] = str(first, WSIZE)
    self.pending[np + 2] = str(1, last - WSIZE)
    np = np + 2
  end
  self.emitted, self.np = self.wn, np
end

-- A match: `len` bytes from `d` back, which may be the bytes this very
-- copy is writing. Cut into runs that neither overlap nor wrap, so the
-- store moves each one whole.
local function repeated(self, d, len)
  local copy, wi = self.ops.copy, self.wi
  local si = wi - d
  if si < 1 then si = si + WSIZE end
  local left = len
  while left > 0 do
    local n = left
    if n > d then n = d end
    if n > WSIZE - wi + 1 then n = WSIZE - wi + 1 end
    if n > WSIZE - si + 1 then n = WSIZE - si + 1 end
    copy(wi, si, n)
    wi = wi + n
    if wi > WSIZE then wi = 1 end
    si = si + n
    if si > WSIZE then si = 1 end
    left = left - n
  end
  self.wi, self.wn = wi, self.wn + len
end

-- As much of the stream as the input allows. Raises NEED when it runs
-- out, having first put the bit position back to the last point the
-- decoder can resume from: a block header, or a symbol boundary. Nothing
-- reaches the window until every bit it takes has been read, so a resume
-- never writes a byte twice.
local function run(self)
  local st = self.st
  while not self.done do
    local state = self.state

    if state == "header" then
      self.mi, self.mh, self.mn = st.i, st.hold, st.n
      self.final = getbits(st, 1) == 1
      local btype = getbits(st, 2)
      if btype == 0 then
        align(st)
        if #st.s - st.i + 1 < 4 then error(NEED) end
        local len = byte(st.s, st.i) | (byte(st.s, st.i + 1) << 8)
        local nlen = byte(st.s, st.i + 2) | (byte(st.s, st.i + 3) << 8)
        if len ~= (~nlen & 0xffff) then return nil, "stored length mismatch" end
        st.i = st.i + 4
        self.state, self.remain = "stored", len
      elseif btype == 1 then
        self.lit, self.dist, self.state = fixed_lit, fixed_dist, "block"
      elseif btype == 2 then
        local lit, dist = dynamic(st, self)
        if not lit then return nil, dist or "bad dynamic block" end
        self.lit, self.dist, self.state = lit, dist, "block"
      else
        return nil, "reserved block type"
      end

    elseif state == "stored" then
      drain(self)
      local have = #st.s - st.i + 1
      local take = self.remain < have and self.remain or have
      if take > DRAINAT then take = DRAINAT end
      local put, wi = self.ops.put, self.wi
      local left = take
      while left > 0 do
        local n = left
        if n > WSIZE - wi + 1 then n = WSIZE - wi + 1 end
        put(wi, st.s, st.i, st.i + n - 1)
        wi = wi + n
        if wi > WSIZE then wi = 1 end
        st.i, left = st.i + n, left - n
      end
      self.wi, self.wn, self.remain = wi, self.wn + take, self.remain - take
      drain(self)
      -- The rest of a stored block resumes where the copy stopped, not
      -- at the header that has already been read.
      self.mi, self.mh, self.mn = st.i, 0, 0
      if self.remain > 0 then
        if st.i > #st.s then error(NEED) end
      else
        self.state = "header"
        self.done = self.final
      end

    else
      local w, lit, dist = self.w, self.lit, self.dist
      local wi, wn = self.wi, self.wn
      while true do
        -- The resume point, and the window with it: a short read here
        -- gives back only the bits of the symbol that was cut in half.
        self.mi, self.mh, self.mn = st.i, st.hold, st.n
        self.wi, self.wn = wi, wn
        local sym = decode(st, lit)
        if sym < 256 then
          w[wi] = sym
          wi = wi + 1
          if wi > WSIZE then wi = 1 end
          wn = wn + 1
        elseif sym == 256 then
          break
        else
          if sym > 285 then return nil, "bad length code" end
          local lsym = sym - 257
          local len = lbase[lsym] + getbits(st, lext[lsym])
          local dsym = decode(st, dist)
          if dsym > 29 then return nil, "bad distance code" end
          local d = dbase[dsym] + getbits(st, dext[dsym])
          if d > wn or d > WSIZE then
            return nil, "distance past start of window"
          end
          self.wi, self.wn = wi, wn
          repeated(self, d, len)
          wi, wn = self.wi, self.wn
        end
        if wn - self.emitted > DRAINAT then
          self.wi, self.wn = wi, wn
          drain(self)
        end
      end
      self.wi, self.wn, self.state = wi, wn, "header"
      self.done = self.final
    end
  end
  return true
end

-- Bytes in, bytes out. Returns "" while a block is still incomplete, and
-- nil plus a reason for a stream that cannot be decoded, which the stream
-- does not recover from.
function Z:update(s)
  local st = self.st
  if self.err then return nil, self.err end
  if self.done then
    if s ~= "" then return nil, "data after final block" end
    return ""
  end
  st.s = st.i > 1 and sub(st.s, st.i) .. s or st.s .. s
  st.i = 1

  local ok, res, why = pcall(run, self)
  if not ok then
    if res ~= NEED then
      self.err = tostring(res)
      return nil, self.err
    end
    st.i, st.hold, st.n = self.mi, self.mh, self.mn
  elseif not res then
    self.err = why or "corrupt stream"
    return nil, self.err
  end

  drain(self)
  local out = concat(self.pending, "", 1, self.np)
  self.pending, self.np = {}, 0
  return out
end

-- True once the final block has been decoded.
function Z:finished() return self.done end

-- The input after the stream, from the byte boundary the final block
-- ended on: a gzip or zlib trailer, or another member.
function Z:unused()
  local st = self.st
  return sub(st.s, st.i - (st.n >> 3))
end

-- A whole raw deflate stream at once.
function M.decompress(s)
  local z = M.new()
  local out, err = z:update(s)
  if not out then return nil, err end
  if not z.done then return nil, "truncated stream" end
  return out
end

return M
