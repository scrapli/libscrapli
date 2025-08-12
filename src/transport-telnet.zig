const std = @import("std");
const file = @import("file.zig");
const bytes = @import("bytes.zig");
const logging = @import("logging.zig");
const errors = @import("errors.zig");
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

pub const OptionsInputs = struct {};

pub const Options = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, _: OptionsInputs) !*Options {
        const o = try allocator.create(Options);
        errdefer allocator.destroy(o);

        o.* = Options{
            .allocator = allocator,
        };

        return o;
    }

    pub fn deinit(self: *Options) void {
        self.allocator.destroy(self);
    }
};

pub const Transport = struct {
    allocator: std.mem.Allocator,
    log: logging.Logger,

    options: *Options,

    stream: ?std.net.Stream,
    initial_buf: std.ArrayList(u8),

    pub fn init(
        allocator: std.mem.Allocator,
        log: logging.Logger,
        options: *Options,
    ) !*Transport {
        logging.traceWithSrc(log, @src(), "telnet.Transport initializing", .{});

        const t = try allocator.create(Transport);

        t.* = Transport{
            .allocator = allocator,
            .log = log,
            .options = options,
            .stream = null,
            .initial_buf = std.ArrayList(u8).init(allocator),
        };

        return t;
    }

    pub fn deinit(self: *Transport) void {
        logging.traceWithSrc(self.log, @src(), "telnet.Transport deinitializing", .{});

        self.initial_buf.deinit();
        self.allocator.destroy(self);
    }

    fn handleControlCharResponse(
        self: *Transport,
        control_buf: *std.ArrayList(u8),
        maybe_control_char: u8,
    ) !bool {
        if (control_buf.items.len == 0) {
            if (maybe_control_char != control_char_iac) {
                try self.initial_buf.append(maybe_control_char);

                return true;
            } else {
                try control_buf.append(maybe_control_char);
            }
        } else if (control_buf.items.len == 1) {
            if (bytes.charIn(&control_chars_actionable, maybe_control_char)) {
                try control_buf.append(maybe_control_char);
            } else {
                // not 100% sure this is "correct" behavior, but have seen at least EOS devices
                // send one last control char, then start sending non-actionable chars (like the
                // start of the username prompt)
                return true;
            }
        } else if (control_buf.items.len == 2) {
            const cmd = control_buf.items[1..2][0];

            try control_buf.resize(0);

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
        timer: *std.time.Timer,
        cancel: ?*bool,
        operation_timeout_ns: u64,
    ) !void {
        var control_buf = std.ArrayList(u8).init(self.allocator);
        defer control_buf.deinit();

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

            const elapsed_time = timer.read();

            if (operation_timeout_ns != 0 and elapsed_time > operation_timeout_ns) {
                return errors.wrapCriticalError(
                    errors.ScrapliError.TimeoutExceeded,
                    @src(),
                    self.log,
                    "telnet.Transport handleControlChars: operation timeout exceeded",
                    .{},
                );
            }

            var control_char_buf: [1]u8 = undefined;

            const n = try self.read(null, &control_char_buf);

            if (n == 0) {
                // we may get 0 bytes while the server is figuring its life out
                continue;
            } else if (n != 1) {
                // this would be bad obv
                self.log.critical(
                    "telnet.Transport handleControlChars: expected to read one control char but read {d}",
                    .{n},
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

    pub fn open(
        self: *Transport,
        timer: *std.time.Timer,
        cancel: ?*bool,
        operation_timeout_ns: u64,
        host: []const u8,
        port: u16,
    ) !void {
        self.log.info("telnet.Transport open requested", .{});

        self.stream = std.net.tcpConnectToHost(
            self.allocator,
            host,
            port,
        ) catch |err| {
            return errors.wrapCriticalError(
                errors.ScrapliError.Transport,
                @src(),
                self.log,
                "telnet.Transport open: failed connecting to host '{s}', err: {}",
                .{ host, err },
            );
        };

        file.setNonBlocking(self.stream.?.handle) catch {
            return errors.wrapCriticalError(
                errors.ScrapliError.Transport,
                @src(),
                self.log,
                "telnet.Transport open: failed ensuring socket set to non blocking",
                .{},
            );
        };

        try self.handleControlChars(
            timer,
            cancel,
            operation_timeout_ns,
        );
    }

    pub fn close(self: *Transport) void {
        self.log.info("telnet.Transport close requested", .{});

        if (self.stream != null) {
            self.stream.?.close();
            self.stream = null;
        }
    }

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

        self.stream.?.writeAll(buf) catch |err| {
            return errors.wrapCriticalError(
                err,
                @src(),
                self.log,
                "telnet.Transport write: transport write failed",
                .{},
            );
        };
    }

    pub fn read(self: *Transport, w: ?transport_waiter.Waiter, buf: []u8) !usize {
        self.log.info("telnet.Transport read requested", .{});

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

        const n = self.stream.?.read(buf) catch |err| {
            switch (err) {
                error.WouldBlock => {
                    if (w) |waiter| {
                        try waiter.wait(self.stream.?.handle);
                    }

                    return 0;
                },
                else => {
                    return errors.wrapCriticalError(
                        errors.ScrapliError.Transport,
                        @src(),
                        self.log,
                        "telnet.Transport read: transport read failed",
                        .{},
                    );
                },
            }
        };

        return n;
    }
};
