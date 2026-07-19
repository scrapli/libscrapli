const std = @import("std");

const errors = @import("errors.zig");

/// Is the epoll (linux) waiter for the transports.
pub const EpollWaiter = struct {
    ep: std.posix.fd_t,
    ev: std.posix.fd_t,
    fd: ?std.posix.fd_t = null,

    /// Initializes the epoll waiter.
    pub fn init() !EpollWaiter {
        const epoll_rc = std.posix.system.epoll_create1(0);
        if (std.posix.errno(epoll_rc) != .SUCCESS) {
            return errors.ScrapliError.Transport;
        }

        const epoll_fd: std.posix.fd_t = @intCast(epoll_rc);
        errdefer _ = std.posix.system.close(epoll_fd);

        const event_rc = std.posix.system.eventfd(0, 0);
        if (std.posix.errno(event_rc) != .SUCCESS) {
            return errors.ScrapliError.Transport;
        }

        const event_fd: std.posix.fd_t = @intCast(event_rc);
        errdefer _ = std.posix.system.close(event_fd);

        var event = std.posix.system.epoll_event{
            .events = std.os.linux.EPOLL.IN,
            .data = .{ .fd = event_fd },
        };

        const ctl_rc = std.posix.system.epoll_ctl(
            epoll_fd,
            std.os.linux.EPOLL.CTL_ADD,
            event_fd,
            &event,
        );
        if (std.posix.errno(ctl_rc) != .SUCCESS) {
            return errors.ScrapliError.Transport;
        }

        return EpollWaiter{
            .ep = epoll_fd,
            .ev = event_fd,
        };
    }

    /// Deinitializes the epoll waiter.
    pub fn deinit(self: EpollWaiter) void {
        _ = std.posix.system.close(self.ep);
        _ = std.posix.system.close(self.ev);
    }

    /// Waits until the given fd has something to read, or until the waiter is unblocked.
    pub fn wait(self: *EpollWaiter, fd: std.posix.fd_t) !void {
        if (self.fd == null) {
            var event = std.posix.system.epoll_event{
                .events = std.os.linux.EPOLL.IN,
                .data = .{ .fd = fd },
            };

            const ctl_rc = std.posix.system.epoll_ctl(
                self.ep,
                std.os.linux.EPOLL.CTL_ADD,
                fd,
                &event,
            );
            if (std.posix.errno(ctl_rc) != .SUCCESS) {
                return errors.ScrapliError.Transport;
            }

            self.fd = fd;
        }

        while (true) {
            var out: [2]std.posix.system.epoll_event = .{
                std.mem.zeroes(std.posix.system.epoll_event),
                std.mem.zeroes(std.posix.system.epoll_event),
            };

            const rc = std.posix.system.epoll_wait(self.ep, &out, out.len, -1);

            switch (std.posix.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return errors.ScrapliError.Transport,
            }

            const ready_count: usize = @intCast(rc);

            for (out[0..ready_count]) |out_event| {
                if (out_event.data.fd == self.ev) {
                    var drain: u64 = 0;
                    _ = std.posix.system.read(
                        self.ev,
                        std.mem.asBytes(&drain),
                        @sizeOf(u64),
                    );
                }
            }

            return;
        }
    }

    /// Unblocks the waiter when it is waiting.
    pub fn unblock(self: EpollWaiter) !void {
        const val: u64 = 1;

        const rc = std.posix.system.write(
            self.ev,
            std.mem.asBytes(&val),
            @sizeOf(u64),
        );
        if (std.posix.errno(rc) != .SUCCESS) {
            return errors.ScrapliError.Transport;
        }
    }
};
