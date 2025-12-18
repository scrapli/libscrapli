const std = @import("std");
const builtin = @import("builtin");

/// Waiter returns a wrapper around the appropriate waiter for the target os -- epoll for linux,
/// kqueue for darwin.
pub const Waiter: type = switch (builtin.target.os.tag) {
    .linux => struct {
        w: *@import("transport-waiter-epoll.zig").EpollWaiter,

        /// Initializes the waiter.
        pub fn init(allocator: std.mem.Allocator) !Waiter {
            return Waiter{
                .w = try @import("transport-waiter-epoll.zig").EpollWaiter.init(allocator),
            };
        }

        /// Deinitializes the waiter.
        pub fn deinit(self: Waiter) void {
            self.w.deinit();
        }

        /// Waits for the fd to be readable.
        pub fn wait(self: Waiter, fd: std.posix.fd_t) !void {
            return self.w.wait(fd);
        }

        /// Unblocks the waiter.
        pub fn unblock(self: Waiter) !void {
            return self.w.unblock();
        }
    },
    .macos => struct {
        w: *@import("transport-waiter-kqueue.zig").KqueueWaiter,

        /// Initializes the waiter.
        pub fn init(allocator: std.mem.Allocator) !Waiter {
            return Waiter{
                .w = try @import("transport-waiter-kqueue.zig").KqueueWaiter.init(allocator),
            };
        }

        /// Deinitializes the waiter.
        pub fn deinit(self: Waiter) void {
            self.w.deinit();
        }

        /// Waits for the fd to be readable.
        pub fn wait(self: Waiter, fd: std.posix.fd_t) !void {
            return self.w.wait(fd);
        }

        /// Unblocks the waiter.
        pub fn unblock(self: Waiter) !void {
            try self.w.unblock();
        }
    },
    else => @compileError("unsupported platform"),
};
