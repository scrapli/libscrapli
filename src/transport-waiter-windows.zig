//! Windows waiter backed by wepoll (epoll-for-Windows emulation).
//!
//! wepoll provides the same epoll_create1/epoll_ctl/epoll_wait API as Linux
//! epoll, implemented on top of IOCP. wepoll.c is compiled into the library
//! by build.zig on Windows targets; this file declares its extern entry
//! points and wraps them in the Waiter interface used by transport.zig.
const std = @import("std");

const errors = @import("errors.zig");

/// wepoll returns opaque HANDLEs; nullable so init-failure is detectable.
const WepollHandle = ?*anyopaque;

// --- wepoll.c entry points (built via addCSourceFile on windows) ---
extern fn epoll_create1(flags: c_int) callconv(.c) WepollHandle;
extern fn epoll_close(ephnd: WepollHandle) callconv(.c) c_int;
extern fn epoll_ctl(ephnd: WepollHandle, op: c_int, sock: usize, event: ?*EpollEvent) callconv(.c) c_int;
extern fn epoll_wait(ephnd: WepollHandle, events: [*]EpollEvent, maxevents: c_int, timeout: c_int) callconv(.c) c_int;

/// Mirror of struct epoll_event from wepoll.h.
const EpollEvent = extern struct {
    events: u32,
    data: extern union {
        ptr: ?*anyopaque,
        fd: i32,
        u32_: u32,
        u64_: u64,
        sock: usize,
        hnd: WepollHandle,
    },
};

const EPOLLIN: u32 = 1 << 0;
const EPOLL_CTL_ADD: c_int = 1;

// --- minimal WinSock externs ---
// zig 0.17-dev's std.os.windows.ws2_32 lacks some of these; declare the
// handful we need directly against ws2_32.dll.
const ws2 = struct {
    const SOCKET: type = usize;
    const INVALID_SOCKET: SOCKET = std.math.maxInt(SOCKET);
    const SOCKET_ERROR: i32 = -1;

    fn WSAStartupStub() void {
        // wepoll.c already calls WSAStartup internally on first use; nothing
        // needed here beyond keeping a reference for future expansion.
    }

    extern "ws2_32" fn socket(af: c_int, typ: c_int, protocol: c_int) callconv(.c) SOCKET;
    extern "ws2_32" fn closesocket(s: SOCKET) callconv(.c) i32;
    extern "ws2_32" fn bind(s: SOCKET, name: *const sockaddr_in, namelen: c_int) callconv(.c) i32;
    extern "ws2_32" fn getsockname(s: SOCKET, name: *sockaddr_in, namelen: *c_int) callconv(.c) i32;
    extern "ws2_32" fn sendto(s: SOCKET, buf: [*]const u8, len: c_int, flags: c_int, to: *const sockaddr_in, tolen: c_int) callconv(.c) i32;

    // WinSock constants (stable ABI values, not version-dependent)
    const AF_INET: c_int = 2;
    const SOCK_DGRAM: c_int = 2;
    const IPPROTO_UDP: c_int = 17;
};

const sockaddr_in = extern struct {
    family: u16 = 0,
    port: u16 = 0,
    addr: u32 = 0,
    zero: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
};

/// Is the wepoll (Windows) waiter for the transports.
pub const WindowsWaiter = struct {
    ep: WepollHandle,
    /// UDP socket bound to localhost used to wake epoll_wait from another
    /// thread (Windows has no eventfd; a loopback datagram is the cheapest
    /// portable wake-up primitive).
    wake_sock: usize = 0,

    /// Initializes the wepoll waiter plus the internal wake-up socket.
    pub fn init() !WindowsWaiter {
        const ep = epoll_create1(0);
        if (ep == null) {
            return errors.ScrapliError.Transport;
        }
        errdefer _ = epoll_close(ep);

        const sock = ws2.socket(ws2.AF_INET, ws2.SOCK_DGRAM, ws2.IPPROTO_UDP);
        if (sock == ws2.INVALID_SOCKET) {
            return errors.ScrapliError.Transport;
        }

        var addr = sockaddr_in{ .family = @intCast(ws2.AF_INET) };

        if (ws2.bind(sock, &addr, @sizeOf(sockaddr_in)) == ws2.SOCKET_ERROR) {
            _ = ws2.closesocket(sock);
            return errors.ScrapliError.Transport;
        }

        // Register the wake socket so a datagram wakes epoll_wait.
        var ev = EpollEvent{
            .events = EPOLLIN,
            .data = .{ .sock = sock },
        };
        if (epoll_ctl(ep, EPOLL_CTL_ADD, sock, &ev) != 0) {
            _ = ws2.closesocket(sock);
            return errors.ScrapliError.Transport;
        }

        return WindowsWaiter{
            .ep = ep,
            .wake_sock = sock,
        };
    }

    pub fn deinit(self: WindowsWaiter) void {
        if (self.wake_sock != 0) {
            _ = ws2.closesocket(self.wake_sock);
        }
        _ = epoll_close(self.ep);
    }

    /// Waits until the given SOCKET becomes readable or the internal wake
    /// socket receives a datagram. `fd` is a WinSock SOCKET (uintptr_t).
    pub fn wait(self: *WindowsWaiter, fd: usize) !void {
        var events: [4]EpollEvent = undefined;

        // (Re-)arm the watched socket. wepoll requires explicit ctl calls;
        // EPOLL_CTL_ADD fails with EEXIST after the first arm, which we
        // treat as success by falling back to MOD.
        var ev = EpollEvent{
            .events = EPOLLIN,
            .data = .{ .sock = fd },
        };
        const add_rc = epoll_ctl(self.ep, EPOLL_CTL_ADD, fd, &ev);
        if (add_rc != 0) {
            const EPOLL_CTL_MOD: c_int = 2;
            _ = epoll_ctl(self.ep, EPOLL_CTL_MOD, fd, &ev);
        }

        const rc = epoll_wait(self.ep, &events, events.len, -1);
        if (rc < 0) {
            return errors.ScrapliError.Transport;
        }
        // Any returned event (device data or wake datagram) unblocks the
        // caller; libscrapli re-checks device state afterwards.
    }

    /// Unblocks a concurrent wait() by sending one datagram to the loopback
    /// wake socket registered inside our epoll instance.
    pub fn unblock(self: *WindowsWaiter) !void {
        if (self.wake_sock == 0) {
            return;
        }

        // Resolve the bound port of the wake socket. The port field comes
        // back already in network byte order, so we can reuse it verbatim
        // as the sendto destination.
        var addr: sockaddr_in = undefined;
        var len: c_int = @sizeOf(sockaddr_in);
        if (ws2.getsockname(self.wake_sock, &addr, &len) == ws2.SOCKET_ERROR) {
            return errors.ScrapliError.Transport;
        }

        const payload = [_]u8{0};
        _ = ws2.sendto(
            self.wake_sock,
            &payload,
            1,
            0,
            &addr,
            @sizeOf(sockaddr_in),
        );
    }
};
