const std = @import("std");
const transport = @import("transport.zig");
const file = @import("file.zig");
const logger = @import("logger.zig");

pub fn NewOptions() transport.ImplementationOptions {
    return transport.ImplementationOptions{ .Test = Options{
        .f = null,
        .netconf = false,
    } };
}

pub const Options = struct {
    f: ?[]const u8,
    netconf: bool,
};

pub fn NewTransport(
    allocator: std.mem.Allocator,
    log: logger.Logger,
    host: []const u8,
    base_options: transport.Options,
    options: Options,
) !*Transport {
    const t = try allocator.create(Transport);

    t.* = Transport{
        .allocator = allocator,
        .log = log,
        .host = host,
        .base_options = base_options,
        .options = options,
        .reader = null,
    };

    return t;
}

pub const Transport = struct {
    allocator: std.mem.Allocator,
    log: logger.Logger,

    host: []const u8,
    base_options: transport.Options,
    options: Options,

    reader: ?std.fs.File.Reader,

    pub fn init(self: *Transport) !void {
        _ = self;
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

        self.reader = try file.ReaderFromPath(self.allocator, self.options.f.?);
    }

    pub fn close(self: *Transport) void {
        _ = self;
    }

    pub fn write(self: *Transport, buf: []const u8) !void {
        _ = self;
        _ = buf;
    }

    pub fn read(self: *Transport, buf: []u8) !usize {
        const n = self.reader.?.read(buf) catch |err| {
            switch (err) {
                error.WouldBlock => {
                    return 0;
                },
                else => {
                    return error.ReadFailed;
                },
            }
        };

        // we'll just read 0 bytes when eof, would be probably bad to not report eof upstream in
        // a "normal" transport, but doesnt matter for the test one

        return n;
    }
};
