-- The Cloud Saves screen.
--
-- The whole design brief for this file is the four lines the player should
-- ever have to read:
--
--     CLOUD SAVES
--     Connected
--     Last synced: just now
--     Sync Now / Pair Another Device / Restore Previous Save
--
-- Everything else -- providers, device codes, conflicts, history -- is a view
-- the player is taken to only when they ask for it, or when something has
-- gone wrong and a decision is genuinely theirs to make.
--
-- Drawn with the confirmed mod toolkit only (mod.ui.Font + game.input), the
-- same surfaces the engine's own menus use.  The Gen 1 charmap has no ">",
-- "_" or check-mark tile, so the cursor is the vanilla filled arrow
-- (Theme.cursor) and the "connected" tick is drawn as three rectangles.

local Sync = CLOUD_SAVES_INCLUDE("src/sync.lua")
local Store = CLOUD_SAVES_INCLUDE("src/store.lua")
local Pairing = CLOUD_SAVES_INCLUDE("src/pairing.lua")
local Providers = CLOUD_SAVES_INCLUDE("src/providers/init.lua")
local Util = CLOUD_SAVES_INCLUDE("src/util.lua")

local VISIBLE = 7            -- menu rows that fit between title and footer

return function(mod, cfgOpts)
  mod.content.screens:register("CloudSaves", {
    new = function(game)
      local Font = mod.ui.Font
      local Theme = mod.ui.Theme
      local self = { game = game, isOpaque = true }
      local input = game.input

      self.view = "main"
      self.cursor = 1
      self.scroll = 0
      self.message = nil          -- one-line feedback under the title
      self.link = nil             -- live link state during Set Up
      self.linkOp = nil
      self.list = nil             -- rows for restore/history views
      self.pendingRestore = nil

      -- ------------------------------------------------------- helpers

      local function say(msg) self.message = msg end

      local function clipboardGet()
        local ok, text = pcall(function()
          return love.system and love.system.getClipboardText
            and love.system.getClipboardText()
        end)
        return ok and type(text) == "string" and text or nil
      end

      local function clipboardSet(text)
        pcall(function()
          if love.system and love.system.setClipboardText then
            love.system.setClipboardText(text)
          end
        end)
      end

      local function openUrl(url)
        local ok = pcall(function()
          return love.system and love.system.openURL and love.system.openURL(url)
        end)
        return ok
      end

      -- Some devices have no clipboard at all.  A plain text file beside the
      -- save is the escape hatch: put the code in cloud_saves/setup-code.txt
      -- and the game reads it.  It costs three lines and it means nobody is
      -- ever stranded by a platform without a clipboard.
      local CODE_FILE = "cloud_saves/setup-code.txt"
      local function codeFromFile()
        if not (love and love.filesystem and love.filesystem.getInfo(CODE_FILE)) then
          return nil
        end
        return love.filesystem.read(CODE_FILE)
      end

      local function goto_(view)
        self.view = view
        self.cursor = 1
        self.scroll = 0
      end

      -- --------------------------------------------------- menu models

      local function mainItems()
        local items = {}
        if not Sync.configured() then
          items[#items + 1] = { "Set Up", function() goto_("setup") end }
          return items
        end
        items[#items + 1] = { "Sync Now", function()
          Sync.request(true)
          say("Syncing...")
        end }
        items[#items + 1] = { "Pair Another Device", function() goto_("pair") end }
        items[#items + 1] = { "Restore Previous Save", function()
          self.list = nil
          goto_("restorePick")
        end }
        items[#items + 1] = {
          "Auto sync: " .. (Store.config().auto and "ON" or "OFF"),
          function()
            local c = Store.config()
            c.auto = not c.auto
            Store.saveConfig(c)
          end }
        items[#items + 1] = { "Disconnect", function() goto_("disconnect") end }
        return items
      end

      local function setupItems()
        local items = {}
        for _, p in ipairs(Providers.choosable()) do
          items[#items + 1] = { p.label, function() self:startLink(p) end }
        end
        items[#items + 1] = { "Use a setup code", function()
          self.link = { pasteOnly = true }
          goto_("paste")
        end }
        items[#items + 1] = { "Back", function() goto_("main") end }
        return items
      end

      local function pairItems()
        local c = Store.config()
        local code = Pairing.encode(c.provider, c.cfg)
        local items = {}
        if code then
          items[#items + 1] = { "Copy code", function()
            clipboardSet(code)
            say("Copied. Paste it on the other device.")
          end }
        end
        items[#items + 1] = { "Back", function() goto_("main") end }
        return items
      end

      local function conflictItems()
        local key = self.conflictKey
        return {
          { "Keep this device", function()
            Sync.runForeground(Sync.resolveKeepLocal(key),
              "Uploading this device's save...", "Kept this device's save")
            goto_("main")
          end },
          { "Use the cloud save", function()
            Sync.runForeground(Sync.resolveUseCloud(key),
              "Downloading the cloud save...", "Cloud save restored")
            goto_("main")
          end },
          { "Decide later", function() goto_("main") end },
        }
      end

      -- ------------------------------------------------------ set up

      function self:startLink(provider)
        self.link = { provider = provider }
        local opts = { clientId = cfgOpts.clientIds[provider.id] }
        if provider.linkStyle == "paste" then
          goto_("paste")
          return
        end
        self.linkOp = provider.link(self.link, opts)
        goto_(provider.linkStyle == "browser" and "browser" or "device")
      end

      -- A pasted string is either a setup code (adopt it wholesale) or, in
      -- the Dropbox browser flow, the authorization code that op is waiting
      -- for.  One entry point handles both so the player never has to know
      -- which kind of string they are holding.
      function self:acceptPaste(text)
        if not text or text == "" then
          say("Nothing to paste. Copy the code first.")
          return
        end
        if self.link and self.link.awaitPaste then
          self.link.pasted = text
          say("Checking...")
          goto_("device")
          return
        end
        local payload, err = Pairing.decode(text)
        if not payload then
          say(err or "that code did not work")
          return
        end
        local provider = Providers.get(payload.provider)
        self.link = { provider = provider, pasted = payload }
        local linker = provider.adopt or provider.link
        self.linkOp = linker(self.link, { clientId = payload.clientId })
        goto_("device")
      end

      local function finishLink(cfg)
        local c = Store.config()
        c.provider, c.cfg = cfg.provider, cfg
        c.keys = {}
        Store.saveConfig(c)
        Sync.conflicts = {}
        Sync.request(true)
        self.link, self.linkOp = nil, nil
        goto_("main")
        say("Connected. Syncing your saves...")
      end

      -- ------------------------------------------------------ restore

      local function loadLocalBackups()
        local rows = {}
        for key in pairs(Store.readAllLocal()) do
          for _, b in ipairs(Store.listBackups(key)) do
            rows[#rows + 1] = { key = key, name = b.name, when = b.when,
                                tag = b.tag, where = "local" }
          end
        end
        -- Keys with no local save can still have backups from a previous
        -- restore; the list above only walks live saves, which is the case
        -- that matters and keeps this from scanning the whole folder tree.
        table.sort(rows, function(a, b) return a.name > b.name end)
        return rows
      end

      local function doRestore(row)
        if row.where == "local" then
          local ok, err = Store.restoreBackup(Store.versionOfKey(row.key),
            row.key, row.name)
          if ok then
            Sync.resetBookkeeping()
            Sync.request(true)
            say("Restored. It will sync to the cloud.")
          else
            say(err or "could not restore that save")
          end
          goto_("main")
        else
          Sync.runForeground(Sync.restoreHistory(row.key, row.name),
            "Restoring from the cloud...", "Restored from the cloud")
          goto_("main")
        end
      end

      -- ---------------------------------------------------- update

      local function currentItems()
        if self.view == "main" then return mainItems() end
        if self.view == "setup" then return setupItems() end
        if self.view == "pair" then return pairItems() end
        if self.view == "conflict" then return conflictItems() end
        if self.view == "disconnect" then
          return {
            { "Yes, disconnect", function()
              Store.forget()
              Sync.state, Sync.status = "off", ""
              say("Disconnected. Your saves are still on this device.")
              goto_("main")
            end },
            { "No, keep it", function() goto_("main") end },
          }
        end
        if self.view == "paste" then
          local items = {
            { "Paste from clipboard", function()
              self:acceptPaste(clipboardGet())
            end },
          }
          if codeFromFile() then
            items[#items + 1] = { "Read setup-code.txt", function()
              self:acceptPaste(codeFromFile())
            end }
          end
          items[#items + 1] = { "Back", function() goto_("main") end }
          return items
        end
        if self.view == "browser" then
          local items = {}
          if self.link and self.link.authUrl then
            items[#items + 1] = { "Open sign-in page", function()
              openUrl(self.link.authUrl)
            end }
            items[#items + 1] = { "Paste the code", function()
              self:acceptPaste(clipboardGet())
            end }
          end
          items[#items + 1] = { "Cancel", function()
            if self.link then self.link.cancelled = true end
            if self.linkOp then self.linkOp:cancel() end
            self.link, self.linkOp = nil, nil
            goto_("main")
          end }
          return items
        end
        if self.view == "device" then
          local items = {}
          if self.link and self.link.verifyUrl then
            items[#items + 1] = { "Open the page", function()
              openUrl(self.link.verifyUrl)
            end }
            if self.link.userCode then
              items[#items + 1] = { "Copy the code", function()
                clipboardSet(self.link.userCode)
                say("Copied.")
              end }
            end
          end
          items[#items + 1] = { "Cancel", function()
            if self.linkOp then self.linkOp:cancel() end
            self.link, self.linkOp = nil, nil
            goto_("main")
          end }
          return items
        end
        if self.view == "restorePick" then
          local items = {
            { "From this device", function()
              self.list = loadLocalBackups()
              self.listKind = "local"
              goto_("restoreList")
            end },
          }
          if Sync.configured() then
            items[#items + 1] = { "From the cloud", function()
              local first = next(Store.readAllLocal())
              if not first then
                say("No save on this device to match up.")
                return
              end
              self.list = nil
              self.listKind = "cloud"
              self.historyKey = first
              self.historyOp = Sync.history(first)
              goto_("restoreList")
            end }
          end
          items[#items + 1] = { "Back", function() goto_("main") end }
          return items
        end
        if self.view == "restoreList" then
          local items = {}
          for _, row in ipairs(self.list or {}) do
            local label = row.where == "local"
              and (row.when .. " " .. row.tag)
              or ("version " .. tostring(row.seq))
            items[#items + 1] = { label, function()
              self.pendingRestore = row
              goto_("confirmRestore")
            end }
          end
          items[#items + 1] = { "Back", function() goto_("restorePick") end }
          return items
        end
        if self.view == "confirmRestore" then
          return {
            { "Yes, restore it", function()
              doRestore(self.pendingRestore)
            end },
            { "No", function() goto_("restoreList") end },
          }
        end
        return { { "Back", function() goto_("main") end } }
      end

      local function clampScroll(count)
        self.scroll = math.min(self.scroll, math.max(0, count - VISIBLE))
        if self.cursor - self.scroll > VISIBLE then
          self.scroll = self.cursor - VISIBLE
        elseif self.cursor - self.scroll < 1 then
          self.scroll = self.cursor - 1
        end
      end

      function self:update(_dt)
        -- A conflict outranks whatever the player was doing: it is the one
        -- state where sync has stopped and only they can restart it.
        if Sync.state == "conflict" and self.view == "main" then
          local key = next(Sync.conflicts)
          if key then
            self.conflictKey = key
            goto_("conflict")
          end
        end

        if self.linkOp then
          local st, value = self.linkOp:poll()
          if st == "ok" then
            self.linkOp = nil
            finishLink(value)
          elseif st == "error" then
            self.linkOp = nil
            say(tostring(value))
            goto_("setup")
          end
        end

        if self.historyOp then
          local st, value = self.historyOp:poll()
          if st == "ok" then
            self.historyOp = nil
            self.list = {}
            for _, h in ipairs(value) do
              self.list[#self.list + 1] = { key = self.historyKey,
                name = h.name, seq = h.seq, where = "cloud" }
            end
            if #self.list == 0 then say("No older versions in the cloud yet.") end
          elseif st == "error" then
            self.historyOp = nil
            say(tostring(value))
          end
        end

        local items = currentItems()
        clampScroll(#items)

        if input:wasPressed("up") then
          self.cursor = self.cursor > 1 and self.cursor - 1 or #items
        elseif input:wasPressed("down") then
          self.cursor = self.cursor < #items and self.cursor + 1 or 1
        elseif input:wasPressed("a") then
          local it = items[self.cursor]
          if it then it[2]() end
        elseif input:wasPressed("b") then
          if self.view == "main" then
            self.game.stack:pop()
          elseif self.view == "restoreList" then
            goto_("restorePick")
          else
            goto_("main")
          end
        end
        clampScroll(#currentItems())
      end

      function self:onTap(cx, cy)
        local items = currentItems()
        for row = 1, VISIBLE do
          local i = self.scroll + row
          if not items[i] then break end
          local y = self.rowsTop + (row - 1) * 12
          if cy >= y - 4 and cy <= y + 9 then
            self.cursor = i
            items[i][2]()
            return
          end
        end
      end

      -- ------------------------------------------------------- draw

      -- The Gen 1 charmap has no check-mark tile, so the connected tick is
      -- drawn rather than typed.
      local function drawTick(x, y)
        local r, g, b, a = love.graphics.getColor()
        love.graphics.setColor(0, 0, 0, 1)
        love.graphics.rectangle("fill", x, y + 3, 2, 2)
        love.graphics.rectangle("fill", x + 2, y + 5, 2, 2)
        love.graphics.rectangle("fill", x + 4, y + 3, 2, 2)
        love.graphics.rectangle("fill", x + 6, y + 1, 2, 2)
        love.graphics.setColor(r, g, b, a)
      end

      -- The lines UNDER the "Connected" header: where the saves live, and
      -- what sync is doing about them right now.
      local function statusLines()
        if not Sync.configured() then
          return { "Not set up yet.", "Keep your saves on all", "your devices." }
        end
        local lines = { Sync.describe() }
        if Sync.state == "working" then
          lines[#lines + 1] = Sync.status
        elseif Sync.state == "conflict" then
          lines[#lines + 1] = "Two devices changed a save"
        elseif Sync.state == "offline" then
          lines[#lines + 1] = "Offline - will retry"
        elseif Sync.state == "error" then
          lines[#lines + 1] = Sync.status
        else
          lines[#lines + 1] = "Last synced: "
            .. Util.ago(Store.config().lastSync or 0)
        end
        return lines
      end

      function self:draw()
        Font.drawBox(0, 0, 20, 18)
        Font.draw("CLOUD SAVES", 16, 8)

        local y = 22
        if Sync.configured() and Sync.state ~= "conflict" then
          Font.draw("Connected", 16, y)
          drawTick(92, y)
        end
        for _, line in ipairs(statusLines()) do
          Font.draw(line:sub(1, 19), 8, y + 12)
          y = y + 12
        end

        if self.message then
          Font.draw(self.message:sub(1, 19), 8, y + 12)
          y = y + 12
        end

        -- View-specific detail above the menu.
        if self.view == "device" and self.link then
          if self.link.userCode then
            Font.draw("Code: " .. self.link.userCode, 8, y + 12)
            y = y + 12
          end
          if self.link.verifyUrl then
            Font.draw(self.link.verifyUrl:gsub("^https://", ""):sub(1, 19), 8, y + 12)
            y = y + 12
          end
          if self.link.message then
            Font.draw(self.link.message:sub(1, 19), 8, y + 12)
            y = y + 12
          end
        elseif self.view == "browser" and self.link then
          Font.draw("Sign in, copy the", 8, y + 12)
          Font.draw("code, come back.", 8, y + 24)
          y = y + 24
        elseif self.view == "paste" then
          Font.draw("Copy the code on the", 8, y + 12)
          Font.draw("other device first.", 8, y + 24)
          y = y + 24
        elseif self.view == "pair" then
          local c = Store.config()
          local code = Pairing.encode(c.provider, c.cfg)
          if c.provider == "github" then
            Font.draw("Easiest: sign in with", 8, y + 12)
            Font.draw("GitHub over there.", 8, y + 24)
            y = y + 24
          elseif code then
            for i, line in ipairs(Pairing.wrap(code, 19)) do
              if i > 4 then break end
              Font.draw(line, 8, y + 12)
              y = y + 10
            end
            if #code > 76 then Font.draw("...", 8, y + 12); y = y + 10 end
          end
        elseif self.view == "conflict" then
          local con = Sync.conflicts[self.conflictKey]
          if con then
            Font.draw("This device:", 8, y + 12)
            Font.draw(" " .. (con.localRec.summary
              and (tostring(con.localRec.summary.badges or 0) .. " badges "
                   .. tostring(con.localRec.summary.timeText or "")) or "save"),
              8, y + 24)
            Font.draw("Cloud (" .. tostring(con.cloud.deviceName or "?"):sub(1, 9)
              .. "):", 8, y + 36)
            Font.draw(" " .. tostring(con.cloud.badges or 0) .. " badges "
              .. tostring(con.cloud.time or ""), 8, y + 48)
            y = y + 48
          end
        elseif self.view == "confirmRestore" and self.pendingRestore then
          Font.draw("Replace the save on", 8, y + 12)
          Font.draw("this device?", 8, y + 24)
          y = y + 24
        elseif self.view == "disconnect" then
          Font.draw("Stop syncing on this", 8, y + 12)
          Font.draw("device? Saves stay.", 8, y + 24)
          y = y + 24
        end

        local items = currentItems()
        self.rowsTop = math.min(y + 18, 132 - math.min(#items, VISIBLE) * 12 + 12)
        for row = 1, VISIBLE do
          local i = self.scroll + row
          local it = items[i]
          if not it then break end
          local ry = self.rowsTop + (row - 1) * 12
          if ry > 132 then break end
          Font.draw(it[1]:sub(1, 17), 20, ry)
          if self.cursor == i then Font.drawCode(Theme.cursor, 12, ry) end
        end
        if self.scroll + VISIBLE < #items then
          Font.drawCode(Theme.moreArrow, 144, 134)
        end
      end

      return self
    end,
  })
end
