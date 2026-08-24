//! Windows fd compatibility shim for libscrapli's POSIX-style I/O layer.
//!
//! libscrapli assumes BSD-socket int fds everywhere: `-1` sentinel,
//! `>= 0` validity checks, `std.posix.read/write`. On Windows, sockets are
//! `SOCKET` (UINT_PTR) and `std.posix.fd_t` is a HANDLE (`*anyopaque`),
//! breaking all of that.
//!
//! Instead of rewriting every call site, we normalize at the boundary the
//! same way libuv does (src/win/poll.c:407 uses uv__get_osfhandle): convert
//! WinSock SOCKETs into CRT integer fds once at creation via
//! `_open_osfhandle`, then CRT `_read/_write/_close` behave exactly like
//! their POSIX counterparts.
//!
//! Also provides:
//!   - sockRead/sockWrite: WinSock recv/send with POSIX errno semantics
//!     (WouldBlock mirrors EAGAIN) for transports on raw SOCKETs.
//!   - tcpSocketPair(): loopback socketpair emulation for ssh2 proxy jump.

const std = @import("std");
const win = std.os.windows;

pub const Fd = i32;
pub const INVALID_FD: Fd = -1;

// --- CRT POSIX-ish I/O (io.h / MSVCRT) ---

extern "c" fn _open_osfhandle(os_handle: isize, flags: c_int) callconv(.c) c_int;

const O_BINARY: c_int = 0x8000;
const O_RDONLY: c_int = 0x0000;
const O_WRONLY: c_int = 0x0001;

/// Convert a WinSock SOCKET (or any OS HANDLE) into a CRT int fd usable with
/// readFd/writeFd/closeFd. Returns INVALID_FD on failure.
pub fn sockToFd(sock: usize) Fd {
    const fd = _open_osfhandle(@bitCast(sock), O_BINARY | O_RDONLY);
    if (fd == INVALID_FD) {
        return INVALID_FD;
    }
    return fd;
}

extern "c" fn _read(fd: c_int, buf: [*]u8, count: c_uint) callconv(.c) c_int;
extern "c" fn _write(fd: c_int, buf: [*]const u8, count: c_uint) callconv(.c) c_int;
extern "c" fn _close(fd: c_int) callconv(.c) c_int;

/// CRT read with POSIX semantics: n bytes read, 0 = EOF, -1 = error.
pub fn readFd(fd: Fd, buf: []u8) isize {
    return _read(fd, buf.ptr, @intCast(buf.len));
}

/// CRT write with POSIX semantics: n bytes written or -1 on error.
pub fn writeFd(fd: Fd, buf: []const u8) isize {
    return _write(fd, buf.ptr, @intCast(buf.len));
}

pub fn closeFd(fd: Fd) void {
    _ = _close(fd);
}

// --- anonymous pipe emulation (replaces std.c.pipe for the ffi-driver
//     cancellation self-pipe; CRT fds keep Python-side select() working) ---

const kernel32 = struct {
    const HANDLE = win.HANDLE;
    extern "kernel32" fn CreatePipe(
        out_read: *HANDLE,
        out_write: *HANDLE,
        attrs: ?*anyopaque,
        size: u32,
    ) callconv(.c) i32;
};

/// Create an anonymous pipe and return both ends as CRT int fds.
/// Mirrors POSIX pipe(): [0] = read end, [1] = write end.
pub fn pipeToFds() ![2]Fd {
    var read_h: kernel32.HANDLE = undefined;
    var write_h: kernel32.HANDLE = undefined;
    if (kernel32.CreatePipe(&read_h, &write_h, null, 0) == 0) {
        return error.PipeFailed;
    }
    errdefer {
        _ = win.CloseHandle(read_h);
        _ = win.CloseHandle(write_h);
    }

    const rfd = _open_osfhandle(handleToIsize(read_h), O_BINARY | O_RDONLY);
    if (rfd == INVALID_FD) {
        return error.PipeFailed;
    }
    const wfd = _open_osfhandle(handleToIsize(write_h), O_BINARY | O_WRONLY);
    if (wfd == INVALID_FD) {
        _ = _close(rfd);
        return error.PipeFailed;
    }

    return .{ rfd, wfd };
}

/// HANDLE (*anyopaque) → isize for _open_osfhandle.
fn handleToIsize(h: win.HANDLE) isize {
    const u: usize = @intFromPtr(h);
    return @bitCast(u);
}

// --- raw file HANDLE read (kernel32.ReadFile; missing from zig 0.17-dev std) ---

const k32 = struct {
    const HANDLE = win.HANDLE;
    extern "kernel32" fn ReadFile(
        h: HANDLE,
        buf: [*]u8,
        len: u32,
        out_n: *u32,
        overlapped: ?*anyopaque,
    ) callconv(.c) i32;
};

/// ReadFile wrapper returning bytes read (0 on failure/EOF).
///
/// Error-mapping note (mirrors libuv src/win/fs.c:915-924): we collapse
/// ERROR_HANDLE_EOF and ERROR_BROKEN_PIPE into "0 bytes", which callers
/// already treat as clean EOF. Other failures also map to 0 here because
/// every current caller treats 0 as terminal.
pub fn readFile(h: win.HANDLE, buf: []u8) usize {
    var n: u32 = 0;
    const ok = k32.ReadFile(h, buf.ptr, @intCast(buf.len), &n, null);
    if (ok == 0) return 0;
    return n;
}

// --- WinSock declarations ---
//
// zig 0.17-dev's std.os.windows.ws2_32 lacks several of these; declare the
// full set we need directly against ws2_32.dll in one place.

