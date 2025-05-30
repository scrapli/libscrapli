const std = @import("std");
const builtin = @import("builtin");

pub const Waiter = switch (builtin.target.os.tag) {
    .linux => struct {
        w: *@import("transport-waiter-epoll.zig").EpollWaiter,

        pub fn init(allocator: std.mem.Allocator) !Waiter {
            return Waiter{
                .w = try @import("transport-waiter-epoll.zig").EpollWaiter.init(allocator),
            };
        }

        pub fn deinit(self: Waiter) void {
            self.w.deinit();
        }

        pub fn wait(self: Waiter, fd: std.posix.fd_t) !void {
            return self.w.wait(fd);
        }

        pub fn unblock(self: Waiter) !void {
            return self.w.unblock();
        }
    },
    .macos => struct {
        w: *@import("transport-waiter-kqueue.zig").KqueueWaiter,

        pub fn init(allocator: std.mem.Allocator) !Waiter {
            return Waiter{
                .w = try @import("transport-waiter-kqueue.zig").KqueueWaiter.init(allocator),
            };
        }

        pub fn deinit(self: Waiter) void {
            self.w.deinit();
        }

        pub fn wait(self: Waiter, fd: std.posix.fd_t) !void {
            return self.w.wait(fd);
        }

        pub fn unblock(self: Waiter) !void {
            try self.w.unblock();
        }
    },
    else => @compileError("unsupported platform"),
};
