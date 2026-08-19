-- A luasocket-shaped `socket` module over the LuaJIT FFI, for the live
-- e2e: the shipped net.lua runs UNMODIFIED against a real TCP socket in a
-- plain luajit process that has no compiled luasocket.
--
-- Exactly the surface net.lua touches:
--   socket.tcp() -> sock:settimeout(t) / :connect(host, port)
--                   :setoption("tcp-nodelay", true)
--                   :send(buf) -> sentCount | nil, err
--                   :receive(n) -> chunk | nil, "timeout"|"closed", partial
--                   :close()
-- settimeout(0) flips the fd non-blocking (FIONBIO), which is the mode the
-- whole pump runs in after connect.
--
-- Windows (winsock) and POSIX both implemented; each host tests only its
-- own branch, the same honesty rule as everything else in this suite.

local ffi = require("ffi")
local IS_WINDOWS = ffi.os == "Windows"

local C
if IS_WINDOWS then
  ffi.cdef[[
    typedef uintptr_t SOCKET;
    typedef struct { uint16_t a; uint16_t b; char c[257]; char d[129];
                     unsigned short e; unsigned short f; char *g; } WSADATA_shim;
    int WSAStartup(uint16_t v, WSADATA_shim *d);
    int WSAGetLastError(void);
    SOCKET socket(int af, int type, int protocol);
    int connect(SOCKET s, const void *name, int namelen);
    int send(SOCKET s, const char *buf, int len, int flags);
    int recv(SOCKET s, char *buf, int len, int flags);
    int closesocket(SOCKET s);
    int setsockopt(SOCKET s, int level, int optname, const char *optval, int optlen);
    int ioctlsocket(SOCKET s, long cmd, unsigned long *argp);
    unsigned long inet_addr(const char *cp);
    uint16_t htons(uint16_t x);
    struct in_addr_shim { uint32_t s_addr; };
    struct sockaddr_in_shim { int16_t sin_family; uint16_t sin_port;
                              struct in_addr_shim sin_addr; char sin_zero[8]; };
  ]]
  C = ffi.load("ws2_32")
  local wsa = ffi.new("WSADATA_shim")
  assert(C.WSAStartup(0x0202, wsa) == 0, "WSAStartup failed")
else
  ffi.cdef[[
    typedef int SOCKET;
    SOCKET socket(int af, int type, int protocol);
    int connect(SOCKET s, const void *name, int namelen);
    long send(SOCKET s, const char *buf, size_t len, int flags);
    long recv(SOCKET s, char *buf, size_t len, int flags);
    int close(SOCKET s);
    int setsockopt(SOCKET s, int level, int optname, const void *optval, unsigned int optlen);
    int fcntl(int fd, int cmd, int arg);
    unsigned int inet_addr(const char *cp);
    uint16_t htons(uint16_t x);
    struct in_addr_shim { uint32_t s_addr; };
    struct sockaddr_in_shim { int16_t sin_family; uint16_t sin_port;
                              struct in_addr_shim sin_addr; char sin_zero[8]; };
  ]]
  C = ffi.C
end

local AF_INET, SOCK_STREAM, IPPROTO_TCP = 2, 1, 6
local IPPROTO_TCP_LEVEL, TCP_NODELAY = 6, 1
-- FIONBIO is 0x8004667E, which does NOT fit a signed 32-bit long: passed
-- as a plain Lua number the FFI conversion mangles it, ioctlsocket becomes
-- a silent no-op, the fd stays BLOCKING, and the first quiet recv deadlocks
-- the whole pump (tx never flushes while rx is parked). bit.tobit gives
-- the same 32 bits as a signed value, which converts cleanly.
local bit = require("bit")
local FIONBIO = bit.tobit(0x8004667E)
local WSAEWOULDBLOCK = 10035

local Sock = {}
Sock.__index = Sock

local M = {}

function M.tcp()
  local fd = C.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
  return setmetatable({ fd = fd, nonblocking = false }, Sock)
end

function Sock:settimeout(t)
  if t == 0 then
    self.nonblocking = true
    if IS_WINDOWS then
      local one = ffi.new("unsigned long[1]", 1)
      C.ioctlsocket(self.fd, FIONBIO, one)
    else
      C.fcntl(self.fd, 4 --[[F_SETFL]], 0x800 --[[O_NONBLOCK]])
    end
  end
  -- a blocking timeout before connect: leave the fd blocking; connect's
  -- own default timeout is well under net.lua's tolerance for a press
  return 1
end

function Sock:setoption(name, value)
  if name == "tcp-nodelay" and value then
    local one = ffi.new("int[1]", 1)
    C.setsockopt(self.fd, IPPROTO_TCP_LEVEL, TCP_NODELAY,
      ffi.cast("const char*", one), 4)
  end
  return 1
end

function Sock:connect(host, port)
  local sa = ffi.new("struct sockaddr_in_shim")
  sa.sin_family = AF_INET
  sa.sin_port = C.htons(tonumber(port))
  sa.sin_addr.s_addr = C.inet_addr(host)
  if C.connect(self.fd, sa, ffi.sizeof(sa)) ~= 0 then
    return nil, "connection refused"
  end
  return 1
end

function Sock:send(data)
  local n = tonumber(C.send(self.fd, data, #data, 0))
  if n and n > 0 then return n end
  if n == 0 then return nil, "closed" end
  if IS_WINDOWS and C.WSAGetLastError() == WSAEWOULDBLOCK then
    return nil, "timeout"
  end
  if not IS_WINDOWS then return nil, "timeout" end -- EAGAIN in practice
  return nil, "closed"
end

--- receive(n): non-blocking read of up to n bytes, in luasocket's
--- convention -- a full read returns the chunk, a partial or empty one
--- returns nil, "timeout", partial. net.lua treats them identically.
function Sock:receive(n)
  n = tonumber(n) or 2048
  local buf = ffi.new("char[?]", n)
  local got = tonumber(C.recv(self.fd, buf, n, 0))
  if got and got > 0 then
    local data = ffi.string(buf, got)
    if got == n then return data end
    return nil, "timeout", data
  end
  if got == 0 then return nil, "closed", "" end
  if IS_WINDOWS and C.WSAGetLastError() == WSAEWOULDBLOCK then
    return nil, "timeout", ""
  end
  if not IS_WINDOWS then return nil, "timeout", "" end
  return nil, "closed", ""
end

function Sock:close()
  if IS_WINDOWS then C.closesocket(self.fd) else C.close(self.fd) end
  return 1
end

return M
