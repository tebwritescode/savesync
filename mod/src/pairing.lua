-- Setup codes: one string that moves a working connection to another device.
--
-- FORMAT.  `SSYNC1.<base64url of a small JSON object>` -- a version prefix so
-- a future format can be told apart at a glance, then the provider config the
-- other device needs.  URL-safe base64 with no padding, so the code survives
-- a chat app, a QR reader, a text file, or being read aloud badly.
--
-- WHAT IS IN IT.  Only what the provider's `exportable(cfg)` chooses to
-- publish -- for Dropbox that is the refresh token and app key, never the
-- short-lived access token; for the self-hosted server the URL and its
-- bearer token.  It is a credential, and the UI says so in plain words.
--
-- WHAT IS NOT IN IT.  No save data, ever.  A setup code says where the saves
-- live, not what they are.
--
-- ON GITHUB, PREFER SIGNING IN AGAIN.  The GitHub provider finds the same
-- storage gist from any device the player signs into, so pairing there needs
-- no code at all.  The code exists for the cases where that is not true (a
-- self-hosted server) or not convenient (a device with no browser).

local Util = SAVESYNC_INCLUDE("src/util.lua")
local Json = SAVESYNC_INCLUDE("src/json.lua")
local Providers = SAVESYNC_INCLUDE("src/providers/init.lua")

local Pairing = {}

local PREFIX = "SSYNC1."

--- Build the code another device pastes.  nil when the current provider has
--- nothing safe to hand over (and the UI then says "just sign in again").
function Pairing.encode(providerId, cfg)
  local p = Providers.get(providerId)
  if not p or not cfg then return nil end
  local payload = p.exportable(cfg)
  if not payload then return nil end
  payload.provider = payload.provider or providerId
  return PREFIX .. Util.b64url(Json.encode(payload))
end

--- Decode a pasted code.  Tolerant of the things people actually paste:
--- surrounding whitespace, a stray "gen1recomp://" wrapper, a code split
--- across lines by a chat app.
function Pairing.decode(text)
  if type(text) ~= "string" then return nil, "nothing pasted" end
  local s = text:gsub("%s", "")
  s = s:gsub("^gen1recomp://savesync?%??c?=?", "")
  local body = s:match("^" .. PREFIX:gsub("%.", "%%.") .. "(.+)$")
  if not body then
    return nil, "that does not look like a setup code"
  end
  local raw = Util.unb64url(body)
  if not raw then return nil, "that code is damaged" end
  local payload = Json.decode(raw)
  if type(payload) ~= "table" or not payload.provider then
    return nil, "that code is damaged"
  end
  if not Providers.get(payload.provider) then
    return nil, "that code is for a service this version does not support"
  end
  return payload
end

--- A form that a browser or QR reader will treat as a link, for players who
--- would rather send themselves a URL than a bare string.
function Pairing.uri(code)
  if not code then return nil end
  return "gen1recomp://savesync?c=" .. code
end

--- Break a long code into fixed-width lines so it can be read off a 160x144
--- screen without a magnifying glass.
function Pairing.wrap(code, width)
  width = width or 18
  local out = {}
  for i = 1, #code, width do out[#out + 1] = code:sub(i, i + width - 1) end
  return out
end

return Pairing
