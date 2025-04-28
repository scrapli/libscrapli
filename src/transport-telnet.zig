const std = @import("std");
const file = @import("file.zig");
const bytes = @import("bytes.zig");
const logging = @import("logging.zig");
const errors = @import("errors.zig");

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
                self.initial_buf.append(maybe_control_char) catch |err| {
                    self.log.critical(
                        "failed to append maybe control char to control initial buf array list, err: {}",
                        .{err},
                    );

                    return errors.ScrapliError.OpenFailed;
                };

                return true;
            } else {
                control_buf.append(maybe_control_char) catch |err| {
                    self.log.critical(
                        "failed to append control char to control char array list, err: {}",
                        .{err},
                    );

                    return errors.ScrapliError.OpenFailed;
                };
            }
        } else if (control_buf.items.len == 1) {
            if (bytes.charIn(&control_chars_actionable, maybe_control_char)) {
                control_buf.append(maybe_control_char) catch |err| {
                    self.log.critical(
                        "failed to append control char to control char array list, err: {}",
                        .{err},
                    );

                    return errors.ScrapliError.OpenFailed;
                };
            } else {
                // not 100% sure this is "correct" behavior, but have seen at least EOS devices
                // send one last control char, then start sending non-actionable chars (like the
                // start of the username prompt)
                return true;
            }
        } else if (control_buf.items.len == 2) {
            const cmd = control_buf.items[1..2][0];

            control_buf.resize(0) catch |err| {
                self.log.critical(
                    "failed to zeroize control char array list, err: {}",
                    .{err},
                );

                return errors.ScrapliError.OpenFailed;
            };

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
                self.log.critical("operation cancelled", .{});

                return errors.ScrapliError.Cancelled;
            }

            const elapsed_time = timer.read();

            if (operation_timeout_ns != 0 and elapsed_time > operation_timeout_ns) {
                self.log.critical("op timeout exceeded", .{});

                return errors.ScrapliError.TimeoutExceeded;
            }

            var control_char_buf: [1]u8 = undefined;

            const n = try self.read(&control_char_buf);

            if (n == 0) {
                // we may get 0 bytes while the server is figuring its life out
                continue;
            } else if (n != 1) {
                // this would be bad obv
                self.log.critical(
                    "expected to read one control char but read {d}",
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
        self.stream = std.net.tcpConnectToHost(
            self.allocator,
            host,
            port,
        ) catch |err| {
            self.log.critical(
                "failed connecting to host '{s}', err: {}",
                .{ host, err },
            );

            return errors.ScrapliError.OpenFailed;
        };

        file.setNonBlocking(self.stream.?.handle) catch {
            self.log.critical("failed ensuring socket set to non blocking", .{});

            return errors.ScrapliError.OpenFailed;
        };

        try self.handleControlChars(
            timer,
            cancel,
            operation_timeout_ns,
        );
    }

    pub fn close(self: *Transport) void {
        if (self.stream != null) {
            self.stream.?.close();
            self.stream = null;
        }
    }

    pub fn write(self: *Transport, buf: []const u8) !void {
        if (self.stream == null) {
            return errors.ScrapliError.NotOpened;
        }

        self.stream.?.writeAll(buf) catch |err| {
            self.log.critical("failed writing to stream, err: {}", .{err});

            return errors.ScrapliError.WriteFailed;
        };
    }

    pub fn read(self: *Transport, buf: []u8) !usize {
        if (self.stream == null) {
            return errors.ScrapliError.NotOpened;
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
                    return 0;
                },
                else => {
                    self.log.critical("failed reading from stream, err: {}", .{err});

                    return errors.ScrapliError.ReadFailed;
                },
            }
        };

        return n;
    }
};
