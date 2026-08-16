-- DEFLATE compression, RFC 1951.
--
-- A stream, because zlib@openssh.com is one flush per packet over a
-- stream that lasts the connection. Matching is greedy over hash chains
-- keyed by the exact 3 bytes, so a chain has no false hits. Each block
-- goes out the cheapest of dynamic, fixed, or stored.

local store = require "zlib.store"

local M = {}

local byte, char, sub, concat = string.byte, string.char, string.sub, table.concat
local move, sort, unpack = table.move, table.sort, table.unpack

local MINMATCH, MAXMATCH, WSIZE = 3, 258, 32768

-- Tokens per block, and how far back a chain is walked. Both are the
-- compression/speed knob; zlib's level 6 walks 128.
local MAXTOKENS = 16384
local CHAIN = 128

-- The window holds two windows' worth and slides by one, which is what
-- lets a chain entry be a position modulo the window. The trigger leaves
-- room for the longest match still being looked at.
local WMASK, HMASK = WSIZE - 1, 0x7fff
local SLIDEAT = 2 * WSIZE - MAXMATCH - MINMATCH

--------------------------------------------------------------------------
-- the tables of RFC 1951 3.2.5, indexed by code

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

-- length -> code, and distance -> code. The distance table is halved
-- twice over: distances above 256 share a slot per 128, which is enough
-- because a code covers at least that many at that size.
local lcode, dcode = {}, {}
do
  for c = 0, 28 do
    local hi = lbase[c] + (1 << lext[c]) - 1
    if hi > MAXMATCH then hi = MAXMATCH end
    for l = lbase[c], hi do lcode[l] = c end
  end
  for c = 0, 29 do
    local hi = dbase[c] + (1 << dext[c]) - 1
    if hi > WSIZE then hi = WSIZE end
    for d = dbase[c], hi do
      dcode[d <= 256 and d - 1 or 256 + ((d - 1) >> 7)] = c
    end
  end
end

local function distcode(d)
  return dcode[d <= 256 and d - 1 or 256 + ((d - 1) >> 7)]
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

-- Code lengths for one merge pass, or nil if the tree came out deeper
-- than `maxlen`. Two queues rather than a heap: the leaves sorted once,
-- and the internal nodes, which are produced in weight order already.
local function pass(f, n, maxlen)
  local leaf, k = {}, 0
  for sym = 0, n - 1 do
    if f[sym] > 0 then
      k = k + 1
      leaf[k] = sym
    end
  end
  local lens = {}
  for sym = 0, n - 1 do lens[sym] = 0 end
  if k == 0 then return lens end
  if k == 1 then
    lens[leaf[1]] = 1
    return lens
  end
  sort(leaf, function(a, b)
    if f[a] ~= f[b] then return f[a] < f[b] end
    return a < b
  end)

  -- Nodes 1..k are the leaves in sorted order; the rest are internal.
  local wt, le, ri = {}, {}, {}
  for i = 1, k do wt[i] = f[leaf[i]] end
  local a, b, top = 1, k + 1, k
  local function pick()
    if a <= k and (b > top or wt[a] <= wt[b]) then
      a = a + 1
      return a - 1
    end
    b = b + 1
    return b - 1
  end
  for _ = 1, k - 1 do
    local x, y = pick(), pick()
    top = top + 1
    wt[top], le[top], ri[top] = wt[x] + wt[y], x, y
  end

  local depth, stack, sp = {}, { top }, 1
  depth[top] = 0
  while sp > 0 do
    local node = stack[sp]
    sp = sp - 1
    local d = depth[node]
    if le[node] then
      if d + 1 > maxlen then return nil end
      depth[le[node]], depth[ri[node]] = d + 1, d + 1
      stack[sp + 1], stack[sp + 2] = le[node], ri[node]
      sp = sp + 2
    else
      lens[leaf[node]] = d
    end
  end
  return lens
end

-- Optimal lengths, unless the tree is too deep for the format: halving
-- the counts flattens it and costs a fraction of a bit per symbol.
local function build(freq, n, maxlen)
  local f = {}
  for i = 0, n - 1 do f[i] = freq[i] or 0 end
  while true do
    local lens = pass(f, n, maxlen)
    if lens then return lens end
    for i = 0, n - 1 do
      if f[i] > 0 then f[i] = (f[i] + 1) >> 1 end
    end
  end
end

-- Canonical codes, already bit-reversed: a code goes on the wire high bit
-- first and everything else goes low bit first.
local function codes(lens, n)
  local count, out = {}, {}
  for len = 0, 15 do count[len] = 0 end
  for sym = 0, n - 1 do count[lens[sym]] = count[lens[sym]] + 1 end
  local at, code = {}, 0
  for len = 1, 15 do
    code = (code + count[len - 1]) << 1
    at[len] = code
  end
  for sym = 0, n - 1 do
    local len = lens[sym]
    if len > 0 then
      out[sym] = reverse(at[len], len)
      at[len] = at[len] + 1
    end
  end
  return out
