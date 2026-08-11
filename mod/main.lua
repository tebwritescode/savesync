-- Cloud Saves for Gen1Recomp -- entry point.
--
-- Wires four things into the engine and nothing else:
--   * a CLOUD SAVES row on the title menu and the in-game Start menu
--   * a per-frame pump for the sync engine (render.hud)
--   * "the game just saved" -> upload, via the save.writing event
--   * "a session is live" -> hold downloads back, via the state stack
--
-- Everything with an opinion lives in src/: the provider layer (which cloud),
-- the sync engine (what to upload and when), the store (what a save is and
-- how to replace one safely) and the screen.

local mod = ...

-- Module loader.  Mods are single-entry, so submodules come in through
-- mod:read + load(), cached as singletons -- the same idiom the other mods in
-- this engine use.  Global, so submodules can pull their own dependencies.
local _cache = {}
function CLOUD_SAVES_INCLUDE(path)
  if _cache[path] then return _cache[path] end
  local src, err = mod:read(path)
  if not src then
    error("cloud_saves: cannot read " .. path .. ": " .. tostring(err))
  end
  local chunk = assert(load(src, "@cloud_saves/" .. path))
  local result = chunk()
  _cache[path] = result
  return result
end

local Json = CLOUD_SAVES_INCLUDE("src/json.lua")
local Sync = CLOUD_SAVES_INCLUDE("src/sync.lua")
local Store = CLOUD_SAVES_INCLUDE("src/store.lua")
local Http = CLOUD_SAVES_INCLUDE("src/http.lua")
local installScreen = CLOUD_SAVES_INCLUDE("src/ui.lua")

-- OAuth client ids.  These are PUBLIC values (the device flow and PKCE exist
-- precisely so a client needs no secret), they differ per distribution, and a
-- fork should ship its own -- so they live in a data file rather than in
-- code.  An unset id simply means that provider says "not configured" when
-- picked, instead of failing halfway through a sign-in.
local clientIds = {}
do
  local raw = mod:read("providers.json")
  local parsed = raw and Json.decode(raw)
  if type(parsed) == "table" then
    for id, entry in pairs(parsed) do
      if type(entry) == "table" then clientIds[id] = entry.client_id end
    end
  end
  -- Overridable for development, so a contributor can test a sign-in flow
  -- against their own OAuth app without editing a tracked file.
  local envGithub = os.getenv("GEN1RECOMP_CLOUD_GITHUB_CLIENT_ID")
  if envGithub and envGithub ~= "" then clientIds.github = envGithub end
  local envDropbox = os.getenv("GEN1RECOMP_CLOUD_DROPBOX_APP_KEY")
  if envDropbox and envDropbox ~= "" then clientIds.dropbox = envDropbox end
end

installScreen(mod, { clientIds = clientIds })

-- A download replaces the save FILE.  A live session holds the old save in
-- memory and would write it straight back out at the next in-game SAVE, so a
-- download landing mid-playthrough would be silently undone -- and worse,
-- would look like it had worked.  Downloads therefore wait for the title
-- screen, and the screen says so.
local liveGame
Sync.canApplyDownload = function()
  if not liveGame or not liveGame.stack then return true end
  for _, state in ipairs(liveGame.stack.states or {}) do
    if state == liveGame.overworld then return false end
  end
  return true
end

-- Per-frame pump.  render.hud runs every frame the game draws, title screen
-- included, which is exactly where a download is allowed to land.
mod.hooks:wrap("render.hud", function(next, game, viewport)
  liveGame = game
  local ok, err = pcall(Sync.update)
  if not ok then
    Sync.state, Sync.status = "error", tostring(err)
  end
  return next(game, viewport)
end)

local function openScreen(game)
  mod.ui.push(game, "CloudSaves")
end

-- Title menu: the one place a download can actually be applied, so the row
-- belongs here even more than it does in the Start menu.
mod.hooks:wrap("ui.title_menu.items", function(next, game, items)
  pcall(function()
    items[#items + 1] = {
      label = "CLOUD SAVES",
      onSelect = function() openScreen(game) end,
    }
  end)
  return next(game, items)
end)

mod.hooks:wrap("ui.start_menu.items", function(next, game, items)
  pcall(function()
    mod.ui.insertBefore(items, "OPTION", {
      label = "CLOUD",
      onSelect = function() openScreen(game) end,
    })
  end)
  return next(game, items)
end)

-- The game is about to write save.lua.  Ask for an upload; the engine
-- debounces and does the work a few seconds later, off the render thread.
mod.events:on("save.writing", function()
  if Store.config().auto then Sync.markSaved() end
end)

-- Boot: check the cloud once, early, while the player is still on the title
-- screen and a download can be applied without argument.
mod.events:on("game.ready", function()
  if Sync.configured() and Store.config().auto then Sync.request(true) end
end)

-- Returning to the title after a session is the other moment a deferred
-- download becomes applicable.
mod.events:on("screen.popped", function()
  if Sync.deferred and Sync.canApplyDownload() then Sync.request(true) end
end)

-- NOTE ON QUITTING.  There is no "game is quitting" event a mod can listen
-- for, and LÖVE waits for every live thread before the process exits -- so
-- the network workers retire themselves after a few seconds of no work (see
-- src/http.lua) rather than relying on a shutdown call that would never
-- arrive.  Http.shutdown exists for tests and for a future quit hook.

mod.exports = {
  sync = Sync,
  store = Store,
  version = ((mod:read("manifest.json") or ""):match('"version"%s*:%s*"([^"]+)"'))
    or "?",
}
return mod.exports
