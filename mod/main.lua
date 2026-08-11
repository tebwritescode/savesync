-- SaveSync for Gen1Recomp -- entry point.
--
-- Wires four things into the engine and nothing else:
--   * a SAVESYNC row on the title menu and the in-game Start menu
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
function SAVESYNC_INCLUDE(path)
  if _cache[path] then return _cache[path] end
  local src, err = mod:read(path)
  if not src then
    error("savesync: cannot read " .. path .. ": " .. tostring(err))
  end
  local chunk = assert(load(src, "@savesync/" .. path))
  local result = chunk()
  _cache[path] = result
  return result
end

local Json = SAVESYNC_INCLUDE("src/json.lua")
local Sync = SAVESYNC_INCLUDE("src/sync.lua")
local Store = SAVESYNC_INCLUDE("src/store.lua")
local Http = SAVESYNC_INCLUDE("src/http.lua")
local Snapshot = SAVESYNC_INCLUDE("src/snapshot.lua")
local Autosave = SAVESYNC_INCLUDE("src/autosave.lua")
local Gate = SAVESYNC_INCLUDE("src/gate.lua")
local installScreen = SAVESYNC_INCLUDE("src/ui.lua")

-- Hand the engine's checkpoint API to the snapshot module.  `mod.checkpoints`
-- is absent on an engine build predating it, and Snapshot.bind copes with a
-- nil just fine -- Snapshot.available() then answers false everywhere else,
-- which is what hides every snapshot row and pump instead of erroring.
Snapshot.bind(mod)

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
  local envGithub = os.getenv("SAVESYNC_GITHUB_CLIENT_ID")
  if envGithub and envGithub ~= "" then clientIds.github = envGithub end
  local envDropbox = os.getenv("SAVESYNC_DROPBOX_APP_KEY")
  if envDropbox and envDropbox ~= "" then clientIds.dropbox = envDropbox end
end

installScreen(mod, { clientIds = clientIds })
Gate.install(mod)

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
  -- Autosave is independent of the cloud: it is useful on a machine that has
  -- never been set up, so it is not gated on Sync.configured().  Both calls
  -- are wrapped because a throw here would cost the player the frame.
  pcall(Autosave.update, game)
  pcall(Autosave.draw, mod.ui.Font, viewport)
  return next(game, viewport)
end)

local function openScreen(game)
  mod.ui.push(game, "SaveSync")
end

-- Title menu: the one place a download can actually be applied, so the row
-- belongs here even more than it does in the Start menu.
mod.hooks:wrap("ui.title_menu.items", function(next, game, items)
  pcall(function()
    items[#items + 1] = {
      label = "SAVESYNC",
      onSelect = function() openScreen(game) end,
    }
    -- CONTINUE asks first when the boot check could not confirm this save is
    -- the current one. Loading a stale save is not data loss -- the conflict
    -- rule catches that -- but it costs the player every hour they then play
    -- on the wrong file before anyone tells them.
    Gate.wrapItems(mod, game, items)
  end)
  return next(game, items)
end)

-- Start menu: "SYNC", not "SAVESYNC".  The vanilla Start menu box is sized
-- for POKeMON / ITEM / SAVE / OPTION, and an eight-character row is wider
-- than any of them; the short form also reads as the sibling of SAVE, which
-- is exactly what it is.
mod.hooks:wrap("ui.start_menu.items", function(next, game, items)
  pcall(function()
    mod.ui.insertBefore(items, "OPTION", {
      label = "SYNC",
      onSelect = function() openScreen(game) end,
    })
  end)
  return next(game, items)
end)

-- The game is about to write save.lua.  Ask for an upload; the engine
-- debounces and does the work a few seconds later, off the render thread.
mod.events:on("save.writing", function()
  -- Any save restarts the autosave clock, the player's own included: someone
  -- who just saved at a Poke Center should not get an autosave a moment later.
  Autosave.noteSaved()
  if Store.config().auto then Sync.markSaved() end
end)

-- Boot: check the cloud once, early, while the player is still on the title
-- screen and a download can be applied without argument.
mod.events:on("game.ready", function()
  -- The second argument marks this as the BOOT check, which is what the
  -- CONTINUE gate waits on. The title screen is also the only place a
  -- download can be applied, so this is the one sync that can actually fix a
  -- stale save rather than just report one.
  if Sync.configured() and Store.config().auto then Sync.request(true, true) end
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
  autosave = Autosave,
  version = ((mod:read("manifest.json") or ""):match('"version"%s*:%s*"([^"]+)"'))
    or "?",
}
return mod.exports
