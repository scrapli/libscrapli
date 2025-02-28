// zlint-disable suppressed-errors, no-undefined, unsafe-undefined, unused-decls
const std = @import("std");

const xml = @import("zig-xml");
const yaml = @import("zig-yaml");

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

    opts.port = port;
    opts.auth.lookup_fn = lookup_fn;
    opts.auth.username = username;

    if (key != null) {
        opts.auth.private_key_path = key;
        opts.auth.passphrase = passphrase;
    } else {
        opts.auth.password = "__lookup::login";
    }

    switch (transportKind) {
        .Bin => {},
        .SSH2 => {
            opts.transport = ssh2_transport.NewOptions();
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

const allocatorlessCapability = struct {
    namespace: []const u8,
    name: []const u8,
    revision: []const u8,
};

fn compareAllocatorlessCapability(
    context: void,
    a: allocatorlessCapability,
    b: allocatorlessCapability,
) bool {
    _ = context;

    if (std.mem.eql(u8, a.namespace, b.namespace)) {
        // if namespace is equal we'll compare the name, we'll almost certainly have duplicated
        // namaespaces but *not* names
        for (0.., a.name) |idx, char| {
            if (idx >= b.name.len) {
                return false;
            }

            if (char == b.name[idx]) {
                continue;
            }

            if (char > b.name[idx]) {
                return false;
            }

            return true;
        }
    } else {
        for (0.., a.namespace) |idx, char| {
            if (idx >= b.namespace.len) {
                return false;
            }

            if (char == b.namespace[idx]) {
                continue;
            }

            if (char > b.namespace[idx]) {
                return false;
            }

            return true;
        }
    }

    return false;
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
            "src/tests/functional/golden/netconf/{s}-{s}-capabilities.yaml",
            .{ test_name, case.platform },
        );
        defer std.testing.allocator.free(golden_filename);

        var d = try GetDriver(
            case.transportKind,
            case.platform,
            case.username,
            case.key,
            case.passphrase,
        );

        try d.init();
        defer d.deinit();

        const actual_res = try d.open(std.testing.allocator, operation.NewOpenOptions());
        defer actual_res.deinit();

        defer {
            const close_ret = d.close(std.testing.allocator, operation.NewCloseOptions()) catch unreachable;
            close_ret.deinit();
        }

        const open_ret = try actual_res.getResult(std.testing.allocator);
        defer std.testing.allocator.free(open_ret);

        // for open, we'll just check/assert the capabilities because if we check that we know
        // that the open/auth worked of course, and also cap parcing is good, if those are null
        // we obviously failed
        if (d.server_capabilities == null) {
            return error.NoCapabilitiesRecorded;
        }

        // dump the caps we processed to a struct that does not include vtable magic for allocators
        // so that we can easily serialize it to dump to disk and compare to golden
        var yamlable_capabilities = try std.testing.allocator.alloc(
            allocatorlessCapability,
            d.server_capabilities.?.items.len,
        );
        defer std.testing.allocator.free(yamlable_capabilities);

        // TODO we need to sort this i think otherwise we'll still get stuff out of order breaking
        // the test (i think)
        for (0.., d.server_capabilities.?.items) |idx, cap| {
            yamlable_capabilities[idx] = allocatorlessCapability{
                .namespace = cap.namespace,
                .name = cap.name,
                .revision = cap.revision,
            };
        }

        // sort the caps slice so its always a good comparison
        std.sort.insertion(
            allocatorlessCapability,
            yamlable_capabilities,
            {},
            compareAllocatorlessCapability,
        );

        var output = std.ArrayList(u8).init(std.testing.allocator);
        defer output.deinit();

        try yaml.stringify(std.testing.allocator, yamlable_capabilities, output.writer());

        try helper.processFixutreTestStrResult(
            test_name,
            case.name,
            golden_filename,
            output.items,
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
