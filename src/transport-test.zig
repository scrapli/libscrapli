const std = @import("std");

const errors = @import("errors.zig");
const file = @import("file.zig");

/// Holds option inputs for the test transport.
pub const OptionsInputs = struct {
    f: ?[]const u8 = null,
};

/// Holds test transport options.
pub const Options = struct {
    allocator: std.mem.Allocator,
    f: ?[]const u8,

    /// Initialize the transport options.
    pub fn init(allocator: std.mem.Allocator, opts: OptionsInputs) !*Options {
        const o = try allocator.create(Options);
        errdefer allocator.destroy(o);

        o.* = Options{
            .allocator = allocator,
            .f = opts.f,
        };

        if (o.f != null) {
            o.f = try o.allocator.dupe(u8, o.f.?);
        }

        return o;
    }

    /// Deinitialize the transport options.
    pub fn deinit(self: *Options) void {
        if (self.f != null) {
            self.allocator.free(self.f.?);
        }

        self.allocator.destroy(self);
    }
};

/// The "test" transport -- basically read from a file instead of a socket/ssh session.
pub const Transport = struct {
    io: std.Io,

    options: *Options,

    fd: ?std.posix.fd_t = null,

    /// Initialize the transport object.
    pub fn init(
        io: std.Io,
        options: *Options,
    ) !Transport {
        return Transport{
            .io = io,
            .options = options,
            .fd = null,
        };
    }

    /// Deinitialize the transport object.
    pub fn deinit(self: *Transport) void {
        _ = self;
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
