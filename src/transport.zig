const std = @import("std");
const transport_bin = @import("transport-bin.zig");
const transport_telnet = @import("transport-telnet.zig");
const transport_ssh2 = @import("transport-ssh2.zig");
const transport_test = @import("transport-test.zig");
const logger = @import("logger.zig");
const lookup = @import("lookup.zig");

pub const AuthOptions = struct {
    is_in_session: bool,
    username: ?[]const u8,
    password: ?[]const u8,
    passphrase: ?[]const u8,
    lookup_fn: lookup.LookupFn,
};

pub const Kind = enum {
    Bin,
    Telnet,
    SSH2,
    Test,

    pub fn toString(self: Kind) []const u8 {
        switch (self) {
            .Bin => {
                return "bin";
            },
            .Telnet => {
                return "telnet";
            },
            .SSH2 => {
                return "ssh2";
            },
            .Test => {
                return "test";
            },
        }
    }
};

pub const Implementation = union(Kind) {
    Bin: *transport_bin.Transport,
    Telnet: *transport_telnet.Transport,
    SSH2: *transport_ssh2.Transport,
    Test: *transport_test.Transport,
};

pub const Options = union(Kind) {
    Bin: transport_bin.Options,
    Telnet: transport_telnet.Options,
    SSH2: transport_ssh2.Options,
    Test: transport_test.Options,
};

pub fn Factory(
    allocator: std.mem.Allocator,
    log: logger.Logger,
    options: Options,
) !*Transport {
    const t = try allocator.create(Transport);

    switch (options) {
        .Bin => {
            t.* = Transport{
                .allocator = allocator,
                .log = log,
                .implementation = Implementation{
                    .Bin = try transport_bin.NewTransport(
                        allocator,
                        log,
                        options.Bin,
                    ),
                },
            };
        },
        .Telnet => {
            t.* = Transport{
                .allocator = allocator,
                .log = log,
                .implementation = Implementation{
                    .Telnet = try transport_telnet.NewTransport(
                        allocator,
                        log,
                        options.Telnet,
                    ),
                },
            };
        },
        .SSH2 => {
            t.* = Transport{
                .allocator = allocator,
                .log = log,
                .implementation = Implementation{
                    .SSH2 = try transport_ssh2.NewTransport(
                        allocator,
                        log,
                        options.SSH2,
                    ),
                },
            };
        },
        .Test => {
            t.* = Transport{
                .allocator = allocator,
                .log = log,
                .implementation = Implementation{
                    .Test = try transport_test.NewTransport(
                        allocator,
                        options.Test,
                    ),
                },
            };
        },
    }

    return t;
}

pub const Transport = struct {
    allocator: std.mem.Allocator,
    log: logger.Logger,
    implementation: Implementation,

    pub fn init(self: *Transport) !void {
        switch (self.implementation) {
            Kind.Bin => |t| {
                try t.init();
            },
            Kind.Telnet => |t| {
                try t.init();
            },
            Kind.SSH2 => |t| {
                try t.init();
            },
            Kind.Test => |t| {
                try t.init();
            },
        }
    }

    pub fn deinit(self: *Transport) void {
        switch (self.implementation) {
            Kind.Bin => |t| {
                t.deinit();
            },
            Kind.Telnet => |t| {
                t.deinit();
            },
            Kind.SSH2 => |t| {
                t.deinit();
            },
            Kind.Test => |t| {
                t.deinit();
            },
        }

        self.allocator.destroy(self);
    }

    pub fn open(
        self: *Transport,
        timer: *std.time.Timer,
        cancel: ?*bool,
        operation_timeout_ns: u64,
        host: []const u8,
        port: u16,
        username: ?[]const u8,
        password: ?[]const u8,
        private_key_path: ?[]const u8,
        passphrase: ?[]const u8,
        lookup_fn: lookup.LookupFn,
    ) !void {
        self.log.debug("transport open start...", .{});

        switch (self.implementation) {
            Kind.Bin => |t| {
                // bin transport doesnt need the timer, since we just pass the timeout value to
                // to the cli args and let openssh do it, then the rest of the timing out bits
                // happen in in session auth
                try t.open(operation_timeout_ns, host, port, username, private_key_path);
            },
            Kind.Telnet => |t| {
                try t.open(timer, cancel, operation_timeout_ns, host, port);
            },
            Kind.SSH2 => |t| {
                try t.open(
                    timer,
                    cancel,
                    operation_timeout_ns,
                    host,
                    port,
                    username,
                    password,
                    private_key_path,
                    passphrase,
                    lookup_fn,
                );
            },
            Kind.Test => |t| {
                try t.open(cancel);
            },
        }

        self.log.debug("transport open successful...", .{});
    }

    pub fn isInSessionAuth(
        self: *Transport,
    ) bool {
        switch (self.implementation) {
            Kind.Bin, Kind.Telnet, Kind.Test => {
                return true;
            },
            else => {
                return false;
            },
        }
    }

    // close can never error, worst case we just tear down and free the underlying handle/session
    // this allows the session to ensure that the transport gets closed during deinit so its always
    // nicely tidied up.
    pub fn close(self: *Transport) void {
        self.log.debug("transport close start...", .{});

        switch (self.implementation) {
            Kind.Bin => |t| {
                t.close();
            },
            Kind.Telnet => |t| {
                t.close();
            },
            Kind.SSH2 => |t| {
                t.close();
            },
            Kind.Test => |t| {
                t.close();
            },
        }

        self.log.debug("transport close successful...", .{});
    }

    pub fn write(self: *Transport, buf: []const u8) !void {
        self.log.debug("transport write start, writing '{s}'", .{buf});

        switch (self.implementation) {
            Kind.Bin => |t| {
                try t.write(buf);
            },
            Kind.Telnet => |t| {
                try t.write(buf);
            },
            Kind.SSH2 => |t| {
                try t.write(buf);
            },
            Kind.Test => |t| {
                try t.write(buf);
            },
        }

        self.log.debug("transport write sucessful...", .{});
    }

    pub fn read(self: *Transport, buf: []u8) !usize {
        var n: usize = 0;

        switch (self.implementation) {
            Kind.Bin => |t| {
                n = try t.read(buf);
            },
            Kind.Telnet => |t| {
                n = try t.read(buf);
            },
            Kind.SSH2 => |t| {
                n = try t.read(buf);
            },
            Kind.Test => |t| {
                n = try t.read(buf);
            },
        }

        if (n > 0) {
            self.log.debug("transport read succesful, read {} bytes: '{s}'", .{ n, buf[0..n] });
        }

        return n;
    }
};
