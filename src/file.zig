const std = @import("std");
const errors = @import("errors.zig");

const c = @cImport({
    @cDefine("_XOPEN_SOURCE", "500");
    @cInclude("fcntl.h");
});

// tried this in zig and couldn't get it to work... no idea
// fn setNonBlocking(fd: std.posix.fd_t) !void {
//     var flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
//
//     flags |= std.posix.SOCK.NONBLOCK;
//
//     _ = try std.posix.fcntl(fd, std.posix.F.SETFL, flags);
// }
pub fn setNonBlocking(fd: std.posix.fd_t) !void {
    var got_flags = c.fcntl(fd, c.F_GETFL);
    if (got_flags == -1) {
        return error.SetNonBlockingFailed;
    }

    got_flags |= c.O_NONBLOCK;

    const set_flags_ret = c.fcntl(fd, c.F_SETFL, got_flags);
    if (set_flags_ret == -1) {
        return error.SetNonBlockingFailed;
    }
}

pub fn resolveAbsolutePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, path, "~")) {
        const resolved = std.fs.realpathAlloc(
            allocator,
            path,
        ) catch |err| switch (err) {
            error.FileNotFound => {
                var dir = try std.fs.cwd().openDir(std.fs.path.dirname(path).?, .{});
                defer dir.close();

                var f = try dir.createFile(std.fs.path.basename(path), .{});
                defer f.close();

                return resolveAbsolutePath(allocator, path);
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

    return std.fs.realpathAlloc(allocator, expanded_path);
}

pub fn ReaderFromPath(allocator: std.mem.Allocator, path: []const u8) !std.fs.File.Reader {
    const resolved_path = try resolveAbsolutePath(allocator, path);
    defer allocator.free(resolved_path);

    const f = try std.fs.openFileAbsolute(resolved_path, .{});
    return f.reader();
}

pub fn readFromPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const resolved_path = try resolveAbsolutePath(allocator, path);
    defer allocator.free(resolved_path);

    const f = try std.fs.openFileAbsolute(resolved_path, .{});
    const content = try f.readToEndAlloc(
        allocator,
        std.math.maxInt(usize),
    );

    return content;
}

pub fn writeToPath(allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const resolved_path = try resolveAbsolutePath(allocator, path);
    defer allocator.free(resolved_path);

    const f = try std.fs.createFileAbsolute(resolved_path, .{});
    try f.writeAll(data);
}
