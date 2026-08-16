-- SSH message numbers, RFC 4250 section 4.1.2 and RFC 4253/4252/4254.
-- Named rather than numbered at the call sites, and a reverse table for
-- error messages.

local M = {
  DISCONNECT = 1,
  IGNORE = 2,
  UNIMPLEMENTED = 3,
  DEBUG = 4,
  SERVICE_REQUEST = 5,
  SERVICE_ACCEPT = 6,
  EXT_INFO = 7,

  KEXINIT = 20,
  NEWKEYS = 21,

  -- 30 and 31 are kex-method specific; these are the ECDH names.
  KEX_ECDH_INIT = 30,
  KEX_ECDH_REPLY = 31,

  USERAUTH_REQUEST = 50,
  USERAUTH_FAILURE = 51,
  USERAUTH_SUCCESS = 52,
  USERAUTH_BANNER = 53,
  -- 60 belongs to whichever method is running: publickey reads it as
  -- PK_OK, keyboard-interactive as the prompts. Neither is in flight
  -- while the other is, so the number is read inside the method.
  USERAUTH_PK_OK = 60,
  USERAUTH_INFO_REQUEST = 60,
  USERAUTH_INFO_RESPONSE = 61,

  GLOBAL_REQUEST = 80,
  REQUEST_SUCCESS = 81,
  REQUEST_FAILURE = 82,

  CHANNEL_OPEN = 90,
  CHANNEL_OPEN_CONFIRMATION = 91,
  CHANNEL_OPEN_FAILURE = 92,
  CHANNEL_WINDOW_ADJUST = 93,
  CHANNEL_DATA = 94,
  CHANNEL_EXTENDED_DATA = 95,
  CHANNEL_EOF = 96,
  CHANNEL_CLOSE = 97,
  CHANNEL_REQUEST = 98,
  CHANNEL_SUCCESS = 99,
  CHANNEL_FAILURE = 100,
}

M.name = {}
for k, v in pairs(M) do
  if type(v) == "number" then M.name[v] = k end
end

return M
