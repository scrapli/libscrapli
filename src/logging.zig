const std = @import("std");

pub const LogLevel = enum(u8) {
    debug,
    info,
    warn,
    critical,
    fatal,
};

pub fn noopLogf(level: u8, message: *[]u8) callconv(.C) void {
    _ = level;
    _ = message;
}

pub fn stdLogf(level: u8, message: *[]u8) callconv(.C) void {
    switch (level) {
        @intFromEnum(LogLevel.debug) => {
            std.log.debug("{s}", .{message.*});
        },
        @intFromEnum(LogLevel.info) => {
            std.log.info("{s}", .{message.*});
        },
        @intFromEnum(LogLevel.warn) => {
            std.log.err("{s}", .{message.*});
        },
        @intFromEnum(LogLevel.critical) => {
            std.log.err("{s}", .{message.*});
        },
        @intFromEnum(LogLevel.fatal) => {
            std.log.err("{s}", .{message.*});

            std.posix.exit(1);
        },
        else => {
            unreachable;
        },
    }
}

pub const Logger = struct {
    allocator: std.mem.Allocator,
    f: ?*const fn (level: u8, message: *[]u8) callconv(.C) void,

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

    pub fn debug(
        self: Logger,
        comptime format: []const u8,
        args: anytype,
    ) void {
        if (self.f == null) {
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
