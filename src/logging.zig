const std = @import("std");

/// LogLevel is an enum holding the supported log levels for libscrapli.
pub const LogLevel = enum(u8) {
    trace,
    debug,
    info,
    warn,
    critical,
    fatal,

    /// Return an instance of the LogLevel enum based on the given string, fallback to warn level.
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

/// A standard debug.print logger function.
pub fn stdLogf(level: u8, message: *[]u8) callconv(.c) void {
    switch (level) {
        @backingInt(LogLevel.trace) => {
            std.debug.print("   trace: {s}\n", .{message.*});
        },
        @backingInt(LogLevel.debug) => {
            std.debug.print("   debug: {s}\n", .{message.*});
        },
        @backingInt(LogLevel.info) => {
            std.debug.print("    info: {s}\n", .{message.*});
        },
        @backingInt(LogLevel.warn) => {
            std.debug.print("    warn: {s}\n", .{message.*});
        },
        @backingInt(LogLevel.critical) => {
            std.debug.print("critical: {s}\n", .{message.*});
        },
        @backingInt(LogLevel.fatal) => {
            std.debug.print("   fatal: {s}\n", .{message.*});

            std.process.exit(1);
        },
        else => {
            unreachable;
        },
    }
}

const loggerF = union(enum) {
    z: *const fn (level: u8, message: *[]u8) callconv(.c) void,
    ffi: struct {
        user_data: usize,
        cb: *const fn (user_data: usize, level: u8, message: *[]u8) callconv(.c) void,
    },
};

/// Logger is a simple logger for use in libscrapli.
pub const Logger = struct {
    allocator: std.mem.Allocator,
    f: ?loggerF = null,
    level: LogLevel = LogLevel.warn,

    /// Formats the message.
    fn sprintf(
        self: Logger,
        comptime format: []const u8,
        args: anytype,
    ) ?[]u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        buf.print(self.allocator, format, args) catch {
            return null;
        };

        return buf.toOwnedSlice(self.allocator) catch null;
    }

    fn emit(
        self: Logger,
        comptime level: LogLevel,
        comptime format: []const u8,
        args: anytype,
    ) void {
        if (level != LogLevel.fatal and @backingInt(self.level) > @backingInt(level)) {
            return;
        }

        const formatted_message = self.sprintf(format, args);

        defer {
            if (formatted_message) |m| {
                self.allocator.free(m);
            }
        }

        var msg: []u8 = formatted_message orelse @constCast(format);

        if (self.f) |f| {
            switch (f) {
                .z => |cb| {
                    cb(@backingInt(level), &msg);
                },
                .ffi => |ffi_cb| {
                    ffi_cb.cb(ffi_cb.user_data, @backingInt(level), &msg);
                },
            }
        }
    }

    /// Emit a log at the "trace" level.
    pub fn trace(
        self: Logger,
        comptime format: []const u8,
        args: anytype,
    ) void {
        self.emit(LogLevel.trace, format, args);
    }

    /// Emit a log at the "debug" level.
    pub fn debug(
        self: Logger,
        comptime format: []const u8,
        args: anytype,
    ) void {
        self.emit(LogLevel.debug, format, args);
    }

    /// Emit a log at the "info" level.
    pub fn info(
        self: Logger,
        comptime format: []const u8,
        args: anytype,
    ) void {
        self.emit(LogLevel.info, format, args);
    }

    /// Emit a log at the "warn" level.
    pub fn warn(
        self: Logger,
        comptime format: []const u8,
        args: anytype,
    ) void {
        self.emit(LogLevel.warn, format, args);
    }

    /// Emit a log at the "critical" level.
    pub fn critical(
        self: Logger,
        comptime format: []const u8,
        args: anytype,
    ) void {
        self.emit(LogLevel.critical, format, args);
    }

    /// Emit a log at the "fatal" level. Always emitted regardless of configured level.
    pub fn fatal(
        self: Logger,
        comptime format: []const u8,
        args: anytype,
    ) void {
        self.emit(LogLevel.fatal, format, args);
    }
};

/// Emit a trace log and include the source code file/line.
pub fn traceWithSrc(
    log: Logger,
    src: std.lang.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    const full_format = comptime "{s}:{d}: " ++ format;

    log.trace(full_format, .{ src.file, src.line } ++ args);
}
