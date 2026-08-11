-- Loads the mod through the engine's own mod-SDK harness, to prove the
-- manifest, the hook names, the registries and every module actually parse
-- and run inside a real loader -- not just a stubbed one.
--
-- Run from a Gen1Recomp checkout with the mod installed:
--
--   cp -r mod /path/to/gen1recomp/mods/savesync
--   cd /path/to/gen1recomp
--   luajit tests/../../gen1recomp-savesync/tests/mod_load.test.lua
--
-- or, more simply, copy this file into the engine's tests/ and run it there.
-- It needs no ROM: the harness supplies fixture data.

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

-- Exports are the documented way for another mod (or a test) to reach in;
-- the loader collects them per id rather than on the mod handle.
local exports = r.loader and r.loader.exports["savesync"]
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

T.check(hasLabel(rowsFrom("ui.title_menu.items"), "SAVESYNC"),
  "adds a title-menu row")

-- The Start-menu row anchors before OPTION, so seed the vanilla anchor.
local startRows = rowsFrom("ui.start_menu.items",
  { { label = "POKEMON" }, { label = "OPTION" }, { label = "EXIT" } })
T.check(hasLabel(startRows, "SYNC"), "adds a Start-menu row")
T.eq(#startRows, 4, "and adds exactly one row")

T.check(type(Data.screens) == "table" and Data.screens.SaveSync ~= nil,
  "registers the SaveSync screen")

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
  local ok, screen = pcall(Data.screens.SaveSync.new, game)
  T.check(ok and type(screen) == "table", "the screen constructs: "
    .. tostring(screen))
  if ok and screen then
    T.check(pcall(screen.update, screen, 0.016), "update runs with no input")
    pressed.down = true
    T.check(pcall(screen.update, screen, 0.016), "update runs on DOWN")
    pressed.down = false

    -- Select by cursor position rather than by counting keypresses: the row
    -- list grows, and a test that walks it blind starts asserting about
    -- whichever row happens to be second.
    screen.cursor = 1
    pressed.a = true
    T.check(pcall(screen.update, screen, 0.016), "update runs on A")
    -- Set Up is the first row on a fresh install; this walks into the
    -- provider picker, which is where a bad provider table would blow up.
    T.eq(screen.view, "setup", "A on the first row opens Set Up")
    pressed.a = false
    T.check(pcall(screen.update, screen, 0.016), "the provider list builds")

    -- Auto save must be reachable WITHOUT the cloud being set up, and must
    -- start off.
    local Autosave = exports and exports.autosave
    T.check(type(Autosave) == "table", "autosave is exported")
    if Autosave then
      T.eq(Autosave.minutes(), 0, "autosave starts off")
      screen.view, screen.cursor = "main", 2
      pressed.a = true
      T.check(pcall(screen.update, screen, 0.016), "the auto save row runs")
      pressed.a = false
      T.check(Autosave.minutes() > 0,
        "the second row on an unconnected install toggles auto save")
      Autosave.setMinutes(0)
    end
  end
end

-- ---- the reader: a long error must be reachable, not merely wrapped.
-- This is the regression for a real field bug: `GitHub said HTTP 400` drew as
-- `GitHub said HTTP 40`, and 400 could not be told from 404.
do
  local pressed = {}
  local game = {
    input = { wasPressed = function(_, k) return pressed[k] == true end },
    stack = { states = {}, pop = function(s) table.remove(s.states) end },
  }
  local ok, screen = pcall(Data.screens.SaveSync.new, game)
  T.check(ok and type(screen) == "table", "screen constructs for the reader test")
  if ok and screen then
    -- clamping is pure and must never overshoot either end
    T.eq(screen.clampReader(-5, 20, 8), 0, "reader cannot scroll above the top")
    T.eq(screen.clampReader(99, 20, 8), 12, "reader cannot scroll past the end")
    T.eq(screen.clampReader(3, 20, 8), 3, "a valid offset is left alone")
    T.eq(screen.clampReader(2, 4, 8), 0,
      "content shorter than the window cannot scroll")
    T.eq(screen.clampReader(0, 0, 8), 0, "empty content cannot scroll")

    local long = "GitHub said HTTP 400 Problems parsing JSON while writing "
      .. "the save file, which usually means the payload was not valid UTF-8 "
      .. "and the upload was refused before anything was stored."
    screen:openReader("ERROR", long)
    T.eq(screen.view, "reader", "the reader opens")
    T.check(#screen.reader.lines > 8, "the message really does overflow")

    pressed.down = true
    screen:update(0.016)
    T.check(screen.reader.scroll > 0, "DOWN scrolls the reader")
    local top = screen.reader.scroll
    for _ = 1, 50 do screen:update(0.016) end
    T.eq(screen.reader.scroll, #screen.reader.lines - 8,
      "scrolling stops at the last line")
    T.check(screen.reader.scroll > top, "and it got there by scrolling")

    pressed.down = false
    pressed.up = true
    for _ = 1, 100 do screen:update(0.016) end
    T.eq(screen.reader.scroll, 0, "UP returns to the top and stops")

    -- B must always lead back out; getting stuck in a reader would be worse
    -- than the truncation it replaced.
    pressed.up = false
    pressed.b = true
    screen:update(0.016)
    T.eq(screen.view, "main", "B leaves the reader")
    T.eq(screen.reader, nil, "and drops the text it was holding")
  end
end

r.release()
T.finish("savesync load")
