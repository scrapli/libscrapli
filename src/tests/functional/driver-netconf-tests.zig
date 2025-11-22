// zlint-disable suppressed-errors, no-undefined, unsafe-undefined, unused-decls
const std = @import("std");
const os = @import("builtin").os.tag;

const scrapli = @import("scrapli");
const netconf = scrapli.netconf;
const transport = scrapli.transport;
const result = scrapli.netconf_result;
const operation = scrapli.netconf_operation;
const ascii = scrapli.ascii;
const ssh2_transport = scrapli.transport_ssh2;
const flags = scrapli.flags;
const file = scrapli.file;
const helper = scrapli.test_helper;
const xml = @import("xml");
const yaml = @import("yaml");

fn GetDriver(
    transportKind: transport.Kind,
    platform: []const u8,
    username: ?[]const u8,
    key: ?[]const u8,
    passphrase: ?[]const u8,
) !*netconf.Driver {
    // on darwin we'll be targetting localhost, on linux we'll target the ip exposed via clab/docker
    var host: []const u8 = undefined;

    var config = netconf.Config{};

    if (std.mem.eql(u8, platform, "nokia-srlinux")) {
        config.auth.lookups = .init(
            &.{
                .{ .key = "login", .value = "NokiaSrl1!" },
            },
        );

        if (username == null) {
            config.auth.username = "admin";
        } else {
            config.auth.username = username.?;
        }

        if (os == .macos) {
            host = "localhost";
            config.port = 21830;
        } else {
            host = "172.20.20.16";
            config.port = 830;
        }
    } else if (std.mem.eql(u8, platform, "arista-eos")) {
        config.auth.lookups = .init(
            &.{
                .{ .key = "login", .value = "admin!" },
            },
        );

        if (username == null) {
            config.auth.username = "netconf-admin";
        } else {
            config.auth.username = username.?;
        }

        if (os == .macos) {
            host = "localhost";
            config.port = 22830;
        } else {
            host = "172.20.20.17";
            config.port = 830;
        }
    } else {
        return error.UnknownPlatform;
    }

    if (key != null) {
        config.auth.private_key_path = key;
        config.auth.private_key_passphrase = passphrase;
    } else {
        config.auth.password = "__lookup::login";
    }

    switch (transportKind) {
        .bin => {},
        .ssh2 => {
            config.transport = transport.OptionsInputs{
                .ssh2 = .{},
            };
        },
        else => {
            unreachable;
        },
    }

    return netconf.Driver.init(
        std.testing.allocator,
        std.testing.io,
        host,
        config,
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

    const ns_order = std.mem.order(u8, a.namespace, b.namespace);
    if (ns_order != .eq) {
        return ns_order == .lt;
    }

    const name_order = std.mem.order(u8, a.name, b.name);
    if (name_order != .eq) {
        return name_order == .lt;
    }

    return std.mem.order(u8, a.revision, b.revision) == .lt;
}

test "driver-netconf open" {
    const test_name = "driver-netconf-open";

    const cases = [_]struct {
        name: []const u8,
        transportKind: transport.Kind,
        platform: []const u8,
        username: ?[]const u8 = null,
        key: ?[]const u8 = null,
        passphrase: ?[]const u8 = null,
    }{
        .{
            .name = "simple",
            .transportKind = transport.Kind.bin,
            .platform = "nokia-srlinux",
        },
        .{
            .name = "simple",
            .transportKind = transport.Kind.ssh2,
            .platform = "nokia-srlinux",
        },
        .{
            .name = "simple",
            .transportKind = transport.Kind.bin,
            .platform = "arista-eos",
        },
        .{
            .name = "simple",
            .transportKind = transport.Kind.ssh2,
            .platform = "arista-eos",
        },
        .{
            .name = "simple-with-key",
            .transportKind = transport.Kind.bin,
            .platform = "arista-eos",
            .username = "admin-sshkey",
            .key = "src/tests/fixtures/libscrapli_test_ssh_key",
        },
        .{
            .name = "simple-with-key",
            .transportKind = transport.Kind.ssh2,
            .platform = "arista-eos",
            .username = "admin-sshkey",
            .key = "src/tests/fixtures/libscrapli_test_ssh_key",
        },
        .{
            .name = "simple-with-key-with-passphrase",
            .transportKind = transport.Kind.bin,
            .platform = "arista-eos",
            .username = "admin-sshkey-passphrase",
            .key = "src/tests/fixtures/libscrapli_test_ssh_key_passphrase",
            .passphrase = "libscrapli",
        },
        .{
            .name = "simple-with-key-with-passphrase",
            .transportKind = transport.Kind.ssh2,
            .platform = "arista-eos",
            .username = "admin-sshkey-passphrase",
            .key = "src/tests/fixtures/libscrapli_test_ssh_key_passphrase",
            .passphrase = "libscrapli",
        },
    };

    const is_ci = flags.parseCustomFlag("--ci", false);

    for (cases) |case| {
        if (is_ci and std.mem.eql(u8, case.platform, "arista-eos")) {
            continue;
        }

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
        defer d.deinit();

        const actual_res = try d.open(std.testing.allocator, .{});
        defer actual_res.deinit();

        defer {
            const close_ret = d.close(std.testing.allocator, .{}) catch unreachable;
            close_ret.deinit();
        }

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

        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();

        try yaml.stringify(std.testing.allocator, yamlable_capabilities, &output.writer);

        const loaded_output = try output.toOwnedSlice();
        defer std.testing.allocator.free(loaded_output);

        try helper.processFixutreTestStrResult(
            test_name,
            case.name,
            golden_filename,
            loaded_output,
        );
    }
}

test "driver-netconf get-config" {
    const test_name = "driver-netconf-get-config";

    const cases = [_]struct {
        name: []const u8,
        transportKind: transport.Kind,
        platform: []const u8,
    }{
        .{
            .name = "simple",
            .transportKind = transport.Kind.bin,
            .platform = "nokia-srlinux",
        },
        .{
            .name = "simple",
            .transportKind = transport.Kind.ssh2,
            .platform = "nokia-srlinux",
        },
        .{
            .name = "simple",
            .transportKind = transport.Kind.bin,
            .platform = "arista-eos",
        },
        .{
            .name = "simple",
            .transportKind = transport.Kind.ssh2,
            .platform = "arista-eos",
        },
    };

    const is_ci = flags.parseCustomFlag("--ci", false);

    for (cases) |case| {
        if (is_ci and std.mem.eql(u8, case.platform, "arista-eos")) {
            continue;
        }

        const golden_filename = try std.fmt.allocPrint(
            std.testing.allocator,
            "src/tests/functional/golden/netconf/{s}-{s}-{s}",
            .{ test_name, case.platform, case.transportKind.toString() },
        );
        defer std.testing.allocator.free(golden_filename);

        var d = try GetDriver(
            case.transportKind,
            case.platform,
            null,
            null,
            null,
        );
        defer d.deinit();

        const open_res = try d.open(std.testing.allocator, .{});
        defer open_res.deinit();

        defer {
            const close_ret = d.close(std.testing.allocator, .{}) catch unreachable;
            close_ret.deinit();
        }

        const actual_res = try d.getConfig(std.testing.allocator, .{});
        defer actual_res.deinit();

        // netconf output needs to get tested/asserted better at some point, for now
        // we'll just ignore errors here
        helper.processFixutreTestStrResult(
            test_name,
            case.name,
            golden_filename,
            actual_res.result,
        ) catch {};
    }
}

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
