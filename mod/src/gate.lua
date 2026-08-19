-- The CONTINUE gate: "is the save you are about to load the current one?"
--
-- WHY THIS EXISTS.  The sync engine already refuses to lose data -- a stale
-- save that gets played turns into a conflict, not an overwrite.  But that is
-- cold comfort: by the time the conflict appears the player has spent hours
-- on the wrong file, and one of the two versions has to lose. The damage is
-- not to the bytes, it is to the evening.
--
-- So before CONTINUE loads anything, this asks the only question that
-- matters: did we manage to check the cloud? Three answers:
--
--   still checking -> hold a moment, then decide with a real answer
--   checked, fine  -> get out of the way entirely, no screen at all
--   could not check -> say so plainly and let the player choose
--
-- IT IS NEVER A WALL.  Offline play is a first-class case, so the warning is
-- a question with "Play anyway" on it, not a refusal. A mod that stops
-- someone playing their own game on a train has failed worse than one that
-- lets them play a slightly old save.
--
-- WHY IT DOES NOT JUST WAIT.  Blocking CONTINUE until the network answers
-- would punish every offline launch with a timeout, and the engine's title
-- screen is the one place a download can actually be applied, so waiting
-- there is pure cost with no benefit once the answer is known.

local Sync = SAVESYNC_INCLUDE("src/sync.lua")
local Store = SAVESYNC_INCLUDE("src/store.lua")
local Util = SAVESYNC_INCLUDE("src/util.lua")
local Link = SAVESYNC_INCLUDE("src/serverlink.lua")

-- How long CONTINUE will wait for an in-flight boot check before asking the
-- player instead. Long enough for a healthy connection to answer, short
-- enough that a dead one does not feel like a hang.
local WAIT_SECONDS = 6

local Gate = {}

--- Does pressing CONTINUE need to say anything at all?
--- Answers false in the overwhelmingly common case -- not set up, or the
--- check already came back clean -- so the gate costs a comparison and
--- nothing else.
function Gate.needed()
  if not Sync.configured() then return false end
  if Store.config().auto == false then return false end

  -- NEVER HOLD THE PLAYER ON A CHECK THAT CANNOT FINISH: a device with no
  -- socket transport at all will not reach the server on this launch or any
  -- other, so warning about staleness here is pure noise -- the SaveSync
  -- screen says it once instead.
  if not Link.transportAvailable() then return false end

  -- "behind" is the one state that CHANGES what CONTINUE should offer: the
  -- server holds news for a save on this device, and per the design a
  -- download is always a question -- this screen is where it gets asked.
  return Sync.boot == "checking" or Sync.boot == "offline"
    or Sync.boot == "error" or Sync.boot == "behind"
end

-- ------------------------------------------------- the after-save prompt
--
-- A save the PLAYER chose is the one moment they are actively thinking about
-- their progress, which makes it the right moment to offer to push it up now
-- instead of in a few seconds. Autosaves and snapshots never reach here --
-- prompting after those would be the opposite of what they are for.
--
-- Answering NO does not cancel anything: the normal debounced upload still
-- happens. All YES buys is "now", which is what someone about to close the
-- lid or swap devices actually wants.
function Gate.installAskSave(mod)
  mod.content.screens:register("SaveSyncAskSave", {
    new = function(game)
      local Font, Theme = mod.ui.Font, mod.ui.Theme
      local self = { game = game, isOpaque = false }
      local input = game.input
      self.cursor = 1

      local items = {
        { "Sync now", function()
          -- Announced: the player asked for this by name, straight after
          -- saving, and gets a SYNCED flash when it actually lands rather
          -- than a screen that closes and says nothing.
          Sync.request(true, false, true)
          game.stack:pop()
        end },
        { "Later", function() game.stack:pop() end },
        { "Stop asking", function()
          local c = Store.config()
          c.askOnSave = false
          Store.saveConfig(c)
          game.stack:pop()
        end },
      }

      function self:update(_dt)
        if input:wasPressed("up") then
          self.cursor = self.cursor > 1 and self.cursor - 1 or #items
        elseif input:wasPressed("down") then
          self.cursor = self.cursor < #items and self.cursor + 1 or 1
        elseif input:wasPressed("a") then
          items[self.cursor][2]()
        elseif input:wasPressed("b") then
          game.stack:pop()
        end
      end

      function self:draw()
        -- A box at the bottom, the way the vanilla game asks a question --
        -- the world stays visible behind it, so this reads as a prompt
        -- rather than as having been taken somewhere.
        --
        -- EVERY COORDINATE BELOW IS PIXELS EXCEPT drawBox's, WHICH IS TILES.
        -- Mixing the two put the box across the bottom half of the screen
        -- while its text was drawn at y=20 -- up in the top quarter, over
        -- the world, nowhere near the box it belonged to, with the first
        -- menu row straddling the box's own top border.
        --
        -- Box: tile row 8 is y=64, ten tiles tall reaches the screen floor
        -- at 144. Its border eats 8px, so the usable band is 72..136 --
        -- which is five 12px rows, exactly what two lines of question and
        -- three answers need.
        Font.drawBox(0, 8, 20, 10)
        Font.draw("Saved. Send to", 16, 72)
        Font.draw("the cloud now?", 16, 84)
        for i, it in ipairs(items) do
          local y = 96 + (i - 1) * 12
          Font.draw(it[1], 28, y)
          if self.cursor == i then Font.drawCode(Theme.cursor, 20, y) end
        end
      end

      return self
    end,
  })
