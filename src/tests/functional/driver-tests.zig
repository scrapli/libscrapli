// zlint-disable suppressed-errors, no-undefined, unsafe-undefined, unused-decls
// note: disabling because tests can have unreachable blocks
// note: disabling because of driver/file setup in tests and its fine
// note: disabling unused-dcls because it thinks result is unused, will look at zlint later to try
//       to fix and pr!
const std = @import("std");
const os = @import("builtin").os.tag;

const scrapli = @import("scrapli");
const cli = scrapli.cli;
const transport = scrapli.transport;
const ssh2_transport = scrapli.transport_ssh2;
const telnet_transport = scrapli.transport_telnet;
const operation = scrapli.cli_operation;
const result = scrapli.cli_result;
const flags = scrapli.flags;
const helper = scrapli.test_helper;

const nokia_srlinux_platform_path_from_project_root = "src/tests/fixtures/platform_nokia_srlinux_no_open_close_callbacks.yaml";
const arista_eos_platform_path_from_project_root = "src/tests/fixtures/platform_arista_eos_no_open_close_callbacks.yaml";

fn GetDriver(
    transport_kind: transport.Kind,
    platform: []const u8,
    username: ?[]const u8,
    key: ?[]const u8,
    passphrase: ?[]const u8,
) !*cli.Driver {
    // on darwin we'll be targetting localhost, on linux we'll target the ips exposed via clab/docker
    var host: []const u8 = undefined;

    var platform_definition_path: []const u8 = undefined;

    var config = cli.Config{
        .definition = .{
            .file = "",
        },
    };

    if (std.mem.eql(u8, platform, "nokia-srlinux")) {
        platform_definition_path = nokia_srlinux_platform_path_from_project_root;
        config.auth.lookups = .init(
            &.{
                .{ .key = "login", .value = "NokiaSrl1!" },
            },
        );

        if (os == .macos) {
            host = "localhost";
            config.port = 21022;
        } else {
            host = "172.20.20.16";
            config.port = 22;
        }
    } else if (std.mem.eql(u8, platform, "arista-eos")) {
        platform_definition_path = arista_eos_platform_path_from_project_root;
        config.auth.lookups = .init(
            &.{
                .{ .key = "login", .value = "admin" },
                .{ .key = "enable", .value = "libscrapli" },
            },
        );

        if (os == .macos) {
            host = "localhost";
            config.port = 22022;
        } else {
            host = "172.20.20.17";
            config.port = 22;
        }
    } else {
        return error.UnknownPlatform;
    }

    config.definition.file = platform_definition_path;

    if (username == null) {
        config.auth.username = "admin";
    } else {
        config.auth.username = username.?;
    }

    if (key != null) {
        config.auth.private_key_path = key;
        config.auth.private_key_passphrase = passphrase;
    } else {
        config.auth.password = "__lookup::login";
    }

    switch (transport_kind) {
        .bin,
        => {},
        .ssh2 => {
            config.transport = transport.OptionsInputs{
                .ssh2 = .{},
            };
        },
        .telnet => {
            config.transport = transport.OptionsInputs{
                .telnet = .{},
            };
            config.port = config.port.? - 1;
        },
        else => {
            unreachable;
        },
    }

    return cli.Driver.init(
        std.testing.allocator,
        std.testing.io,
        host,
        config,
    );
}

test "driver open" {
    const test_name = "driver-open";

    const cases = [_]struct {
        name: []const u8,
        transport_kind: transport.Kind,
        platform: []const u8,
        username: []const u8,
        key: ?[]const u8 = null,
        passphrase: ?[]const u8 = null,
        onOpenCallback: ?*const fn (
            d: *cli.Driver,
            allocator: std.mem.Allocator,
            cancel: ?*bool,
        ) anyerror!*result.Result = null,
    }{
        .{
            .name = "simple",
            .transport_kind = transport.Kind.bin,
            .platform = "nokia-srlinux",
            .username = "admin",
        },
        .{
            .name = "simple",
            .transport_kind = transport.Kind.ssh2,
            .platform = "nokia-srlinux",
            .username = "admin",
        },
        .{
            .name = "simple",
            .transport_kind = transport.Kind.bin,
            .platform = "arista-eos",
            .username = "admin",
        },
        .{
            .name = "simple",
            .transport_kind = transport.Kind.ssh2,
            .platform = "arista-eos",
            .username = "admin",
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
        // TODO with callbacks and bound callbacks too
    };

    const is_ci = helper.parseCustomFlag("--ci", false);

    for (cases) |case| {
        errdefer {
            std.debug.print("failed case: {s}\n", .{case.name});
        }

        if (is_ci and std.mem.eql(u8, case.platform, "arista-eos")) {
            continue;
        }

        // open has its own golden files since this will include in channel auth for some transports
        // but not others
        const golden_filename = try std.fmt.allocPrint(
            std.testing.allocator,
            "src/tests/functional/golden/driver/{s}-{s}-{s}-{s}.txt",
            .{ test_name, case.name, case.platform, case.transport_kind.toString() },
        );
        defer std.testing.allocator.free(golden_filename);

        var d = try GetDriver(
            case.transport_kind,
            case.platform,
            case.username,
            case.key,
            case.passphrase,
        );
        d.definition.onOpenCallback = case.onOpenCallback;

        defer d.deinit();

        const actual_res = try d.open(std.testing.allocator, .{});
        defer actual_res.deinit();

        defer {
            const close_res = d.close(
                std.testing.allocator,
                .{},
            ) catch unreachable;
            close_res.deinit();
        }

        const actual = try actual_res.getResult(std.testing.allocator, .{});
        defer std.testing.allocator.free(actual);

        // rather than dealing w/ capturing exact banner/login/etc. (which is a PITA, esp w/ diff
        // hosts -- darwin vs linux, clab w/ port forward vs docker bridge etc etc), just ignore
        // it and do the roughly contains check rather than explicit
        try helper.processFixutreTestStrResultRoughly(
            test_name,
            case.name,
            golden_filename,
            actual,
        );
    }
}
