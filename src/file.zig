const std = @import("std");
const builtin = @import("builtin");

pub fn setNonBlocking(fd: std.posix.fd_t) !void {
    var flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);

    // would have thought there would be a portable std.posix.O.NONBLOCK but
    // seems that doesnt exist on darwin but this does work on darwin? then
    // darwin was content doing c.O_NONBLOCK but for some reason fnctl things
    // were not getting transalted nicely on linux-gnu... so this should work
    // on darwin+linux(gnu/musl)
    flags |= @as(usize, 1 << @bitOffsetOf(std.posix.O, "NONBLOCK"));

    _ = try std.posix.fcntl(fd, std.posix.F.SETFL, flags);
}

pub fn resolveAbsolutePath(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, path, "~")) {
        const resolved = std.Io.Dir.realPathFileAbsoluteAlloc(
            io,
            path,
            allocator,
        ) catch |err| switch (err) {
            error.FileNotFound => {
                var dir = try std.Io.Dir.cwd().openDir(io, std.fs.path.dirname(path).?, .{});
                defer dir.close(io);

                var f = try dir.createFile(io, std.fs.path.basename(path), .{});
                defer f.close(io);

                return resolveAbsolutePath(io, allocator, path);
            },
            else => {
                return err;
            },
        };

        return resolved;
    }

    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    const expanded_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ home, path[2..] },
    );
    defer allocator.free(expanded_path);

    return std.Io.Dir.realPathFileAbsoluteAlloc(io, expanded_path, allocator);
}

// buf is passed in for lifetime reasons of course, so needs to be allocated outside of this
pub fn readerFromPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    buf: []u8,
    path: []const u8,
) !std.Io.File.Reader {
    const resolved_path = try resolveAbsolutePath(io, allocator, path);
    defer allocator.free(resolved_path);

    const f = try std.Io.Dir.openFileAbsolute(io, resolved_path, .{});
    return f.reader(io, buf);
}

pub fn readFromPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const resolved_path = try resolveAbsolutePath(io, allocator, path);
    defer allocator.free(resolved_path);

    const f = try std.Io.Dir.openFileAbsolute(io, resolved_path, .{});

    var r_buf: [1024]u8 = undefined;
    var r = f.reader(io, &r_buf);

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);

    try std.Io.Reader.appendRemainingUnlimited(&r.interface, allocator, &out);

    return try out.toOwnedSlice(allocator);
}

pub fn writeToPath(io: std.Io, allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const resolved_path = try resolveAbsolutePath(io, allocator, path);
    defer allocator.free(resolved_path);

    const f = try std.Io.Dir.createFileAbsolute(io, resolved_path, .{});
    try f.writeStreamingAll(io, data);
}
