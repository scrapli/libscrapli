const std = @import("std");
const auth = @import("auth.zig");
const transport_bin = @import("transport-bin.zig");
const transport_telnet = @import("transport-telnet.zig");
const transport_ssh2 = @import("transport-ssh2.zig");
const transport_test = @import("transport-test.zig");
const logger = @import("logger.zig");

pub const Kind = enum {
    bin,
    telnet,
    ssh2,
    test_,

    pub fn toString(self: Kind) []const u8 {
        switch (self) {
            .bin => {
                return "bin";
            },
            .telnet => {
                return "telnet";
            },
            .ssh2 => {
                return "ssh2";
            },
            .test_ => {
                return "test";
            },
        }
    }
};

pub const Implementation = union(Kind) {
    bin: *transport_bin.Transport,
    telnet: *transport_telnet.Transport,
    ssh2: *transport_ssh2.Transport,
    test_: *transport_test.Transport,
};

pub const OptionsInputs = union(Kind) {
    bin: transport_bin.OptionsInputs,
    telnet: transport_telnet.OptionsInputs,
    ssh2: transport_ssh2.OptionsInputs,
    test_: transport_test.OptionsInputs,
};

pub const Options = union(Kind) {
    bin: *transport_bin.Options,
    telnet: *transport_telnet.Options,
    ssh2: *transport_ssh2.Options,
    test_: *transport_test.Options,

    pub fn init(allocator: std.mem.Allocator, opts: OptionsInputs) !*Options {
        const o = try allocator.create(Options);
        errdefer allocator.destroy(o);

        switch (opts) {
            .bin => |impl_option_inputs| {
                o.* = Options{
                    .bin = try transport_bin.Options.init(
                        allocator,
                        impl_option_inputs,
                    ),
                };
            },
            .ssh2 => |impl_option_inputs| {
                o.* = Options{
                    .ssh2 = try transport_ssh2.Options.init(
                        allocator,
                        impl_option_inputs,
                    ),
                };
            },
            .telnet => |impl_option_inputs| {
                o.* = Options{
                    .telnet = try transport_telnet.Options.init(
                        allocator,
                        impl_option_inputs,
                    ),
                };
            },
            .test_ => |impl_option_inputs| {
                o.* = Options{
                    .test_ = try transport_test.Options.init(
                        allocator,
                        impl_option_inputs,
                    ),
                };
            },
        }

        return o;
    }

    pub fn deinit(self: *Options) void {
        switch (self.*) {
            .bin => |o| {
                // clunky since the tagged union doesnt have the allocator... but works
                var _o = o;
                var _a = _o.allocator;
                _o.deinit();
                _a.destroy(self);
            },
            .ssh2 => |o| {
                var _o = o;
                var _a = _o.allocator;
                _o.deinit();
                _a.destroy(self);
            },
            .telnet => |o| {
                var _o = o;
                var _a = _o.allocator;
                _o.deinit();
                _a.destroy(self);
            },
            .test_ => |o| {
                var _o = o;
                var _a = _o.allocator;
                _o.deinit();
                _a.destroy(self);
            },
        }
    }
};

pub const Transport = struct {
    allocator: std.mem.Allocator,
    log: logger.Logger,
    implementation: Implementation,

    pub fn init(
        allocator: std.mem.Allocator,
        log: logger.Logger,
        options: *Options,
    ) !*Transport {
        const t = try allocator.create(Transport);

        switch (options.*) {
            .bin => {
                t.* = Transport{
                    .allocator = allocator,
                    .log = log,
                    .implementation = Implementation{
                        .bin = try transport_bin.Transport.init(
                            allocator,
                            log,
                            options.bin,
                        ),
                    },
                };
            },
            .telnet => {
                t.* = Transport{
                    .allocator = allocator,
                    .log = log,
                    .implementation = Implementation{
                        .telnet = try transport_telnet.Transport.init(
                            allocator,
                            log,
                            options.telnet,
                        ),
                    },
                };
            },
            .ssh2 => {
                t.* = Transport{
                    .allocator = allocator,
                    .log = log,
                    .implementation = Implementation{
                        .ssh2 = try transport_ssh2.Transport.init(
                            allocator,
                            log,
                            options.ssh2,
                        ),
                    },
                };
            },
            .test_ => {
                t.* = Transport{
                    .allocator = allocator,
                    .log = log,
                    .implementation = Implementation{
                        .test_ = try transport_test.Transport.init(
                            allocator,
                            options.test_,
                        ),
                    },
                };
            },
        }

        return t;
    }

    pub fn deinit(self: *Transport) void {
        switch (self.implementation) {
            Kind.bin => |t| {
                t.deinit();
            },
            Kind.telnet => |t| {
                t.deinit();
            },
            Kind.ssh2 => |t| {
                t.deinit();
            },
            Kind.test_ => |t| {
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
        auth_options: *auth.Options,
    ) !void {
        self.log.debug("transport open start...", .{});

        switch (self.implementation) {
            Kind.bin => |t| {
                // bin transport doesnt need the timer, since we just pass the timeout value to
                // to the cli args and let openssh do it, then the rest of the timing out bits
                // happen in in session auth
                try t.open(operation_timeout_ns, host, port, auth_options);
            },
            Kind.telnet => |t| {
                try t.open(timer, cancel, operation_timeout_ns, host, port);
            },
            Kind.ssh2 => |t| {
                try t.open(
                    timer,
                    cancel,
                    operation_timeout_ns,
                    host,
                    port,
                    auth_options,
                );
            },
            Kind.test_ => |t| {
                try t.open(cancel);
            },
        }

        self.log.debug("transport open successful...", .{});
    }

    pub fn isInSessionAuth(
        self: *Transport,
    ) bool {
        switch (self.implementation) {
            Kind.bin, Kind.telnet, Kind.test_ => {
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
            Kind.bin => |t| {
                t.close();
            },
            Kind.telnet => |t| {
                t.close();
            },
            Kind.ssh2 => |t| {
                t.close();
            },
            Kind.test_ => |t| {
                t.close();
            },
        }

        self.log.debug("transport close successful...", .{});
    }

    pub fn write(self: *Transport, buf: []const u8) !void {
        switch (self.implementation) {
            Kind.bin => |t| {
                try t.write(buf);
            },
            Kind.telnet => |t| {
                try t.write(buf);
            },
            Kind.ssh2 => |t| {
                try t.write(buf);
            },
            Kind.test_ => |t| {
                try t.write(buf);
            },
        }
    }

    pub fn read(self: *Transport, buf: []u8) !usize {
        var n: usize = 0;

        switch (self.implementation) {
            Kind.bin => |t| {
                n = try t.read(buf);
            },
            Kind.telnet => |t| {
                n = try t.read(buf);
            },
            Kind.ssh2 => |t| {
                n = try t.read(buf);
            },
            Kind.test_ => |t| {
                n = try t.read(buf);
            },
        }

        return n;
    }
};
