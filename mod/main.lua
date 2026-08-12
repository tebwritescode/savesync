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
  --
  -- GUARDED, because os.getenv DOES NOT EXIST on iOS. LOVE's sandbox there
  -- omits it, so calling it threw during mod load and took the entire mod
  -- down before the game had even reached the title screen -- a developer
  -- convenience costing every iOS player the whole feature. Anything reached
  -- at load time has to survive the smallest platform the engine runs on.
  local function env(name)
    if type(os) ~= "table" or type(os.getenv) ~= "function" then return nil end
    local ok, value = pcall(os.getenv, name)
    return ok and value or nil
  end
  local envGithub = env("SAVESYNC_GITHUB_CLIENT_ID")
  if envGithub and envGithub ~= "" then clientIds.github = envGithub end
  local envDropbox = env("SAVESYNC_DROPBOX_APP_KEY")
  if envDropbox and envDropbox ~= "" then clientIds.dropbox = envDropbox end
end

installScreen(mod, { clientIds = clientIds })
Gate.install(mod)
Gate.installAskSave(mod)

-- A download replaces the save FILE.  A live session holds the old save in
-- memory and would write it straight back out at the next in-game SAVE, so a
-- download landing mid-playthrough would be silently undone -- and worse,
-- would look like it had worked.  Downloads therefore wait for the title
-- screen, and the screen says so.
local liveGame
local askAfterSave = false
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

  -- The prompt waits for the save script to finish and the world to settle.
  -- Pushing a screen while the vanilla SAVE sequence is still running would
  -- land on top of its own text box and interrupt a script mid-sentence.
  if askAfterSave then
    local ok, gate = pcall(function()
      return require("src.render.Zoom").gateOK(game.stack:top(), game.overworld)
    end)
    if ok and gate == true then
      askAfterSave = false
      pcall(mod.ui.push, game, "SaveSyncAskSave")
    end
  end
  return next(game, viewport)
end)

local function openScreen(game)
  mod.ui.push(game, "SaveSync")
end

-- Title menu: the one place a download can actually be applied, so the row
-- belongs here even more than it does in the Start menu.
mod.hooks:wrap("ui.title_menu.items", function(next, game, items)
  pcall(function()
    -- Before EXIT GAME, not appended. Appending put SAVESYNC underneath the
    -- way out, and EXIT belongs at the bottom of a menu -- that is where every
    -- player's thumb already expects it. Anchored on the engine's own
    -- localised string so a translated build orders correctly too.
    local okS, Strings = pcall(require, "src.core.Strings")
    local exitLabel = okS and Strings and Strings("EXIT GAME") or "EXIT GAME"
    mod.ui.insertBefore(items, exitLabel, {
      label = "SAVESYNC",
      onSelect = function() openScreen(game) end,
    })
    -- CONTINUE asks first when the boot check could not confirm this save is
    -- the current one. Loading a stale save is not data loss -- the conflict
    -- rule catches that -- but it costs the player every hour they then play
    -- on the wrong file before anyone tells them.
    Gate.wrapItems(mod, game, items)
  end)
  return next(game, items)
end)

-- OPTIONS, not the Start menu.
--
-- SaveSync is a setting, not a verb the player reaches for mid-battle, and
-- OPTIONS is already on BOTH the title screen and the in-game Start menu --
-- so one row here replaces two and stops the mod squatting on a menu the
-- vanilla game keeps short on purpose.
--
-- The row reads SAVESYNC / OPEN, because that is what it does: every other
-- row on this screen changes a setting in place, and this one is a door. A
-- status word in the value column read like something the row could be
-- cycled through, which is exactly what the rows either side of it do. The
-- state it used to show lives on the screen the row opens, where there is
-- room to say it in words rather than in seven characters.
mod.hooks:wrap("ui.options.rows", function(next, game, rows)
  pcall(function()
    rows[#rows + 1] = {
      id = "savesync",
      label = "SAVESYNC",
      value = function() return "OPEN" end,
      activate = function(g) openScreen(g or game) end,
    }
  end)
  return next(game, rows)
end)

-- The game is about to write save.lua.  Ask for an upload; the engine
-- debounces and does the work a few seconds later, off the render thread.
mod.events:on("save.writing", function()
  -- Any save restarts the autosave clock, the player's own included: someone
  -- who just saved at a Poke Center should not get an autosave a moment later.
  Autosave.noteSaved()
  if Store.config().auto ~= false then Sync.markSaved() end

  -- A save the PLAYER chose is the one moment they are thinking about their
  -- progress, so it is the right moment to offer to push it up now rather
  -- than in a few seconds. Autosaves and snapshots are excluded: a prompt
  -- after every one of those is the opposite of what they are for.
  -- `~= false`, matching the row that displays this: a setting that is
  -- absent is one that has never been turned off. The two spellings
  -- disagreeing about nil is what made the row read ON while nothing asked.
  if Sync.configured() and Store.config().askOnSave ~= false
      and not Autosave.writingOurselves then
    askAfterSave = true
  end
end)

-- Boot: check the cloud once, early, while the player is still on the title
-- screen and a download can be applied without argument.
mod.events:on("game.ready", function()
  -- The second argument marks this as the BOOT check, which is what the
  -- CONTINUE gate waits on. The title screen is also the only place a
  -- download can be applied, so this is the one sync that can actually fix a
  -- stale save rather than just report one.
  if Sync.configured() and Store.config().auto ~= false then Sync.request(true, true) end
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
