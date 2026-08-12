-- Async HTTP for the cloud-saves mod: arbitrary method, headers and body.
--
-- WHY NOT src/net/Fetch.lua.  The engine's fetch pool is exactly what this
-- wants -- a job queue over love.thread workers, polled once a frame, never
-- blocking the render thread -- but its worker only knows GET and file
-- download through HostShell.httpGet/httpDownload.  Sync needs PUT with an
-- Authorization header and a body.  So this is the same shape with a wider
-- verb set, and it reuses HostShell for the transport so it inherits the
-- platform matrix (curl on desktop, console hiding on Windows, the popen
-- lock) rather than inventing a second one.
--
-- CONTRACT.  Callers get an opaque job id back immediately and poll it:
--     local job = Http.request({ method = "PUT", url = ..., body = ... })
--     local st = Http.poll(job)   -- { status, code, body, err }
-- status is pending | ok | error.  "ok" means the transport worked; the HTTP
-- status is in `code` and a 404 is an ok job with code 404, because half of
-- this protocol's logic is "is that object there or not".  poll() never
-- blocks and never throws.  Results are retained until Http.release(job).
--
-- DEGRADATION.  No love.thread, or no curl and no Android bridge, and every
-- job completes immediately as an error with a reason the UI can show.  A GET
-- with no auth header can still go through HostShell's Android bridge, so a
-- phone without curl degrades to read-only rather than to nothing.

local Http = {}

local CMD    = "savesync_http_cmd"
local RESULT = "savesync_http_result"
local QUIT   = "savesync_http_quit"

-- Two workers.  Sync is one request at a time in the common case; the second
-- exists so a slow upload cannot stall the manifest read that the UI is
-- waiting on.
local POOL = 2

local workers = {}
local cmdCh, resCh, quitCh
local ready
local unavailableReason
local jobs = {}
local nextId = 0

