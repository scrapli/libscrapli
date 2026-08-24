const std = @import("std");
const builtin = @import("builtin");

/// Waiter returns a wrapper around the appropriate waiter for the target os -- epoll for linux,
/// kqueue for darwin.
pub const Waiter: type = switch (builtin.target.os.tag) {
    .linux => struct {
        w: @import("transport-waiter-epoll.zig").EpollWaiter,

        /// Initializes the waiter.
        pub fn init() !Waiter {
            return Waiter{
                .w = try @import("transport-waiter-epoll.zig").EpollWaiter.init(),
            };
        }

        /// Deinitializes the waiter.
        pub fn deinit(self: *Waiter) void {
            self.w.deinit();
        }

        /// Waits for the fd to be readable.
        pub fn wait(self: *Waiter, fd: std.posix.fd_t) !void {
            return self.w.wait(fd);
        }

        /// Unblocks the waiter.
        pub fn unblock(self: *Waiter) !void {
            return self.w.unblock();
        }
    },
    .macos => struct {
        w: @import("transport-waiter-kqueue.zig").KqueueWaiter,

        /// Initializes the waiter.
        pub fn init() !Waiter {
            return Waiter{
                .w = try @import("transport-waiter-kqueue.zig").KqueueWaiter.init(),
            };
        }

        /// Deinitializes the waiter.
        pub fn deinit(self: *Waiter) void {
            self.w.deinit();
        }

        /// Waits for the fd to be readable.
        pub fn wait(self: *Waiter, fd: std.posix.fd_t) !void {
            return self.w.wait(fd);
        }

        /// Unblocks the waiter.
        pub fn unblock(self: *Waiter) !void {
            try self.w.unblock();
        }
    },
    .windows => struct {
        w: @import("transport-waiter-windows.zig").WindowsWaiter,

        /// Initializes the waiter.
        pub fn init() !Waiter {
            return Waiter{
                .w = try @import("transport-waiter-windows.zig").WindowsWaiter.init(),
            };
        }

        /// Deinitializes the waiter.
        pub fn deinit(self: *Waiter) void {
            self.w.deinit();
        }

        /// Waits for the fd to become readable. Accepts either a WinSock
        /// SOCKET (usize) or an OS HANDLE (pointer), normalizing both into
        /// the uintptr_t SOCKET representation wepoll expects.
        pub fn wait(self: *Waiter, fd: anytype) !void {
            const sock: usize = switch (@typeInfo(@TypeOf(fd))) {
                .int, .comptime_int => @intCast(fd),
                .pointer => @intFromPtr(fd),
                else => @compileError("wait(fd): expected int fd or HANDLE pointer"),
            };
            return self.w.wait(sock);
        }

        /// Unblocks the waiter.
        pub fn unblock(self: *Waiter) !void {
            try self.w.unblock();
        }
    },
    else => @compileError("unsupported platform"),
};

test "refAllDecls" {
    std.testing.refAllDecls(Waiter);
}
