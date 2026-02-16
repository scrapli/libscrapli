const std = @import("std");

const bytes = @import("bytes.zig");
const errors = @import("errors.zig");
const file = @import("file.zig");
const logging = @import("logging.zig");
const transport_socket = @import("transport-socket.zig");
const transport_waiter = @import("transport-waiter.zig");

const control_char_iac: u8 = 255;
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

/// Holds option inputs for the telnet transport.
// zlinter-disable-next-line declaration_naming
pub const OptionsInputs = struct {};

/// Holds telnet transport options.
pub const Options = struct {
    allocator: std.mem.Allocator,

    /// Initialize the transport options.
    pub fn init(allocator: std.mem.Allocator, _: OptionsInputs) !*Options {
        const o = try allocator.create(Options);
        errdefer allocator.destroy(o);

        o.* = Options{
            .allocator = allocator,
        };

        return o;
    }

    /// Deinitialize the transport options.
    pub fn deinit(self: *Options) void {
        self.allocator.destroy(self);
    }
};

pub const Transport = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    log: logging.Logger,

    options: *Options,
    waiter: transport_waiter.Waiter,

    stream: ?std.Io.net.Stream,
    initial_buf: std.ArrayList(u8),

    r_buffer: [1024]u8 = undefined,
    reader: ?std.Io.net.Stream.Reader = null,

    w_buffer: [1024]u8 = undefined,
    writer: ?std.Io.net.Stream.Writer = null,

    /// Initialize the transport object.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        log: logging.Logger,
        options: *Options,
    ) !*Transport {
        logging.traceWithSrc(log, @src(), "telnet.Transport initializing", .{});

        const t = try allocator.create(Transport);

        t.* = Transport{
            .allocator = allocator,
            .io = io,
            .log = log,
            .options = options,
            .waiter = try transport_waiter.Waiter.init(allocator),
            .stream = null,
            .initial_buf = .{},
        };

        return t;
    }

    /// Deinitialize the transport object.
    pub fn deinit(self: *Transport) void {
        logging.traceWithSrc(self.log, @src(), "telnet.Transport deinitializing", .{});

        self.initial_buf.deinit(self.allocator);
        self.waiter.deinit();

        self.allocator.destroy(self);
    }

    fn handleControlCharResponse(
        self: *Transport,
        control_buf: *std.ArrayList(u8),
        maybe_control_char: u8,
    ) !bool {
        if (control_buf.items.len == 0) {
            if (maybe_control_char != control_char_iac) {
                try self.initial_buf.append(self.allocator, maybe_control_char);

                return true;
            } else {
                try control_buf.append(self.allocator, maybe_control_char);
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
        var control_buf: std.ArrayList(u8) = .{};
        defer control_buf.deinit(self.allocator);

        while (true) {
            if (cancel != null and cancel.?.*) {
                return errors.wrapCriticalError(
                    errors.ScrapliError.Cancelled,
                    @src(),
                    self.log,
                    "telnet.Transport handleControlChars: operation cancelled",
                    .{},
                );
            }

            if (operation_timeout_ns != 0 and start_time.untilNow(self.io, .real).nanoseconds > operation_timeout_ns) {
                return errors.wrapCriticalError(
                    errors.ScrapliError.TimeoutExceeded,
                    @src(),
                    self.log,
                    "telnet.Transport handleControlChars: operation timeout exceeded",
                    .{},
                );
            }

            var control_char_buf: [1]u8 = undefined;

            const ri = &self.reader.?.interface;

            var w: std.Io.Writer = .fixed(&control_char_buf);

            // only wait if the internal reader buffer is zero *or* the internal buffer seek is less
            // than the end position of the internal buffer -- meaning there is *not* stuff to read
            // on the internal buffer
            if (ri.end == 0 or (ri.seek >= ri.end)) {
                try self.waiter.wait(self.stream.?.socket.handle);
            }

            try ri.streamExact(&w, 1);

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

        self.stream = transport_socket.getStream(self.io, host, port) catch {
            return errors.wrapCriticalError(
                errors.ScrapliError.Transport,
                @src(),
                self.log,
                "ssh2.Transport initSocket: failed initializing socket, " ++
                    "unable to resolve host",
                .{},
            );
        };

        file.setNonBlocking(self.stream.?.socket.handle) catch {
            return errors.wrapCriticalError(
                errors.ScrapliError.Transport,
                @src(),
                self.log,
                "telnet.Transport open: failed ensuring socket set to non blocking",
                .{},
            );
        };

        self.reader = self.stream.?.reader(self.io, &self.r_buffer);
        self.writer = self.stream.?.writer(self.io, &self.w_buffer);

        try self.handleControlChars(
            start_time,
            cancel,
            operation_timeout_ns,
        );
    }

    /// Close the transport object.
    pub fn close(self: *Transport) void {
        self.log.info("telnet.Transport close requested", .{});

        if (self.stream != null) {
            self.stream.?.close(self.io);
            self.stream = null;
        }
    }

    /// Write to the transport object.
    pub fn write(self: *Transport, buf: []const u8) !void {
        self.log.info("telnet.Transport write requested", .{});

        if (self.stream == null) {
            return errors.wrapCriticalError(
                errors.ScrapliError.Transport,
                @src(),
                self.log,
                "telnet.Transport write: write attempted, but transport not opened",
                .{},
            );
        }

        _ = self.writer.?.interface.write(buf) catch |err| {
            return errors.wrapCriticalError(
                err,
                @src(),
                self.log,
                "bin.Transport write: writing to stream failed",
                .{},
            );
        };

        const wi = &self.writer.?.interface;
        try wi.flush();
    }

    /// Read from the transport object.
    pub fn read(self: *Transport, buf: []u8) !usize {
        self.log.debug("telnet.Transport read requested", .{});

        if (self.stream == null) {
            return errors.wrapCriticalError(
                errors.ScrapliError.Transport,
                @src(),
                self.log,
                "telnet.Transport read: read attempted, but transport not opened",
                .{},
            );
        }

        if (self.initial_buf.items.len > 0) {
            // drain the initial buf if it exists -- this would be any leftover chars we over-read
            // from the control char handling
            const n = @min(self.initial_buf.items.len, buf.len);

            @memcpy(buf[0..n], self.initial_buf.items[0..n]);
            _ = self.initial_buf.orderedRemove(n - 1);

            return n;
        }

        const ri = &self.reader.?.interface;

        // only wait if the internal reader buffer is zero *or* the internal buffer seek is less
        // than the end position of the internal buffer -- meaning there is *not* stuff to read
        // on the internal buffer
        if (ri.end == 0 or (ri.seek >= ri.end)) {
            try self.waiter.wait(self.stream.?.socket.handle);
        }

        var w: std.Io.Writer = .fixed(buf);

        const n = ri.stream(&w, .unlimited) catch |err| {
            // a warning as this can happen during close so we dont necessarily want to
            // log a crit
            return errors.wrapWarnError(
                err,
                @src(),
                self.log,
                "telnet.Transport read: failed reading from stream",
                .{},
            );
        };

        return n;
    }

    /// Unblock any in flight reads.
    pub fn unblock(self: *Transport) !void {
        try self.waiter.unblock();
    }
};

test "transportInit" {
    const o = try Options.init(std.testing.allocator, .{});
    const t = try Transport.init(
        std.testing.allocator,
        std.testing.io,
        logging.Logger{
            .allocator = std.testing.allocator,
        },
        o,
    );

    t.deinit();
    o.deinit();
}
