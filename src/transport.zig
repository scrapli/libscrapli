const std = @import("std");
const transport_bin = @import("transport-bin.zig");
const transport_telnet = @import("transport-telnet.zig");
const transport_ssh2 = @import("transport-ssh2.zig");
const transport_test = @import("transport-test.zig");
const logger = @import("logger.zig");
const lookup = @import("lookup.zig");

const default_port: u16 = 22;
const default_term_height: u16 = 255;
const default_term_width: u16 = 80;

pub const AuthData = struct {
    is_in_session: bool,
    username: ?[]const u8,
    password: ?[]const u8,
    passphrase: ?[]const u8,
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

pub fn NewOptions() Options {
    return Options{
        .port = default_port,
        .term_height = default_term_height,
        .term_width = default_term_width,
        .username = null,
        .password = null,
    };
}

pub const Options = struct {
    port: u16,

    term_height: u16,
    term_width: u16,

    username: ?[]const u8,
    password: ?[]const u8,
};

pub const ImplementationOptions = union(Kind) {
    Bin: transport_bin.Options,
    Telnet: transport_telnet.Options,
    SSH2: transport_ssh2.Options,
    Test: transport_test.Options,
};

pub fn Factory(
    allocator: std.mem.Allocator,
    log: logger.Logger,
    host: []const u8,
    options: Options,
    implementation_options: ImplementationOptions,
) !*Transport {
    const t = try allocator.create(Transport);

    switch (implementation_options) {
        .Bin => {
            t.* = Transport{
                .allocator = allocator,
                .log = log,
                .host = host,
                .port = options.port,
                .implementation = Implementation{
                    .Bin = try transport_bin.NewTransport(
                        allocator,
                        log,
                        host,
                        options,
                        implementation_options.Bin,
                    ),
                },
            };
        },
        .Telnet => {
            t.* = Transport{
                .allocator = allocator,
                .log = log,
                .host = host,
                .port = options.port,
                .implementation = Implementation{
                    .Telnet = try transport_telnet.NewTransport(
                        allocator,
                        log,
                        host,
                        options,
                        implementation_options.Telnet,
                    ),
                },
            };
        },
        .SSH2 => {
            t.* = Transport{
                .allocator = allocator,
                .log = log,
                .host = host,
                .port = options.port,
                .implementation = Implementation{
                    .SSH2 = try transport_ssh2.NewTransport(
                        allocator,
                        log,
                        host,
                        options,
                        implementation_options.SSH2,
                    ),
                },
            };
        },
        .Test => {
            t.* = Transport{
                .allocator = allocator,
                .log = log,
                .host = host,
                .port = options.port,
                .implementation = Implementation{
                    .Test = try transport_test.NewTransport(
                        allocator,
                        log,
                        host,
                        options,
                        implementation_options.Test,
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
    host: []const u8,
    port: u16,
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

    pub fn GetAuthData(self: *Transport) AuthData {
        switch (self.implementation) {
            Kind.Bin => {
                return .{
                    .is_in_session = true,
                    .username = self.implementation.Bin.base_options.username,
                    .password = self.implementation.Bin.base_options.password,
                    .passphrase = self.implementation.Bin.options.private_key_passphrase,
                };
            },
            Kind.Telnet => {
                return .{
                    .is_in_session = true,
                    .username = self.implementation.Telnet.base_options.username,
                    .password = self.implementation.Telnet.base_options.password,
                    .passphrase = null,
                };
            },
            Kind.SSH2 => {
                return .{
                    .is_in_session = false,
                    .username = null,
                    .password = null,
                    .passphrase = null,
                };
            },
            Kind.Test => {
                return .{
                    // we want test transport to do in channel auth so we can test that part!
                    .is_in_session = true,
                    .username = self.implementation.Test.base_options.username,
                    .password = self.implementation.Test.base_options.password,
                    .passphrase = null,
                };
            },
        }
    }

    pub fn open(
        self: *Transport,
        timer: *std.time.Timer,
        cancel: ?*bool,
        operation_timeout_ns: u64,
        lookup_fn: lookup.LookupFn,
    ) !void {
        self.log.debug("transport open start...", .{});

        switch (self.implementation) {
            Kind.Bin => |t| {
                // bin transport doesnt need the timer, since we just pass the timeout value to
                // to the cli args and let openssh do it, then the rest of the timing out bits
                // happen in in session auth
                try t.open(operation_timeout_ns);
            },
            Kind.Telnet => |t| {
                try t.open(timer, cancel, operation_timeout_ns);
            },
            Kind.SSH2 => |t| {
                try t.open(timer, cancel, operation_timeout_ns, lookup_fn);
            },
            Kind.Test => |t| {
                try t.open(cancel);
            },
        }

        self.log.debug("transport open successful...", .{});
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
