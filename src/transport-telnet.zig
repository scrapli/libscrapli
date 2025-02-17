const std = @import("std");
const transport = @import("transport.zig");
const file = @import("file.zig");
const bytes = @import("bytes.zig");
const logger = @import("logger.zig");

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

pub fn NewOptions() transport.ImplementationOptions {
    return transport.ImplementationOptions{ .Telnet = Options{} };
}

pub const Options = struct {};

pub fn NewTransport(
    allocator: std.mem.Allocator,
    log: logger.Logger,
    host: []const u8,
    base_options: transport.Options,
    options: Options,
) !*Transport {
    const t = try allocator.create(Transport);

    t.* = Transport{
        .allocator = allocator,
        .log = log,
        .host = host,
        .base_options = base_options,
        .options = options,
        .stream = null,
        .initial_buf = std.ArrayList(u8).init(allocator),
    };

    return t;
}

pub const Transport = struct {
    allocator: std.mem.Allocator,
    log: logger.Logger,

    host: []const u8,
    base_options: transport.Options,
    options: Options,

    stream: ?std.net.Stream,
    initial_buf: std.ArrayList(u8),

    pub fn init(self: *Transport) !void {
        _ = self;
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
                    self.log.critical("failed to append maybe control char to control initial buf array list, err: {}", .{err});

                    return error.OpenFailed;
                };

                return true;
            } else {
                control_buf.append(maybe_control_char) catch |err| {
                    self.log.critical("failed to append control char to control char array list, err: {}", .{err});

                    return error.OpenFailed;
                };
            }
        } else if (control_buf.items.len == 1 and bytes.charIn(&control_chars_actionable, maybe_control_char)) {
            control_buf.append(maybe_control_char) catch |err| {
                self.log.critical("failed to append control char to control char array list, err: {}", .{err});

                return error.OpenFailed;
            };
        } else if (control_buf.items.len == 2) {
            const cmd = control_buf.items[1..2][0];

            control_buf.resize(0) catch |err| {
                self.log.critical("failed to zeroize control char array list, err: {}", .{err});

                return error.OpenFailed;
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

    fn handleControlChars(self: *Transport, cancel: ?*bool) !void {
        var control_buf = std.ArrayList(u8).init(self.allocator);
        defer control_buf.deinit();

        while (true) {
            if (cancel != null and cancel.?.*) {
                self.log.critical("operation cancelled", .{});

                return error.Cancelled;
            }

            var control_char_buf: [1]u8 = undefined;

            const n = try self.read(&control_char_buf);

            if (n != 1) {
                // this would be bad obv
                self.log.critical("expected to read one control char but read {d}", .{n});
            }

            const done = try self.handleControlCharResponse(&control_buf, control_char_buf[0]);

            if (done) {
                return;
            }
        }
    }

    pub fn open(self: *Transport, cancel: ?*bool) !void {
        self.stream = std.net.tcpConnectToHost(
            self.allocator,
            self.host,
            self.base_options.port,
        ) catch |err| {
            self.log.critical("failed connecting to host '{s}', err: {}", .{ self.host, err });

            return error.OpenFailed;
        };

        file.setNonBlocking(self.stream.?.handle) catch {
            self.log.critical("failed ensuring socket set to non blocking", .{});

            return error.OpenFailed;
        };

        try self.handleControlChars(cancel);
    }

    pub fn close(self: *Transport) void {
        if (self.stream != null) {
            self.stream.?.close();
            self.stream = null;
        }
    }

    pub fn write(self: *Transport, buf: []const u8) !void {
        if (self.stream == null) {
            return error.NotOpened;
        }

        self.stream.?.writeAll(buf) catch |err| {
            self.log.critical("failed writing to stream, err: {}", .{err});

            return error.WriteFailed;
        };
    }

    pub fn read(self: *Transport, buf: []u8) !usize {
        if (self.stream == null) {
            return error.NotOpened;
        }

        const n = self.stream.?.read(buf) catch |err| {
            switch (err) {
                error.WouldBlock => {
                    return 0;
                },
                else => {
                    self.log.critical("failed reading from stream, err: {}", .{err});

                    return error.ReadFailed;
                },
            }
        };

        return n;
    }
};
