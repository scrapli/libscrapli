const std = @import("std");
const builtin = @import("builtin");

const EVADD = 0x0001;
const EVCLEAR = 0x0020;
const EVNOTETRIGGER = 0x0100;

const UNBLOCK_IDENT = 1;

pub const KqueueWaiter = struct {
    allocator: std.mem.Allocator,
    kq: std.posix.fd_t,
    fd: ?std.posix.fd_t = null,

    pub fn init(allocator: std.mem.Allocator) !*KqueueWaiter {
        const w = try allocator.create(KqueueWaiter);

        const kq = try std.posix.kqueue();

        const user_event = std.posix.Kevent{
            .ident = UNBLOCK_IDENT,
            .filter = -10, // EVFILT_USER
            .flags = EVADD | EVCLEAR,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };

        _ = try std.posix.kevent(
            kq,
            &[_]std.posix.Kevent{user_event},
            &[_]std.posix.Kevent{},
            null,
        );

        w.* = KqueueWaiter{
            .allocator = allocator,
            .kq = kq,
        };

        return w;
    }

    pub fn deinit(self: *KqueueWaiter) void {
        self.allocator.destroy(self);
    }

    fn registerFd(self: *KqueueWaiter, fd: std.posix.fd_t) !void {
        self.fd = fd;

        const ev = std.posix.Kevent{
            .ident = @intCast(fd),
            .filter = -1, // read
            .flags = EVADD | EVCLEAR,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };

        _ = try std.posix.kevent(
            self.kq,
            &[_]std.posix.Kevent{ev},
            &[_]std.posix.Kevent{},
            null,
        );
    }

    pub fn wait(self: *KqueueWaiter, fd: std.posix.fd_t) !void {
        if (self.fd == null) {
            try self.registerFd(fd);
        }

        var out: [2]std.posix.Kevent = undefined;

        _ = try std.posix.kevent(
            self.kq,
            &[_]std.posix.Kevent{},
            &out,
            null,
        );
    }

    pub fn unblock(self: *KqueueWaiter) !void {
        const event = std.posix.Kevent{
            .ident = 1,
            .filter = -10, // EVFILT_USER
            .flags = 0,
            .fflags = EVNOTETRIGGER,
            .data = 0,
            .udata = 0,
        };

        _ = try std.posix.kevent(
            self.kq,
            &[_]std.posix.Kevent{event},
            &[_]std.posix.Kevent{},
            null,
        );
    }
};
