-- The SaveSync screen, v2: one account, five cloud slots.
--
-- The lines the player should ever need:
--
--     SAVESYNC
--     Signed in as ASH
--     1 RED ASH 3B    28d
--     Download / Upload / Clear
--
-- Everything is a view reached on purpose. The design rule that shapes
-- every flow here: NOTHING REPLACES A SAVE WITHOUT ASKING. Downloads always
-- confirm; uploads confirm whenever the server copy has its own changes;
-- clearing confirms; and every confirmation shows what is on each side.
--
-- One account serves SaveSync AND Gen1MMO -- registration says so, and the
-- name-taken message tells a Gen1MMO player their login already works here.
--
-- Drawn with the confirmed mod toolkit only (mod.ui.Font + game.input).
-- The Gen 1 charmap has no ">", "_" or "*": cursor is the vanilla filled
-- arrow (Theme.cursor), underscores draw as strokes, overflow is "...".

local Sync = SAVESYNC_INCLUDE("src/sync.lua")
local Store = SAVESYNC_INCLUDE("src/store.lua")
local Util = SAVESYNC_INCLUDE("src/util.lua")
local Autosave = SAVESYNC_INCLUDE("src/autosave.lua")
local Snapshot = SAVESYNC_INCLUDE("src/snapshot.lua")
local Link = SAVESYNC_INCLUDE("src/serverlink.lua")

local WRAP_WIDTH = 18
local MENU_TOP = 36
local MENU_VISIBLE = 8
local PAGE_SIZE = 4

-- the d-pad letter grid, straight from Gen1MMO's proven text entry
local GRID = {
  "ABCDEFGHIJ",
  "KLMNOPQRST",
  "UVWXYZ0123",
  "456789_.-!",
}

