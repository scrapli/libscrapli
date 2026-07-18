const std = @import("std");

const auth = @import("auth.zig");
const logging = @import("logging.zig");
const transport_bin = @import("transport-bin.zig");
const transport_ssh2 = @import("transport-ssh2.zig");
const transport_telnet = @import("transport-telnet.zig");
const transport_test = @import("transport-test.zig");

/// Holds all the possible transportation kinds.
pub const Kind = enum {
    bin,
    telnet,
    ssh2,
    test_,

    /// Returns the nice string name of the transport - cant use the enum tag because of the _ in
    /// the test transport name to not conflict with the builtin of course.
    pub fn toString(self: Kind) []const u8 {
        switch (self) {
            .bin, .telnet, .ssh2 => {
                return @tagName(self);
            },
            .test_ => {
                return "test";
            },
        }
    }
};

/// Is a tagged union holding all the possible transportation kinds.
pub const Implementation = union(Kind) {
    bin: transport_bin.Transport,
    telnet: transport_telnet.Transport,
    ssh2: transport_ssh2.Transport,
    test_: transport_test.Transport,
};

/// Holds transport options.
pub const Options = union(Kind) {
    bin: transport_bin.Options,
    telnet: transport_telnet.Options,
    ssh2: transport_ssh2.Options,
    test_: transport_test.Options,
};

/// Transport is a wrapper around any of the supported libscrapli transport structs.
pub const Transport = struct {
    log: logging.Logger,
    implementation: Implementation,

    /// Initialize the transport.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        log: logging.Logger,
        options: Options,
    ) !Transport {
        switch (options) {
            .bin => |o| {
                return Transport{
                    .log = log,
                    .implementation = Implementation{
                        .bin = try transport_bin.Transport.init(
                            allocator,
                            io,
                            log,
                            o,
                        ),
                    },
                };
            },
            .telnet => {
                return Transport{
                    .log = log,
                    .implementation = Implementation{
                        .telnet = try transport_telnet.Transport.init(
                            allocator,
                            io,
                            log,
                        ),
                    },
                };
            },
            .ssh2 => |o| {
                return Transport{
                    .log = log,
                    .implementation = Implementation{
                        .ssh2 = try transport_ssh2.Transport.init(
                            allocator,
                            io,
                            log,
                            o,
                        ),
                    },
                };
            },
            .test_ => |o| {
                return Transport{
                    .log = log,
                    .implementation = Implementation{
                        .test_ = try transport_test.Transport.init(
                            allocator,
                            io,
                            o,
                        ),
                    },
                };
            },
        }
    }

    /// Deinitialize the transport.
    pub fn deinit(self: *Transport) void {
        switch (self.implementation) {
            Kind.bin => self.implementation.bin.deinit(),
            Kind.telnet => self.implementation.telnet.deinit(),
            Kind.ssh2 => self.implementation.ssh2.deinit(),
            Kind.test_ => self.implementation.test_.deinit(),
        }
    }

    /// Returns the last error value from the transports -- noop on test transport.
    pub fn getLastError(self: *Transport) []const u8 {
        switch (self.implementation) {
            Kind.bin => return self.implementation.bin.last_error[0..self.implementation.bin.last_error_len],
            Kind.telnet => return self.implementation.telnet.last_error[0..self.implementation.telnet.last_error_len],
            Kind.ssh2 => return self.implementation.ssh2.last_error[0..self.implementation.ssh2.last_error_len],
            Kind.test_ => {
                return "";
            },
        }
    }

    /// Open the transport connection.
    pub fn open(
        self: *Transport,
        start_time: std.Io.Timestamp,
        cancel: ?*bool,
        operation_timeout_ns: u64,
        host: []const u8,
        port: u16,
        auth_options: auth.Options,
    ) !void {
        switch (self.implementation) {
            Kind.bin => {
                // bin transport doesnt need the timer, since we just pass the timeout value to
                // to the cli args and let openssh do it, then the rest of the timing out bits
                // happen in in session auth
                try self.implementation.bin.open(operation_timeout_ns, host, port, auth_options);
            },
            Kind.telnet => {
                try self.implementation.telnet.open(start_time, cancel, operation_timeout_ns, host, port);
            },
            Kind.ssh2 => {
                try self.implementation.ssh2.open(
                    start_time,
                    cancel,
                    operation_timeout_ns,
                    host,
                    port,
                    auth_options,
                );
            },
            Kind.test_ => {
                try self.implementation.test_.open(cancel);
            },
        }
    }

    /// Returns true if the underlying transport does auth "in session" (like as in not in the ssh
    /// protocol like ssh2 does).
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

    /// Unblocks the transport waiter to stop any in flight reads; used before closing the
    /// session to free up the session read loop.
    pub fn prepareClose(self: *Transport) !void {
        switch (self.implementation) {
            Kind.bin => {
                try self.implementation.bin.prepareClose();
            },
            Kind.telnet => {
                try self.implementation.telnet.prepareClose();
            },
            Kind.ssh2 => {
                try self.implementation.ssh2.prepareClose();
            },
            Kind.test_ => {},
        }
    }

    /// Close the transport. Close can never error, worst case we just tear down and free the
    /// underlying handle/session this allows the session to ensure that the transport gets closed
    /// during deinit so its always nicely tidied up.
    pub fn close(self: *Transport) void {
        switch (self.implementation) {
            Kind.bin => {
                self.implementation.bin.close();
            },
            Kind.telnet => {
                self.implementation.telnet.close();
            },
            Kind.ssh2 => {
                self.implementation.ssh2.close();
            },
            Kind.test_ => {
                self.implementation.test_.close();
            },
        }
    }

    /// Write to the transport.
    pub fn write(self: *Transport, buf: []const u8) !void {
        switch (self.implementation) {
            Kind.bin => {
                try self.implementation.bin.write(buf);
            },
            Kind.telnet => {
                try self.implementation.telnet.write(buf);
            },
            Kind.ssh2 => {
                try self.implementation.ssh2.write(buf);
            },
            Kind.test_ => {
                try self.implementation.test_.write(buf);
            },
        }
    }

    /// Read from the transport.
    pub fn read(self: *Transport, buf: []u8) !usize {
        var n: usize = 0;

        switch (self.implementation) {
            Kind.bin => {
                n = try self.implementation.bin.read(buf);
            },
            Kind.telnet => {
                n = try self.implementation.telnet.read(buf);
            },
            Kind.ssh2 => {
                n = try self.implementation.ssh2.read(buf);
            },
            Kind.test_ => {
                n = try self.implementation.test_.read(buf);
            },
        }

        return n;
    }
};

test "transportInit" {
    var t = try Transport.init(
        std.testing.allocator,
        std.testing.io,
        logging.Logger{
            .allocator = std.testing.allocator,
        },
        .{
            .bin = .{},
        },
    );

    t.deinit();
}

test "refAllDecls" {
    std.testing.refAllDecls(Transport);
}
