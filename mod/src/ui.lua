-- The SaveSync screen.
--
-- The whole design brief for this file is the four lines the player should
-- ever have to read:
--
--     SAVESYNC
--     Connected
--     Last synced: just now
--     Sync Now / Pair Device / Restore Old Save
--
-- Everything else -- providers, device codes, conflicts, history, snapshots
-- -- is a view the player is taken to only when they ask for it, or when
-- something has gone wrong and a decision is genuinely theirs to make.
--
-- Drawn with the confirmed mod toolkit only (mod.ui.Font + game.input), the
-- same surfaces the engine's own menus use.  The Gen 1 charmap has no ">",
-- "_", "*" or check-mark tile, so the cursor is the vanilla filled arrow
-- (Theme.cursor), the "connected" tick is drawn as three rectangles, and
-- overflow is a plain "..." rather than an ellipsis glyph.
--
-- TWO KINDS OF TEXT, TWO RULES.  Menu row labels are single-line and never
-- wrap -- every one of them is a fixed string chosen to fit inside roughly
-- 17 characters, with :sub() kept only as a last-resort safety net, never as
-- the plan.  Status lines and player-facing messages are the opposite: they
-- can carry arbitrary text from the engine or a provider (an OAuth error, an
-- HTTP status line), so they run through Util.wrap and get several rows to
-- land in instead of being cut at a fixed column -- a player who cannot read
-- an error cannot act on it.

local Sync = SAVESYNC_INCLUDE("src/sync.lua")
local Store = SAVESYNC_INCLUDE("src/store.lua")
local Pairing = SAVESYNC_INCLUDE("src/pairing.lua")
local Providers = SAVESYNC_INCLUDE("src/providers/init.lua")
local Util = SAVESYNC_INCLUDE("src/util.lua")
local Autosave = SAVESYNC_INCLUDE("src/autosave.lua")
local Snapshot = SAVESYNC_INCLUDE("src/snapshot.lua")

-- THE LAYOUT BUDGET, in one place.
--
-- The header used to flow with its content while the rows were clamped
-- upward to fit, so a wrapped status line and the menu drew on top of each
-- other. Fixed regions are the only thing that works at 160x144, and keeping
-- them here (rather than as locals inside draw) is what lets a test assert
-- they still add up.
local BOX_BOTTOM = 132       -- last y a row may occupy inside the border
local HEADER_TOP, HEADER_SLOTS = 22, 4
local ROWS_TOP, ROW_COUNT = 72, 5
local VISIBLE = ROW_COUNT    -- cursor window; a mismatch scrolls it out of sight
local WRAP_WIDTH = 19        -- columns available to text starting at x=8

