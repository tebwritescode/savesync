-- Auto save: write the game's own save on a timer, so a crash, a flat
-- battery or a closed lid costs minutes instead of hours.
--
-- WHY THIS IS OFF BY DEFAULT.  In Gen 1, saving is part of how people play.
-- Soft-resetting to re-roll a starter, a legendary catch, or a stat spread is
-- a real technique, and it works precisely BECAUSE the game only writes when
-- you tell it to.  An autosave that fires between the encounter and the reset
-- silently destroys that.  So this ships off, the option says what it does,
-- and every autosave takes a backup first -- an autosave that lands at the
-- wrong moment is recoverable from Restore Previous Save, tagged `auto`.
--
-- WHEN IT IS SAFE TO WRITE.  Not "every N seconds" -- only when the player is
-- settled in the free-roam overworld.  That gate is the engine's own
-- (`Zoom.gateOK`): the overworld must be the TOP of the state stack, so no
-- battle, menu, dialog or shop is open; it must not be transitioning, so no
-- warp is in flight; and no script may be running, so no cutscene is
-- mid-sentence.  On top of that the player must not be mid-step, because a
-- save captures a tile and half a tile is not one.
--
-- A save that is not safe yet is not skipped, only deferred: the moment the
-- player walks out of the building the write happens.

local Store = SAVESYNC_INCLUDE("src/store.lua")

local Autosave = {}

-- The choices the option row cycles through.  Zero is off, and is first
-- because it is the default.
Autosave.CHOICES = { 0, 3, 5, 10, 15 }

-- How long "SAVED" stays on screen.  Long enough to notice, short enough not
-- to sit over the world while the player is walking.
local FLASH_SECONDS = 1.5

-- A veto (the save.write hook, a tool mod running an ephemeral session) is a
-- legitimate answer, not an error.  Back off rather than retry every frame.
local VETO_BACKOFF = 60

local lastSaveAt = 0
local flashUntil = 0
local blockedUntil = 0

local function now()
  return (love and love.timer and love.timer.getTime and love.timer.getTime())
    or os.clock()
end

--- Minutes between saves; 0 means off.  Lives in the mod's own config, not in
--- the game save -- a setting about how the save is written has no business
--- being a thing the save carries between devices.
function Autosave.minutes()
  local m = Store.config().autosaveMinutes
  return tonumber(m) or 0
end

function Autosave.setMinutes(m)
  local c = Store.config()
  c.autosaveMinutes = tonumber(m) or 0
  Store.saveConfig(c)
  -- Start the clock from the change, so turning it on does not immediately
  -- fire a save the player did not expect.
  lastSaveAt = now()
end

function Autosave.label()
  local m = Autosave.minutes()
  if m <= 0 then return "OFF" end
  return m .. " min"
end

--- Advance to the next choice; wraps.
function Autosave.cycle()
  local m = Autosave.minutes()
  local i = 1
  for n, choice in ipairs(Autosave.CHOICES) do
    if choice == m then i = n break end
  end
  Autosave.setMinutes(Autosave.CHOICES[(i % #Autosave.CHOICES) + 1])
end

--- Any save resets the clock -- including the player's own.  Someone who
--- just saved at a Poke Center should not get an autosave thirty seconds
--- later.  Wired to the save.writing event in main.lua.
function Autosave.noteSaved()
  lastSaveAt = now()
end

--- Is the game settled enough to write?  Uses the engine's own free-roam
--- gate rather than a second opinion about what "in the overworld" means.
function Autosave.safe(game)
  if not (game and game.stack and game.overworld) then return false end
  local top = game.stack.top and game.stack:top()
  if not top then return false end

  local okGate, Zoom = pcall(require, "src.render.Zoom")
  if okGate and Zoom and Zoom.gateOK then
    if Zoom.gateOK(top, game.overworld) ~= true then return false end
  else
    -- Zoom is engine-internal.  If a future build moves it, this must be the
    -- SAME predicate, not a looser one -- a fallback that quietly drops the
    -- script check would autosave in the middle of a cutscene on exactly the
    -- builds where nobody thought to look.
    if top ~= game.overworld then return false end
    if top.transitioning then return false end
    if top.runner and top.runner.isRunning and top.runner:isRunning() then
      return false
    end
  end

  -- Mid-step: the save records a tile, and the player is between two.
  local player = game.overworld.player
  if player and player.moving then return false end
  return true
end

--- Call once a frame.  Does nothing at all when the feature is off, which is
--- the state most installs are in.
function Autosave.update(game)
  local minutes = Autosave.minutes()
  if minutes <= 0 then return end

  local t = now()
  if lastSaveAt == 0 then lastSaveAt = t return end
  if t < blockedUntil then return end
  if t - lastSaveAt < minutes * 60 then return end
  if not Autosave.safe(game) then return end
  if not game.writeSave then return end

  -- Snapshot what is on disk BEFORE overwriting it.  This is what makes an
  -- ill-timed autosave undoable: the pre-autosave state goes into the same
  -- backup folder Restore Previous Save reads, tagged `auto`.
  local version = game.save and game.save.version
  local ok, rec = pcall(Store.readLocal, version)
  if ok and rec then
    pcall(Store.backup, rec.key, rec.bytes, "auto")
  end

  local wrote
  ok, wrote = pcall(function() return game:writeSave() end)
  if not ok then
    -- A failed write must not take the frame down, and must not spin.
    blockedUntil = t + VETO_BACKOFF
    return
  end
  if wrote == false then
    blockedUntil = t + VETO_BACKOFF
    return
  end

  lastSaveAt = t
  flashUntil = t + FLASH_SECONDS
end

--- Draw the brief confirmation.  Called from the render.hud hook, which is
--- SCREEN space -- so the game-canvas coordinates below are mapped through
--- the viewport rather than used raw, or the text would render eight pixels
--- tall in the corner of a 4K window.
function Autosave.draw(Font, viewport)
  if now() >= flashUntil then return end
  if not (viewport and viewport.gameWidth and viewport.gameWidth > 0) then return end

  local sx = viewport.gameWidth / 160
  local sy = viewport.gameHeight / 144
  love.graphics.push()
  love.graphics.translate(viewport.gameX or 0, viewport.gameY or 0)
  love.graphics.scale(sx, sy)
  -- Top-right, clear of the dialog box and the HUD the world draws.
  Font.draw("SAVED", 112, 6)
  love.graphics.pop()
end

--- Seconds until the next autosave, or nil when off.  The screen shows this
--- so the setting is not a black box.
function Autosave.nextIn()
  local minutes = Autosave.minutes()
  if minutes <= 0 then return nil end
  local left = (lastSaveAt + minutes * 60) - now()
  return left > 0 and math.floor(left) or 0
end

return Autosave
