const std = @import("std");

const errors = @import("errors.zig");

const unblock_ident = 1;

/// Is the kqueue (darwin) waiter for the transports.
pub const KqueueWaiter = struct {
    allocator: std.mem.Allocator,
    kq: std.posix.fd_t,
    fd: ?std.posix.fd_t = null,

    /// Initializes the kqueue waiter.
    pub fn init(allocator: std.mem.Allocator) !*KqueueWaiter {
        const w = try allocator.create(KqueueWaiter);

        const kq = try std.Io.Kqueue.createFileDescriptor();

        const user_event = std.posix.Kevent{
            .ident = unblock_ident,
            .filter = std.c.EVFILT.USER,
            .flags = std.c.EV.ADD | std.c.EV.CLEAR,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };

        const rc = std.c.kevent(
            kq,
            &[_]std.posix.Kevent{user_event},
            1,
            &[_]std.posix.Kevent{},
            0,
            null,
        );
        if (rc == -1) {
            return errors.ScrapliError.Transport;
        }

        w.* = KqueueWaiter{
            .allocator = allocator,
            .kq = kq,
        };

        return w;
    }

    /// Deinitializes the kqueue waiter.
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

        const rc = std.c.kevent(
            self.kq,
            &[_]std.posix.Kevent{ev},
            1,
            &[_]std.posix.Kevent{},
            0,
            null,
        );
        if (rc == -1) {
            return errors.ScrapliError.Transport;
        }
    }

    /// Waits until the given fd has something to read, or if the fd is unblocked.
    pub fn wait(self: *KqueueWaiter, fd: std.posix.fd_t) !void {
        if (self.fd == null) {
            try self.registerFd(fd);
        }

        // fairly sure we need this to be sized to 2 -- for each event type we care about receiving
        // -- that is the there is data available and our unblock messages
        var out: [2]std.posix.Kevent = undefined;

        const o_out = &out;
        const changelist = &[_]std.posix.Kevent{};

        while (true) {
            const rc = std.posix.system.kevent(
                self.kq,
                changelist.ptr,
                std.math.cast(c_int, changelist.len) orelse return error.Overflow,
                o_out.ptr,
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

    /// Unblocks the waiter when it is waiting.
    pub fn unblock(self: *KqueueWaiter) !void {
        const event = std.posix.Kevent{
            .ident = unblock_ident,
            .filter = std.c.EVFILT.USER,
            .flags = 0,
            .fflags = std.c.NOTE.TRIGGER,
            .data = 0,
            .udata = 0,
        };

        const rc = std.c.kevent(
            self.kq,
            &[_]std.posix.Kevent{event},
            1,
            &[_]std.posix.Kevent{},
            0,
            null,
        );
        if (rc == -1) {
            return errors.ScrapliError.Transport;
        }
    }
};
