const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("sys/epoll.h");
    @cInclude("sys/eventfd.h");
});

pub const EpollWaiter = struct {
    ep: std.posix.fd_t,
    ev: std.posix.fd_t,

    pub fn init() !EpollWaiter {
        const epoll_fd = std.os.linux.epoll_create1(0);

        const event_fd = c.eventfd(0, 0);

        var event = c.epoll_event{
            .events = std.os.linux.EPOLL.IN,
            .data = .{ .fd = event_fd },
        };

        _ = c.epoll_ctl(@intCast(epoll_fd), c.EPOLL_CTL_ADD, event_fd, &event);

        return EpollWaiter{ .ep = @intCast(epoll_fd), .ev = event_fd };
    }

    pub fn wait(self: EpollWaiter, fd: std.posix.fd_t) !void {
        var event = std.os.linux.epoll_event{
            .events = std.os.linux.EPOLL.IN,
            .data = .{ .fd = fd },
        };

        // TODO i assume this returns a normal error code style thing?
        // Register once — you may want to cache this
        _ = std.os.linux.epoll_ctl(
            self.ep,
            std.os.linux.EPOLL.CTL_ADD,
            fd,
            &event,
        );

        var out: [1]std.os.linux.epoll_event = undefined;

        const n = std.os.linux.epoll_wait(self.ep, &out, 1, -1);
        if (n == 0) return error.Timeout;
    }

    pub fn unblock(self: EpollWaiter) !void {
        const val: u64 = 1;
        _ = c.write(self.ev, &val, @sizeOf(u64));
    }
};
