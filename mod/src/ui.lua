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
local Http = SAVESYNC_INCLUDE("src/http.lua")

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
-- 18, not 19. Text starts at x=8 and the glyphs are 8 wide, so 19 columns
-- end at 160 -- exactly under the box's right border, which sliced the last
-- character off every full line ("no GitHub client i" on a real phone).
-- 18 leaves the same 8px margin on the right as the text has on the left.
local WRAP_WIDTH = 18        -- columns available to text starting at x=8

-- Restore lists are PAGED rather than scrolled. Ten backups plus ten cloud
-- versions is a long ribbon to drag a cursor through on a d-pad, and a player
-- picking a restore point wants to see a handful and step, not hunt. Four
-- entries plus "More" and "Back" is exactly what fits without the list
-- running past the border.
local PAGE_SIZE = 4

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
        -- A new view always starts on page one; carrying a page number across
        -- lists would open the cloud history on page three of the local one.
        self.page = 1
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

      -- Offered on any screen that can show a message too long for the
      -- header's four lines -- not only the main one.
      --
      -- IT USED TO BE MAIN-ONLY. A failed sign-in says why and returns to the
      -- PROVIDER LIST, where the reason was cut to four lines with no way to
      -- open it: the player was told to read a message they had no route to.
      -- Reaching it meant going Back to main, by which point the message had
      -- often been replaced.
      --
      -- Only added when there is genuinely more text than fits: a row that is
      -- always present but usually says nothing is worse than no row at all
      -- on a screen this small.
      local function readerRow(items)
        local long = longText()
        if long then
          items[#items + 1] = { "Read full message", function()
            self:openReader("MESSAGE", long)
          end }
        end
        return items
      end

      local function mainItems()
        local items = readerRow({})
        if not Sync.configured() then
          items[#items + 1] = { "Set Up", function() self:beginPreflight() end }
          items[#items + 1] = autosaveRow()
          for _, row in ipairs(snapshotRows()) do items[#items + 1] = row end
          items[#items + 1] = { "Restore Old Save", function()
            self.slotRows = Store.slotOverview(Sync.conflicts)
            self.restoreFlow = true
            goto_("slots")
          end }
          return items
        end
        -- ONLINE-ONLY ROWS ARE HIDDEN WHILE OFFLINE.
        --
        -- `Sync Now` and `Pair Device` both need the network the device has
        -- just failed to reach. Offering them anyway invites a player to
        -- press them, wait, and be told again what the header already says.
        -- A row that cannot work is worse than no row: it reads as something
        -- that might fix this, and it cannot.
        --
        -- Everything that works WITHOUT the network stays exactly where it
        -- is -- Save files, Restore Old Save, auto save, snapshots -- because
        -- being offline costs the cloud, not the saves.
        local offline = Sync.state == "offline" or Sync.state == "error"
        if not offline then
          items[#items + 1] = { "Sync Now", function()
            Sync.request(true)
            say("Syncing...")
          end }
        end
        items[#items + 1] = { "Save files", function()
          self.slotRows = Store.slotOverview(Sync.conflicts)
          goto_("slots")
        end }
        if not offline then
          items[#items + 1] = { "Pair Device", function() goto_("pair") end }
        else
          -- One row that DOES something useful here: try the connection
          -- again, rather than leaving the player to guess when it recovers.
          items[#items + 1] = { "Try again", function()
            Sync.request(true)
            say("Trying again...")
          end }
        end
        -- Choose the save FIRST, then a version of it. One flat list across
        -- every playthrough is how ten backups each became forty rows with no
        -- way to tell whose they were.
        items[#items + 1] = { "Restore Old Save", function()
          self.slotRows = Store.slotOverview(Sync.conflicts)
          self.restoreFlow = true
          goto_("slots")
        end }
        items[#items + 1] = autosaveRow()
        for _, row in ipairs(snapshotRows()) do items[#items + 1] = row end
        items[#items + 1] = {
          "Ask on save: " .. (Store.config().askOnSave ~= false and "ON" or "OFF"),
          function()
            local c = Store.config()
            c.askOnSave = (c.askOnSave == false)
            Store.saveConfig(c)
          end }
        items[#items + 1] = {
          "Auto sync: " .. (Store.config().auto ~= false and "ON" or "OFF"),
          function()
            local c = Store.config()
            c.auto = not c.auto
            Store.saveConfig(c)
          end }
        items[#items + 1] = { "Disconnect", function() goto_("disconnect") end }
        return items
      end

      -- BEFORE ANY SIGN-IN SCREEN, in two steps.
      --
      -- 1. CAN THIS APP REACH THE NETWORK AT ALL? Some builds ship no
      --    transport whatsoever -- no worker threads, no TLS module, no
      --    sockets. Offering a sign-in there walks the player through a
      --    browser round trip that cannot possibly complete. Phosphor on iOS
      --    is exactly this case.
      -- 2. IS THERE ACTUALLY AN INTERNET CONNECTION? A transport that exists
      --    still fails on a plane or behind a captive portal, and "your sign
      --    in did not work" is a much worse thing to be told than "this
      --    device is offline".
      --
      -- Only when both hold does the provider list appear.
      local PROBE_URL = "https://api.github.com/zen"

      function self:beginPreflight()
        if not Http.available() then
          self.preflight = { state = "noTransport" }
          goto_("preflight")
          return
        end
        if not Http.tlsCapable() then
          -- Nothing secure can be reached, so there is no useful probe to
          -- run: go straight in, where the list shows only what works here.
          self.preflight = { state = "ok" }
          goto_("setup")
          return
        end
        self.preflight = { state = "checking", job = Http.request({
          url = PROBE_URL,
          headers = { ["Accept"] = "text/plain" },
        }) }
        goto_("preflight")
      end

      function self:pollPreflight()
        local pf = self.preflight
        if not (pf and pf.job) then return end
        local st = Http.poll(pf.job)
        if st.status == "pending" then return end
        Http.release(pf.job)
        pf.job = nil
        -- Any answer at all proves the connection; the CONTENT is not the
        -- point, so an odd status code is still online.
        if st.status == "ok" then
          pf.state = "ok"
          goto_("setup")
        else
          pf.state = "offline"
          pf.detail = st.err
        end
      end

      local function preflightItems()
        local pf = self.preflight or {}
        if pf.state == "checking" then
          return { { "Cancel", function()
            if pf.job then Http.release(pf.job) end
            self.preflight = nil
            goto_("main")
          end } }
        end
        if pf.state == "noTransport" then
          local items = { { "Why not?", function()
            self:openReader("NETWORK", Http.diagnostics())
          end } }
          items[#items + 1] = { "Back", function()
            self.preflight = nil
            goto_("main")
          end }
          return items
        end
        -- offline
        return {
          { "Try again", function() self:beginPreflight() end },
          { "Set up anyway", function() goto_("setup") end },
          { "Back", function()
            self.preflight = nil
            goto_("main")
          end },
        }
      end

      local function setupItems()
        local items = readerRow({})
        local tls = Http.tlsCapable()
        for _, p in ipairs(Providers.choosable()) do
          -- A provider this device cannot reach is left out rather than
          -- offered and then failing: GitHub and Dropbox are HTTPS-only, and
          -- a build whose only transport is luasocket has no TLS at all.
          if tls or not p.needsTls then
            items[#items + 1] = { p.label, function() self:startLink(p) end }
          end
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
        -- `paired` marks WHICH flow this is, so the outcome can say "Paired"
        -- rather than the sign-in wording. A code that fails used to drop the
        -- player back on the provider list with a truncated message and no
        -- statement of what had just happened.
        self.link = { provider = provider, pasted = payload, paired = true }
        local linker = provider.adopt or provider.link
        self.linkOp = linker(self.link, { clientId = payload.clientId })
        say("Checking that code...")
        goto_("device")
      end

      local function finishLink(cfg)
        local paired = self.link and self.link.paired
        local c = Store.config()
        c.provider, c.cfg = cfg.provider, cfg
        c.keys = {}
        Store.saveConfig(c)
        Sync.conflicts = {}
        Sync.request(true)
        self.link, self.linkOp = nil, nil
        goto_("main")
        if paired then
          say("Paired. This device now shares those saves.")
        else
          say("Connected. Syncing your saves...")
        end
      end

      -- ------------------------------------------------------ restore

      -- `onlyKey` scopes the list to one save file. Picking a slot first and
      -- then a version of it is far easier to reason about than one flat list
      -- of every backup on the device, which on a multi-slot install is a
      -- wall of timestamps with no way to tell whose they are.
      -- "RED 1 08-12 00:09" -- game, slot, then when it was taken.
      -- NEVER CALL THIS PER FRAME. It is built once per list, because
      -- currentItems() runs three times a frame (twice in update, once in
      -- draw) and the slot lookup it used to do read and decoded EVERY save
      -- slot on disk. Ten backups by three slots by three calls was ninety
      -- full save decodes a frame, which froze the game hard enough to need
      -- a force quit. Labels are now computed when the list is built and
      -- stored on the row; the per-frame path only reads a string.
      local function restoreLabel(row, slotByKey)
        local version = Store.versionOfKey(row.key)
        local ver = tostring(version or "?"):upper():sub(1, 6)
        local slot = tostring(row.slotId
          or (slotByKey and slotByKey[row.key]) or "?"):match("(%d+)$") or "?"
        local when
        if row.stamp then
          -- cloud history stamp: "20260812-000913"
          when = row.stamp:sub(5, 6) .. "-" .. row.stamp:sub(7, 8) .. " "
            .. row.stamp:sub(10, 11) .. ":" .. row.stamp:sub(12, 13)
        elseif row.when then
          -- local backup: "2026-08-12 00:09" -- drop the year, it never helps
          when = tostring(row.when):sub(6)
        else
          -- a history entry written before names carried a stamp
          when = "v" .. tostring(row.seq or "?")
        end
        return ("%s %s %s"):format(ver, slot, when)
      end

      -- One pass over the slots for the whole list, rather than one per row.
      local function slotLookup()
        local map = {}
        for key, rec in pairs(Store.readAllLocal()) do map[key] = rec.slotId end
        return map
      end

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
        local map = slotLookup()
        for _, row in ipairs(rows) do row.label = restoreLabel(row, map) end
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

      -- Build the rows for one page of `list`, plus the navigation. `onPick`
      -- receives the row itself, so callers never do index arithmetic against
      -- a paged list -- getting that wrong restores the wrong save.
      local function pagedItems(list, onPick, backView)
        list = list or {}
        local pages = math.max(1, math.ceil(#list / PAGE_SIZE))
        self.page = math.min(math.max(self.page or 1, 1), pages)
        local items = {}
        local first = (self.page - 1) * PAGE_SIZE + 1
        for i = first, math.min(first + PAGE_SIZE - 1, #list) do
          local row = list[i]
          items[#items + 1] = { row.label or row.when or "?",
                                function() onPick(row) end }
        end
        if #list == 0 then
          items[#items + 1] = { "Nothing saved yet", function() goto_(backView) end }
        end
        if pages > 1 then
          items[#items + 1] = { ("More (%d/%d)"):format(self.page, pages),
            function()
              -- Wraps, so one button walks the whole list and a player can
              -- never strand themselves on the last page.
              self.page = (self.page % pages) + 1
              self.cursor = 1
            end }
        end
        items[#items + 1] = { "Back", function()
          self.page = 1
          goto_(backView)
        end }
        return items
      end

      local function currentItems()
        if self.view == "reader" then return {} end
        if self.view == "main" then return mainItems() end
        if self.view == "setup" then return setupItems() end
        if self.view == "preflight" then return preflightItems() end
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
          -- Paginated like every other list here: an install still carrying
          -- the stray slots the old key scheme created has dozens of these,
          -- and a list nobody can reach the end of is not a list.
          local rows = {}
          for _, row in ipairs(self.slotRows or {}) do
            -- "RED 1 synced" fits the 17-column budget where the slot id and
            -- a full status word would not.
            local n = tostring(row.slotId or "?"):match("(%d+)$") or "?"
            row.label = ("%s %s %s"):format(
              tostring(row.version):upper():sub(1, 6), n, row.status)
            rows[#rows + 1] = row
          end
          local items = pagedItems(rows, function(row)
            if not row.key then
              -- A save the engine has not stamped yet has no versions to
              -- restore from, because it has never synced. Say so.
              say("Save in game once to sync this file.")
              return
            end
            self.restoreKey = row.key
            if self.restoreFlow then
              -- Came from Restore Old Save: now ask WHERE from, scoped to
              -- the save just chosen.
              goto_("restorePick")
            else
              -- Came from Save files: go straight to this save's versions.
              self.list = loadLocalBackups(row.key)
              self.listKind = "local"
              goto_("restoreList")
            end
          end, "main")
          return items
        end

        if self.view == "restorePick" then
          local items = {
            { "From this device", function()
              self.list = loadLocalBackups(self.restoreKey)
              self.listKind = "local"
              goto_("restoreList")
            end },
          }
          if Sync.configured() then
            items[#items + 1] = { "From the cloud", function()
              local first = self.restoreKey or next(Store.readAllLocal())
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
          return pagedItems(self.list, function(row)
            self.pendingRestore = row
            goto_("confirmRestore")
          end, self.restoreKey and "slots" or "restorePick")
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
          return pagedItems(self.list, function(row)
            self.pendingSnapRestore = row
            goto_("confirmSnapRestore")
          end, "main")
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

      -- Test seam: the labels the current view is offering.  Which rows a
      -- screen shows IS the behaviour under test for anything that hides an
      -- option (a provider this device cannot reach, a row that only appears
      -- when there is something to say), and a headless suite has no other
      -- way to see them.  The game never calls this.
      function self:menuLabels()
        local out = {}
        for _, row in ipairs(currentItems() or {}) do
          out[#out + 1] = tostring(row[1])
        end
        return out
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

        if self.view == "preflight" then self:pollPreflight() end

        if self.linkOp then
          local st, value = self.linkOp:poll()
          if st == "ok" then
            self.linkOp = nil
            finishLink(value)
          elseif st == "error" then
            local paired = self.link and self.link.paired
            self.linkOp = nil
            self.link = nil
            -- Name the thing that failed. Landing on the provider list with a
            -- bare provider error read as "nothing happened".
            say(paired and ("Pairing failed. " .. tostring(value))
                or tostring(value))
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
                name = h.name, seq = h.seq, stamp = h.stamp, where = "cloud" }
            end
            -- Same rule as the local list: label once, here, not per frame.
            local map = slotLookup()
            for _, row in ipairs(self.list) do
              row.label = restoreLabel(row, map)
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
          -- BOX_BOTTOM, not 134: two pixels lower put this under the border
          -- and cut the footer in half on a real screen.
          Font.draw("B: back", 8, BOX_BOTTOM)
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
        -- WRAP, never chop.
        --
        -- This used to cut every header line at WRAP_WIDTH with a plain
        -- :sub, so anything longer lost its tail MID-WORD and with no sign
        -- that it had: `GitHub: tebwritesc`, `Saving to the clou`. The part
        -- that gets cut is exactly the part that identifies the thing --
        -- which account, which state -- so the line that survived was the
        -- useless half.
        --
        -- Long text now flows into the remaining header slots. Only when it
        -- runs out of those is anything shortened, and then with "..." so it
        -- is visibly unfinished and `Read full message` is worth reaching for.
        local function hdr(text)
          if not text or text == "" then return end
          local lines = Util.wrap(tostring(text), WRAP_WIDTH)
          for i, line in ipairs(lines) do
            if slot >= HEADER_SLOTS then return end
            if slot == HEADER_SLOTS - 1 and i < #lines then
              line = line:sub(1, math.max(0, WRAP_WIDTH - 3)) .. "..."
            end
            Font.draw(line, 8, HEADER_TOP + slot * 12)
            slot = slot + 1
          end
        end

        -- The tick means SYNCING IS WORKING, not "a provider is configured".
        -- It used to mean the latter, so a device that could not reach its
        -- storage drew `Connected ✓` directly above `Offline - will retry`
        -- and left the player to work out which of the two to believe.
        local healthy = Sync.state ~= "offline" and Sync.state ~= "error"
          and Sync.state ~= "conflict"
        if Sync.configured() and healthy then
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
        elseif self.view == "preflight" then
          local pf = self.preflight or {}
          if pf.state == "checking" then
            hdr("Checking your")
            hdr("connection...")
          elseif pf.state == "noTransport" then
            hdr("This app has no way")
            hdr("to reach the")
            hdr("internet.")
            hdr("Saves stay on this")
          else
            hdr("Cannot reach the")
            hdr("internet right now.")
            hdr("Check your")
            hdr("connection.")
          end
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