end

local fixed_llens, fixed_lcodes, fixed_dlens, fixed_dcodes
do
  fixed_llens = {}
  for i = 0, 143 do fixed_llens[i] = 8 end
  for i = 144, 255 do fixed_llens[i] = 9 end
  for i = 256, 279 do fixed_llens[i] = 7 end
  for i = 280, 287 do fixed_llens[i] = 8 end
  fixed_lcodes = codes(fixed_llens, 288)
  fixed_dlens = {}
  for i = 0, 29 do fixed_dlens[i] = 5 end
  fixed_dcodes = codes(fixed_dlens, 30)
end

--------------------------------------------------------------------------
-- bits out

local function put(z, v, n)
  z.hold = z.hold | ((v & ((1 << n) - 1)) << z.nbits)
  z.nbits = z.nbits + n
  while z.nbits >= 8 do
    z.no = z.no + 1
    z.out[z.no] = z.hold & 0xff
    z.hold = z.hold >> 8
    z.nbits = z.nbits - 8
  end
end

local function align(z)
  if z.nbits > 0 then put(z, 0, 8 - z.nbits) end
end

local function take(z)
  local out, o, n = z.out, {}, 0
  for i = 1, z.no, 1024 do
    local j = i + 1023
    if j > z.no then j = z.no end
    n = n + 1
    o[n] = char(unpack(out, i, j))
  end
  z.no = 0
  return concat(o, "", 1, n)
end

--------------------------------------------------------------------------
-- blocks

-- The code lengths of both trees, run-length encoded as RFC 1951 3.2.7
-- describes: a list of (symbol, extra value, extra bits).
local function rle(llens, hlit, dlens, hdist)
  local all, n = {}, 0
  for i = 0, hlit - 1 do
    n = n + 1
    all[n] = llens[i]
  end
  for i = 0, hdist - 1 do
    n = n + 1
    all[n] = dlens[i]
  end

  local items, m, i = {}, 0, 1
  local function emit(sym, v, bits)
    m = m + 1
    items[m] = { sym, v, bits }
  end
  while i <= n do
    local len, run = all[i], 1
    while i + run <= n and all[i + run] == len do run = run + 1 end
    if len == 0 then
      while run >= 11 do
        local r = run > 138 and 138 or run
        emit(18, r - 11, 7)
        i, run = i + r, run - r
      end
      while run >= 3 do
        local r = run > 10 and 10 or run
        emit(17, r - 3, 3)
        i, run = i + r, run - r
      end
    else
      emit(len, 0, 0)
      i, run = i + 1, run - 1
      while run >= 3 do
        local r = run > 6 and 6 or run
        emit(16, r - 3, 2)
        i, run = i + r, run - r
      end
    end
    for _ = 1, run do
      emit(all[i], 0, 0)
      i = i + 1
    end
  end
  return items, m
end

-- Everything a dynamic header needs, plus what it costs in bits.
local function header(llens, hlit, dlens, hdist)
  local items, m = rle(llens, hlit, dlens, hdist)
  local freq = {}
  for i = 0, 18 do freq[i] = 0 end
  for i = 1, m do freq[items[i][1]] = freq[items[i][1]] + 1 end
  local cllens = build(freq, 19, 7)
  local clcodes = codes(cllens, 19)

  local hclen = 19
  while hclen > 4 and cllens[CLORDER[hclen - 1]] == 0 do hclen = hclen - 1 end

  local bits = 14 + 3 * hclen
  for i = 1, m do
    local it = items[i]
    bits = bits + cllens[it[1]] + it[3]
  end
  return { items = items, m = m, cllens = cllens, clcodes = clcodes,
           hclen = hclen, bits = bits }
end

local function treebits(freq, lens, n)
  local bits = 0
  for i = 0, n - 1 do
    local f = freq[i]
    if f and f > 0 then bits = bits + f * lens[i] end
  end
  return bits
end

