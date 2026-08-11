-- The provider registry -- the seam that makes today's free service
-- replaceable tomorrow.
--
-- A provider is four functions over a flat namespace of small named blobs:
--
--   link(state, opts) -> Op -> cfg     sign in / adopt a pairing code
--   read(cfg, names)  -> Op -> { [name] = contents }   (missing = absent)
--   write(cfg, files) -> Op -> true    files[name] = contents, or false to delete
--   list(cfg)         -> Op -> { [name] = size }
--
-- plus `describe(cfg)` for the UI and `exportable(cfg)` for pairing codes.
-- Nothing above this line knows what a gist or a Dropbox folder is, and
-- nothing below it knows what a save file is.  Adding a provider is one file
-- and one line here.
--
-- WRITE IS A BATCH ON PURPOSE.  A sync writes the save, its manifest, one
-- history entry and a prune in the same breath; a provider that can do that
-- in one request (gists, the self-hosted server) then leaves the store in
-- either the old state or the new one, never half of each.

local Registry = {}

local LIST = {
  SAVESYNC_INCLUDE("src/providers/github.lua"),
  SAVESYNC_INCLUDE("src/providers/dropbox.lua"),
  SAVESYNC_INCLUDE("src/providers/server.lua"),
  SAVESYNC_INCLUDE("src/providers/gdrive.lua"),
}

local byId = {}
for _, p in ipairs(LIST) do byId[p.id] = p end

function Registry.get(id)
  return byId[id]
end

--- Providers a player may choose in Set Up, in the order they are offered.
--- The first is the recommended one.
function Registry.choosable()
  local out = {}
  for _, p in ipairs(LIST) do
    if not p.hidden then out[#out + 1] = p end
  end
  return out
end

function Registry.all()
  return LIST
end

return Registry
