-- A minimal socket.core for LuaJIT's FFI, so the REAL vendored luasocket --
-- the exact http.lua/ltn12.lua the Android APK compiles in -- can run in a
-- plain luajit test process that has no compiled luasocket.
--
-- WHY. The Android build of the game ships luasocket as its ONLY plain-HTTP
-- transport, and the transport bug this suite exists to catch (reading
-- luasocket's first return as the HTTP status) lived precisely in the seam
-- between SaveSync and luasocket's real API. A fake that "acts like"
-- luasocket is how that bug shipped; running the vendored files themselves
-- is the fix. This file is dumb plumbing -- TCP connect/send/receive --
-- and every line of protocol logic above it is the real library.
--
-- Windows (winsock) and POSIX are both implemented; only the branch the
-- host runs is tested on that host, the same honesty rule as e2e.test.js.
--
-- Provides exactly what the pure-Lua layer reaches for:
--   core.tcp() -> master:  settimeout, connect, send, receive, close
--   core.newtry, core.protect, core.skip
-- (socket.lua supplies try/choose/sink/source/BLOCKSIZE itself.)

local ffi = require("ffi")

local IS_WINDOWS = ffi.os == "Windows"

local C, SOCK_INVALID
if IS_WINDOWS then
  ffi.cdef[[
    typedef uintptr_t SOCKET;
    typedef struct { uint16_t wVersion; uint16_t wHighVersion;
                     char szDescription[257]; char szSystemStatus[129];
                     unsigned short iMaxSockets; unsigned short iMaxUdpDg;
                     char *lpVendorInfo; } WSADATA;
    int WSAStartup(uint16_t wVersionRequested, WSADATA *lpWSAData);
    SOCKET socket(int af, int type, int protocol);
    int connect(SOCKET s, const void *name, int namelen);
    int send(SOCKET s, const char *buf, int len, int flags);
    int recv(SOCKET s, char *buf, int len, int flags);
    int closesocket(SOCKET s);
    int setsockopt(SOCKET s, int level, int optname,
                   const char *optval, int optlen);
    unsigned long inet_addr(const char *cp);
    uint16_t htons(uint16_t hostshort);
    struct in_addr { uint32_t s_addr; };
    struct sockaddr_in { int16_t sin_family; uint16_t sin_port;
                         struct in_addr sin_addr; char sin_zero[8]; };
    typedef struct hostent { char *h_name; char **h_aliases;
                             short h_addrtype; short h_length;
                             char **h_addr_list; } hostent;
    hostent *gethostbyname(const char *name);
    int WSAGetLastError(void);
  ]]
  C = ffi.load("ws2_32")
  local wsa = ffi.new("WSADATA")
  assert(C.WSAStartup(0x0202, wsa) == 0, "WSAStartup failed")
  SOCK_INVALID = ffi.cast("SOCKET", -1)
else
  ffi.cdef[[
    typedef int SOCKET;
    SOCKET socket(int af, int type, int protocol);
    int connect(SOCKET s, const void *name, int namelen);
    long send(SOCKET s, const char *buf, size_t len, int flags);
    long recv(SOCKET s, char *buf, size_t len, int flags);
    int close(SOCKET s);
    int setsockopt(SOCKET s, int level, int optname,
                   const void *optval, unsigned int optlen);
    unsigned int inet_addr(const char *cp);
    uint16_t htons(uint16_t hostshort);
    struct in_addr { uint32_t s_addr; };
    struct sockaddr_in { int16_t sin_family; uint16_t sin_port;
                         struct in_addr sin_addr; char sin_zero[8]; };
    typedef struct hostent { char *h_name; char **h_aliases;
                             int h_addrtype; int h_length;
                             char **h_addr_list; } hostent;
    hostent *gethostbyname(const char *name);
  ]]
  C = ffi.C
  SOCK_INVALID = -1
end

local AF_INET, SOCK_STREAM, IPPROTO_TCP = 2, 1, 6
local SOL_SOCKET = IS_WINDOWS and 0xFFFF or 1
local SO_RCVTIMEO = IS_WINDOWS and 0x1006 or 20
local SO_SNDTIMEO = IS_WINDOWS and 0x1005 or 21

local function resolve(host)
  local packed = C.inet_addr(host)
  if packed ~= 0xFFFFFFFF then return packed end
  local he = C.gethostbyname(host)
  if he == nil or he.h_addr_list == nil or he.h_addr_list[0] == nil then
    return nil
  end
  return ffi.cast("uint32_t*", he.h_addr_list[0])[0]
end

local core = {}

-- ---- try/protect/skip, with luasocket's exact sentinel discipline: try on
-- a falsy first value raises a wrapped error that protect unwraps to
-- nil, err -- anything else propagates as a genuine bug.
local SENTINEL = {}

function core.newtry(finalizer)
  return function(ok, err, ...)
    if ok then return ok, err, ... end
    if finalizer then pcall(finalizer) end
    error(setmetatable({ err }, SENTINEL), 0)
  end
end

function core.protect(f)
  return function(...)
    local results = { pcall(f, ...) }
    if results[1] then
      return unpack(results, 2)
    end
    local e = results[2]
    if type(e) == "table" and getmetatable(e) == SENTINEL then
      return nil, e[1]
    end
    error(e, 0)
  end
end

function core.skip(d, ...)
  return select(d + 1, ...)
end

-- ---- the TCP master object
local Master = {}
Master.__index = Master

function core.tcp()
  local fd = C.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
  if fd == SOCK_INVALID then return nil, "could not create socket" end
  return setmetatable({ fd = fd, buf = "", timeoutMs = 15000 }, Master)
end

function Master:settimeout(t)
  self.timeoutMs = t and math.floor(t * 1000) or 0
  if IS_WINDOWS then
    -- winsock takes a DWORD of milliseconds
    local v = ffi.new("int[1]", self.timeoutMs)
    C.setsockopt(self.fd, SOL_SOCKET, SO_RCVTIMEO, ffi.cast("const char*", v), 4)
    C.setsockopt(self.fd, SOL_SOCKET, SO_SNDTIMEO, ffi.cast("const char*", v), 4)
  else
    ffi.cdef[[ struct timeval_shim { long tv_sec; long tv_usec; }; ]]
    local tv = ffi.new("struct timeval_shim",
      math.floor(self.timeoutMs / 1000), (self.timeoutMs % 1000) * 1000)
    C.setsockopt(self.fd, SOL_SOCKET, SO_RCVTIMEO, tv, ffi.sizeof(tv))
    C.setsockopt(self.fd, SOL_SOCKET, SO_SNDTIMEO, tv, ffi.sizeof(tv))
  end
  return 1
end

function Master:connect(host, port)
  local packed = resolve(host)
  if not packed then return nil, "host not found" end
  local sa = ffi.new("struct sockaddr_in")
  sa.sin_family = AF_INET
  -- the vendored url.lua hands the port over as a STRING
  sa.sin_port = C.htons(tonumber(port))
  sa.sin_addr.s_addr = packed
  if C.connect(self.fd, sa, ffi.sizeof(sa)) ~= 0 then
    return nil, "connection refused"
  end
  return 1
end

--- luasocket send contract: returns the index of the last byte sent, or
--- nil, err, index-of-last-byte-sent.
function Master:send(data, i, j)
  i = i or 1
  j = j or #data
  local chunk = data:sub(i, j)
  local sent = 0
  while sent < #chunk do
    local n = tonumber(C.send(self.fd, chunk:sub(sent + 1), #chunk - sent, 0))
    if n <= 0 then return nil, "closed", i + sent - 1 end
    sent = sent + n
  end
  return i + #chunk - 1
end

local function pull(self)
  local BUF = 8192
  local tmp = ffi.new("char[?]", BUF)
  local n = tonumber(C.recv(self.fd, tmp, BUF, 0))
  if n and n > 0 then
    self.buf = self.buf .. ffi.string(tmp, n)
    return true
  end
  return false, (n == 0) and "closed" or "timeout"
end

--- luasocket receive contract: pattern "*l" (a line, CRLF stripped),
--- "*a" (until closed), or a byte count. Returns data, or nil, err, partial.
function Master:receive(pattern, prefix)
  prefix = prefix or ""
  pattern = pattern or "*l"
  if pattern == "*l" then
    while true do
      local nl = self.buf:find("\n", 1, true)
      if nl then
        local line = self.buf:sub(1, nl - 1):gsub("\r$", "")
        self.buf = self.buf:sub(nl + 1)
        return prefix .. line
      end
      local ok, err = pull(self)
      if not ok then return nil, err, prefix .. self.buf end
    end
  elseif pattern == "*a" then
    while true do
      local ok, err = pull(self)
      if not ok then
        if err == "closed" then
          local all = prefix .. self.buf
          self.buf = ""
          return all
        end
        return nil, err, prefix .. self.buf
      end
    end
  else
    local want = tonumber(pattern)
    while #self.buf < want do
      local ok, err = pull(self)
      if not ok then
        local part = self.buf
        self.buf = ""
        return nil, err, prefix .. part
      end
    end
    local got = self.buf:sub(1, want)
    self.buf = self.buf:sub(want + 1)
    return prefix .. got
  end
end

function Master:close()
  if self.fd ~= SOCK_INVALID then
    if IS_WINDOWS then C.closesocket(self.fd) else C.close(self.fd) end
    self.fd = SOCK_INVALID
  end
  return 1
end

-- http.lua calls methods luasocket masters carry that never matter on a
-- straight request; answer them harmlessly rather than crash the library.
function Master:setoption() return 1 end
function Master:getfd() return tonumber(ffi.cast("intptr_t", self.fd)) end

core.gettime = os.clock
function core.sleep() end
core.select = function() return {}, {}, "timeout" end

return core
