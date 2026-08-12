-- Auto save AND auto snapshot: two independent timers that write two very
-- different things.
--
-- WHY THIS SPLIT EXISTS.  Auto save writes the game's own save.lua on a
-- timer, so a crash, a flat battery or a closed lid costs minutes instead of
-- hours -- but in Gen 1, saving is part of how people play.  Soft-resetting
-- to re-roll a starter, a legendary catch, or a stat spread is a real
-- technique, and it works precisely BECAUSE the game only writes when you
-- tell it to.  An autosave that fires between the encounter and the reset
-- silently destroys that.  So save-file autosave ships off, and every write
-- it does takes a backup first -- one that lands at the wrong moment is
-- recoverable from Restore Previous Save, tagged `auto`.
--
-- Auto SNAPSHOT does not have that problem.  A snapshot (src/snapshot.lua)
-- never touches save.lua at all, so it cannot be the thing that quietly
-- lands between a soft-reset encounter and the reset -- there is nothing on
-- disk for CONTINUE to pick up.  It is therefore safe to default ON, and
-- doing so is the whole point of having it: crash insurance that costs the
-- soft-reset technique nothing.
--
-- WHEN EACH IS SAFE TO WRITE.  Not "every N seconds" for either -- only when
-- the player is settled in the free-roam overworld.  Auto save uses the
-- engine's own free-roam gate (`Zoom.gateOK`): the overworld must be the TOP
-- of the state stack, so no battle, menu, dialog or shop is open; it must not
-- be transitioning, so no warp is in flight; and no script may be running, so
-- no cutscene is mid-sentence.  Auto snapshot uses a stricter, ENGINE-OWNED
-- answer to the same question -- `Snapshot.inspect(game).canCapture` -- rather
-- than a second opinion here, because the checkpoint format has its own
-- extra rules (no queued script movement, no partial field animation) that
-- this module has no business re-deriving and getting slightly wrong.
--
-- A write that comes due at a bad moment is not skipped, only deferred: the
-- moment the player walks out of the building it happens, for whichever
-- timer came due.

local Store = SAVESYNC_INCLUDE("src/store.lua")
local Snapshot = SAVESYNC_INCLUDE("src/snapshot.lua")

local Autosave = {}

-- The choices both option rows cycle through.  Zero is off, and is first
-- because it is auto save's default -- auto snapshot's different default of
-- 5 lives in Autosave.snapshotMinutes() below, not here; the row still walks
-- OFF -> 3 -> 5 -> 10 -> 15 -> OFF like auto save's does, only starting
-- somewhere else on the dial.
Autosave.CHOICES = { 0, 3, 5, 10, 15 }

-- How long a corner flash stays up.  Long enough to notice, short enough not
-- to sit over the world while the player is walking.
local FLASH_SECONDS = 1.5

-- A veto (the save.write hook, a tool mod running an ephemeral session) or a
-- capture refusal is a legitimate answer, not an error.  Back off rather
-- than retry every frame.
local VETO_BACKOFF = 60

local lastSaveAt = 0
local saveBlockedUntil = 0
local lastSnapshotAt = 0
local snapshotBlockedUntil = 0

-- One flash slot, not two.  The two timers are minutes apart by design, so
-- both landing on the same frame is not a case worth a second line of HUD
-- text for, and one slot is what keeps the draw code below a single copy
-- instead of two near-identical ones.
local flashUntil = 0
local flashText = "SAVED"

local function now()
  return (love and love.timer and love.timer.getTime and love.timer.getTime())
    or os.clock()
end

-- ------------------------------------------------------------- auto save

--- Minutes between save-file writes; 0 means off.  Lives in the mod's own
--- config, not in the game save -- a setting about how the save is written
--- has no business being a thing the save carries between devices.
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

--- Is the game settled enough to write the save file?  Uses the engine's own
--- free-roam gate rather than a second opinion about what "in the overworld"
--- means.
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

-- ---------------------------------------------------------- auto snapshot

--- Minutes between snapshots; defaults to 5 rather than 0.  Unlike auto save
--- this default costs nothing -- see the file header -- so shipping it off
--- would just be crash insurance nobody has, for no reason.
function Autosave.snapshotMinutes()
  return tonumber(Store.config().snapshotMinutes) or 5
end

function Autosave.setSnapshotMinutes(m)
  local c = Store.config()
  c.snapshotMinutes = tonumber(m) or 0
  Store.saveConfig(c)
  lastSnapshotAt = now()
end

function Autosave.snapshotLabel()
  local m = Autosave.snapshotMinutes()
  if m <= 0 then return "OFF" end
  return m .. " min"
end

