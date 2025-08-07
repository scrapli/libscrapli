const std = @import("std");

pub const LogLevel = enum(u8) {
    trace,
    debug,
    info,
    warn,
    critical,
    fatal,

    pub fn fromString(s: []const u8) LogLevel {
        if (std.mem.eql(u8, s, "trace")) {
            return LogLevel.trace;
        } else if (std.mem.eql(u8, s, "debug")) {
            return LogLevel.debug;
        } else if (std.mem.eql(u8, s, "info")) {
            return LogLevel.info;
        } else if (std.mem.eql(u8, s, "warn")) {
            return LogLevel.warn;
        } else if (std.mem.eql(u8, s, "critical")) {
            return LogLevel.critical;
        } else if (std.mem.eql(u8, s, "fatal")) {
            return LogLevel.fatal;
        } else {
            return LogLevel.warn;
        }
    }
};

pub fn stdLogf(level: u8, message: *[]u8) callconv(.C) void {
    switch (level) {
        @intFromEnum(LogLevel.trace) => {
            std.debug.print("   trace: {s}\n", .{message.*});
        },
        @intFromEnum(LogLevel.debug) => {
            std.debug.print("   debug: {s}\n", .{message.*});
        },
        @intFromEnum(LogLevel.info) => {
            std.debug.print("    info: {s}\n", .{message.*});
        },
        @intFromEnum(LogLevel.warn) => {
            std.debug.print("    warn: {s}\n", .{message.*});
        },
        @intFromEnum(LogLevel.critical) => {
            std.debug.print("critical: {s}\n", .{message.*});
        },
        @intFromEnum(LogLevel.fatal) => {
            std.debug.print("   fatal: {s}\n", .{message.*});

            std.posix.exit(1);
        },
        else => {
            unreachable;
        },
    }
}

pub const Logger = struct {
    allocator: std.mem.Allocator,
    f: ?*const fn (level: u8, message: *[]u8) callconv(.C) void = null,
    level: LogLevel = LogLevel.warn,

    fn sprintf(
        self: Logger,
        comptime format: []const u8,
        args: anytype,
    ) []u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        std.fmt.format(buf.writer(), format, args) catch {
            // fail with unformatted message worst case
            return @constCast(format);
        };

        // caller of sprintf must free!
        const formatted_buf = buf.toOwnedSlice() catch {
            // fail with unformatted message worst case
            return @constCast(format);
        };

        return formatted_buf;
    }

    pub fn trace(
        self: Logger,
        comptime format: []const u8,
        args: anytype,
    ) void {
        if (self.f == null) {
            return;
        }

        if (@intFromEnum(self.level) > @intFromEnum(LogLevel.trace)) {
            return;
        }

        var formatted_message = self.sprintf(format, args);
        defer self.allocator.free(formatted_message);

        self.f.?(@intFromEnum(LogLevel.trace), &formatted_message);
    }

    pub fn debug(
        self: Logger,
        comptime format: []const u8,
        args: anytype,
    ) void {
        if (self.f == null) {
            return;
        }

        if (@intFromEnum(self.level) > @intFromEnum(LogLevel.debug)) {
            return;
        }

        var formatted_message = self.sprintf(format, args);
        defer self.allocator.free(formatted_message);

        self.f.?(@intFromEnum(LogLevel.debug), &formatted_message);
    }

    pub fn info(
        self: Logger,
        comptime format: []const u8,
        args: anytype,
    ) void {
        if (self.f == null) {
            return;
        }

        if (@intFromEnum(self.level) > @intFromEnum(LogLevel.info)) {
            return;
        }

        var formatted_message = self.sprintf(format, args);
        defer self.allocator.free(formatted_message);

        self.f.?(@intFromEnum(LogLevel.info), &formatted_message);
    }

    pub fn warn(
        self: Logger,
        comptime format: []const u8,
        args: anytype,
    ) void {
        if (self.f == null) {
            return;
        }

        if (@intFromEnum(self.level) > @intFromEnum(LogLevel.warn)) {
            return;
        }

        var formatted_message = self.sprintf(format, args);
        defer self.allocator.free(formatted_message);

        self.f.?(@intFromEnum(LogLevel.warn), &formatted_message);
    }

    pub fn critical(
        self: Logger,
        comptime format: []const u8,
        args: anytype,
    ) void {
        if (self.f == null) {
            return;
        }

        if (@intFromEnum(self.level) > @intFromEnum(LogLevel.critical)) {
            return;
        }

        var formatted_message = self.sprintf(format, args);
        defer self.allocator.free(formatted_message);

        self.f.?(@intFromEnum(LogLevel.critical), &formatted_message);
    }

    pub fn fatal(
        self: Logger,
        comptime format: []const u8,
        args: anytype,
    ) void {
        if (self.f == null) {
            return;
        }

        var formatted_message = self.sprintf(format, args);
        defer self.allocator.free(formatted_message);

        self.f.?(@intFromEnum(LogLevel.fatal), &formatted_message);
    }
};

pub fn traceWithSrc(
    log: Logger,
    src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    const full_format = comptime "{s}:{d}: " ++ format;

    log.trace(full_format, .{ src.file, src.line } ++ args);
}
