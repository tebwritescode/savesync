-- The transport, tested on the platform matrix that actually broke.
--
--   luajit tests/http.test.lua
--
-- WHY THIS FILE EXISTS. Phosphor's iOS build has no love.thread. The pool
-- therefore never started, every request failed with "background threads
-- unavailable" before any provider logic ran, and so NO provider worked on
-- iOS -- sign-in, pairing and the self-hosted server alike. Nothing here was
-- covered by a test, because the transport had always been mocked away at the
-- Op layer.
--
-- These load the real src/http.lua against a fake LÖVE, so the branch that
-- decides HOW a request goes out is exercised rather than assumed.

package.path = "./mod/?.lua;" .. package.path

local passed, failed = 0, 0
local function check(name, cond)
  if cond then passed = passed + 1
  else failed = failed + 1 print("FAIL: " .. name) end
end
local function eq(name, got, want)
  if got == want then passed = passed + 1
  else failed = failed + 1
    print(("FAIL: %s  -- got %s, want %s"):format(name, tostring(got), tostring(want)))
  end
end

-- Load http.lua fresh against a chosen fake environment.
local function loadHttp(env)
  _G.love = env.love
  package.loaded["https"] = env.https
  -- `require("https")` must fail outright when the platform has no such
  -- module, which is what a desktop LÖVE 11.x does.
  local realRequire = require
  _G.require = function(name)
    if name == "https" then
      if env.https == nil then error("module 'https' not found", 2) end
      return env.https
    end
    if name == "socket.http" then
      if env.socket == nil then error("module 'socket.http' not found", 2) end
      return env.socket
    end
    if name == "ltn12" then
      if env.socket == nil then error("module 'ltn12' not found", 2) end
      return {
        source = { string = function(b) return b end },
        sink = { table = function(t) return t end },
      }
    end
    if name:sub(1, 5) == "love." then return true end
    return realRequire(name)
  end
  _G.SAVESYNC_INCLUDE = function(path)
    return assert(loadfile("mod/" .. path))()
  end
  local chunk = assert(loadfile("mod/src/http.lua"))
  local Http = chunk()
  _G.require = realRequire
  return Http
end

local function fakeLove(opts)
  return {
    thread = opts.threads and {
      newThread = function() return { start = function() end,
                                      isRunning = function() return true end } end,
      getChannel = function()
        return { push = function() end, pop = function() return nil end,
                 clear = function() end }
      end,
    } or nil,
    filesystem = {
      load = function() return nil end,
      write = function() return true end,
      createDirectory = function() end,
    },
    system = { getOS = function() return opts.os or "iOS" end },
  }
end

-- A stand-in for lua-https that records what it was handed.
local function fakeHttps(record, code, body)
  return {
    request = function(url, opts)
      record.url, record.opts = url, opts
      return code or 200, body or "hello"
    end,
  }
end

-- 1. NO THREADS, NO HTTPS: the honest dead end.
do
  local Http = loadHttp({ love = fakeLove({ threads = false }), https = nil })
  eq("no transport at all is unavailable", Http.available(), false)
  local why = Http.unavailableReason()
  check("and says so in words a player can act on",
    type(why) == "string" and why:find("internet", 1, true) ~= nil)
  check("without blaming background threads",
    why:lower():find("thread", 1, true) == nil)

  local id = Http.request({ url = "https://example.com/x" })
  eq("a request fails immediately", Http.poll(id).status, "error")
end

-- 2. NO THREADS BUT HTTPS PRESENT -- iOS. This is the case that was dead.
do
  local rec = {}
  local Http = loadHttp({ love = fakeLove({ threads = false }),
                          https = fakeHttps(rec, 201, "made") })
  eq("a device with no threads still has a transport", Http.available(), true)
  eq("and reports no failure reason", Http.unavailableReason(), nil)
  check("and says requests run inline", Http.isInline())

  local id = Http.request({
    method = "POST",
    url = "https://api.github.com/gists",
    headers = { ["Authorization"] = "Bearer tok", ["Accept"] = "application/json" },
    body = '{"a":1}',
  })
  local st = Http.poll(id)
  eq("the request completes", st.status, "ok")
  eq("with the transport's status code", st.code, 201)
  eq("and its body", st.body, "made")

  -- The shape lua-https wants, not the array of strings curl wants.
  -- Read defensively: handing it the wrong shape entirely is the mistake
  -- being guarded against, and that must report as a failure rather than
  -- take the suite down with an index-a-nil traceback.
  local opts = rec.opts or {}
  local h = type(opts.headers) == "table" and opts.headers or {}
  eq("the method is passed through", opts.method, "POST")
  eq("the body is passed through", opts.data, '{"a":1}')
  eq("headers arrive as a MAP, not an array", h["Authorization"], "Bearer tok")
  eq("every header survives", h["Accept"], "application/json")
  check("a User-Agent is always sent", type(h["User-Agent"]) == "string")
  eq("no array entries leak into the header map", h[1], nil)
