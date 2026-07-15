const std = @import("std");

const errors = @import("errors.zig");
const file = @import("file.zig");

/// Holds test transport options.
pub const Options = struct {
    f: ?[]const u8 = null,

    fn init(opts: Options, allocator: std.mem.Allocator) !Options {
        var o = opts;
        errdefer o.deinit(allocator);

        if (opts.f) |f| {
            o.f = try allocator.dupe(u8, f);
        }

        return o;
    }

    fn deinit(self: Options, allocator: std.mem.Allocator) void {
        if (self.f) |f| {
            allocator.free(f);
        }
    }
};

/// The "test" transport -- basically read from a file instead of a socket/ssh session.
pub const Transport = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    options: Options,

    fd: ?std.posix.fd_t = null,

    /// Initialize the transport object.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: Options,
    ) !Transport {
        var o = try Options.init(options, allocator);
        errdefer o.deinit(allocator);

        return Transport{
            .allocator = allocator,
            .io = io,
            .options = o,
            .fd = null,
        };
    }

    /// Deinitialize the transport object.
    pub fn deinit(self: *Transport) void {
        self.options.deinit(self.allocator);
    }

    /// Open the transport object.
    pub fn open(self: *Transport, cancel: ?*bool) !void {
        // ignored for file because nothing to cancel!
        _ = cancel;

        if (self.options.f == null) {
            // zlinter-disable-next-line no_panic - should never happen
            @panic("must set file for test transport!");
        }

        const f = try std.Io.Dir.cwd().openFile(
            self.io,
            self.options.f.?,
            .{ .mode = .read_only },
        );
        self.fd = f.handle;

        file.setNonBlocking(self.fd.?) catch {
            return errors.wrapCriticalError(
                errors.ScrapliError.Transport,
                @src(),
                null,
                "test.Transport open: failed ensuring file set to non blocking",
                .{},
            );
        };
    }

    /// Close the transport object.
    pub fn close(self: *Transport) void {
        if (self.fd) |fd| {
            _ = std.c.close(fd);

            self.fd = null;
        }
    }

    /// Write to the transport object. A noop for the test transport.
    pub fn write(self: *Transport, buf: []const u8) !void {
        _ = self;
        _ = buf;
    }

    /// Read from the transport object.
    pub fn read(self: *Transport, buf: []u8) !usize {
        const n = std.posix.read(self.fd.?, buf) catch |err| {
            switch (err) {
                error.WouldBlock => return 0,
                else => return err,
            }
        };

        return n;
    }
};