-- One block, written whichever of the three ways is smallest. `upto` is
-- one past the last input byte the tokens cover.
local function emit(z, final, upto)
  local lf, df = z.lfreq, z.dfreq
  lf[256] = (lf[256] or 0) + 1

  local llens = build(lf, 286, 15)
  local dlens = build(df, 30, 15)
  local hlit, hdist = 286, 30
  while hlit > 257 and llens[hlit - 1] == 0 do hlit = hlit - 1 end
  while hdist > 1 and dlens[hdist - 1] == 0 do hdist = hdist - 1 end

  local hdr = header(llens, hlit, dlens, hdist)
  local dyn = hdr.bits + treebits(lf, llens, 286) + treebits(df, dlens, 30)
  local fix = 3 + treebits(lf, fixed_llens, 286) + treebits(df, fixed_dlens, 30)
  local raw = upto - z.blockstart
  local stored = raw <= 0xffff
      and 3 + ((8 - (z.nbits + 3) % 8) % 8) + 32 + 8 * raw
      or math.huge

  if stored <= dyn + z.extra and stored <= fix + z.extra then
    put(z, final and 1 or 0, 1)
    put(z, 0, 2)
    align(z)
    put(z, raw & 0xff, 8)
    put(z, raw >> 8, 8)
    put(z, ~raw & 0xff, 8)
    put(z, (~raw >> 8) & 0xff, 8)
    local raws = sub(z.s, z.blockstart, upto - 1)
    for i = 1, raw do put(z, byte(raws, i), 8) end
    return
  end

  local lcodes, dcodes
  if dyn <= fix then
    put(z, final and 1 or 0, 1)
    put(z, 2, 2)
    put(z, hlit - 257, 5)
    put(z, hdist - 1, 5)
    put(z, hdr.hclen - 4, 4)
    for i = 0, hdr.hclen - 1 do put(z, hdr.cllens[CLORDER[i]], 3) end
    for i = 1, hdr.m do
      local it = hdr.items[i]
      put(z, hdr.clcodes[it[1]], hdr.cllens[it[1]])
      if it[3] > 0 then put(z, it[2], it[3]) end
    end
    lcodes, dcodes = codes(llens, 286), codes(dlens, 30)
  else
    put(z, final and 1 or 0, 1)
    put(z, 1, 2)
    llens, dlens = fixed_llens, fixed_dlens
    lcodes, dcodes = fixed_lcodes, fixed_dcodes
  end

  local lit, dist = z.lit, z.dist
  for i = 1, z.nt do
    local l, d = lit[i], dist[i]
    if d == 0 then
      put(z, lcodes[l], llens[l])
    else
      local c = lcode[l]
      put(z, lcodes[257 + c], llens[257 + c])
      if lext[c] > 0 then put(z, l - lbase[c], lext[c]) end
      local dc = distcode(d)
      put(z, dcodes[dc], dlens[dc])
      if dext[dc] > 0 then put(z, d - dbase[dc], dext[dc]) end
    end
  end
  put(z, lcodes[256], llens[256])
end

local function reset(z, upto)
  z.nt, z.extra, z.blockstart = 0, 0, upto
  z.lfreq, z.dfreq = {}, {}
end

--------------------------------------------------------------------------
-- matching

local Z = {}
Z.__index = Z

function M.new(opts)
  opts = opts or {}
  local z = setmetatable({
    s = "", n = 0, pos = 1,       -- the window, and the first byte not coded
    pend = {}, pn = 0, pi = 1,    -- input that has not reached the window
    head = store.words(HMASK + 1),  -- hash chains, by a 15-bit key
    prev = store.words(WSIZE),
    -- The block's tokens: a literal, or a length with a distance.
    lit = store.rawwords(MAXTOKENS + 1),
    dist = store.rawwords(MAXTOKENS + 1), nt = 0,
    out = {}, no = 0, hold = 0, nbits = 0,
    chain = opts.chain or CHAIN,
    done = false,
  }, Z)
  reset(z, 1)
  return z
end

local function token(z, len, d)
  local n = z.nt + 1
  z.nt, z.lit[n], z.dist[n] = n, len, d
  if d == 0 then
    z.lfreq[len] = (z.lfreq[len] or 0) + 1
  else
    local c, dc = lcode[len], distcode(d)
    z.lfreq[257 + c] = (z.lfreq[257 + c] or 0) + 1
    z.dfreq[dc] = (z.dfreq[dc] or 0) + 1
    z.extra = z.extra + lext[c] + dext[dc]
  end
end

