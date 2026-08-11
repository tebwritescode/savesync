-- Ops: a one-shot asynchronous unit of work that the sync engine polls once
-- a frame.
--
-- Every provider call is "fire an HTTP request, maybe another one after it,
-- then hand back a value".  Coroutines model that with straight-line code --
-- `local r = yieldHttp(...)` reads like a blocking call while never blocking
-- a frame -- and one 60-line module here is what lets each provider stay a
-- flat list of small functions instead of a hand-rolled state machine.
--
--     local op = Op.new(function(ctx)
--       local res = ctx:http({ url = ..., method = "GET" })
--       if res.code ~= 200 then return ctx:fail("not found") end
--       return { body = res.body }
--     end)
--     -- once a frame:
--     local status, value = op:poll()   -- "pending" | "ok" | "error"
--
-- A body that throws becomes a clean error, never a crashed frame.

local Http = SAVESYNC_INCLUDE("src/http.lua")

local Op = {}
Op.__index = Op

local Ctx = {}
Ctx.__index = Ctx

--- Issue a request and suspend until it finishes.  Returns
--- { code, body, err } -- a non-2xx is a normal return, not a failure,
--- because "is that object there" is answered by a 404.
function Ctx:http(req)
  local id = Http.request(req)
  local res = coroutine.yield({ wait = id })
  return res
end

--- Abandon the op with a player-facing message.
function Ctx:fail(msg)
  error({ __opFail = tostring(msg) }, 0)
end

--- Run another op to completion and return its value; its failure becomes
--- this op's failure.  This is what lets the sync engine be written as one
--- readable sequence over provider calls that are themselves ops.
function Ctx:await(op)
  local r = coroutine.yield({ child = op })
  if not r.ok then error({ __opFail = tostring(r.err) }, 0) end
  return r.value
end

--- Suspend for roughly `seconds`.  The OAuth device flow is required to wait
--- between token polls, and a provider should express that as a sleep rather
--- than by counting frames.
function Ctx:sleep(seconds)
  coroutine.yield({ sleep = seconds })
end

function Op.new(body)
  local self = setmetatable({
    co = coroutine.create(body),
    status = "pending",
    value = nil,
    err = nil,
    waiting = nil,
    ctx = setmetatable({}, Ctx),
  }, Op)
  return self
end

--- An op that is already finished -- used by providers to answer without a
--- round trip (a cached value, an unsupported operation).
function Op.done(value)
  local self = Op.new(function() return value end)
  return self
end

function Op.failed(err)
  local self = Op.new(function(ctx) return ctx:fail(err) end)
  return self
end

local function nowSeconds()
  if love and love.timer and love.timer.getTime then return love.timer.getTime() end
  return os.clock()
end

function Op:poll()
  if self.status ~= "pending" then return self.status, self.value or self.err end

  if self.sleepUntil then
    if nowSeconds() < self.sleepUntil then return "pending" end
    self.sleepUntil = nil
  end

  if self.child then
    local st, v = self.child:poll()
    if st == "pending" then return "pending" end
    self.child = nil
    self.resume = { ok = st == "ok", value = v, err = st ~= "ok" and v or nil }
  end

  if self.waiting then
    local st = Http.poll(self.waiting)
    if st.status == "pending" then return "pending" end
    Http.release(self.waiting)
    self.waiting = nil
    self.resume = { code = st.code, body = st.body, err = st.err,
                    ok = st.status == "ok" }
  end

  local ok, ret = coroutine.resume(self.co, self.resume or self.ctx)
  self.resume = nil

  if not ok then
    -- ctx:fail throws a marker table; anything else is a genuine bug in a
    -- provider and gets reported with its message rather than swallowed
    if type(ret) == "table" and ret.__opFail then
      self.status, self.err = "error", ret.__opFail
    else
      self.status, self.err = "error", tostring(ret)
    end
    return self.status, self.err
  end

  if coroutine.status(self.co) == "dead" then
    self.status, self.value = "ok", ret
    return "ok", ret
  end

  if type(ret) == "table" and ret.wait then
    self.waiting = ret.wait
    return "pending"
  end
  if type(ret) == "table" and ret.sleep then
    self.sleepUntil = nowSeconds() + tonumber(ret.sleep or 1)
    return "pending"
  end
  if type(ret) == "table" and ret.child then
    self.child = ret.child
    return "pending"
  end

  -- A bare yield is a voluntary "come back next frame".
  return "pending"
end

--- The ctx is passed on the FIRST resume only; later resumes carry the HTTP
--- result.  Coroutine bodies therefore take ctx as their argument and keep it.
function Op:cancel()
  if self.status == "pending" then
    if self.waiting then Http.release(self.waiting) end
    if self.child then self.child:cancel() end
    self.status, self.err = "error", "cancelled"
  end
end

function Op:isDone()
  return self.status ~= "pending"
end

return Op
