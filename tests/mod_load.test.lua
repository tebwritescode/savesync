-- Loads SaveSync v2 through the engine's own mod-SDK harness: manifest,
-- hooks, registries and every module parse and run inside a real loader --
-- including the real sandbox -- not a stubbed one.
--
-- Run from a Gen1Recomp checkout with the mod installed:
--
--   cp -r mod /path/to/gen1recomp/mods/savesync
--   cp tests/mod_load.test.lua /path/to/gen1recomp/tests/savesync_load_test.lua
--   cd /path/to/gen1recomp && luajit tests/savesync_load_test.lua
--
-- No ROM, no network: the transport is exercised separately (tunnel e2e);
-- here the mod must simply be HARMLESS and correct without either.

local T = require("tests.modkit")

local Data = T.fixtures.load()
local r = T.sdk.loadMod("mods/savesync", { data = Data })

T.check(r ~= nil, "loadMod returned a result")
for _, err in ipairs(r and r.errors or {}) do
  T.check(false, "loader error: " .. tostring(err.message or err))
end
T.check(#(r.errors or {}) == 0, "mod loads with no errors")
T.check(r.mod ~= nil, "the loader kept a mod handle")
T.eq(r.mod and r.mod.manifest.id, "savesync", "loaded under the right id")

-- v2 is for both generations: the manifest must claim every game.
do
  local games = r.mod and r.mod.manifest.games or {}
  local byId = {}
  for _, g in ipairs(games) do byId[g] = true end
  T.check(byId.red and byId.blue and byId.yellow, "claims every Gen 1 game")
  T.check(byId.gold, "claims Gold -- gen2compat is declared, not implied")
end

local exports = r.loader and r.loader.exports["savesync"]
T.check(type(exports) == "table", "mod publishes its exports")

if type(exports) == "table" then
  local Sync = exports.sync
  T.check(type(Sync) == "table", "exports the sync engine")
  T.check(type(exports.store) == "table", "exports the store")
  T.check(exports.version == "2.0.0", "exports its version from the manifest")

  -- With no account, sync must be inert: no network, no state, no errors.
  T.check(Sync.configured() == false, "starts unconfigured")
  T.check(pcall(Sync.update), "update() is safe when unconfigured")
  T.eq(Sync.state, "off", "state is off when unconfigured")
  T.check(Sync.link == nil, "and no connection was opened")

  -- THE SAFETY TABLE. assess() is what keeps a replace from ever being
  -- silent; every row here is a promise to the player.
  local A = Sync.assess
  T.eq(A("h", "h", "h"), "match", "all agree: nothing to do")
  T.eq(A("h", "h", "old"), "match", "local and server agree: done, whatever last saw")
  T.eq(A("new", "h", "h"), "upload", "only this device moved: fast-forward up")
  T.eq(A("h", "new", "h"), "ask_download", "only the server moved: a QUESTION, never a silent download")
  T.eq(A("a", "b", "c"), "ask_both", "both moved: a QUESTION with both sides shown")
  T.eq(A("a", "b", "a"), "ask_download", "server ahead of an unchanged local: still a question")
  T.eq(A("b", "a", "a"), "upload", "local ahead of an unchanged server: the one silent flow")
end

-- ---- the visible surface: menu rows and the screen.
local Runtime = require("src.mods.Runtime")

local function rowsFrom(hook, seed)
  local items = seed or {}
  return Runtime.call(hook, function(_, list) return list end, {}, items)
end

local function hasLabel(items, label)
  for _, it in ipairs(items or {}) do
    if it.label == label then return true end
  end
  return false
end

T.check(hasLabel(rowsFrom("ui.title_menu.items"), "SAVESYNC"),
  "adds a title-menu row")

local startRows = rowsFrom("ui.start_menu.items",
  { { label = "POKEMON" }, { label = "OPTION" }, { label = "EXIT" } })
T.eq(#startRows, 3, "the Start menu is left alone")

local optionRows = rowsFrom("ui.options.rows", { { id = "text_speed" } })
local hasOption = false
for _, row in ipairs(optionRows or {}) do
  if row.id == "savesync" then
    hasOption = true
    T.check(type(row.activate) == "function", "the options row opens the screen")
    T.eq(row.value and row.value({}), "OPEN", "and reads OPEN: it is a door")
  end
end
T.check(hasOption, "adds a SAVESYNC row to OPTIONS")

local titleRows = rowsFrom("ui.title_menu.items",
  { { label = "CONTINUE" }, { label = "NEW GAME" }, { label = "OPTION" },
    { label = "EXIT GAME" } })
T.eq(titleRows[#titleRows].label, "EXIT GAME",
  "EXIT stays at the bottom of the title menu")

T.check(type(Data.screens) == "table" and Data.screens.SaveSync ~= nil,
  "registers the SaveSync screen")

-- ---- the screen constructs and runs, signed out.
do
  local pressed = {}
  local game = {
    input = { wasPressed = function(_, k) return pressed[k] == true end },
    stack = { states = {}, pop = function(s) table.remove(s.states) end },
  }
  local ok, screen = pcall(Data.screens.SaveSync.new, game)
  T.check(ok and type(screen) == "table", "the screen constructs: " .. tostring(screen))
  if ok and screen then
    T.eq(screen.view, "main", "opens on the main view")
    T.check(pcall(screen.update, screen, 0.016), "update runs with no input")
    pressed.down = true
    T.check(pcall(screen.update, screen, 0.016), "update runs on DOWN")
    pressed.down = false

    -- Auto save is useful without any account and must start OFF (the
    -- soft-reset rule); its rows live on the main view either way.
    local Autosave = exports and exports.autosave
    T.check(type(Autosave) == "table", "autosave is exported")
    if Autosave then
      T.eq(Autosave.minutes(), 0, "autosave starts off")
      T.eq(Autosave.target(), "active", "and targets the active save by default")
      -- the target cycles through existing slots and back
      Autosave.setTarget("slot2")
      T.eq(Autosave.target(), "slot2", "a picked autosave slot sticks")
      T.eq(Autosave.targetLabel(), "SLOT 2", "and reads as SLOT 2")
      Autosave.setTarget("active")
    end

    -- Signed out, the account door must be first; entering it must not
    -- open any network connection by itself.
    screen.view, screen.cursor = "main", 1
    pressed.a = true
    T.check(pcall(screen.update, screen, 0.016), "A on Set up account runs")
    pressed.a = false
    T.check(screen.view == "account" or screen.view == "main",
      "Set up leads to the account view (or refuses politely with no transport)")
    T.check((exports.sync.link and exports.sync.link.net) == nil,
      "no socket was opened by menu navigation")
  end
end

-- ---- config: an account, once stored, survives a reload round trip.
do
  local Store = exports.store
  local Sync = exports.sync
  local c = Store.config()
  c.account = { name = "Ash", verifier = "dGVzdA==" }
  T.check(Store.saveConfig(c), "config with an account writes")
  Store.forgetCache()
  T.check(Sync.configured(), "and reads back as configured")
  T.eq(Sync.accountName(), "Ash", "with the right name")

  -- bindings: bind, exclusive slot, unbind
  Sync.bind("red-abc123", 2)
  T.check(Sync.bindingFor("red-abc123").slot == 2, "a binding sticks")
  Sync.bind("yellow-def456", 2)
  T.check(Sync.bindingFor("red-abc123") == nil,
    "one slot serves one save: rebinding evicts the old key")
  T.eq(Sync.keyForSlot(2), "yellow-def456", "and the slot answers for its key")
  Sync.unbind("yellow-def456")
  T.check(Sync.keyForSlot(2) == nil, "unbind frees the slot")

  -- logged out: account gone, recovery code KEPT
  c = Store.config()
  c.recoveryCode = "G1MMO-TEST"
  Store.saveConfig(c)
  Sync.logout()
  T.check(not Sync.configured(), "logout clears the account")
  T.eq(Store.config().recoveryCode, "G1MMO-TEST",
    "but never the recovery code -- it is the player's, not the session's")
end

-- ---- the CONTINUE gate wraps the real localized label and only fires
-- when there is something to say.
do
  local Gate = nil
  -- reach the gate through the loader's include cache is private; test the
  -- observable instead: wrapping a fake title menu decorates CONTINUE.
  local items = rowsFrom("ui.title_menu.items",
    { { label = "CONTINUE", onSelect = function() end } })
  local cont
  for _, it in ipairs(items) do if it.label == "CONTINUE" then cont = it end end
  T.check(cont and cont.savesyncWrapped, "CONTINUE is wrapped by the gate")
  -- unconfigured (we logged out above): the gate must not interpose
  T.check(pcall(cont.onSelect), "and pressing it with no account just proceeds")
end

T.finish("savesync load")
