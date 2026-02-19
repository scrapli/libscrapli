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
    allocator: std.mem.Allocator,
    io: std.Io,

    options: *Options,

    // we do a zillion reads, but w/e having the intermediate buffer be 1 seems to be marginally
    // faster than having it be bigger for some reason
    r_buffer: [1]u8 = undefined,
    reader: ?std.Io.File.Reader,

    /// Initialize the transport object.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: *Options,
    ) !*Transport {
        const t = try allocator.create(Transport);

        t.* = Transport{
            .allocator = allocator,
            .io = io,
            .options = options,
            .reader = null,
        };

        return t;
    }

    /// Deinitialize the transport object.
    pub fn deinit(self: *Transport) void {
        self.allocator.destroy(self);
    }

    /// Open the transport object.
    pub fn open(self: *Transport, cancel: ?*bool) !void {
        // ignored for file because nothing to cancel!
        _ = cancel;

        if (self.options.f == null) {
            // zlinter-disable-next-line no_panic - should never happen
            @panic("must set file for test transport!");
        }

        self.reader = try file.readerFromPath(
            self.io,
            &self.r_buffer,
            self.options.f.?,
        );

        file.setNonBlocking(self.reader.?.file.handle) catch {
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
        self.reader.?.file.close(self.io);
    }

    /// Write to the transport object. A noop for the test transport.
    pub fn write(self: *Transport, buf: []const u8) !void {
        _ = self;
        _ = buf;
    }

    /// Read from the transport object.
    pub fn read(self: *Transport, buf: []u8) !usize {
        const ri = &self.reader.?.interface;

        const n = try ri.readSliceShort(buf);

        return n;
    }
};