return function(mod, cfgOpts)
  cfgOpts = cfgOpts or {}

  mod.content.screens:register("SaveSync", {
    new = function(game)
      local Font = mod.ui.Font
      local Theme = mod.ui.Theme
      local self = { game = game, isOpaque = true }
      local input = game.input

      self.view = "main"
      self.cursor = 1
      self.scroll = 0
      self.message = nil
      self.syncSeen = Sync.syncedSeq or 0
      self.page = 0

      -- ------------------------------------------------------- helpers

      local function say(msg) self.message = msg end

      local function drawWrapped(x, y, text, maxLines)
        if not text or text == "" then return y end
        local lines = Util.wrap(text, WRAP_WIDTH)
        local shown = math.min(#lines, maxLines)
        for i = 1, shown do
          local line = lines[i]
          if i == shown and shown < #lines then
            line = line:sub(1, math.max(0, WRAP_WIDTH - 3)) .. "..."
          end
          Font.draw(line, x, y)
          y = y + 12
        end
        return y
      end

      local function drawUnderscore(x, y)
        local r, g, b, a = love.graphics.getColor()
        love.graphics.setColor(0, 0, 0, 1)
        love.graphics.rectangle("fill", x, y + 6, 7, 2)
        love.graphics.setColor(r, g, b, a)
      end

      local function goto_(view)
        self.view = view
        self.cursor = 1
        self.scroll = 0
        self.page = 0
        self.message = nil
      end

      -- generic yes/no. confirmLines wraps; A on YES runs onYes.
      function self:confirm(lines, yesLabel, onYes, noLabel)
        self.confirmLines = lines
        self.confirmYes = yesLabel or "Yes"
        self.confirmNo = noLabel or "Back"
        self.confirmAction = onYes
        goto_("confirm")
      end

      -- ------------------------------------------------------- text entry
      -- (Gen1MMO's grid, with native typing where the platform delivers it)

      function self:enterText(prompt, mask, onDone, initial, maxLen)
        self.view = "text"
        self.buffer = tostring(initial or "")
        self.textPrompt = prompt
        self.textMask = mask
        self.textOnDone = onDone
        self.textMax = maxLen or 24
        self.gx, self.gy = 1, 1
        self.acceptTyped = true
        self.typedThisFrame = false
        self.submitTyped = false
        local osName = "unknown"
        pcall(function() osName = love.system.getOS() end)
        if osName ~= "iOS" then
          pcall(function() love.keyboard.setTextInput(true) end)
        end
      end

      function self:leaveText(nextView)
        self.acceptTyped = false
        pcall(function() love.keyboard.setTextInput(false) end)
        self.view = nextView or "main"
      end

      -- main.lua routes love.textinput/keypressed here
      function self:textinput(ch)
        if not self.acceptTyped or self.view ~= "text" then return end
        if #self.buffer < self.textMax and #ch == 1 and ch:byte() >= 32 and ch:byte() < 127 then
          self.buffer = self.buffer .. ch
          self.typedThisFrame = true
        end
      end

      function self:keypressed(k)
        if not self.acceptTyped or self.view ~= "text" then return end
        if k == "backspace" then
          self.buffer = self.buffer:sub(1, -2)
          self.typedThisFrame = true
        elseif k == "return" or k == "kpenter" then
          self.submitTyped = true
        end
      end

      local function updateText()
        if self.submitTyped then
          self.submitTyped = false
          self.typedThisFrame = false
          local cb = self.textOnDone
          self:leaveText()
          if cb then cb(self.buffer) end
          return
        end
        if self.typedThisFrame then
          self.typedThisFrame = false
          return
        end
        if input:wasPressed("up") then self.gy = ((self.gy - 2) % #GRID) + 1 end
        if input:wasPressed("down") then self.gy = (self.gy % #GRID) + 1 end
        if input:wasPressed("left") then self.gx = ((self.gx - 2) % #GRID[1]) + 1 end
        if input:wasPressed("right") then self.gx = (self.gx % #GRID[1]) + 1 end
        if input:wasPressed("a") then
          if #self.buffer < self.textMax then
            self.buffer = self.buffer .. GRID[self.gy]:sub(self.gx, self.gx)
          end
        end
        if input:wasPressed("select") then self.buffer = self.buffer:sub(1, -2) end
        if input:wasPressed("start") then
          local cb = self.textOnDone
          self:leaveText()
          if cb then cb(self.buffer) end
        end
        if input:wasPressed("b") then self:leaveText() end
      end

      local function drawText()
        Font.drawBox(0, 0, 20, 18)
        drawWrapped(8, 8, self.textPrompt or "", 2)
        local shown = self.buffer
        if self.textMask then shown = ("*"):rep(#shown) end
        -- typed line, underscores as strokes
        local x = 8
        for i = 1, #shown do
          local ch = shown:sub(i, i)
          if ch == "_" then drawUnderscore(x, 34) else Font.draw(ch, x, 34) end
          x = x + 8
        end
        drawUnderscore(x, 34)
        for gy, row in ipairs(GRID) do
          for gx = 1, #row do
            local ch = row:sub(gx, gx)
            local cx, cy = 8 + (gx - 1) * 14, 52 + (gy - 1) * 14
            if ch == "_" then drawUnderscore(cx, cy) else Font.draw(ch, cx, cy) end
            if self.gx == gx and self.gy == gy then
              Font.drawCode(Theme.cursor, cx - 8, cy)
            end
          end
        end
        Font.draw("A:add SEL:del", 8, 116)
        Font.draw("START:done B:back", 8, 128)
      end

      -- ------------------------------------------------------- account flows

      local pendingName, pendingPassword

      local function beginRegister()
        self:enterText("Pick a name (3-16):", false, function(name)
          if #name < 3 then say("Names are 3-16 characters") goto_("account") return end
          pendingName = name
          self:enterText("Pick a password:", true, function(pw)
            if #pw < 4 then say("Longer password, please") goto_("account") return end
            pendingPassword = pw
            self:enterText("Password again:", true, function(pw2)
              if pw2 ~= pendingPassword then
                pendingPassword = nil
                say("Passwords did not match")
                goto_("account")
                return
              end
              Sync.register(pendingName, pendingPassword)
              pendingName, pendingPassword = nil, nil
              goto_("linking")
            end)
          end)
        end, "", 16)
      end

      local function beginLogin()
        local c = Store.config()
        self:enterText("Account name:", false, function(name)
          if #name < 3 then goto_("account") return end
          self:enterText("Password:", true, function(pw)
            Sync.login(name, pw)
            goto_("linking")
          end)
        end, c.lastName or "", 16)
      end

      local function beginRecover()
        self:enterText("Account name:", false, function(name)
          if #name < 3 then goto_("account") return end
          self:enterText("Recovery code:", false, function(code)
            self:enterText("NEW password:", true, function(pw)
              if #pw < 4 then say("Longer password, please") goto_("account") return end
              Sync.recover(name, code, pw)
              goto_("linking")
            end)
          end, "", 40)
        end, "", 16)
      end

      -- ------------------------------------------------------- menus

      local function mainItems()
        local items = {}
        if not Sync.configured() then
          items[#items + 1] = { "Set up account", function()
            if not Link.transportAvailable() then
              say("No network transport on this device")
              return
            end
            goto_("account")
          end }
        else
          items[#items + 1] = { "Cloud slots", function()
            goto_("slots")
            -- refresh from the server; the cached copy draws meanwhile
            local link = Sync.link
            if not (link and link:ready()) then Sync.request() end
          end }
          items[#items + 1] = { "Sync now", function()
            Sync.request()
            say("Syncing...")
          end }
          local c = Store.config()
          items[#items + 1] = { "Auto sync: " .. (c.auto ~= false and "ON" or "OFF"), function()
            c.auto = not (c.auto ~= false)
            Store.saveConfig(c)
          end }
          items[#items + 1] = { "Ask on save: " .. (c.askOnSave ~= false and "ON" or "OFF"), function()
            c.askOnSave = not (c.askOnSave ~= false)
            Store.saveConfig(c)
          end }
        end
        items[#items + 1] = { "Auto save: " .. Autosave.label(), function() Autosave.cycle() end }
        items[#items + 1] = { "Save to: " .. Autosave.targetLabel(), function()
          Autosave.cycleTarget(game)
        end }
        items[#items + 1] = { "Auto snapshot: " .. Autosave.snapshotLabel(), function()
          Autosave.cycleSnapshot()
        end }
        if Snapshot.available() then
          items[#items + 1] = { "Snapshots", function()
            self.list = Snapshot.allLocal()
            goto_("snapshots")
          end }
        end
        if Store.config().recoveryCode then
          items[#items + 1] = { "Recovery key", function() goto_("key") end }
        end
        items[#items + 1] = { "Network info", function() goto_("netinfo") end }
        if Sync.configured() then
          items[#items + 1] = { "Log out", function()
            self:confirm({
              "Log out of " .. tostring(Sync.accountName()) .. "?",
              "Saves stay on this device and on the server.",
            }, "Log out", function()
              Sync.logout()
              say("Logged out")
              goto_("main")
            end)
          end }
        end
        return items
      end

      local function accountItems()
        return {
          { "Register", beginRegister },
          { "Log in", beginLogin },
          { "Use recovery code", beginRecover },
          { "Back", function() goto_("main") end },
        }
      end

      -- ------------------------------------------------------- slots

      --- The five rows, from the link's cache merged with local knowledge.
      local function slotRows()
        local link = Sync.link
        local byNum = {}
        for _, s in ipairs((link and link.slots) or {}) do byNum[s.slot] = s end
        local max = (link and link.maxSlots) or 5
        local rows = {}
        for i = 1, max do
          local s = byNum[i]
          local boundKey = Sync.keyForSlot(i)
          local label
          if not s then
            label = ("%d --"):format(i)
          elseif s.expired then
            label = ("%d %s EXPIRED"):format(i, tostring(s.label or s.game):sub(1, 9))
          else
            local days = tostring(s.expiresIn or "?")
            label = ("%d %s %sd"):format(i, tostring(s.label or s.game):sub(1, 11), days)
          end
          rows[#rows + 1] = { label = label, slot = i, server = s, boundKey = boundKey }
        end
        return rows
      end

      local function localChoices()
        local rows = {}
        for _, row in ipairs(Store.slotOverview()) do
          if row.key then
            local label = ("%s %s %s"):format(
              tostring(row.version):upper(),
              tostring(row.name or "?"),
              row.badges and (tostring(row.badges) .. "B") or "")
            rows[#rows + 1] = { label = label:sub(1, 16), key = row.key }
          end
        end
        return rows
      end

      local function describeServer(s)
        if not s then return "empty" end
        return ("%s rev%s %s"):format(tostring(s.label or s.game),
          tostring(s.rev), s.expired and "EXPIRED" or ((s.expiresIn or "?") .. "d left"))
      end

      local function uploadFlow(slotRow, key)
        local slot = slotRow.slot
        local s = slotRow.server
        local sameLineage = s and key == (tostring(s.game) .. "-" .. tostring(s.playthrough))
        if s and not sameLineage then
          -- a different adventure lives in the slot: full-sentence ask
          self:confirm({
            "Slot " .. slot .. " holds:",
            describeServer(s),
            "Replace it with this device's save?",
          }, "Replace", function()
            Sync.bind(key, slot)
            Sync.push(key, slot, true, function(ok, err)
              say(ok and "Sent." or Sync.describeError(err))
            end)
            goto_("slots")
          end)
        else
          -- same adventure (or an empty slot): send without confirm. If the
          -- server copy moved since this device last agreed with it, the
          -- server answers sync_conflict and the question flow takes over --
          -- the ask happens exactly when it is real.
          Sync.bind(key, slot)
          Sync.push(key, slot, false, function(ok, err)
            if ok then say("Sent.")
            elseif err ~= "sync_conflict" and err ~= "slot_conflict" then
              say(Sync.describeError(err))
            end
          end)
          goto_("slots")
        end
      end

      local function slotItems(row)
        local items = {}
        local s = row.server
        local key = s and (tostring(s.game) .. "-" .. tostring(s.playthrough)) or nil
        if s and not s.expired then
          items[#items + 1] = { "Download", function()
            local localRec = key and Store.readAllLocal()[key]
            local warn = localRec
              and "This REPLACES that save on this device (a backup is kept)."
              or "This lands as a new save on this device."
            self:confirm({
              "Server: " .. describeServer(s),
              warn,
            }, "Download", function()
              Sync.pull(row.slot, key, function(ok, err)
                if ok then
                  say(Sync.deferred and "Lands at the title screen" or "Downloaded.")
                else
                  say(Sync.describeError(err))
                end
              end)
              goto_("slots")
            end)
          end }
        end
        -- upload: the current device's saves may go here
        items[#items + 1] = { "Upload a save here", function()
          self.pickTarget = row
          self.list = localChoices()
          if #self.list == 0 then
            say("No local saves to send")
          else
            goto_("pick")
          end
        end }
        if s then
          items[#items + 1] = { "Clear slot", function()
            self:confirm({
              "Clear slot " .. row.slot .. "?",
              describeServer(s),
              "The server copy is deleted. Local saves stay.",
            }, "Clear", function()
              Sync.clearSlot(row.slot, function(ok, err)
                say(ok and "Cleared." or Sync.describeError(err))
              end)
              goto_("slots")
            end)
          end }
        end
        if row.boundKey then
          items[#items + 1] = { "Stop auto-sync", function()
            Sync.unbind(row.boundKey)
            say("This slot no longer auto-syncs")
            goto_("slots")
          end }
        end
        items[#items + 1] = { "Back", function() goto_("slots") end }
        return items
      end

      -- ------------------------------------------------------- questions
      -- Sync.question arrives from background uploads; drawn as its own
      -- view whenever the screen is open and one is pending.

      local function questionItems()
        local q = Sync.question
        if not q then return { { "Back", function() goto_("main") end } } end
        if q.kind == "slot_conflict" then
          return {
            { "Replace server copy", function() Sync.answer("replace_server") end },
            { "Take server copy", function() Sync.answer("take_server") end },
            { "Later", function() Sync.answer("later") end },
          }
        end
        -- both_moved: same adventure, both sides changed
        return {
          { "Keep this device's", function() Sync.answer("keep_local") end },
          { "Take the server's", function() Sync.answer("take_server") end },
          { "Later", function() Sync.answer("later") end },
        }
      end

      -- ------------------------------------------------------- generic list

      local function clampScroll(count)
        self.scroll = math.min(self.scroll, math.max(0, count - MENU_VISIBLE))
        if self.cursor - self.scroll > MENU_VISIBLE then
          self.scroll = self.cursor - MENU_VISIBLE
        elseif self.cursor - self.scroll < 1 then
          self.scroll = self.cursor - 1
        end
      end

      local function menuUpdate(items, onB)
        if self.cursor > #items then self.cursor = math.max(1, #items) end
        if input:wasPressed("up") then
          self.cursor = self.cursor > 1 and self.cursor - 1 or #items
        end
        if input:wasPressed("down") then
          self.cursor = self.cursor < #items and self.cursor + 1 or 1
        end
        clampScroll(#items)
        self._aCool = math.max(0, (self._aCool or 0) - 1)
        if input:wasPressed("a") and self._aCool == 0 and items[self.cursor] then
          self._aCool = 8
          local it = items[self.cursor]
          local fn = it[2] or it.action
          if fn then fn() end
        end
        if input:wasPressed("b") then onB() end
      end

      local function menuDraw(title, items, topLines)
        Font.drawBox(0, 0, 20, 18)
        Font.draw(title, 8, 8)
        local y = 20
        for _, line in ipairs(topLines or {}) do
          y = drawWrapped(8, y, line, 2)
        end
        y = math.max(y, MENU_TOP)
        for i = 1 + self.scroll, math.min(#items, self.scroll + MENU_VISIBLE) do
          local it = items[i]
          local label = it[1] or it.label
          Font.draw(tostring(label):sub(1, WRAP_WIDTH - 1), 16, y)
          if self.cursor == i then Font.drawCode(Theme.cursor, 8, y) end
          y = y + 12
        end
        if self.message then
          drawWrapped(8, 120, self.message, 2)
        end
      end

      -- ------------------------------------------------------- update/draw

      function self:update(_dt)
        pcall(Sync.update)

        -- a background sync landing while the screen is open says so
        if (Sync.syncedSeq or 0) > self.syncSeen then
          self.syncSeen = Sync.syncedSeq
          say("Synced.")
        end

        -- a question outranks whatever view was up (never interrupts text
        -- entry or an explicit confirm the player is inside)
        if Sync.question and self.view ~= "question" and self.view ~= "text"
          and self.view ~= "confirm" then
          goto_("question")
        end

        if self.view == "text" then updateText() return end

        if self.view == "linking" then
          local link = Sync.link
          if not link then goto_("account") return end
          if link.state == "ready" then
            local c = Store.config()
            c.lastName = link.name
            Store.saveConfig(c)
            if link.recoveryCode then
              goto_("key")
            else
              say("Signed in as " .. tostring(link.name))
              goto_("main")
            end
          elseif link.state == "error" then
            say(link.errorCode and Sync.describeError(link.errorCode)
              or link.status or "Could not sign in")
            goto_("account")
          elseif input:wasPressed("b") then
            link:disconnect()
            goto_("account")
          end
          return
        end

        if self.view == "confirm" then
          local items = {
            { self.confirmYes, function()
              local fn = self.confirmAction
              self.confirmAction = nil
              if fn then fn() end
            end },
            { self.confirmNo, function() goto_(self.confirmBack or "main") end },
          }
          menuUpdate(items, function() goto_(self.confirmBack or "main") end)
          self._confirmItems = items
          return
        end

        local map = {
          main = function() return mainItems(), function() game.stack:pop() end end,
          account = function() return accountItems(), function() goto_("main") end end,
          question = function() return questionItems(), function() Sync.answer("later") goto_("main") end end,
          netinfo = function() return { { "Back", function() goto_("main") end } },
            function() goto_("main") end end,
          key = function() return { { "I wrote it down", function() goto_("main") end } },
            function() goto_("main") end end,
        }

        if self.view == "slots" then
          local rows = slotRows()
          local items = {}
          for _, row in ipairs(rows) do
            items[#items + 1] = { row.label, function()
              self.slotRow = row
              goto_("slotmenu")
            end }
          end
          items[#items + 1] = { "Back", function() goto_("main") end }
          menuUpdate(items, function() goto_("main") end)
          return
        end

        if self.view == "slotmenu" then
          menuUpdate(slotItems(self.slotRow or {}), function() goto_("slots") end)
          return
        end

        if self.view == "pick" then
          local items = {}
          for _, choice in ipairs(self.list or {}) do
            items[#items + 1] = { choice.label, function()
              uploadFlow(self.pickTarget, choice.key)
            end }
          end
          items[#items + 1] = { "Back", function() goto_("slots") end }
          menuUpdate(items, function() goto_("slots") end)
          return
        end

        if self.view == "snapshots" then
          local items = {}
          for _, entry in ipairs(self.list or {}) do
            items[#items + 1] = { tostring(entry.label or entry.name):sub(1, 16), function()
              self:confirm({
                "Restore this snapshot?",
                "The current position is snapshotted first.",
              }, "Restore", function()
                local ok, err = Snapshot.restore(self.game, entry.key, entry.name)
                say(ok and "Restored." or tostring(err or "could not restore"))
                goto_("main")
              end)
            end }
          end
          items[#items + 1] = { "Back", function() goto_("main") end }
          menuUpdate(items, function() goto_("main") end)
          return
        end

        local entry = map[self.view]
        if entry then
          local items, onB = entry()
          menuUpdate(items, onB)
        else
          goto_("main")
        end
      end

      function self:draw()
        if self.view == "text" then drawText() return end

        if self.view == "confirm" then
          Font.drawBox(0, 0, 20, 18)
          Font.draw("SAVESYNC", 8, 8)
          local y = 24
          for _, line in ipairs(self.confirmLines or {}) do
            y = drawWrapped(8, y, line, 3) + 2
          end
          local items = self._confirmItems or {}
          local ry = math.max(y + 4, 100)
          for i, it in ipairs(items) do
            Font.draw(it[1], 20, ry)
            if self.cursor == i then Font.drawCode(Theme.cursor, 12, ry) end
            ry = ry + 12
          end
          return
        end

        if self.view == "linking" then
          Font.drawBox(0, 0, 20, 18)
          Font.draw("SAVESYNC", 8, 8)
          local link = Sync.link
          drawWrapped(8, 40, (link and link.status) or "Working...", 4)
          Font.draw("B: cancel", 8, 128)
          return
        end

        if self.view == "key" then
          Font.drawBox(0, 0, 20, 18)
          Font.draw("RECOVERY KEY", 8, 8)
          local code = (Sync.link and Sync.link.recoveryCode)
            or Store.config().recoveryCode or "?"
          local y = drawWrapped(8, 24, code, 4)
          y = drawWrapped(8, y + 4,
            "Write this down. If you lose your password AND this code, the"
            .. " account is gone -- nobody can restore it.", 5)
          Font.draw("A: I wrote it down", 8, 128)
          return
        end

        if self.view == "question" then
          local q = Sync.question
          Font.drawBox(0, 0, 20, 18)
          Font.draw("SYNC QUESTION", 8, 8)
          local y = 24
          if q then
            if q.kind == "slot_conflict" then
              y = drawWrapped(8, y, "Slot " .. tostring(q.slot) .. " holds another save:", 2)
              y = drawWrapped(8, y, describeServer(q.have), 2) + 4
              y = drawWrapped(8, y, "Yours: " .. tostring(q.localLabel), 2)
            else
              y = drawWrapped(8, y, "Both this device and the server changed:", 3)
              y = drawWrapped(8, y, "Server: " .. describeServer(q.have), 2)
              y = drawWrapped(8, y, "Here: " .. tostring(q.localLabel), 2)
            end
          end
          local items = questionItems()
          local ry = 96
          for i, it in ipairs(items) do
            Font.draw(it[1], 20, ry)
            if self.cursor == i then Font.drawCode(Theme.cursor, 12, ry) end
            ry = ry + 12
          end
          return
        end

        if self.view == "netinfo" then
          Font.drawBox(0, 0, 20, 18)
          Font.draw("NETWORK", 8, 8)
          local lines = {
            "Server: " .. tostring(cfgOpts.host or "?"),
            "Transport: " .. (Link.transportAvailable() and "sockets OK" or "MISSING"),
            "Tunnel: encrypted,",
            "identity pinned",
          }
          local y = 24
          for _, l in ipairs(lines) do y = drawWrapped(8, y, l, 2) end
          drawWrapped(8, y + 4,
            "Accounts here also work in Gen1MMO, and the other way around.", 4)
          Font.draw("B: back", 8, 128)
          return
        end

        -- list views share the frame
        if self.view == "slots" then
          local rows = slotRows()
          local items = {}
          for _, row in ipairs(rows) do items[#items + 1] = { row.label } end
          items[#items + 1] = { "Back" }
          menuDraw("CLOUD SLOTS", items, {
            "Saves expire after " .. tostring((Sync.link and Sync.link.expiryDays) or 30)
              .. "d untouched.",
          })
          return
        end
        if self.view == "slotmenu" then
          local row = self.slotRow or {}
          menuDraw("SLOT " .. tostring(row.slot or "?"),
            slotItems(row), { describeServer(row.server) })
          return
        end
        if self.view == "pick" then
          local items = {}
          for _, choice in ipairs(self.list or {}) do items[#items + 1] = { choice.label } end
          items[#items + 1] = { "Back" }
          menuDraw("SEND WHICH SAVE?", items)
          return
        end
        if self.view == "snapshots" then
          local items = {}
          for _, entry in ipairs(self.list or {}) do
            items[#items + 1] = { tostring(entry.label or entry.name):sub(1, 16) }
          end
          items[#items + 1] = { "Back" }
          menuDraw("SNAPSHOTS", items)
          return
        end
        if self.view == "account" then
          menuDraw("ACCOUNT", accountItems(), {
            "One account works in SaveSync AND Gen1MMO.",
          })
          return
        end

        -- main
        local status
        if Sync.configured() then
          status = "Signed in as " .. tostring(Sync.accountName())
          if Sync.state == "working" then status = Sync.status or "Syncing..." end
          if Sync.state == "error" and Sync.status then status = Sync.status end
        else
          status = "Not signed in"
        end
        menuDraw("SAVESYNC", mainItems(), {
          status,
          "Last synced: " .. Util.ago(Store.config().lastSync or 0),
        })
      end

      return self
    end,
  })
end
