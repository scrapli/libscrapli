const std = @import("std");

const errors = @import("errors.zig");
const file = @import("file.zig");

pub const OptionsInputs = struct {
    f: ?[]const u8 = null,
};

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

    options: *Options,

    r_buffer: [1024]u8 = undefined,
    reader: ?std.fs.File.Reader,

    pub fn init(
        allocator: std.mem.Allocator,
        options: *Options,
    ) !*Transport {
        const t = try allocator.create(Transport);

        t.* = Transport{
            .allocator = allocator,
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

        self.reader = try file.ReaderFromPath(
            self.allocator,
            &self.r_buffer,
            self.options.f.?,
        );
    }

    pub fn close(self: *Transport) void {
        _ = self;
    }

    pub fn write(self: *Transport, buf: []const u8) !void {
        _ = self;
        _ = buf;
    }

    pub fn read(self: *Transport, buf: []u8) !usize {
        const n = self.reader.?.read(buf) catch {
            return errors.wrapCriticalError(
                errors.ScrapliError.Transport,
                @src(),
                null,
                "transport read failed",
                .{},
            );
        };

        // we'll just read 0 bytes when eof, would be probably bad to not report eof upstream in
        // a "normal" transport, but doesnt matter for the test one
        return n;
    }
};