-- Code input up to and including `limit`. A match may reach past it into
-- bytes already in the window, which is what makes holding back a
-- lookahead enough to keep matches from being cut short at a boundary.
local function code(z, limit)
  local s, head, prev, n = z.s, z.head, z.prev, z.n
  local pos = z.pos
  while pos <= limit do
    local best, bestd = MINMATCH - 1, 0
    local p1, p2, p3 = byte(s, pos, pos + 2)
    if p3 then
      local h = ((p1 << 10) ~ (p2 << 5) ~ p3) & HMASK
      local cand = head[h]
      head[h] = pos
      prev[pos & WMASK] = cand

      local floor = pos - WSIZE
      local maxlen = n - pos + 1
      if maxlen > MAXMATCH then maxlen = MAXMATCH end
      local chain = z.chain
      while cand and cand > floor and chain > 0 do
        -- The byte one past the best match first, which rejects most
        -- candidates in one read; the three the hash stands for after,
        -- because the hash is 15 bits and does collide.
        if byte(s, cand + best) == byte(s, pos + best) then
          local c1, c2, c3 = byte(s, cand, cand + 2)
          if c1 == p1 and c2 == p2 and c3 == p3 then
            local l = MINMATCH
            while l < maxlen and byte(s, cand + l) == byte(s, pos + l) do
              l = l + 1
            end
            if l > best then
              best, bestd = l, pos - cand
              if l == maxlen then break end
            end
          end
        end
        chain = chain - 1
        local nc = prev[cand & WMASK]
        if not nc or nc >= cand then break end
        cand = nc
      end
    end

    if bestd > 0 then
      token(z, best, bestd)
      for i = pos + 1, pos + best - 1 do
        local b1, b2, b3 = byte(s, i, i + 2)
        if b3 then
          local h = ((b1 << 10) ~ (b2 << 5) ~ b3) & HMASK
          prev[i & WMASK] = head[h]
          head[h] = i
        end
      end
      pos = pos + best
    else
      token(z, p1, 0)
      pos = pos + 1
    end

    -- Also bounded in bytes, not only in tokens: a stored block cannot
    -- carry more than 65535, and the input before `pos` cannot be dropped
    -- until the block that covers it is written.
    if z.nt >= MAXTOKENS or pos - z.blockstart >= 0xffff then
      emit(z, false, pos)
      reset(z, pos)
    end
  end
  z.pos = pos
end

-- Drop what a match can no longer reach. Exactly one window at a time,
-- never a byte less: a chain is keyed by position modulo the window, so
-- any other distance would move every entry into the wrong slot.
local function slide(z)
  if z.pos <= SLIDEAT then return end
  if z.blockstart <= WSIZE then
    emit(z, false, z.pos)
    reset(z, z.pos)
  end
  local cut = WSIZE
  z.s = sub(z.s, cut + 1)
  z.n, z.pos, z.blockstart = z.n - cut, z.pos - cut, z.blockstart - cut
  local head, prev = z.head, z.prev
  for i = 0, HMASK do
    local v = head[i]
    if v then head[i] = v > cut and v - cut or nil end
  end
  for i = 0, WMASK do
    local v = prev[i]
    if v then prev[i] = v > cut and v - cut or nil end
  end
end

--------------------------------------------------------------------------
-- the stream

-- Bytes into the window, and out again as codes. The window holds two
-- windows' worth at most: filling it, coding it, and sliding it are one
-- loop, so a caller can hand over a megabyte and the memory does not
-- move.
local function fill(z)
  local pend, pi = z.pend, z.pi
  while true do
    local room = 2 * WSIZE - z.n
    while room > 0 and pi <= z.pn do
      local chunk = pend[pi]
      if #chunk <= room then
        z.s = z.s .. chunk
        z.n = z.n + #chunk
        room = room - #chunk
        pend[pi] = nil
        pi = pi + 1
      else
        z.s = z.s .. sub(chunk, 1, room)
        z.n = z.n + room
        pend[pi] = sub(chunk, room + 1)
        room = 0
      end
    end
    if pi > z.pn then break end
    -- Still input left over, so the window is full: code all but the
    -- lookahead, drop a window, and go round again.
    code(z, z.n - MAXMATCH)
    slide(z)
  end
  z.pi = pi
end

-- Buffer bytes, and code them once enough have piled up to be worth a
-- block. Returns whatever is ready to go on the wire, often "".
function Z:update(s)
  if self.done then return nil, "stream finished" end
  if #s > 0 then
    self.pn = self.pn + 1
    self.pend[self.pn] = s
    fill(self)
  end
  if self.n - self.pos > 16384 then
    code(self, self.n - MAXMATCH)
    slide(self)
  end
  return take(self)
end

-- End the block and align, so what has been written decodes on its own:
-- Z_SYNC_FLUSH, an empty stored block after the data.
function Z:flush()
  if self.done then return nil, "stream finished" end
  code(self, self.n)
  if self.nt > 0 then
    emit(self, false, self.pos)
    reset(self, self.pos)
  end
  put(self, 0, 3)
  align(self)
  self.no = self.no + 4
  self.out[self.no - 3], self.out[self.no - 2] = 0, 0
  self.out[self.no - 1], self.out[self.no] = 0xff, 0xff
  slide(self)
  return take(self)
end

-- The final block. Nothing more may be written after it.
function Z:finish()
  if self.done then return nil, "stream finished" end
  code(self, self.n)
  emit(self, true, self.pos)
  reset(self, self.pos)
  align(self)
  self.done = true
  return take(self)
end

-- One raw deflate stream from one string.
function M.compress(s, opts)
  local z = M.new(opts)
  local a = z:update(s)
  return a .. z:finish()
end

return M
