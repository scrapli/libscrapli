const std = @import("std");

const errors = @import("errors.zig");
const file = @import("file.zig");
const transport_waiter = @import("transport-waiter.zig");

pub const Pause = struct {
    pos: usize,
    ns: u64,
};

/// Holds test transport options.
pub const Options = struct {
    f: ?[]const u8 = null,
    content: ?[]const u8 = null,

    pause_at: ?[]const Pause = null,

    eof_at: ?usize = null,

    fn init(allocator: std.mem.Allocator, opts: Options) !Options {
        var o = opts;

        // reset the owned pointer field so a failed dupe below never frees the caller's memory
        o.f = null;

        errdefer o.deinit(allocator);

        if (opts.f) |f| {
            o.f = try allocator.dupe(u8, f);
        }

        if (opts.content) |content| {
            o.content = try allocator.dupe(u8, content);
        }

        if (opts.pause_at) |pause_at| {
            o.pause_at = try allocator.dupe(Pause, pause_at);
        }

        return o;
    }

    fn deinit(self: Options, allocator: std.mem.Allocator) void {
        if (self.f) |f| {
            allocator.free(f);
        }

        if (self.content) |content| {
            allocator.free(content);
        }

        if (self.pause_at) |pause| {
            allocator.free(pause);
        }
    }
};

/// The "test" transport -- basically read from a file instead of a socket/ssh session.
pub const Transport = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    options: Options,

    closing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fd: ?std.posix.fd_t = null,

    cur_pos: usize = 0,

    /// Initialize the transport object.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: Options,
    ) !Transport {
        var o = try Options.init(allocator, options);
        errdefer o.deinit(allocator);

        return Transport{
            .allocator = allocator,
            .io = io,
            .options = o,
            .fd = null,
        };
    }

    /// Deinitialize the transport object.
    pub fn deinit(self: *Transport) void {
        self.options.deinit(self.allocator);
    }

    /// Open the transport object.
    pub fn open(self: *Transport, cancel: ?*bool) !void {
        // ignored for file because nothing to cancel!
        _ = cancel;

        if (self.options.content != null) {
            return;
        }

        if (self.options.f == null) {
            // zlinter-disable-next-line no_panic - should never happen
            @panic("must set file for test transport!");
        }

        const f = try std.Io.Dir.cwd().openFile(
            self.io,
            self.options.f.?,
            .{ .mode = .read_only },
        );
        self.fd = f.handle;

        file.setNonBlocking(self.fd.?) catch {
            return errors.wrapCriticalError(
                errors.ScrapliError.Transport,
                @src(),
                null,
                "test.Transport open: failed ensuring file set to non blocking",
                .{},
            );
        };
    }

    /// Close the transport object.
    pub fn getLastError(self: *Transport) []const u8 {
        _ = self;

        return "";
    }

    /// In test transport cose we do the poor mans waiter signaling basically.
    pub fn prepareClose(self: *Transport) !void {
        self.closing.store(true, std.lang.AtomicOrder.release);
    }

    pub fn close(self: *Transport) void {
        if (self.fd) |fd| {
            _ = std.c.close(fd);

            self.fd = null;
        }
    }

    /// Write to the transport object. A noop for the test transport.
    pub fn write(self: *Transport, buf: []const u8) !void {
        _ = self;
        _ = buf;
    }

    fn readFd(self: *Transport, buf: []u8) !usize {
        var n: usize = 0;

        // buf *should* always be 1 for test transport, though that is not explicitly enforced but
        // rather expected that testers set it, so rather than  increment by 1 we'll just increment
        // by the actual n we read
        defer self.cur_pos += n;

        n = std.posix.read(self.fd.?, buf) catch |err| {
            switch (err) {
                error.WouldBlock => return 0,
                else => return err,
            }
        };

        return n;
    }

    fn readContent(self: *Transport, buf: []u8) !usize {
        const content = self.options.content.?;

        if (self.cur_pos >= content.len) {
            return 0;
        }

        const n = @min(buf.len, content.len - self.cur_pos);

        @memcpy(buf[0..n], content[self.cur_pos..][0..n]);

        self.cur_pos += n;

        return n;
    }

    /// Read from the transport object.
    pub fn read(self: *Transport, buf: []u8) !usize {
        if (self.options.eof_at) |eof_pos| {
            if (eof_pos == self.cur_pos) {
                return errors.ScrapliError.EOF;
            }
        }

        if (self.options.pause_at) |pauses| {
            for (pauses) |pause| {
                if (pause.pos != self.cur_pos) {
                    continue;
                }

                const now = std.Io.Clock.now(.awake, self.io);
                const pause_until = now.addDuration(.fromNanoseconds(@intCast(pause.ns)));

                while (true) {
                    // rather than faff w/ waiter and signaling and blah we'll do a poor mans tight
                    // loop sleepy+atomic check
                    try self.io.sleep(.fromMilliseconds(1), .awake);

                    if (self.closing.load(std.lang.AtomicOrder.acquire)) {
                        return 0;
                    }

                    if (std.Io.Clock.now(.awake, self.io).compare(.gte, pause_until)) {
                        break;
                    }
                }
            }
        }

        if (self.fd != null) {
            return self.readFd(buf);
        }

        return self.readContent(buf);
    }
};

test "refAllDecls" {
    std.testing.refAllDecls(Transport);
}

fn optionsInitForAllocFailures(allocator: std.mem.Allocator) !void {
    // options w/ the owned field populated so allocation failures exercise the partial-failure
    // cleanup path (and would catch any invalid free of caller owned memory)
    const o = try Options.init(
        allocator,
        .{
            .f = "/some/file",
        },
    );

    o.deinit(allocator);
}

test "optionsInitAllocationFailures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        optionsInitForAllocFailures,
        .{},
    );
}
