const std = @import("std");

/// Is the epoll (linux) waiter for the transports.
pub const EpollWaiter = struct {
    allocator: std.mem.Allocator,
    ep: std.posix.fd_t,
    ev: std.posix.fd_t,
    fd: ?std.posix.fd_t = null,

    /// Initializes the epoll waiter.
    pub fn init(allocator: std.mem.Allocator) !*EpollWaiter {
        const w = try allocator.create(EpollWaiter);

        const epoll_fd = std.posix.system.epoll_create1(0);
        const event_fd = std.posix.system.eventfd(0, 0);

        var event = std.posix.system.epoll_event{
            .events = std.os.linux.EPOLL.IN,
            .data = .{ .fd = event_fd },
        };

        _ = std.posix.system.epoll_ctl(
            @intCast(epoll_fd),
            std.os.linux.EPOLL.CTL_ADD,
            event_fd,
            &event,
        );

        w.* = EpollWaiter{
            .allocator = allocator,
            .ep = @intCast(epoll_fd),
            .ev = event_fd,
        };

        return w;
    }

    /// Deinitializes the epoll waiter.
    pub fn deinit(self: *EpollWaiter) void {
        _ = std.posix.system.close(self.ep);
        _ = std.posix.system.close(self.ev);

        self.allocator.destroy(self);
    }

    /// Waits until the given fd has something to read, or if the fd is unblocked.
    pub fn wait(self: *EpollWaiter, fd: std.posix.fd_t) !void {
        if (self.fd == null) {
            self.fd = fd;

            var event = std.posix.system.epoll_event{
                .events = std.os.linux.EPOLL.IN,
                .data = .{ .fd = fd },
            };

            _ = std.posix.system.epoll_ctl(
                self.ep,
                std.os.linux.EPOLL.CTL_ADD,
                fd,
                &event,
            );
        }

        var out: [1]std.posix.system.epoll_event = .{
            std.mem.zeroes(std.posix.system.epoll_event),
        };

        _ = std.posix.system.epoll_wait(self.ep, &out, 1, -1);
    }

    /// Unblocks the waiter when it is waiting.
    pub fn unblock(self: EpollWaiter) !void {
        const val: u64 = 1;
        const bytes = std.mem.asBytes(&val);

        _ = std.posix.system.write(self.ev, bytes.ptr, @sizeOf(u64));
    }
};
