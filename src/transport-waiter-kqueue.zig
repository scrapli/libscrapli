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

        const oOut = &out;
        const changelist = &[_]std.posix.Kevent{};

        while (true) {
            const rc = std.posix.system.kevent(
                self.kq,
                changelist.ptr,
                std.math.cast(c_int, changelist.len) orelse return error.Overflow,
                oOut.ptr,
                std.math.cast(c_int, out.len) orelse return error.Overflow,
                null,
            );
            switch (std.posix.errno(rc)) {
                .SUCCESS => return,
                .ACCES => return error.AccessDenied,
                .FAULT => unreachable,
                // in std lib BADF is unreachable, but in our case we may have a process shot
                // out from under us (like on connection refused and fd gets freed right away)
                // because we are exec'ing /bin/ssh, so... we just return an EOF rather than
                // unreachable
                .BADF => return error.EOF,
                .INTR => continue,
                .INVAL => unreachable,
                .NOENT => return error.EventNotFound,
                .NOMEM => return error.SystemResources,
                .SRCH => return error.ProcessNotFound,
                else => unreachable,
            }
        }
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
