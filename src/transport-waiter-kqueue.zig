const std = @import("std");

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
            .filter = std.c.EVFILT.USER,
            .flags = std.c.EV.ADD | std.c.EV.CLEAR,
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
        std.posix.close(self.kq);
        self.allocator.destroy(self);
    }

    fn registerFd(self: *KqueueWaiter, fd: std.posix.fd_t) !void {
        self.fd = fd;

        const ev = std.posix.Kevent{
            .ident = @intCast(fd),
            .filter = std.c.EVFILT.READ,
            .flags = std.c.EV.ADD | std.c.EV.CLEAR,
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

        // fairly sure we need this to be sized to 2 -- for each event type we care about receiving
        // -- that is the there is data available and our unblock messages
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
            .ident = UNBLOCK_IDENT,
            .filter = std.c.EVFILT.USER,
            .flags = 0,
            .fflags = std.c.NOTE.TRIGGER,
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