pub const ws2 = struct {
    pub const SOCKET: type = usize;
    pub const INVALID_SOCKET: SOCKET = std.math.maxInt(SOCKET);
    pub const SOCKET_ERROR: c_int = -1;

    pub const AF_INET: c_int = 2;
    pub const SOCK_STREAM: c_int = 1;
    pub const SOCK_DGRAM: c_int = 2;
    pub const IPPROTO_TCP: c_int = 6;
    pub const IPPROTO_UDP: c_int = 17;

    extern "ws2_32" fn socket(af: c_int, typ: c_int, protocol: c_int) callconv(.c) SOCKET;
    pub extern "ws2_32" fn closesocket(s: SOCKET) callconv(.c) c_int;
    extern "ws2_32" fn bind(s: SOCKET, name: *const sockaddr_in, namelen: c_int) callconv(.c) c_int;
    extern "ws2_32" fn listen(s: SOCKET, backlog: c_int) callconv(.c) c_int;
    extern "ws2_32" fn accept(s: SOCKET, addr: ?*sockaddr_in, addrlen: ?*c_int) callconv(.c) SOCKET;
    extern "ws2_32" fn connect(s: SOCKET, name: *const sockaddr_in, namelen: c_int) callconv(.c) c_int;
    extern "ws2_32" fn getsockname(s: SOCKET, name: *sockaddr_in, namelen: *c_int) callconv(.c) c_int;
    extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: c_int, flags: c_int) callconv(.c) c_int;
    extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: c_int, flags: c_int) callconv(.c) c_int;
    extern "ws2_32" fn WSAGetLastError() callconv(.c) c_int;
};

/// WinSock sockaddr_in (stable layout).
pub const sockaddr_in = extern struct {
    family: u16 = 0,
    port: u16 = 0, // network byte order
    addr: u32 = 0, // network byte order
    zero: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
};

const WSAEWOULDBLOCK: c_int = 10035;
const SOCKET_ERROR_VAL: c_int = -1;

pub const SockIoError = error{ WouldBlock, Transport };

/// recv() wrapper. WouldBlock mirrors POSIX EAGAIN for nonblocking sockets.
pub fn sockRead(sock: usize, buf: []u8) SockIoError!usize {
    const n = ws2.recv(sock, buf.ptr, @intCast(buf.len), 0);
    if (n == SOCKET_ERROR_VAL) {
        if (ws2.WSAGetLastError() == WSAEWOULDBLOCK) return error.WouldBlock;
        return error.Transport;
    }
    return @intCast(n);
}

/// send() wrapper. WouldBlock mirrors POSIX EAGAIN.
pub fn sockWrite(sock: usize, buf: []const u8) SockIoError!usize {
    const n = ws2.send(sock, buf.ptr, @intCast(buf.len), 0);
    if (n == SOCKET_ERROR_VAL) {
        if (ws2.WSAGetLastError() == WSAEWOULDBLOCK) return error.WouldBlock;
        return error.Transport;
    }
    return @intCast(n);
}

// --- loopback socketpair emulation (for ssh2 proxy jump) ---
//
// POSIX proxy jump uses AF_UNIX socketpair: libssh2 gets one end, a
// ProxyWrapper thread shuttles bytes through the other. Windows has no
// socketpair; we emulate with two interconnected loopback TCP sockets:
//
//   sockA ══════════════ sockB      (127.0.0.1 TCP connection)
//     │                     │
//     ▼                     ▼
//  given to libssh2       converted to CRT fd via sockToFd()
//  (needs a real SOCKET   (so existing pipe-style read()/write()
//   for select/ioctl)      code works unchanged)
//
// Returns raw SOCKET values; caller decides which end gets wrapped.

/// Create two connected loopback TCP sockets. Returns raw SOCKET values.
pub fn tcpSocketPair() ![2]usize {
    const listener = ws2.socket(ws2.AF_INET, ws2.SOCK_STREAM, ws2.IPPROTO_TCP);
    if (listener == ws2.INVALID_SOCKET) {
        return error.SocketPairFailed;
    }
    defer _ = ws2.closesocket(listener);

    var addr = sockaddr_in{
        .family = @intCast(ws2.AF_INET),
        .port = 0, // ephemeral port
        .addr = 0x0100007F, // 127.0.0.1, network byte order
    };

    if (ws2.bind(listener, &addr, @sizeOf(sockaddr_in)) == ws2.SOCKET_ERROR) {
        return error.SocketPairFailed;
    }
    if (ws2.listen(listener, 1) == ws2.SOCKET_ERROR) {
        return error.SocketPairFailed;
    }

    // discover the ephemeral port actually bound
    var bound: sockaddr_in = undefined;
    var bound_len: c_int = @sizeOf(sockaddr_in);
    if (ws2.getsockname(listener, &bound, &bound_len) == ws2.SOCKET_ERROR) {
        return error.SocketPairFailed;
    }

    const conn_side = ws2.socket(ws2.AF_INET, ws2.SOCK_STREAM, ws2.IPPROTO_TCP);
    if (conn_side == ws2.INVALID_SOCKET) {
        return error.SocketPairFailed;
    }

    var peer_addr = sockaddr_in{
        .family = @intCast(ws2.AF_INET),
        .port = bound.port, // already network byte order from getsockname
        .addr = 0x0100007F,
    };
    if (ws2.connect(conn_side, &peer_addr, @sizeOf(sockaddr_in)) == ws2.SOCKET_ERROR) {
        _ = ws2.closesocket(conn_side);
        return error.SocketPairFailed;
    }

    var accepted_addr: sockaddr_in = undefined;
    var accepted_len: c_int = @sizeOf(sockaddr_in);
    const server_side = ws2.accept(listener, &accepted_addr, &accepted_len);
    if (server_side == ws2.INVALID_SOCKET) {
        _ = ws2.closesocket(conn_side);
        return error.SocketPairFailed;
    }

    return .{ server_side, conn_side };
}
