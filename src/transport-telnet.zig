const std = @import("std");

const bytes = @import("bytes.zig");
const errors = @import("errors.zig");
const file = @import("file.zig");
const logging = @import("logging.zig");
const transport_socket = @import("transport-socket.zig");
const transport_waiter = @import("transport-waiter.zig");

const control_char_iac: u8 = 255;
const default_eagain_delay_ns: u64 = 100_000;
const control_char_do: u8 = 253;
const control_char_dont: u8 = 254;
const control_char_will: u8 = 251;
const control_char_wont: u8 = 252;
const control_char_sga: u8 = 3;

const control_chars_actionable = [4]u8{
    control_char_do,
    control_char_dont,
    control_char_will,
    control_char_wont,
};

const control_chars_actionable_do_dont = [2]u8{
    control_char_do,
    control_char_dont,
};

/// Holds telnet transport options. Clearly a placeholder as there are acutally no current telnet
/// options available.
pub const Options = struct {};

/// Transport is the telnet transport implementation.
pub const Transport = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    log: logging.Logger,

    waiter: transport_waiter.Waiter,
    closing: bool = false,

    stream: ?std.Io.net.Stream = null,
    socket: ?std.posix.socket_t = null,

    initial_buf: std.ArrayList(u8),

    last_error: [512]u8 = @splat(0),
    last_error_len: usize = 0,

    /// Initialize the transport object.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        log: logging.Logger,
    ) !Transport {
        logging.traceWithSrc(log, @src(), "telnet.Transport initializing", .{});

        var w = try transport_waiter.Waiter.init();
        errdefer w.deinit();

        return Transport{
            .allocator = allocator,
            .io = io,
            .log = log,
            .waiter = w,
            .initial_buf = .empty,
        };
    }

    /// Deinitialize the transport object.
    pub fn deinit(self: *Transport) void {
        logging.traceWithSrc(self.log, @src(), "telnet.Transport deinitializing", .{});

        self.initial_buf.deinit(self.allocator);
        self.waiter.deinit();
    }

    fn setLastError(
        self: *Transport,
        s: []const u8,
    ) void {
        const len = @min(s.len, self.last_error.len);

        @memcpy(self.last_error[0..len], s[0..len]);
        self.last_error_len = len;
    }

    fn handleControlCharResponse(
        self: *Transport,
        control_buf: *std.ArrayList(u8),
        maybe_control_char: u8,
    ) !bool {
        if (control_buf.items.len == 0) {
            if (maybe_control_char == control_char_iac) {
                try control_buf.append(self.allocator, maybe_control_char);
            } else {
                try self.initial_buf.append(self.allocator, maybe_control_char);

                return true;
            }
        } else if (control_buf.items.len == 1) {
            if (bytes.charIn(&control_chars_actionable, maybe_control_char)) {
                try control_buf.append(self.allocator, maybe_control_char);
            } else {
                // not 100% sure this is "correct" behavior, but have seen at least EOS devices
                // send one last control char, then start sending non-actionable chars (like the
                // start of the username prompt)
                return true;
            }
        } else if (control_buf.items.len == 2) {
            const cmd = control_buf.items[1..2][0];

            try control_buf.resize(self.allocator, 0);

            if (cmd == control_char_do and maybe_control_char == control_char_sga) {
                const seq = [3]u8{
                    control_char_iac,
                    control_char_will,
                    maybe_control_char,
                };
                try self.write(&seq);
            } else if (bytes.charIn(&control_chars_actionable_do_dont, cmd)) {
                const seq = [3]u8{
                    control_char_iac,
                    control_char_wont,
                    maybe_control_char,
                };
                try self.write(&seq);
            } else if (cmd == control_char_will) {
                const seq = [3]u8{
                    control_char_iac,
                    control_char_do,
                    maybe_control_char,
                };
                try self.write(&seq);
            } else if (cmd == control_char_wont) {
                const seq = [3]u8{
                    control_char_iac,
                    control_char_dont,
                    maybe_control_char,
                };
                try self.write(&seq);
            }
        }

        // still handling control chars...
        return false;
    }

    fn handleControlChars(
        self: *Transport,
        start_time: std.Io.Timestamp,
        cancel: ?*bool,
        operation_timeout_ns: u64,
    ) !void {
        var control_buf: std.ArrayList(u8) = .empty;
        defer control_buf.deinit(self.allocator);

        while (true) {
            if (cancel != null and cancel.?.*) {
                const last_error = "telnet.Transport handleControlChars: operation cancelled";

                self.setLastError(last_error);

                return errors.wrapCriticalError(
                    errors.ScrapliError.Cancelled,
                    @src(),
                    self.log,
                    last_error,
                    .{},
                );
            }

            if (operation_timeout_ns != 0 and start_time.untilNow(
                self.io,
                .awake,
            ).nanoseconds > operation_timeout_ns) {
                const last_error = "telnet.Transport handleControlChars: operation timeout exceeded";

                self.setLastError(last_error);

                return errors.wrapCriticalError(
                    errors.ScrapliError.TimeoutExceeded,
                    @src(),
                    self.log,
                    last_error,
                    .{},
                );
            }

            var control_char_buf: [1]u8 = undefined;

            const n = std.posix.read(self.socket.?, &control_char_buf) catch |err| switch (err) {
                error.WouldBlock => {
                    // zlinter-disable-next-line no_swallow_error - best effort backoff
                    self.io.sleep(
                        .{
                            .nanoseconds = default_eagain_delay_ns,
                        },
                        .awake,
                    ) catch {};

                    continue;
                },
                else => return err,
            };
            if (n == 0) {
                const last_error = "telnet.Transport handleControlChars: peer closed connection " ++
                    "during telnet negotiation";

                self.setLastError(last_error);

                return errors.wrapCriticalError(
                    errors.ScrapliError.Transport,
                    @src(),
                    self.log,
                    last_error,
                    .{},
                );
            }
            const done = try self.handleControlCharResponse(
                &control_buf,
                control_char_buf[0],
            );

            if (done) {
                return;
            }
        }
    }

    /// Open the transport object.
    pub fn open(
        self: *Transport,
        start_time: std.Io.Timestamp,
        cancel: ?*bool,
        operation_timeout_ns: u64,
        host: []const u8,
        port: u16,
    ) !void {
        self.log.info("telnet.Transport open requested", .{});

        self.stream = transport_socket.getStream(self.io, self.log, host, port) catch {
            self.setLastError(
                "telnet.Transport initSocket: failed initializing socket unable to resolve host",
            );

            return errors.wrapCriticalError(
                errors.ScrapliError.Transport,
                @src(),
                self.log,
                "telnet.Transport initSocket: failed initializing socket, " ++
                    "unable to resolve host '{s}'",
                .{host},
            );
        };

        self.socket = self.stream.?.socket.handle;

        file.setNonBlocking(self.socket.?) catch {
            const last_error = "telnet.Transport open: failed ensuring socket set to non blocking";

            self.setLastError(last_error);

            return errors.wrapCriticalError(
                errors.ScrapliError.Transport,
                @src(),
                self.log,
                last_error,
                .{},
            );
        };

        try self.handleControlChars(
            start_time,
            cancel,
            operation_timeout_ns,
        );
    }

    /// Close the transport object.
    pub fn close(self: *Transport) void {
        self.log.info("telnet.Transport close requested", .{});

        if (self.stream) |stream| {
            stream.close(self.io);
            self.stream = null;
            self.socket = null;
        }
    }

    /// Write to the transport object.
    pub fn write(self: *Transport, buf: []const u8) !void {
        self.log.debug("telnet.Transport write requested", .{});

        if (self.socket == null) {
            const last_error = "telnet.Transport write: write attempted, but transport not opened";

            self.setLastError(last_error);

            return errors.wrapCriticalError(
                errors.ScrapliError.Transport,
                @src(),
                self.log,
                last_error,
                .{},
            );
        }

        var written: usize = 0;
        while (written < buf.len) {
            const rc = std.posix.system.write(
                self.socket.?,
                buf[written..].ptr,
                buf[written..].len,
            );
            switch (std.posix.errno(rc)) {
                .SUCCESS => written += @intCast(rc),
                std.posix.E.AGAIN => {
                    // the socket is deliberately nonblocking, so eagain just means the kernel
                    // buffer is full (i.e. a payload bigger than the buffer) -- back off briefly
                    // and keep writing rather than failing a healthy session
                    // zlinter-disable-next-line no_swallow_error - best effort backoff
                    self.io.sleep(
                        .{
                            .nanoseconds = default_eagain_delay_ns,
                        },
                        .awake,
                    ) catch {};
                },
                else => |err| {
                    const last_error = "telnet.Transport write: writing to stream failed";

                    self.setLastError(last_error);

                    return errors.wrapCriticalError(
                        std.posix.unexpectedErrno(err),
                        @src(),
                        self.log,
                        last_error,
                        .{},
                    );
                },
            }
        }
    }

    /// Read from the transport object.
    pub fn read(self: *Transport, buf: []u8) !usize {
        self.log.trace("telnet.Transport read requested", .{});

        if (self.socket == null) {
            const last_error = "telnet.Transport read: read attempted, but transport not opened";

            self.setLastError(last_error);

            return errors.wrapCriticalError(
                errors.ScrapliError.Transport,
                @src(),
                self.log,
                last_error,
                .{},
            );
        }

        if (self.initial_buf.items.len > 0) {
            const n = @min(self.initial_buf.items.len, buf.len);
            @memcpy(buf[0..n], self.initial_buf.items[0..n]);

            try self.initial_buf.replaceRange(
                self.allocator,
                0,
                n,
                "",
            );

            return n;
        }

        while (true) {
            try self.waiter.wait(self.socket.?);

            if (self.closing) {
                return 0;
            }

            const n = std.posix.read(self.socket.?, buf) catch |err| {
                const last_error = "telnet.Transport read: failed reading from stream";

                self.setLastError(last_error);

                return errors.wrapWarnError(
                    err,
                    @src(),
                    self.log,
                    last_error,
                    .{},
                );
            };

            if (n == 0) {
                return n;
            }

            if (buf[0] == control_char_iac) {
                // a telnet negotiation byte leaked into a normal read; drop this chunk and wait
                // for the next one rather than recursing, which could overflow the stack if the
                // peer streams IAC bytes
                continue;
            }

            return n;
        }
    }

    /// Unblocks any in progress reads and sets the prepare close flag, this prevents us from
    /// making a final read the fd that we are about to nuke.
    pub fn prepareClose(self: *Transport) !void {
        self.closing = true;
        try self.waiter.unblock();
    }
};

test "transportInit" {
    var t = try Transport.init(
        std.testing.allocator,
        std.testing.io,
        logging.Logger{
            .allocator = std.testing.allocator,
        },
    );

    t.deinit();
}

test "refAllDecls" {
    std.testing.refAllDecls(Transport);
}

fn transportInitForAllocFailures(allocator: std.mem.Allocator) anyerror!void {
    var t = try Transport.init(
        allocator,
        std.testing.io,
        logging.Logger{
            .allocator = allocator,
        },
    );

    t.deinit();
}

test "transportInitAllocationFailures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        transportInitForAllocFailures,
        .{},
    );
}
