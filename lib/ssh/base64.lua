-- Base64, RFC 4648. Needed to read OpenSSH key files and to print
-- fingerprints.

local M = {}

local ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local rev = {}
for i = 1, #ALPHA do rev[ALPHA:sub(i, i)] = i - 1 end

function M.encode(s, pad)
  if pad == nil then pad = true end
  local out, n = {}, 0
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    local v = a << 16 | (b or 0) << 8 | (c or 0)
    local chunk = ALPHA:sub((v >> 18 & 63) + 1, (v >> 18 & 63) + 1)
              .. ALPHA:sub((v >> 12 & 63) + 1, (v >> 12 & 63) + 1)
              .. (b and ALPHA:sub((v >> 6 & 63) + 1, (v >> 6 & 63) + 1) or (pad and "=" or ""))
              .. (c and ALPHA:sub((v & 63) + 1, (v & 63) + 1) or (pad and "=" or ""))
    n = n + 1
    out[n] = chunk
  end
  return table.concat(out)
end

function M.decode(s)
  s = s:gsub("[%s=]", "")
  local out, n = {}, 0
  local acc, bits = 0, 0
  for i = 1, #s do
    local v = rev[s:sub(i, i)]
    if not v then return nil, "invalid base64" end
    acc = (acc << 6) | v
    bits = bits + 6
    if bits >= 8 then
      bits = bits - 8
      n = n + 1
      out[n] = string.char((acc >> bits) & 0xff)
    end
  end
  return table.concat(out)
end

return M
