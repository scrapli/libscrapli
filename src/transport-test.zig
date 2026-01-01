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

    pub fn deinit(self: *Options) void {
        if (self.f != null) {
            self.allocator.free(self.f.?);
        }

        self.allocator.destroy(self);
    }
};

pub const Transport = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    options: *Options,

    // we do a zillion reads, but w/e having the intermediate buffer be 1 seems to be marginally
    // faster than having it be bigger for some reason
    r_buffer: [1]u8 = undefined,
    reader: ?std.Io.File.Reader,

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

    pub fn deinit(self: *Transport) void {
        self.allocator.destroy(self);
    }

    pub fn open(self: *Transport, cancel: ?*bool) !void {
        // ignored for file because nothing to cancel!
        _ = cancel;

        if (self.options.f == null) {
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

    pub fn close(self: *Transport) void {
        self.reader.?.file.close(self.io);
    }

    pub fn write(self: *Transport, buf: []const u8) !void {
        _ = self;
        _ = buf;
    }

    pub fn read(self: *Transport, buf: []u8) !usize {
        const ri = &self.reader.?.interface;

        const n = try ri.readSliceShort(buf);

        return n;
    }
};
