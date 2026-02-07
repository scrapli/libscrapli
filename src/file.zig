const std = @import("std");
const builtin = @import("builtin");

const c = @cImport(
    {
        @cInclude("fcntl.h");
        @cInclude("unistd.h");
        @cInclude("errno.h");
    },
);

pub fn setNonBlocking(fd: std.posix.fd_t) !void {
    const flags = c.fcntl(fd, std.posix.F.GETFL, @as(usize, 0));
    if (flags == -1) {
        return error.CError;
    }

    const rc = c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK);
    if (rc == -1) {
        return error.CError;
    }
}

// buf is passed in for lifetime reasons of course, so needs to be allocated outside of this
pub fn readerFromPath(
    io: std.Io,
    buf: []u8,
    path: []const u8,
) !std.Io.File.Reader {
    const f = try std.Io.Dir.openFile(std.Io.Dir.cwd(), io, path, .{});
    return f.reader(io, buf);
}

pub fn readFromPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const f = try std.Io.Dir.openFile(std.Io.Dir.cwd(), io, path, .{});

    var r_buf: [1024]u8 = undefined;
    var r = f.reader(io, &r_buf);

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);

    try std.Io.Reader.appendRemainingUnlimited(&r.interface, allocator, &out);

    return try out.toOwnedSlice(allocator);
}

pub fn writeToPath(io: std.Io, path: []const u8, data: []const u8) !void {
    const f = try std.Io.Dir.createFile(std.Io.Dir.cwd(), io, path, .{});
    try f.writeStreamingAll(io, data);
}