end

function Gate.install(mod)
  local Font, Theme = nil, nil

  mod.content.screens:register("SaveSyncGate", {
    new = function(game, proceed)
      Font, Theme = mod.ui.Font, mod.ui.Theme
      local self = { game = game, isOpaque = true }
      local input = game.input
      self.cursor = 1
      self.startedAt = (love and love.timer and love.timer.getTime
        and love.timer.getTime()) or os.clock()

      -- `proceed` is the vanilla CONTINUE action, captured before we wrapped
      -- it. Calling it is the ONLY way out that loads a save, so it is held
      -- here rather than re-derived.
      local function go()
        game.stack:pop()
        if proceed then proceed() end
      end

      local function back()
        game.stack:pop()
      end

      local function now()
        return (love and love.timer and love.timer.getTime
          and love.timer.getTime()) or os.clock()
      end

      function self:update(_dt)
        Sync.update()

        -- a chosen download in flight: pump until its callback pops us
        if self.pulling then return end

        if Sync.boot == "ok" then
          -- The answer arrived while the player was reading. Nothing to warn
          -- about, so do not make them acknowledge a screen that no longer
          -- says anything.
          go()
          return
        end

        local waiting = Sync.boot == "checking"
          and (now() - self.startedAt) < WAIT_SECONDS

        if waiting then
          -- B SKIPS THE CHECK AND LOADS, it does not cancel CONTINUE.
          --
          -- The screen says "skip", and a player who presses it has just told
          -- us they do not want to wait for the cloud -- so dropping them back
          -- on the title menu answers a question they did not ask and makes
          -- them press CONTINUE again. Skipping means "go without the check",
          -- which is what go() does.
          if input:wasPressed("b") then go() end
          return
        end

        local items = self:items()
        if input:wasPressed("up") then
          self.cursor = self.cursor > 1 and self.cursor - 1 or #items
        elseif input:wasPressed("down") then
          self.cursor = self.cursor < #items and self.cursor + 1 or 1
        elseif input:wasPressed("a") then
          local it = items[self.cursor]
          if it then it[2]() end
        elseif input:wasPressed("b") then
          back()
        end
      end

      function self:items()
        if Sync.boot == "behind" then
          -- The always-ask rule, at the moment it matters most: the server
          -- has a newer save for this device. Adopting it is offered, never
          -- forced, and never silent.
          return {
            { "Use server save", function()
              local key, slot = next(Sync.bootNews or {})
              if key then
                Sync.pull(slot, key, function(ok)
                  if ok then go() else back() end
                end)
                self.pulling = true
              else
                go()
              end
            end },
            { "Play this one", go },
            { "Back", back },
          }
        end
        return {
          { "Play anyway", go },
          { "Back", back },
        }
      end

      function self:draw()
        Font.drawBox(0, 0, 20, 18)
        Font.draw("SAVESYNC", 16, 8)

        local waiting = Sync.boot == "checking"
          and (now() - self.startedAt) < WAIT_SECONDS

        local lines
        if self.pulling then
          lines = { "Fetching the server", "save..." }
        elseif waiting then
          lines = { "Checking for a newer", "save on your other",
                    "devices...", "", "B: skip and play" }
        elseif Sync.boot == "behind" then
          lines = { "The server has a",
                    "NEWER save for this",
                    "game, from another",
                    "device or session." }
        elseif Sync.boot == "offline" then
          -- Name the risk in the player's terms. "Offline" alone does not
          -- tell anyone why they should care.
          lines = { "Could not reach your",
                    "cloud saves.",
                    "",
                    "This save may be older",
                    "than another device." }
        else
          lines = { "Could not check your",
                    "cloud saves.",
                    "",
                    "This save may be older",
                    "than another device." }
        end

        local y = 24
        for _, line in ipairs(lines) do
          if line ~= "" then Font.draw(line, 8, y) end
          y = y + 12
        end

        if not waiting then
          -- Last synced is the one fact that tells the player how stale this
          -- could actually be, so it goes on screen rather than in a log.
          local last = Store.config().lastSync or 0
          Font.draw(("Last synced: %s"):format(Util.ago(last)):sub(1, 19), 8, 84)

          local items = self:items()
          for i, it in ipairs(items) do
            local ry = 106 + (i - 1) * 12
            Font.draw(it[1], 20, ry)
            if self.cursor == i then Font.drawCode(Theme.cursor, 12, ry) end
          end
        end
      end

      return self
    end,
  })
end

--- Wrap the vanilla CONTINUE so it asks first when it should.
---
--- Matched against the engine's OWN localised string rather than the literal
--- "CONTINUE": the title menu builds its label through Strings(), so a
--- player running a translation would otherwise never see the gate -- and a
--- safety net that only protects English speakers is not one.
function Gate.wrapItems(mod, game, items)
  local ok, Strings = pcall(require, "src.core.Strings")
  local label = ok and Strings and Strings("CONTINUE") or "CONTINUE"
  for _, it in ipairs(items or {}) do
    if it.label == label and not it.savesyncWrapped then
      local original = it.onSelect
      it.savesyncWrapped = true
      it.onSelect = function(...)
        if Gate.needed() then
          mod.ui.push(game, "SaveSyncGate", original)
          return
        end
        if original then return original(...) end
      end
    end
  end
  return items
end

return Gate
