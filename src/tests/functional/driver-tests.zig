// zlint-disable suppressed-errors, no-undefined, unsafe-undefined, unused-decls
// note: disabling because tests can have unreachable blocks
// note: disabling because of driver/file setup in tests and its fine
// note: disabling unused-dcls because it thinks result is unused, will look at zlint later to try
//       to fix and pr!
const std = @import("std");
const os = @import("builtin").os.tag;

const driver = @import("../../driver.zig");
const transport = @import("../../transport.zig");
const ssh2_transport = @import("../../transport-ssh2.zig");
const telnet_transport = @import("../../transport-telnet.zig");
const operation = @import("../../operation.zig");
const result = @import("../../result.zig");
const flags = @import("../../flags.zig");

const helper = @import("../../test-helper.zig");

const nokia_srlinux_platform_path_from_project_root = "src/tests/fixtures/platform_nokia_srlinux_no_open_close_callbacks.yaml";
const arista_eos_platform_path_from_project_root = "src/tests/fixtures/platform_arista_eos_no_open_close_callbacks.yaml";

fn GetDriver(
    transportKind: transport.Kind,
    platform: []const u8,
    username: []const u8,
    key: ?[]const u8,
    passphrase: ?[]const u8,
) !*driver.Driver {
    // on darwin we'll be targetting localhost, on linux we'll target the ips exposed via clab/docker
    var host: []const u8 = undefined;

    var platform_definition_path: []const u8 = undefined;

    var config = driver.Config{
        .definition = .{
            .file = "",
        },
    };

    if (std.mem.eql(u8, platform, "nokia-srlinux")) {
        platform_definition_path = nokia_srlinux_platform_path_from_project_root;
        config.auth.lookup_map = &.{
            .{ .key = "login", .value = "NokiaSrl1!" },
        };

        if (os == .macos) {
            host = "localhost";
            config.port = 21022;
        } else {
            host = "172.20.20.16";
            config.port = 22;
        }
    } else if (std.mem.eql(u8, platform, "arista-eos")) {
        platform_definition_path = arista_eos_platform_path_from_project_root;
        config.auth.lookup_map = &.{
            .{ .key = "login", .value = "admin" },
            .{ .key = "enable", .value = "libscrapli" },
        };

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

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.posix.getcwd(&cwd_buf);

    var platform_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var platform_path_len: usize = 0;

    @memcpy(platform_path_buf[0..cwd.len], cwd[0..cwd.len]);
    platform_path_len += cwd.len;

    platform_path_buf[platform_path_len] = "/"[0];
    platform_path_len += 1;

    @memcpy(
        platform_path_buf[platform_path_len .. platform_path_len + platform_definition_path.len],
        platform_definition_path,
    );
    platform_path_len += platform_definition_path.len;

    config.definition.file = platform_path_buf[0..platform_path_len];

    config.auth.username = username;

    if (key != null) {
        config.auth.private_key_path = key;
        config.auth.private_key_passphrase = passphrase;
    } else {
        config.auth.password = "__lookup::login";
    }

    switch (transportKind) {
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

    return driver.Driver.init(
        std.testing.allocator,
        host,
        config,
    );
}

test "driver open" {
    const test_name = "driver-open";

    const cases = [_]struct {
        name: []const u8,
        transportKind: transport.Kind,
        platform: []const u8,
        username: []const u8,
        key: ?[]const u8,
        passphrase: ?[]const u8,
        on_open_callback: ?*const fn (
            d: *driver.Driver,
            allocator: std.mem.Allocator,
            cancel: ?*bool,
        ) anyerror!*result.Result,
    }{
        .{
            .name = "simple",
            .transportKind = transport.Kind.bin,
            .platform = "nokia-srlinux",
            .on_open_callback = null,
            .username = "admin",
            .key = null,
            .passphrase = null,
        },
        .{
            .name = "simple",
            .transportKind = transport.Kind.ssh2,
            .platform = "nokia-srlinux",
            .on_open_callback = null,
            .username = "admin",
            .key = null,
            .passphrase = null,
        },
        .{
            .name = "simple",
            .transportKind = transport.Kind.bin,
            .platform = "arista-eos",
            .on_open_callback = null,
            .username = "admin",
            .key = null,
            .passphrase = null,
        },
        .{
            .name = "simple",
            .transportKind = transport.Kind.ssh2,
            .platform = "arista-eos",
            .on_open_callback = null,
            .username = "admin",
            .key = null,
            .passphrase = null,
        },
        .{
            .name = "simple-with-key",
            .transportKind = transport.Kind.bin,
            .platform = "arista-eos",
            .on_open_callback = null,
            .username = "admin-sshkey",
            .key = "src/tests/fixtures/libscrapli_test_ssh_key",
            .passphrase = null,
        },
        .{
            .name = "simple-with-key",
            .transportKind = transport.Kind.ssh2,
            .platform = "arista-eos",
            .on_open_callback = null,
            .username = "admin-sshkey",
            .key = "src/tests/fixtures/libscrapli_test_ssh_key",
            .passphrase = null,
        },
        .{
            .name = "simple-with-key-with-passphrase",
            .transportKind = transport.Kind.bin,
            .platform = "arista-eos",
            .on_open_callback = null,
            .username = "admin-sshkey-passphrase",
            .key = "src/tests/fixtures/libscrapli_test_ssh_key_passphrase",
            .passphrase = "libscrapli",
        },
        .{
            .name = "simple-with-key-with-passphrase",
            .transportKind = transport.Kind.ssh2,
            .platform = "arista-eos",
            .on_open_callback = null,
            .username = "admin-sshkey-passphrase",
            .key = "src/tests/fixtures/libscrapli_test_ssh_key_passphrase",
            .passphrase = "libscrapli",
        },
        // TODO with callbacks and bound callbacks too
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
            "src/tests/functional/golden/driver/{s}-{s}-{s}-{s}.txt",
            .{ test_name, case.name, case.platform, case.transportKind.toString() },
        );
        defer std.testing.allocator.free(golden_filename);

        var d = try GetDriver(case.transportKind, case.platform, case.username, case.key, case.passphrase);
        d.definition.on_open_callback = case.on_open_callback;

        defer d.deinit();

        const actual_res = try d.open(std.testing.allocator, .{});
        defer actual_res.deinit();

        defer {
            const close_res = d.close(std.testing.allocator, .{}) catch unreachable;
            close_res.deinit();
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
