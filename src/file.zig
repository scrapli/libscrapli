const std = @import("std");
const builtin = @import("builtin");

const errors = @import("errors.zig");

// zig 0.17-dev's std.os.windows.ws2_32 lacks ioctlsocket; declare it directly.
extern "ws2_32" fn ioctlsocket(s: usize, cmd: c_int, argp: *u32) callconv(.c) c_int;
fn ws2_ioctlsocket_compat(s: usize, cmd: c_int, argp: *u32) c_int {
    return ioctlsocket(s, cmd, argp);
}

/// Conveinence function to set the given fd to be in non block.
/// Accepts whatever the platform's descriptor type is: POSIX int fd, or on
/// Windows either a WinSock SOCKET (usize) or an OS HANDLE (pointer).
pub fn setNonBlocking(fd: anytype) !void {
    if (builtin.target.os.tag == .windows) {
        // fcntl/F.GETFL doesn't exist on Windows; use ioctlsocket(FIONBIO),
        // which covers the socket case exercised by ssh2/telnet transports.
        // FIONBIO = 0x8004667E — exceeds c_int positive range, so bitcast.
        const FIONBIO: c_int = @bitCast(@as(u32, 0x8004667E));
        const sock: usize = switch (@typeInfo(@TypeOf(fd))) {
            .int, .comptime_int => @intCast(fd),
            .pointer => @intFromPtr(fd),
            else => @compileError("setNonBlocking: expected int fd or HANDLE pointer"),
        };
        var mode: u32 = 1; // enable non-blocking
        if (ws2_ioctlsocket_compat(sock, FIONBIO, &mode) == -1) {
            return errors.ScrapliError.CError;
        }
        return;
    }
    var flags = std.posix.system.fcntl(
        fd,
        std.posix.system.F.GETFL,
        @as(usize, 0),
    );
    if (flags == -1) {
        return errors.ScrapliError.CError;
    }

    // would have thought there would be a portable std.posix.O.NONBLOCK but
    // seems that doesnt exist on darwin but this does work on darwin? then
    // darwin was content doing c.O_NONBLOCK but for some reason fnctl things
    // were not getting transalted nicely on linux-gnu... so this should work
    // on darwin+linux(gnu/musl)
    flags |= @as(usize, 1 << @bitOffsetOf(std.posix.O, "NONBLOCK"));

    const rc = std.posix.system.fcntl(
        fd,
        std.posix.system.F.SETFL,
        flags,
    );
    if (rc == -1) {
        return errors.ScrapliError.CError;
    }
}

/// Conveinence function return a reader from the given path. buf is passed in for lifetime
/// reasons of course, so needs to be allocated outside of this.
pub fn readerFromPath(
    io: std.Io,
    buf: []u8,
    path: []const u8,
) !std.Io.File.Reader {
    const f = try std.Io.Dir.openFile(std.Io.Dir.cwd(), io, path, .{});
    return f.reader(io, buf);
}

/// Conveinence function to read teh contents of a file at path, owner owns returned memory.
pub fn readFromPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const f = try std.Io.Dir.openFile(std.Io.Dir.cwd(), io, path, .{});
    defer f.close(io);

    var r_buf: [1024]u8 = undefined;
    var r = f.reader(io, &r_buf);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try std.Io.Reader.appendRemainingUnlimited(&r.interface, allocator, &out);

    return try out.toOwnedSlice(allocator);
}

/// Conveinence function to write the given contents to the provided path.
pub fn writeToPath(io: std.Io, path: []const u8, data: []const u8) !void {
    const f = try std.Io.Dir.createFile(std.Io.Dir.cwd(), io, path, .{});
    try f.writeStreamingAll(io, data);
}
