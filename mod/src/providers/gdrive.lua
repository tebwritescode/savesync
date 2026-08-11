-- Google Drive provider -- reserved, not shipping yet.
--
-- WHY IT IS A STUB.  The storage side is easy (the Drive `appDataFolder`
-- space is exactly this mod's shape: hidden from the user's Drive, per-app,
-- free).  The sign-in side is not: `drive.appdata` is a SENSITIVE scope, so
-- Google requires the OAuth client to pass brand + security verification
-- before more than a hundred test users can consent, and Google's device
-- flow ("OAuth for TV and limited-input devices") does not offer Drive
-- scopes at all -- which means a loopback-redirect flow with a local HTTP
-- listener, not a code the player types.
--
-- Shipping a half-working Google option would be worse than shipping none:
-- players would pick the name they recognise and hit an "unverified app"
-- warning.  So this file exists to hold the interface shape, and the door it
-- leaves open is the point of the provider layer -- finishing it is one file
-- and one line in providers/init.lua, with nothing else in the mod touched.
--
-- TO FINISH:
--   1. Google Cloud console -> OAuth client (Desktop), scope
--      https://www.googleapis.com/auth/drive.appdata, then verification.
--   2. link(): PKCE with redirect_uri = http://127.0.0.1:<port>, a luasocket
--      listener for the one callback request (the engine already links
--      luasocket -- see src/link/Net.lua).
--   3. read/write/list against
--      https://www.googleapis.com/drive/v3/files?spaces=appDataFolder
--      and the uploadType=media endpoint.  Names are not unique in Drive, so
--      keep a name -> fileId map in the config and reconcile it from list().

local Op = SAVESYNC_INCLUDE("src/op.lua")

local P = {}

P.id = "gdrive"
P.label = "Google Drive"
P.blurb = "Not available yet."
P.linkStyle = "unavailable"
P.needsClientId = true
P.hidden = true                 -- kept out of the Set Up list until it works

function P.link(_state, _opts)
  return Op.failed("Google Drive support is not finished yet")
end

function P.describe(_cfg) return "Google Drive" end
function P.exportable(_cfg) return nil end
function P.read(_cfg, _names) return Op.failed("Google Drive is not available") end
function P.write(_cfg, _files) return Op.failed("Google Drive is not available") end
function P.list(_cfg) return Op.failed("Google Drive is not available") end

return P