return function(mod, cfgOpts)
  mod.content.screens:register("SaveSync", {
    new = function(game)
      local Font = mod.ui.Font
      local Theme = mod.ui.Theme
      local self = { game = game, isOpaque = true }
      local input = game.input

      -- Exposed so the loader test can prove the regions still do not
      -- overlap, which no drawing test can check without real font sheets.
      self.layout = { headerTop = HEADER_TOP, headerSlots = HEADER_SLOTS,
                      rowsTop = ROWS_TOP, rowCount = ROW_COUNT,
                      visible = VISIBLE, boxBottom = BOX_BOTTOM }

      self.view = "main"
      self.cursor = 1
      self.scroll = 0
      self.message = nil          -- one-line feedback under the title
      self.link = nil             -- live link state during Set Up
      self.linkOp = nil
      self.list = nil             -- rows for restore/history/snapshot views
      self.pendingRestore = nil
      self.pendingSnapRestore = nil

      -- ------------------------------------------------------- helpers

      local function say(msg) self.message = msg end

      -- Word-wrap `text` and draw up to `maxLines` of it starting at
      -- (x, y), returning the y position just past what was drawn.  If the
      -- text still does not fit in that many lines, the LAST one is cut to
      -- make room for "..." -- the one place a truncation is acceptable,
      -- because there is nowhere left on a 160x144 screen to put the rest.
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
      -- save is the escape hatch: put the code in savesync/setup-code.txt
      -- and the game reads it.  It costs three lines and it means nobody is
      -- ever stranded by a platform without a clipboard.
      local CODE_FILE = "savesync/setup-code.txt"
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

      -- ------------------------------------------------- the reader
      --
      -- WHY A SEPARATE VIEW.  UP/DOWN already drive the menu cursor, so
      -- scrolling text with the same keys on the same screen means one of the
      -- two silently stops working depending on where the cursor is -- the
      -- kind of thing that reads as a broken game.  Long text therefore gets
      -- its own full-screen view, entered deliberately and left with B.
      -- Nothing else is on screen, so UP/DOWN can only mean one thing.
      --
      -- This exists because a real player hit `GitHub said HTTP 400`, saw it
      -- cut to `GitHub said HTTP 40`, and could not tell 400 from 404.  An
      -- error the player cannot finish reading is a bug.
      local READER_ROWS = 8

      -- Clamp a scroll offset so neither end can be overshot.  Separate from
      -- the drawing so it can be tested without a font.
      function self.clampReader(offset, total, rows)
        local maxOffset = math.max(0, total - rows)
        if offset < 0 then return 0 end
        if offset > maxOffset then return maxOffset end
        return offset
      end

      function self:openReader(title, text)
        self.reader = { title = title or "DETAILS",
                        lines = Util.wrap(text or "", WRAP_WIDTH), scroll = 0 }
        goto_("reader")
      end

      -- The text worth offering a reader for: whatever the player is most
      -- likely to be squinting at right now.
      local function longText()
        local candidates = { self.message, Sync.status }
        for _, t in ipairs(candidates) do
          if t and t ~= "" and #Util.wrap(t, WRAP_WIDTH) > 2 then return t end
        end
        return nil
      end


      -- --------------------------------------------------- menu models

      -- Auto save has nothing to do with the cloud -- it is worth having on a
      -- machine that will never be set up -- so its row appears whether or
      -- not a provider is connected, and Restore Old Save comes with it (an
      -- autosave is only safe to offer if it is undoable).
      local function autosaveRow()
        return { "Auto save: " .. Autosave.label(), function()
          Autosave.cycle()
          if Autosave.minutes() > 0 then
            say("Saves every " .. Autosave.label() .. " when walking.")
          else
            say("Auto save off.")
          end
        end }
      end

      -- Snapshots sit next to auto save for the same reason: they work with
      -- no cloud connected, so they belong above the line where a provider
      -- decides what the rest of the menu even shows.  Hidden entirely on an
      -- engine build with no checkpoint support -- Snapshot.available()
      -- already answers that question, so nothing here re-derives it.
      local function snapshotRows()
        if not Snapshot.available() then return {} end
        local rows = {}
        rows[#rows + 1] = { "Auto snap: " .. Autosave.snapshotLabel(), function()
          Autosave.cycleSnapshot()
          if Autosave.snapshotMinutes() > 0 then
            say("Snapshots every " .. Autosave.snapshotLabel() .. ".")
          else
            say("Auto snapshot off.")
          end
        end }
        rows[#rows + 1] = { "Take Snapshot", function()
          local name, err = Snapshot.take(self.game, "manual")
          if name then
            Autosave.noteSnapshotTaken()
            say("Snapshot saved.")
          else
            -- The engine's own refusal, verbatim -- it explains exactly why
            -- ("Close the active menu or screen..."), and inventing a worse
            -- one here would only make the player guess.
            say(err or "could not snapshot")
          end
        end }
        rows[#rows + 1] = { "Restore Snapshot", function()
          local cap = Snapshot.inspect(self.game)
          if not cap.canRestore then
            say(cap.message or "cannot restore right now")
            return
          end
          local save = self.game and self.game.save
          local key = save and Snapshot.keyFor({ identity = {
            gameVersion = save.version,
            playthroughId = save.meta and save.meta.playthroughId,
          } })
          if not key then
            say("this playthrough has no identity yet")
            return
          end
          self.snapshotKey = key
          self.list = Snapshot.list(key)
          if #self.list == 0 then
            say("No snapshots yet.")
            return
          end
          goto_("snapList")
        end }
        return rows
      end

      local function mainItems()
        local items = {}
        -- Only offered when there is genuinely more text than fits: a row
        -- that is always present but usually says nothing is worse than no
        -- row at all on a screen this small.
        local long = longText()
        if long then
          items[#items + 1] = { "Read full message", function()
            self:openReader("MESSAGE", long)
          end }
        end
        if not Sync.configured() then
          items[#items + 1] = { "Set Up", function() goto_("setup") end }
          items[#items + 1] = autosaveRow()
          for _, row in ipairs(snapshotRows()) do items[#items + 1] = row end
          items[#items + 1] = { "Restore Old Save", function()
            self.list = nil
            goto_("restorePick")
          end }
          return items
        end
        items[#items + 1] = { "Sync Now", function()
          Sync.request(true)
          say("Syncing...")
        end }
        items[#items + 1] = { "Save files", function()
          self.slotRows = Store.slotOverview(Sync.conflicts)
          goto_("slots")
        end }
        items[#items + 1] = { "Pair Device", function() goto_("pair") end }
        items[#items + 1] = { "Restore Old Save", function()
          self.list = nil
          goto_("restorePick")
        end }
        items[#items + 1] = autosaveRow()
        for _, row in ipairs(snapshotRows()) do items[#items + 1] = row end
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
          { "Use cloud save", function()
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

      -- `onlyKey` scopes the list to one save file. Picking a slot first and
      -- then a version of it is far easier to reason about than one flat list
      -- of every backup on the device, which on a multi-slot install is a
      -- wall of timestamps with no way to tell whose they are.
      local function loadLocalBackups(onlyKey)
        local rows = {}
        for key in pairs(Store.readAllLocal()) do
          if not onlyKey or key == onlyKey then
          for _, b in ipairs(Store.listBackups(key)) do
            rows[#rows + 1] = { key = key, name = b.name, when = b.when,
                                tag = b.tag, where = "local" }
          end
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
        if self.view == "reader" then return {} end
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
            { "Paste clipboard", function()
              self:acceptPaste(clipboardGet())
            end },
          }
          if codeFromFile() then
            items[#items + 1] = { "Read code file", function()
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
        if self.view == "slots" then
          local items = {}
          for _, row in ipairs(self.slotRows or {}) do
            -- "RED 1 synced" fits the 17-column budget where the slot id and
            -- a full status word would not.
            local n = tostring(row.slotId or "?"):match("(%d+)$") or "?"
            local label = ("%s %s %s"):format(
              tostring(row.version):upper():sub(1, 6), n, row.status)
            items[#items + 1] = { label, function()
              self.restoreKey = row.key
              self.list = loadLocalBackups(row.key)
              self.listKind = "local"
              goto_("restoreList")
            end }
          end
          if #items == 0 then
            items[#items + 1] = { "No saves yet", function() goto_("main") end }
          end
          items[#items + 1] = { "Back", function() goto_("main") end }
          return items
        end

        if self.view == "restorePick" then
          local items = {
            { "From this device", function()
              self.restoreKey = nil
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
            -- "YYYY-MM-DD HH:MM replaced" does not fit a 17-character row.
            -- The list is newest-first and only ever spans a handful of
            -- months, not years, so the year is the part safe to drop; the
            -- tag is capped to four characters rather than relying on the
            -- fallback :sub() in the draw loop to cut a real word in half.
            local label = row.where == "local"
              and ((row.when and row.when:sub(6) or tostring(row.when))
                   .. " " .. tostring(row.tag or ""):sub(1, 4))
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
        if self.view == "snapList" then
          local items = {}
          for _, row in ipairs(self.list or {}) do
            items[#items + 1] = { row.when, function()
              self.pendingSnapRestore = row
              goto_("confirmSnapRestore")
            end }
          end
          items[#items + 1] = { "Back", function() goto_("main") end }
          return items
        end
        if self.view == "confirmSnapRestore" then
          return {
            { "Yes, restore it", function()
              local row = self.pendingSnapRestore
              local ok, err = Snapshot.restore(self.game, self.snapshotKey,
                row and row.name)
              if ok then
                say("Restored.")
              else
                say(err or "could not restore")
              end
              goto_("main")
            end },
            { "No", function() goto_("snapList") end },
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

        -- The reader owns the d-pad while it is open; falling through to the
        -- menu here is what would let a scroll silently move the cursor
        -- behind the text.
        if self.view == "reader" and self.reader then
          local r = self.reader
          if input:wasPressed("up") then
            r.scroll = self.clampReader(r.scroll - 1, #r.lines, READER_ROWS)
          elseif input:wasPressed("down") then
            r.scroll = self.clampReader(r.scroll + 1, #r.lines, READER_ROWS)
          elseif input:wasPressed("b") or input:wasPressed("a") then
            self.reader = nil
            goto_("main")
          end
          return
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
            goto_(self.restoreKey and "slots" or "restorePick")
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

      -- The charmap has no up-arrow glyph (Theme.moreArrow only points down),
      -- so the "more above" marker is drawn, mirroring the tick above.
      local function drawUpArrow(x, y)
        local r, g, b, a = love.graphics.getColor()
        love.graphics.setColor(0, 0, 0, 1)
        love.graphics.rectangle("fill", x + 3, y, 2, 2)
        love.graphics.rectangle("fill", x + 2, y + 2, 4, 2)
        love.graphics.rectangle("fill", x + 1, y + 4, 6, 2)
        love.graphics.setColor(r, g, b, a)
      end

      function self:draw()
        Font.drawBox(0, 0, 20, 18)

        if self.view == "reader" and self.reader then
          local r = self.reader
          Font.draw(r.title:sub(1, 17), 16, 8)
          for row = 1, READER_ROWS do
            local line = r.lines[r.scroll + row]
            if not line then break end
            Font.draw(line, 8, 24 + (row - 1) * 12)
          end
          if r.scroll > 0 then drawUpArrow(148, 22) end
          if r.scroll + READER_ROWS < #r.lines then
            Font.drawCode(Theme.moreArrow, 148, 122)
          end
          Font.draw("B: back", 8, 134)
          return
        end

        Font.draw("SAVESYNC", 16, 8)

        -- FIXED LAYOUT, NOT A FLOWING ONE.
        --
        -- The header used to grow with its content and the rows were then
        -- clamped UPWARD to fit -- so once the status wrapped onto a few
        -- lines, the rows were positioned above where the text ended and the
        -- two drew on top of each other. On a 160x144 screen there is no
        -- amount of cleverness that makes arbitrary text and a menu share the
        -- space: the only thing that works is giving each a fixed budget and
        -- sending the overflow somewhere it can be read properly.
        --
        -- Header: HEADER_SLOTS single lines from HEADER_TOP.
        -- Rows:   ROW_COUNT lines from ROWS_TOP, always inside the border.
        -- Anything longer than a slot is cut here and reachable in full
        -- through the reader.
        local slot = 0
        local function hdr(text)
          if not text or text == "" or slot >= HEADER_SLOTS then return end
          Font.draw(tostring(text):sub(1, WRAP_WIDTH), 8, HEADER_TOP + slot * 12)
          slot = slot + 1
        end

        if Sync.configured() and Sync.state ~= "conflict" then
          Font.draw("Connected", 16, HEADER_TOP)
          drawTick(92, HEADER_TOP)
          slot = 1
        end
        for _, line in ipairs(statusLines()) do hdr(line) end
        hdr(self.message)

        -- View-specific detail shares the same budget, so it can never push
        -- the menu off the screen either.
        if self.view == "device" and self.link then
          hdr(self.link.userCode and ("Code: " .. self.link.userCode) or nil)
          hdr(self.link.verifyUrl and (self.link.verifyUrl:gsub("^https://", "")) or nil)
          hdr(self.link.message)
        elseif self.view == "browser" and self.link then
          hdr("Sign in, copy the")
          hdr("code, come back.")
        elseif self.view == "paste" then
          hdr("Copy the code on")
          hdr("the other device.")
        elseif self.view == "pair" then
          local c = Store.config()
          local code = Pairing.encode(c.provider, c.cfg)
          if c.provider == "github" then
            hdr("Easiest: sign in")
            hdr("with GitHub there.")
          elseif code then
            -- A pairing code is far too long for the header budget, so show
            -- only that one exists; Copy code puts it on the clipboard and
            -- the reader shows it in full.
            hdr("Code ready. Copy it.")
          end
        elseif self.view == "conflict" then
          local con = Sync.conflicts[self.conflictKey]
          if con then
            local s2 = con.localRec.summary or {}
            hdr("Here: " .. tostring(s2.badges or 0) .. " badges")
            hdr("Cloud: " .. tostring(con.cloud.badges or 0) .. " badges")
            hdr("(" .. tostring(con.cloud.deviceName or "?"):sub(1, 12) .. ")")
          end
        elseif self.view == "confirmRestore" and self.pendingRestore then
          hdr("Replace the save on")
          hdr("this device?")
        elseif self.view == "confirmSnapRestore" and self.pendingSnapRestore then
          hdr("Restore this")
          hdr("snapshot?")
        elseif self.view == "disconnect" then
          hdr("Stop syncing here?")
          hdr("Your saves stay.")
        end

        local items = currentItems()
        self.rowsTop = ROWS_TOP
        for row = 1, ROW_COUNT do
          local i = self.scroll + row
          local it = items[i]
          if not it then break end
          local ry = ROWS_TOP + (row - 1) * 12
          Font.draw(it[1]:sub(1, 17), 20, ry)
          if self.cursor == i then Font.drawCode(Theme.cursor, 12, ry) end
        end
        if self.scroll > 0 then drawUpArrow(148, ROWS_TOP - 10) end
        if self.scroll + ROW_COUNT < #items then
          Font.drawCode(Theme.moreArrow, 148, ROWS_TOP + ROW_COUNT * 12 - 4)
        end
      end

      return self
    end,
  })
end
