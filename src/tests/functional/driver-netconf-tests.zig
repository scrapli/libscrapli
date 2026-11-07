// zlint-disable suppressed-errors, no-undefined, unsafe-undefined, unused-decls
const std = @import("std");
const os = @import("builtin").os.tag;

const scrapli = @import("scrapli");
const netconf = scrapli.netconf;
const transport = scrapli.transport;
const helper = scrapli.test_helper;
const yaml = @import("yaml");

fn getDriver(
    transport_kind: transport.Kind,
    platform: []const u8,
    username: ?[]const u8,
    key: ?[]const u8,
    passphrase: ?[]const u8,
) !*netconf.Driver {
    // on darwin we'll be targeting localhost, on linux we'll target the ip exposed via clab/docker
    var host: []const u8 = "";

    var options = netconf.Options{};

    if (std.mem.eql(u8, platform, "nokia-srlinux")) {
        options.auth.lookups = .init(
            &.{
                .{ .key = "login", .value = "NokiaSrl1!" },
            },
        );

        if (username) |u| {
            options.auth.username = u;
        } else {
            options.auth.username = "admin";
        }

        if (os == .macos) {
            host = "localhost";
            options.port = 21830;
        } else {
            host = "172.20.20.16";
            options.port = 830;
        }
    } else if (std.mem.eql(u8, platform, "arista-eos")) {
        options.auth.lookups = .init(
            &.{
                .{ .key = "login", .value = "admin" },
            },
        );

        if (username) |u| {
            options.auth.username = u;
        } else {
            options.auth.username = "netconf-admin";
        }

        if (os == .macos) {
            host = "localhost";
            options.port = 22830;
        } else {
            host = "172.20.20.17";
            options.port = 830;
        }
    } else {
        return error.UnknownPlatform;
    }

    if (key != null) {
        options.auth.private_key_path = key;
        options.auth.private_key_passphrase = passphrase;
    } else {
        options.auth.password = "__lookup::login";
    }

    switch (transport_kind) {
        .bin => {},
        .ssh2 => {
            options.transport = .{
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
        options,
    );
}

const AllocatorlessCapability = struct {
    name: []const u8,
    revision: []const u8,
    raw: []const u8,
};

fn compareAllocatorlessCapability(
    context: void,
    a: AllocatorlessCapability,
    b: AllocatorlessCapability,
) bool {
    _ = context;

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
        transport_kind: transport.Kind,
        platform: []const u8,
        username: ?[]const u8 = null,
        key: ?[]const u8 = null,
        passphrase: ?[]const u8 = null,
    }{
        .{
            .name = "simple",
            .transport_kind = transport.Kind.bin,
            .platform = "nokia-srlinux",
        },
        .{
            .name = "simple",
            .transport_kind = transport.Kind.ssh2,
            .platform = "nokia-srlinux",
        },
        .{
            .name = "simple",
            .transport_kind = transport.Kind.bin,
            .platform = "arista-eos",
        },
        .{
            .name = "simple",
            .transport_kind = transport.Kind.ssh2,
            .platform = "arista-eos",
        },
        .{
            .name = "simple-with-key",
            .transport_kind = transport.Kind.bin,
            .platform = "arista-eos",
            .username = "admin-sshkey",
            .key = "src/tests/fixtures/libscrapli_test_ssh_key",
        },
        .{
            .name = "simple-with-key",
            .transport_kind = transport.Kind.ssh2,
            .platform = "arista-eos",
            .username = "admin-sshkey",
            .key = "src/tests/fixtures/libscrapli_test_ssh_key",
        },
        .{
            .name = "simple-with-key-with-passphrase",
            .transport_kind = transport.Kind.bin,
            .platform = "arista-eos",
            .username = "admin-sshkey-passphrase",
            .key = "src/tests/fixtures/libscrapli_test_ssh_key_passphrase",
            .passphrase = "libscrapli",
        },
        .{
            .name = "simple-with-key-with-passphrase",
            .transport_kind = transport.Kind.ssh2,
            .platform = "arista-eos",
            .username = "admin-sshkey-passphrase",
            .key = "src/tests/fixtures/libscrapli_test_ssh_key_passphrase",
            .passphrase = "libscrapli",
        },
    };

    const is_ci = helper.parseCustomFlag("--ci", false);

    for (cases) |case| {
        if (is_ci and std.mem.eql(u8, case.platform, "arista-eos")) {
            continue;
        }

        // open has its own golden files since this will include in channel auth for some transports
        // but not others
        const golden_filename = try std.testing.allocator.print(
            "src/tests/functional/golden/netconf/{s}-{s}-capabilities.yaml",
            .{ test_name, case.platform },
        );
        defer std.testing.allocator.free(golden_filename);

        var d = try getDriver(
            case.transport_kind,
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
        if (d.server_capabilities.items.len == 0) {
            return error.NoCapabilitiesRecorded;
        }

        // dump the caps we processed to a struct that does not include vtable magic for allocators
        // so that we can easily serialize it to dump to disk and compare to golden
        var yamlable_capabilities = try std.testing.allocator.alloc(
            AllocatorlessCapability,
            d.server_capabilities.items.len,
        );
        defer std.testing.allocator.free(yamlable_capabilities);

        for (0.., d.server_capabilities.items) |idx, cap| {
            yamlable_capabilities[idx] = AllocatorlessCapability{
                .name = cap.name,
                .revision = cap.revision,
                .raw = cap.raw,
            };
        }

        // sort the caps slice so its always a good comparison
        std.sort.insertion(
            AllocatorlessCapability,
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
        transport_kind: transport.Kind,
        platform: []const u8,
    }{
        .{
            .name = "simple",
            .transport_kind = transport.Kind.bin,
            .platform = "nokia-srlinux",
        },
        .{
            .name = "simple",
            .transport_kind = transport.Kind.ssh2,
            .platform = "nokia-srlinux",
        },
        .{
            .name = "simple",
            .transport_kind = transport.Kind.bin,
            .platform = "arista-eos",
        },
        .{
            .name = "simple",
            .transport_kind = transport.Kind.ssh2,
            .platform = "arista-eos",
        },
    };

    const is_ci = helper.parseCustomFlag("--ci", false);

    for (cases) |case| {
        if (is_ci and std.mem.eql(u8, case.platform, "arista-eos")) {
            continue;
        }

        const golden_filename = try std.testing.allocator.print(
            "src/tests/functional/golden/netconf/{s}-{s}-{s}",
            .{ test_name, case.platform, case.transport_kind.toString() },
        );
        defer std.testing.allocator.free(golden_filename);

        var d = try getDriver(
            case.transport_kind,
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
    }
}

test "driver-netconf proxy-jump large rpc" {
    // pushes an rpc well past the default (2MiB) ssh channel window through the jump host, so
    // the proxied write has to wait on window adjusts that only show up via the jump channel --
    // the case where writeProxied has to wake the reader to pump them into the socketpair. note
    // that writes have no timeout, so if this regresses the test hangs rather than fails.
    const padding_len = 4 * 1024 * 1024;

    // on darwin we go via the forwarded port, on linux straight at the clab ip
    var jump_host: []const u8 = "172.20.20.19";
    var jump_port: u16 = 22;

    if (os == .macos) {
        jump_host = "localhost";
        jump_port = 24022;
    }

    var d = try netconf.Driver.init(
        std.testing.allocator,
        std.testing.io,
        jump_host,
        .{
            .port = jump_port,
            .auth = .{
                .username = "scrapli-pw",
                .password = "scrapli-123-pw",
            },
            .session = .{
                .operation_timeout_ns = std.time.ns_per_min,
            },
            .transport = .{
                .ssh2 = .{
                    .proxy_jump_options = .{
                        // always the clab address since this is resolved from the jump host
                        .host = "172.20.20.18",
                        .port = 830,
                        .username = "root",
                        .password = "password",
                    },
                },
            },
        },
    );
    defer d.deinit();

    const open_res = try d.open(std.testing.allocator, .{});
    defer open_res.deinit();

    defer {
        const close_ret = d.close(std.testing.allocator, .{}) catch unreachable;
        close_ret.deinit();
    }

    // padding goes in an xml comment so the server has to read all of it but otherwise ignores
    // it, leaving a plain get-config
    const padding = try std.testing.allocator.alloc(u8, padding_len);
    defer std.testing.allocator.free(padding);

    @memset(padding, 'x');

    const payload = try std.testing.allocator.print(
        "<!-- {s} --><get-config><source><running/></source></get-config>",
        .{padding},
    );
    defer std.testing.allocator.free(payload);

    const actual_res = try d.rawRpc(std.testing.allocator, .{ .payload = payload });
    defer actual_res.deinit();

    // the point is the write making it through and a reply coming back; dont care if the
    // reply is an rpc-error
    try std.testing.expect(actual_res.result.len > 0);
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
