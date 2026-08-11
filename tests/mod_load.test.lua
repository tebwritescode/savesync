-- Loads the mod through the engine's own mod-SDK harness, to prove the
-- manifest, the hook names, the registries and every module actually parse
-- and run inside a real loader -- not just a stubbed one.
--
-- Run from a Gen1Recomp checkout with the mod installed:
--
--   cp -r mod /path/to/gen1recomp/mods/cloud_saves
--   cd /path/to/gen1recomp
--   luajit tests/../../gen1recomp-cloudsaves/tests/mod_load.test.lua
--
-- or, more simply, copy this file into the engine's tests/ and run it there.
-- It needs no ROM: the harness supplies fixture data.

local T = require("tests.modkit")

local Data = T.fixtures.load()
local r = T.sdk.loadMod("mods/cloud_saves", { data = Data })

T.check(r ~= nil, "loadMod returned a result")

for _, err in ipairs(r and r.errors or {}) do
  T.check(false, "loader error: " .. tostring(err.message or err))
end
T.check(#(r.errors or {}) == 0, "mod loads with no errors")

T.check(r.mod ~= nil, "the loader kept a mod handle")
T.eq(r.mod and r.mod.manifest.id, "cloud_saves", "loaded under the right id")

-- Exports are the documented way for another mod (or a test) to reach in;
-- the loader collects them per id rather than on the mod handle.
local exports = r.loader and r.loader.exports["cloud_saves"]
T.check(type(exports) == "table", "mod publishes its exports")
if type(exports) == "table" then
  T.check(type(exports.sync) == "table", "exports the sync engine")
  T.check(type(exports.store) == "table", "exports the store")
  T.check(exports.version ~= "?", "exports its version from the manifest")

  -- With nothing configured, sync must be inert: no network, no state, and
  -- above all no errors on a machine that has never opened the screen.
  T.check(exports.sync.configured() == false, "starts unconfigured")
  local ok = pcall(exports.sync.update)
  T.check(ok, "update() is safe when unconfigured")
  T.eq(exports.sync.state, "off", "state is off when unconfigured")

  -- The decision table is the safety-critical bit; assert it survived the
  -- trip through the real loader too.
  T.eq(exports.sync.decide("b", "c", nil), "conflict",
    "conflict rule survives loading")
end

-- ---- the visible surface: two menu rows and one screen.
-- Sdk.loadMod installs the loader's buses into the runtime, so calling a
-- hook here runs the mod's real wrap.
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

T.check(hasLabel(rowsFrom("ui.title_menu.items"), "CLOUD SAVES"),
  "adds a title-menu row")

-- The Start-menu row anchors before OPTION, so seed the vanilla anchor.
local startRows = rowsFrom("ui.start_menu.items",
  { { label = "POKEMON" }, { label = "OPTION" }, { label = "EXIT" } })
T.check(hasLabel(startRows, "CLOUD"), "adds a Start-menu row")
T.eq(#startRows, 4, "and adds exactly one row")

T.check(type(Data.screens) == "table" and Data.screens.CloudSaves ~= nil,
  "registers the CloudSaves screen")

-- ---- the screen actually constructs and runs.
-- Registry entries only prove the table is there; a typo inside new() or
-- update() would otherwise wait to be found by a player opening the menu.
-- draw() is left alone: it needs real font sheets, which no fixture has.
do
  local pressed = {}
  local game = {
    input = { wasPressed = function(_, k) return pressed[k] == true end },
    stack = { states = {}, pop = function(s) table.remove(s.states) end },
  }
  local ok, screen = pcall(Data.screens.CloudSaves.new, game)
  T.check(ok and type(screen) == "table", "the screen constructs: "
    .. tostring(screen))
  if ok and screen then
    T.check(pcall(screen.update, screen, 0.016), "update runs with no input")
    pressed.down = true
    T.check(pcall(screen.update, screen, 0.016), "update runs on DOWN")
    pressed.down, pressed.a = false, true
    -- On a fresh install the only row is Set Up, so this walks into the
    -- provider picker -- which is where a bad provider table would blow up.
    T.check(pcall(screen.update, screen, 0.016), "update runs on A")
    T.eq(screen.view, "setup", "A on a fresh install opens Set Up")
    pressed.a = false
    T.check(pcall(screen.update, screen, 0.016), "the provider list builds")
  end
end

r.release()
T.finish("cloud_saves load")