end

-- 3. A plain-http URL cannot go through a TLS-only transport, and must not
--    be silently reported as a network failure.
do
  local rec = {}
  local Http = loadHttp({ love = fakeLove({ threads = false }),
                          https = fakeHttps(rec) })
  local id = Http.request({ url = "http://192.0.2.10:8787/v1/hello" })
  eq("a plain-http self-hosted server does not go out over TLS",
    Http.poll(id).status, "error")
  eq("and the TLS transport was never called", rec.url, nil)
end

-- 4. A transport error is an error, not a pretend success.
do
  local Http = loadHttp({
    love = fakeLove({ threads = false }),
    https = { request = function() return nil end },
  })
  local id = Http.request({ url = "https://example.com/x" })
  eq("an unreachable address is an error", Http.poll(id).status, "error")
end

-- 5. A 404 is a SUCCESSFUL request. Half the sync protocol is "is that object
--    there or not", so a transport that called this an error would make a
--    first-ever upload look like a broken connection.
do
  local rec = {}
  local Http = loadHttp({ love = fakeLove({ threads = false }),
                          https = fakeHttps(rec, 404, "") })
  local st = Http.poll(Http.request({ url = "https://example.com/missing" }))
  eq("a 404 is an ok job", st.status, "ok")
  eq("carrying the code", st.code, 404)
end

-- 6. Where threads DO exist they are still used: the inline path is a
--    fallback, not a replacement, and desktop must not lose its worker pool.
do
  local rec = {}
  local Http = loadHttp({ love = fakeLove({ threads = true, os = "Windows" }),
                          https = fakeHttps(rec) })
  eq("a threaded platform is available", Http.available(), true)
  check("and does NOT run inline", not Http.isInline())
  Http.request({ url = "https://example.com/x" })
  eq("so the inline transport is never touched", rec.url, nil)
end


-- 7. LUASOCKET, which LOVE vendors on every platform including mobile. Plain
--    HTTP only -- luasec is not bundled, so there is no TLS -- which makes it
--    useless for GitHub and exactly right for a self-hosted server on a home
--    network: the one provider a phone with no other transport can still use.
do
  local rec = {}
  local socket = {
    request = function(t)
      rec.t = t
      if t.sink then t.sink[#t.sink + 1] = "from socket" end
      return 200
    end,
  }
  local Http = loadHttp({ love = fakeLove({ threads = false }),
                          https = nil, socket = socket })
  eq("luasocket alone is a transport", Http.available(), true)
  eq("and reports no failure", Http.unavailableReason(), nil)

  local st = Http.poll(Http.request({
    method = "PUT",
    url = "http://192.0.2.10:8787/v1/file/red.sav",
    headers = { ["Authorization"] = "Bearer srv" },
    body = "SAVEBYTES",
  }))
  eq("a plain-http request succeeds", st.status, "ok")
  eq("with its code", st.code, 200)
  eq("and its body", st.body, "from socket")

  local t = rec.t or {}
  local h = type(t.headers) == "table" and t.headers or {}
  eq("the method survives", t.method, "PUT")
  eq("the auth header survives -- the Android bridge cannot do this",
    h["Authorization"], "Bearer srv")
  -- Without Content-Length the far end waits for a body that never ends.
  eq("a body is given its length", h["Content-Length"], "9")
end

-- 8. luasocket cannot do TLS, so an https:// URL must NOT be handed to it.
do
  local rec = {}
  local socket = { request = function(t) rec.t = t return 200 end }
  local Http = loadHttp({ love = fakeLove({ threads = false }),
                          https = nil, socket = socket })
  local st = Http.poll(Http.request({ url = "https://api.github.com/gists" }))
  eq("an https URL is refused when only luasocket exists", st.status, "error")
  eq("and luasocket was never called", rec.t, nil)
end

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