--- Advance to the next choice; wraps.  Same dial as auto save, independent
--- position.
function Autosave.cycleSnapshot()
  local m = Autosave.snapshotMinutes()
  local i = 1
  for n, choice in ipairs(Autosave.CHOICES) do
    if choice == m then i = n break end
  end
  Autosave.setSnapshotMinutes(Autosave.CHOICES[(i % #Autosave.CHOICES) + 1])
end

--- A snapshot taken from anywhere -- the timer below or the UI's manual
--- button -- resets the clock, for the same reason a manual save resets
--- auto save's: someone who just took one should not get another moments
--- later.
function Autosave.noteSnapshotTaken()
  lastSnapshotAt = now()
end

-- ------------------------------------------------------------------ pump

--- Call once a frame.  Does nothing at all for a timer that is off, and does
--- nothing at all for either when both are, which used to be the state most
--- installs were in -- now only true of auto save.
function Autosave.update(game)
  local saveMinutes = Autosave.minutes()
  if saveMinutes > 0 then
    local t = now()
    if lastSaveAt == 0 then
      lastSaveAt = t
    elseif t >= saveBlockedUntil and t - lastSaveAt >= saveMinutes * 60
        and Autosave.safe(game) and game.writeSave then
      -- Snapshot what is on disk BEFORE overwriting it.  This is what makes
      -- an ill-timed autosave undoable: the pre-autosave state goes into the
      -- same backup folder Restore Previous Save reads, tagged `auto`.
      local version = game.save and game.save.version
      local ok, rec = pcall(Store.readLocal, version)
      if ok and rec then pcall(Store.backup, rec.key, rec.bytes, "auto") end

      -- Flagged so the save.writing listener can tell OUR write from one the
      -- player chose. A prompt after every autosave would be the opposite of
      -- what an autosave is for.
      Autosave.writingOurselves = true
      local wroteOk, wrote = pcall(function() return game:writeSave() end)
      Autosave.writingOurselves = false
      if not wroteOk or wrote == false then
        -- A failed write must not take the frame down, and must not spin.
        saveBlockedUntil = t + VETO_BACKOFF
      else
        lastSaveAt = t
        flashUntil, flashText = t + FLASH_SECONDS, "SAVED"
      end
    end
  end

  local snapMinutes = Autosave.snapshotMinutes()
  if snapMinutes > 0 then
    local t = now()
    if lastSnapshotAt == 0 then
      lastSnapshotAt = t
    elseif t >= snapshotBlockedUntil and t - lastSnapshotAt >= snapMinutes * 60
        and Snapshot.inspect(game).canCapture then
      local name = Snapshot.take(game, "auto")
      if not name then
        -- Same reasoning as the save-file veto above: the gate just passed
        -- but the capture itself refused or failed anyway (it can go stale
        -- between the check and the capture -- a script could start on the
        -- very next line), which is a real answer, not a bug.  Back off
        -- instead of retrying every frame.
        snapshotBlockedUntil = t + VETO_BACKOFF
      else
        lastSnapshotAt = t
        flashUntil, flashText = t + FLASH_SECONDS, "SNAPSHOT"
      end
    end
  end
end

--- Draw the brief confirmation for whichever timer last fired.  Called from
--- the render.hud hook, which is SCREEN space -- so the game-canvas
--- coordinates below are mapped through the viewport rather than used raw,
--- or the text would render eight pixels tall in the corner of a 4K window.
function Autosave.draw(Font, viewport)
  if now() >= flashUntil then return end
  if not (viewport and viewport.gameWidth and viewport.gameWidth > 0) then return end

  local sx = viewport.gameWidth / 160
  local sy = viewport.gameHeight / 144
  love.graphics.push()
  love.graphics.translate(viewport.gameX or 0, viewport.gameY or 0)
  love.graphics.scale(sx, sy)
  -- Top-right, clear of the dialog box and the HUD the world draws.
  -- SNAPSHOT is one tile wider than SAVED, so it starts one tile further
  -- left; both still land inside the same clear margin.
  local x = flashText == "SNAPSHOT" and 96 or 112
  Font.draw(flashText, x, 6)
  love.graphics.pop()
end

--- Seconds until the next auto save, or nil when off.  The screen shows this
--- so the setting is not a black box.
function Autosave.nextIn()
  local minutes = Autosave.minutes()
  if minutes <= 0 then return nil end
  local left = (lastSaveAt + minutes * 60) - now()
  return left > 0 and math.floor(left) or 0
end

--- Seconds until the next auto snapshot, or nil when off.
function Autosave.snapshotNextIn()
  local minutes = Autosave.snapshotMinutes()
  if minutes <= 0 then return nil end
  local left = (lastSnapshotAt + minutes * 60) - now()
  return left > 0 and math.floor(left) or 0
end

return Autosave
