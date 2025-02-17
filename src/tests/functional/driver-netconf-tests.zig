// zlint-disable suppressed-errors, no-undefined, unsafe-undefined, unused-decls
const std = @import("std");

const driver = @import("../../driver-netconf.zig");
const transport = @import("../../transport.zig");
const result = @import("../../result-netconf.zig");
const operation = @import("../../operation-netconf.zig");
const ascii = @import("../../ascii.zig");
const ssh2_transport = @import("../../transport-ssh2.zig");
const flags = @import("../../flags.zig");
const file = @import("../../file.zig");
const helper = @import("../../test-helper.zig");

fn lookup_fn(_: []const u8, port: u16, k: []const u8) ?[]const u8 {
    _ = k;
    // testing is assuming containerlab on the host, so we just differentiate based on port
    // since this can work on nix and darwin
    if (port == 21830) {
        return "NokiaSrl1!";
    } else if (port == 22830) {
        return "admin";
    }

    return "";
}

fn GetDriver(
    transportKind: transport.Kind,
    platform: []const u8,
    username: []const u8,
    key: ?[]const u8,
    passphrase: ?[]const u8,
) !*driver.Driver {
    var port: u16 = undefined;

    if (std.mem.eql(u8, platform, "nokia-srlinux")) {
        port = 21830;
    } else if (std.mem.eql(u8, platform, "arista-eos")) {
        port = 22830;
    } else {
        return error.UnknownPlatform;
    }

    var opts = driver.NewOptions();

    opts.lookup_fn = lookup_fn;
    opts.transport.port = port;
    opts.transport.username = username;

    if (key == null) {
        opts.transport.password = "__lookup::login";
    }

    switch (transportKind) {
        .Bin => {
            if (key != null) {
                opts.transport_implementation.Bin.private_key_path = key;
                opts.transport_implementation.Bin.private_key_passphrase = passphrase;
            }
        },
        .SSH2 => {
            opts.transport_implementation = ssh2_transport.NewOptions();

            if (key != null) {
                opts.transport_implementation.SSH2.private_key_path = key;
                opts.transport_implementation.SSH2.private_key_passphrase = passphrase;
            }
        },
        else => {
            unreachable;
        },
    }

    return driver.NewDriver(
        std.testing.allocator,
        "localhost",
        opts,
    );
}

test "driver-netconf open" {
    const test_name = "driver-netconf-open";

    const cases = [_]struct {
        name: []const u8,
        transportKind: transport.Kind,
        platform: []const u8,
        username: []const u8,
        key: ?[]const u8,
        passphrase: ?[]const u8,
    }{
        .{
            .name = "simple",
            .transportKind = transport.Kind.Bin,
            .platform = "nokia-srlinux",
            .username = "admin",
            .key = null,
            .passphrase = null,
        },
        .{
            .name = "simple",
            .transportKind = transport.Kind.SSH2,
            .platform = "nokia-srlinux",
            .username = "admin",
            .key = null,
            .passphrase = null,
        },
        .{
            .name = "simple",
            .transportKind = transport.Kind.Bin,
            .platform = "arista-eos",
            .username = "admin",
            .key = null,
            .passphrase = null,
        },
        .{
            .name = "simple",
            .transportKind = transport.Kind.SSH2,
            .platform = "arista-eos",
            .username = "admin",
            .key = null,
            .passphrase = null,
        },
        .{
            .name = "simple-with-key",
            .transportKind = transport.Kind.Bin,
            .platform = "arista-eos",
            .username = "admin-sshkey",
            .key = "src/tests/fixtures/libscrapli_test_ssh_key",
            .passphrase = null,
        },
        .{
            .name = "simple-with-key",
            .transportKind = transport.Kind.SSH2,
            .platform = "arista-eos",
            .username = "admin-sshkey",
            .key = "src/tests/fixtures/libscrapli_test_ssh_key",
            .passphrase = null,
        },
        .{
            .name = "simple-with-key-with-passphrase",
            .transportKind = transport.Kind.Bin,
            .platform = "arista-eos",
            .username = "admin-sshkey-passphrase",
            .key = "src/tests/fixtures/libscrapli_test_ssh_key_passphrase",
            .passphrase = "libscrapli",
        },
        .{
            .name = "simple-with-key-with-passphrase",
            .transportKind = transport.Kind.SSH2,
            .platform = "arista-eos",
            .username = "admin-sshkey-passphrase",
            .key = "src/tests/fixtures/libscrapli_test_ssh_key_passphrase",
            .passphrase = "libscrapli",
        },
    };

    for (cases) |case| {
        // open has its own golden files since this will include in channel auth for some transports
        // but not others
        const golden_filename = try std.fmt.allocPrint(
            std.testing.allocator,
            "src/tests/functional/golden/netconf/{s}-{s}-{s}-{s}.txt",
            .{ test_name, case.name, case.platform, case.transportKind.toString() },
        );
        defer std.testing.allocator.free(golden_filename);

        var d = try GetDriver(case.transportKind, case.platform, case.username, case.key, case.passphrase);

        try d.init();
        defer d.deinit();

        const actual_res = try d.open(std.testing.allocator, operation.NewOpenOptions());
        defer actual_res.deinit();

        defer {
            const close_ret = d.close(std.testing.allocator, operation.NewCloseOptions()) catch unreachable;
            close_ret.deinit();
        }

        const actual = try actual_res.getResult(std.testing.allocator);
        defer std.testing.allocator.free(actual);

        try helper.processFixutreTestStrResult(
            test_name,
            case.name,
            golden_filename,
            actual,
        );
    }
}

// get config

// edit config

// copy config

// delete config

// lock

// unlock

// get

// close session

// kill sesion

// commit

// discard

// cancel commit

// validate

// create subscription

// establish subscription

// modify subscription

// delete subscription

// resync subscription

// kill subscription

// get schema

// get data

// edit data

// action
