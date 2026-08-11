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
local MARK = "SAVESYNC-STATUS:"
local MARK_FMT = "\\n" .. MARK .. "%{http_code}"

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

local function doRequest(job)
  if not HostShell then
    post({ id = job.id, ok = false, err = "no transport" })
    return
  end

  local bodyPath
  if job.body and #job.body > 0 then
    -- Bodies go through a file, never the command line: a save blob is tens
    -- of kilobytes of arbitrary bytes and no shell quoting survives that.
    love.filesystem.createDirectory("savesync/tmp")
    bodyPath = "savesync/tmp/req-" .. tostring(job.id) .. ".bin"
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
      err = "this device has no curl, so SaveSync cannot upload here" })
    return
  end

  -- The ceiling is also the worst case for how long closing the window can
  -- take: a worker inside a blocking curl cannot notice anything until curl
  -- returns, and LÖVE waits for live threads before the process exits.
  local cmd = "curl -sS --connect-timeout 10 --max-time "
    .. tostring(tonumber(job.timeout) or 20) .. " "
    .. "-X " .. quoting(job.method or "GET") .. " "
  for _, h in ipairs(job.headers or {}) do
    cmd = cmd .. "-H " .. quoting(h) .. " "
  end
  if bodyPath then
    cmd = cmd .. "--data-binary " .. quoting("@" .. saveDir .. "/" .. bodyPath) .. " "
  end
  -- 2>&1 so curl's own diagnosis ("could not resolve host") lands in the
  -- body when there is no HTTP status at all; without it a DNS failure and
  -- an empty 200 look identical to the caller.
  cmd = cmd .. "-w " .. quoting(MARK_FMT) .. " " .. quoting(job.url) .. " 2>&1"

  local pipe = HostShell.popen(cmd)
  if not pipe then
    if bodyPath then love.filesystem.remove(bodyPath) end
    post({ id = job.id, ok = false, err = "could not run curl" })
    return
  end
  local readOk, out = pcall(function() return pipe:read("*a") end)
  HostShell.pclose(pipe)
  if bodyPath then love.filesystem.remove(bodyPath) end

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
    ready, unavailableReason = false, "background threads unavailable"
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

--- Start a request.  `headers` is a map; `body` is a raw string.  Returns a
--- job id that is valid until release().
function Http.request(req)
  nextId = nextId + 1
  local id = nextId
  jobs[id] = { status = "pending" }

  local headers, needsHeaders = {}, false
  for k, v in pairs(req.headers or {}) do
    headers[#headers + 1] = k .. ": " .. v
    needsHeaders = true
  end
  table.sort(headers)

  if not ensureWorkers() then
    jobs[id].status, jobs[id].err = "error", unavailableReason
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

function Http.available()
  return ensureWorkers()
end

function Http.unavailableReason()
  ensureWorkers()
  return unavailableReason
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