-- The worker runs in a fresh Lua state with no "src.*" package searcher, so
-- HostShell comes in through love.filesystem.load -- the same trick
-- src/net/fetch_worker.lua and src/update/check_worker.lua use.  Passing the
-- source as a string (rather than a path) keeps the whole worker inside the
-- mod, which matters because mod files are not reachable by
-- love.thread.newThread on every platform.
local WORKER_SOURCE = [==[
require("love.thread")
require("love.filesystem")
require("love.system")

local cmdCh = love.thread.getChannel("savesync_http_cmd")
local resCh = love.thread.getChannel("savesync_http_result")
local quitCh = love.thread.getChannel("savesync_http_quit")

-- LOVE's own HTTPS module, which the iOS and Android ports ship and the
-- desktop 11.x builds generally do not.
--
-- WHY THIS IS HERE. The transport below is curl through HostShell, plus a
-- native GET bridge on Android. iOS has NEITHER: there is no curl to spawn
-- and no bridge exported, so every request failed and no provider worked at
-- all -- sign-in, pairing and the self-hosted server alike. lua-https is the
-- transport that platform actually has.
--
-- It speaks TLS only, so a plain-http self-hosted server still needs curl.
-- Order therefore matters: https first for https:// URLs, curl after.
local https do
  local ok, mod = pcall(require, "https")
  https = ok and type(mod) == "table" and type(mod.request) == "function"
    and mod or nil
end

local function loadModule(path)
  local ok, chunk = pcall(love.filesystem.load, path)
  if not ok or type(chunk) ~= "function" then return nil end
  local ok2, m = pcall(chunk)
  if not ok2 then return nil end
  return m
end

local HostShell = loadModule("src/core/HostShell.lua")
local saveDir = love.filesystem.getSaveDirectory()

-- curl expands the escape itself, so the format string carries the two
-- characters backslash-n rather than a real newline (the same reason
-- HostShell writes its own marker that way).
-- A REAL newline here; cfgValue turns it into the \n escape curl's config
-- parser wants.  Writing the escape by hand instead would get double-escaped
-- into a literal backslash-n and the status marker would never be found.
local MARK = "SAVESYNC-STATUS:"
local MARK_FMT_CFG = "\n" .. MARK .. "%{http_code}"

local function post(t) resCh:push(t) end

local function quoting(s)
  if HostShell and HostShell.quote then return HostShell.quote(s) end
  return '"' .. tostring(s):gsub('"', '\\"') .. '"'
end

-- Split the status marker off the tail of curl's output.  Everything before
-- the LAST marker is the body: a response could in principle contain the
-- marker text, and the one curl appends is always last.
local function split(out)
  local at
  local from = 1
  while true do
    local s = out:find(MARK, from, true)
    if not s then break end
    at = s
    from = s + 1
  end
  if not at then return out, nil end
  local body = out:sub(1, at - 1):gsub("\r?\n$", "")
  local code = tonumber(out:sub(at + #MARK):match("%d+") or "")
  return body, code
end

-- Escape one value for curl's own config-file syntax: inside double quotes it
-- honours \\, \" and \n / \r / \t, and nothing else.  Backslash goes first or
-- it would escape the escapes we are about to add.
local function cfgValue(s)
  s = tostring(s)
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\n", "\\n")
    :gsub("\r", "\\r")
    :gsub("\t", "\\t")
  return '"' .. s .. '"'
end

-- Send through luasocket, which LOVE vendors on every platform including
-- mobile.  PLAIN HTTP ONLY -- luasec is not bundled, so there is no TLS here.
-- That makes this useless for GitHub and Dropbox and exactly right for a
-- self-hosted server on a home network, which is the one provider a phone
-- with no other transport can still use.
local function trySocket(job)
  local okHttp, http = pcall(require, "socket.http")
  local okLtn, ltn12 = pcall(require, "ltn12")
  if not (okHttp and okLtn and type(http) == "table" and type(ltn12) == "table") then
    return false
  end
  if type(job.url) ~= "string" or job.url:sub(1, 7) ~= "http://" then
    return false
  end
  local headers = {}
  for _, line in ipairs(job.headers or {}) do
    local k, v = tostring(line):match("^([^:]+):%s*(.*)$")
    if k then headers[k] = v end
  end
  headers["User-Agent"] = headers["User-Agent"] or job.userAgent
  if job.accept then headers["Accept"] = headers["Accept"] or job.accept end
  -- A body needs its length, or the far end waits for more of it forever.
  if job.body and #job.body > 0 then
    headers["Content-Length"] = tostring(#job.body)
  end

  local sink = {}
  local ok, code = pcall(http.request, {
    url = job.url,
    method = (job.method or "GET"):upper(),
    headers = headers,
    source = job.body and ltn12.source.string(job.body) or nil,
    sink = ltn12.sink.table(sink),
  })
  if not ok or type(code) ~= "number" then
    post({ id = job.id, ok = false, err = "could not reach that address" })
    return true
  end
  post({ id = job.id, ok = true, code = code, body = table.concat(sink) })
  return true
end

-- Send through lua-https.  Returns true when it handled the job.
local function tryHttps(job)
  if not https then return false end
  -- TLS only; a plain-http URL is left to curl rather than failed here.
  if type(job.url) ~= "string" or job.url:sub(1, 8) ~= "https://" then
    return false
  end
  -- Headers cross the channel as an array of "Key: value" strings, the shape
  -- curl's config file wants; lua-https wants a map.
  local headers = {}
  for _, line in ipairs(job.headers or {}) do
    local k, v = tostring(line):match("^([^:]+):%s*(.*)$")
    if k then headers[k] = v end
  end
  if job.userAgent then headers["User-Agent"] = headers["User-Agent"] or job.userAgent end
  if job.accept then headers["Accept"] = headers["Accept"] or job.accept end

  local ok, code, body = pcall(https.request, job.url, {
    method = job.method or "GET",
    headers = headers,
    data = job.body,
  })
  if not ok then
    post({ id = job.id, ok = false, err = "connection failed" })
    return true
  end
  -- A nil code is lua-https saying the request never left the device.
  if not code then
    post({ id = job.id, ok = false, err = "could not reach that address" })
    return true
  end
  post({ id = job.id, ok = true, code = code, body = body or "" })
  return true
end

local function doRequest(job)
  if tryHttps(job) then return end
  if trySocket(job) then return end
  if not HostShell then
    post({ id = job.id, ok = false, err = "no transport" })
    return
  end

  local tmpDir = "savesync/tmp"
  local bodyPath
  if job.body and #job.body > 0 then
    -- Bodies go through a file, never the command line: a save blob is tens
    -- of kilobytes of arbitrary bytes and no shell quoting survives that.
    love.filesystem.createDirectory(tmpDir)
    bodyPath = tmpDir .. "/req-" .. tostring(job.id) .. ".bin"
    local okW = love.filesystem.write(bodyPath, job.body)
    if not okW then
      post({ id = job.id, ok = false, err = "could not stage request body" })
      return
    end
  end

  if not HostShell.haveCurl() then
    -- No curl.  A plain GET can still go out through HostShell's own
    -- transport (the Android JNI bridge), but it cannot carry headers, so
    -- anything authenticated has to say so plainly.
    if job.method == "GET" and not job.needsHeaders then
      local body, err = HostShell.httpGet(job.url, job.userAgent, job.accept, 25)
      if body then
        post({ id = job.id, ok = true, code = 200, body = body })
      else
        post({ id = job.id, ok = false, err = err or "fetch failed" })
      end
      return
    end
    post({ id = job.id, ok = false,
      err = "this device has no way to reach the internet for SaveSync" })
    return
  end

  -- EVERY ARGUMENT GOES IN A CURL CONFIG FILE, not on the command line.
  --
  -- HostShell.quote is built for the launcher's URLs, and on Windows it
  -- DELETES double quotes from the argument rather than escaping them
  -- (cmd.exe has no single-quote form, so there is no safe escape it could
  -- use).  That is fine for a URL and fatal for a header: Dropbox takes its
  -- file arguments as JSON in a `Dropbox-API-Arg` header, so every upload
  -- and download on Windows would have gone out with the quotes stripped and
  -- been rejected as malformed.
  --
  -- curl -K reads options from a file with its own quoting rules, so the
  -- only thing that touches a shell is the config file's path -- which we
  -- chose.  It fixes the header case and makes the URL and the write-out
  -- format immune to the same class of bug.
  love.filesystem.createDirectory(tmpDir)
  local cfgPath = tmpDir .. "/req-" .. tostring(job.id) .. ".curl"
  local cfg = {
    "silent",
    "show-error",
    -- The ceiling is also the worst case for how long closing the window can
    -- take: a worker inside a blocking curl cannot notice anything until
    -- curl returns, and LÖVE waits for live threads before the process exits.
    "connect-timeout = 10",
    "max-time = " .. tostring(tonumber(job.timeout) or 20),
    "request = " .. cfgValue(job.method or "GET"),
    "url = " .. cfgValue(job.url),
    "write-out = " .. cfgValue(MARK_FMT_CFG),
  }
  for _, h in ipairs(job.headers or {}) do
    cfg[#cfg + 1] = "header = " .. cfgValue(h)
  end
  if bodyPath then
    cfg[#cfg + 1] = "data-binary = " .. cfgValue("@" .. saveDir .. "/" .. bodyPath)
  end
  if not love.filesystem.write(cfgPath, table.concat(cfg, "\n") .. "\n") then
    if bodyPath then love.filesystem.remove(bodyPath) end
    post({ id = job.id, ok = false, err = "could not stage the request" })
    return
  end

  -- 2>&1 so curl's own diagnosis ("could not resolve host") lands in the
  -- output when there is no HTTP status at all; without it a DNS failure and
  -- an empty 200 look identical to the caller.
  local cmd = "curl -K " .. quoting(saveDir .. "/" .. cfgPath) .. " 2>&1"

  local pipe = HostShell.popen(cmd)
  if not pipe then
    if bodyPath then love.filesystem.remove(bodyPath) end
    love.filesystem.remove(cfgPath)
    post({ id = job.id, ok = false, err = "could not run curl" })
    return
  end
  local readOk, out = pcall(function() return pipe:read("*a") end)
  HostShell.pclose(pipe)
  if bodyPath then love.filesystem.remove(bodyPath) end
  -- The config file carries the Authorization header, so it does not linger
  -- on disk a moment longer than the request it configured.
  love.filesystem.remove(cfgPath)

  if not readOk or type(out) ~= "string" then
    post({ id = job.id, ok = false, err = "curl produced no output" })
    return
  end
  local body, code = split(out)
  if not code or code == 0 then
    post({ id = job.id, ok = false, err = (body ~= "" and body) or "no response" })
    return
  end
  post({ id = job.id, ok = true, code = code, body = body })
end

-- Workers RETIRE WHEN IDLE.  The engine has no "game is quitting" event a
-- mod can listen for, and LÖVE waits for every live thread before the
-- process exits -- so a worker parked forever in demand() would hang the
-- window on close.  Three seconds of quiet and it exits; the pool respawns
-- on the next request, which costs a thread create nobody can feel.
local IDLE_EXIT = 3

while true do
  local job = cmdCh:demand(IDLE_EXIT)
  if job == nil then break end
  if quitCh:peek() ~= nil then break end
  if type(job) == "table" then
    if job.kind == "quit" then break end
    local ok, err = pcall(doRequest, job)
    if not ok then post({ id = job.id, ok = false, err = tostring(err) }) end
  end
end
]==]

-- Workers retire when idle (see the worker source), so this both starts the
-- pool the first time and tops it back up afterwards.  Threads that have
-- exited are dropped rather than counted, or the pool would shrink to zero
-- over a long session and every later request would queue forever.
local function ensureWorkers()
  if ready == false then return false end
  if not (love and love.thread and love.thread.newThread) then
    ready, unavailableReason = false,
      "this app cannot reach the internet for SaveSync"
    return false
  end
  if not cmdCh then
    cmdCh = love.thread.getChannel(CMD)
    resCh = love.thread.getChannel(RESULT)
    quitCh = love.thread.getChannel(QUIT)
    -- Channels are global to the process and outlive a pool, so a pool
    -- started after a shutdown has to clear the previous round's quit flag
    -- or its workers exit on their first job.
    quitCh:clear()
    cmdCh:clear()
  end

  local alive = {}
  for _, th in ipairs(workers) do
    if th:isRunning() then alive[#alive + 1] = th end
  end
  workers = alive

  for _ = #workers + 1, POOL do
    local ok, th = pcall(love.thread.newThread, WORKER_SOURCE)
    if ok and th and pcall(function() th:start() end) then
      workers[#workers + 1] = th
    end
  end
  if #workers == 0 then
    ready, unavailableReason = false, "could not start network workers"
    return false
  end
  ready = true
  return true
end

local function drain()
  if not resCh then return end
  local msg = resCh:pop()
  while msg do
    if type(msg) == "table" and msg.id then
      local j = jobs[msg.id]
      if j and j.status == "pending" then
        j.status = msg.ok and "ok" or "error"
        j.code, j.body, j.err = msg.code, msg.body, msg.err
      end
    end
    msg = resCh:pop()
  end
  -- A worker that died takes its in-flight job with it; surface that rather
  -- than leaving a job pending forever and a spinner turning for good.
  for _, th in ipairs(workers) do
    local err = th:getError()
    if err then
      for _, j in pairs(jobs) do
        if j.status == "pending" then j.status, j.err = "error", tostring(err) end
      end
      break
    end
  end
end

-- THE NO-THREADS FALLBACK.
--
-- Phosphor's iOS build has no love.thread, so ensureWorkers() failed and
-- every request errored with "background threads unavailable" before any
-- provider logic ran -- which is why NO provider worked there, sign-in,
-- pairing and self-hosted server alike.
--
-- lua-https is synchronous, which the pool exists to avoid; but a blocked
-- frame during a sign-in is a hitch, and no transport at all is a missing
-- feature. Requests here are a few kilobytes and happen on setup or a few
-- times a minute, so this is used ONLY when there are no workers to use.
-- The main chunk's own handle on HostShell -- the one at the top of this file
-- lives inside the WORKER SOURCE string and does not exist out here.
--
-- GUARDED, like every other global reached at load time here. `love` is
-- absent in the headless suites, and an unguarded reach for it takes the
-- whole module down on load -- which is exactly how the iOS `os.getenv`
-- crash worked. Anything touched at load must survive the smallest
-- environment this file is ever loaded into.
local HostShellMain do
  local fs = love and love.filesystem
  if fs and type(fs.load) == "function" then
    local ok, chunk = pcall(fs.load, "src/core/HostShell.lua")
    if ok and type(chunk) == "function" then
      local ok2, mod = pcall(chunk)
      HostShellMain = ok2 and type(mod) == "table" and mod or nil
    end
  end
end

local inlineHttps do
  local ok, mod = pcall(require, "https")
  inlineHttps = ok and type(mod) == "table" and type(mod.request) == "function"
    and mod or nil
end

-- luasocket, which LOVE vendors on every platform including mobile. Plain
-- HTTP only -- luasec is not bundled, so there is no TLS -- which makes it
-- useless for GitHub and Dropbox and exactly right for a self-hosted server
-- on a home network: the one provider a phone with no other transport can
-- still reach.
local inlineSocket do
  local okHttp, http = pcall(require, "socket.http")
  local okLtn, ltn12 = pcall(require, "ltn12")
  if okHttp and okLtn and type(http) == "table" and type(ltn12) == "table" then
    inlineSocket = { http = http, ltn12 = ltn12 }
  end
end

local function canInline(url)
  if type(url) ~= "string" then return false end
  -- TLS goes to lua-https, plain HTTP to luasocket. Neither can do the
  -- other's job, so a URL with no matching transport is refused here rather
  -- than failing obscurely further down.
  if url:sub(1, 8) == "https://" then return inlineHttps ~= nil end
  if url:sub(1, 7) == "http://" then return inlineSocket ~= nil end
  return false
end

local function runInline(id, req, headerMap)
  if req.url:sub(1, 7) == "http://" then
    local sink = {}
    local headers = {}
    for k, v in pairs(headerMap) do headers[k] = v end
    if req.body and #req.body > 0 then
      headers["Content-Length"] = tostring(#req.body)
    end
    local ok, code = pcall(inlineSocket.http.request, {
      url = req.url,
      method = (req.method or "GET"):upper(),
      headers = headers,
      source = req.body and inlineSocket.ltn12.source.string(req.body) or nil,
      sink = inlineSocket.ltn12.sink.table(sink),
    })
    if not ok or type(code) ~= "number" then
      jobs[id].status, jobs[id].err = "error", "could not reach that address"
      return
    end
    jobs[id].status, jobs[id].code = "ok", code
    jobs[id].body = table.concat(sink)
    return
  end
  local ok, code, body = pcall(inlineHttps.request, req.url, {
    method = (req.method or "GET"):upper(),
    headers = headerMap,
    data = req.body,
  })
  if not ok or not code then
    jobs[id].status = "error"
    jobs[id].err = "could not reach that address"
    return
  end
  jobs[id].status, jobs[id].code, jobs[id].body = "ok", code, body or ""
end

--- Start a request.  `headers` is a map; `body` is a raw string.  Returns a
--- job id that is valid until release().
function Http.request(req)
  nextId = nextId + 1
  local id = nextId
  jobs[id] = { status = "pending" }

  local headers, needsHeaders = {}, false
  local headerMap = {}
  for k, v in pairs(req.headers or {}) do
    headers[#headers + 1] = k .. ": " .. v
    headerMap[k] = v
    needsHeaders = true
  end
  table.sort(headers)
  headerMap["User-Agent"] = headerMap["User-Agent"]
    or req.userAgent or "gen1recomp-savesync"
  if req.accept then headerMap["Accept"] = headerMap["Accept"] or req.accept end

  if not ensureWorkers() then
    if canInline(req.url) then
      runInline(id, req, headerMap)
    else
      jobs[id].status, jobs[id].err = "error", unavailableReason
    end
    return id
  end
  cmdCh:push({
    id = id,
    kind = "request",
    method = (req.method or "GET"):upper(),
    url = req.url,
    headers = headers,
    needsHeaders = needsHeaders,
    body = req.body,
    timeout = req.timeout,
    userAgent = req.userAgent or "gen1recomp-savesync",
    accept = req.accept,
  })
  return id
end

function Http.poll(id)
  drain()
  return jobs[id] or { status = "error", err = "unknown job" }
end

function Http.release(id)
  jobs[id] = nil
end

--- Can this device reach the network at all, by either route?
function Http.available()
  if ensureWorkers() then return true end
  return inlineHttps ~= nil or inlineSocket ~= nil
end

function Http.unavailableReason()
  if ensureWorkers() then return nil end
  if inlineHttps or inlineSocket then return nil end
  return unavailableReason
end

--- True when requests run on the main thread, so the UI can warn that the
--- game will pause during a transfer rather than look frozen.
function Http.isInline()
  return not ensureWorkers() and (inlineHttps ~= nil or inlineSocket ~= nil)
end

--- Can this device do TLS at all?  GitHub and Dropbox are HTTPS-only, so a
--- device without it can reach a self-hosted server and nothing else.
--- curl and lua-https both do TLS; luasocket does not (no luasec is bundled).
function Http.tlsCapable()
  if inlineHttps ~= nil then return true end
  if HostShellMain and HostShellMain.haveCurl then
    local ok, v = pcall(HostShellMain.haveCurl)
    if ok and v == true then return true end
  end
  return false
end

--- What this device actually offers, in plain words.
---
--- WHY THIS EXISTS. "No provider works" on a phone is unanswerable from a
--- desktop: the transport depends on which optional pieces that particular
--- LOVE build shipped, and guessing cost a release. This reports what is
--- really there so the answer comes from the device rather than from a
--- theory about it.
function Http.diagnostics()
  local love_ = love or {}
  local function yn(v) return v and "yes" or "no" end

  local hasThread = not not (love_.thread and love_.thread.newThread)
  local socket = inlineSocket
  local curl = false
  if HostShellMain and HostShellMain.haveCurl then
    local ok, v = pcall(HostShellMain.haveCurl)
    curl = ok and v == true
  end
  local bridge = not not (love_.system and love_.system.httpDownload)

  local osName = "?"
  if love_.system and love_.system.getOS then
    local ok, v = pcall(love_.system.getOS)
    if ok then osName = tostring(v) end
  end
  local ver = "?"
  if love_.getVersion then
    local ok, a, b, c = pcall(love_.getVersion)
    if ok then ver = ("%s.%s.%s"):format(tostring(a), tostring(b), tostring(c)) end
  end

  local lines = {
    "device: " .. osName,
    "love: " .. ver,
    "threads: " .. yn(hasThread),
    "https: " .. yn(inlineHttps),
    "sockets: " .. yn(socket),
    "curl: " .. yn(curl),
    "bridge: " .. yn(bridge),
    "",
  }
  if Http.available() then
    lines[#lines + 1] = hasThread and "Using background workers."
      or "Running on the main thread; the game pauses briefly per request."
  else
    lines[#lines + 1] = "No way to reach the network on this device."
    lines[#lines + 1] = "Send this list to the mod author."
  end
  return table.concat(lines, " | ")
end

--- Stop the pool.  Called from the mod's quit path so LÖVE is not left
--- waiting on a worker parked in demand().
function Http.shutdown()
  if ready ~= true then return end
  quitCh:push(true)
  for _ = 1, #workers do cmdCh:push({ kind = "quit" }) end
  workers, ready = {}, nil
end

return Http
