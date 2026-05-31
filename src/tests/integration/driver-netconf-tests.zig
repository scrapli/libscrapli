const std = @import("std");

const scrapli = @import("scrapli");
const netconf = scrapli.netconf;
const helper = scrapli.test_helper;

fn makeRecordTestDriver(record_path: []const u8) !*netconf.Driver {
    return netconf.Driver.init(
        std.testing.allocator,
        std.testing.io,
        "localhost",
        .{
            .port = 23830,
            .auth = .{
                .username = "root",
                .password = "password",
            },
            .session = .{
                .record_destination = .{
                    .f = record_path,
                },
            },
        },
    );
}

fn makeReplayTestDriver(fixture_path: []const u8) !*netconf.Driver {
    const d = try netconf.Driver.init(
        std.testing.allocator,
        std.testing.io,
        "dummy",
        .{
            .port = 23830,
            .auth = .{
                .username = "root",
                .password = "password",
            },
            .session = .{
                // with read size 1 we end up doing a ZILLION regexs which is slow af,
                // by turning all the timeouts off and having the default netconf search
                // depth be low we speed up the tests quite a bit
                .read_size = 1,
                .operation_timeout_ns = std.time.ns_per_min,
            },
            .transport = .{
                .test_ = .{
                    .f = fixture_path,
                },
            },
        },
    );

    // the default initial search depth of 256 will be too deep and consume some of the
    // server hello. this is just an issue due to how the test transport reads the file
    // we have to set it *after* init since the NewDriver defaults the size (for now its not
    // configurable) to sane things that break the tests
    d.options.session.operation_max_search_depth = 32;

    return d;
}

fn initTestDriver(record: bool, fixture_path: []const u8) !*netconf.Driver {
    return if (record)
        try makeRecordTestDriver(fixture_path)
    else
        try makeReplayTestDriver(fixture_path);
}

test "driver-netconf get-config" {
    const test_name = "get-config";

    const cases = [_]struct {
        name: []const u8,
    }{
        .{
            .name = "simple",
        },
    };

    for (cases) |case| {
        const record = helper.isRecording();

        const fixture_filename = try helper.fixturePath(
            std.testing.allocator,
            "netconf",
            test_name,
            case.name,
        );
        defer std.testing.allocator.free(fixture_filename);

        const golden_filename = try helper.goldenPath(
            std.testing.allocator,
            "netconf",
            test_name,
            case.name,
        );
        defer std.testing.allocator.free(golden_filename);

        const d = try initTestDriver(record, fixture_filename);
        defer d.deinit();

        const open_res = try d.open(std.testing.allocator, .{});
        defer open_res.deinit();

        const actual_res = try d.getConfig(std.testing.allocator, .{});
        defer actual_res.deinit();

        defer helper.closeDriver(netconf.Driver, d, std.testing.allocator);

        try std.testing.expect(!actual_res.result_failure_indicated);

        try helper.processFixutreTestStrResult(
            test_name,
            case.name,
            golden_filename,
            actual_res.result,
        );
    }
}

test "driver-netconf edit-config" {
    const test_name = "edit-config";

    const cases = [_]struct {
        name: []const u8,
        config: []const u8,
    }{
        .{
            .name = "simple",
            .config = "",
        },
    };

    for (cases) |case| {
        const record = helper.isRecording();

        const fixture_filename = try helper.fixturePath(
            std.testing.allocator,
            "netconf",
            test_name,
            case.name,
        );
        defer std.testing.allocator.free(fixture_filename);

        const golden_filename = try helper.goldenPath(
            std.testing.allocator,
            "netconf",
            test_name,
            case.name,
        );
        defer std.testing.allocator.free(golden_filename);

        const d = try initTestDriver(record, fixture_filename);
        defer d.deinit();

        const open_res = try d.open(std.testing.allocator, .{});
        defer open_res.deinit();

        const actual_res = try d.editConfig(
            std.testing.allocator,
            .{
                .config = case.config,
            },
        );
        defer actual_res.deinit();

        defer helper.closeDriver(netconf.Driver, d, std.testing.allocator);

        try std.testing.expect(!actual_res.result_failure_indicated);

        try helper.processFixutreTestStrResult(
            test_name,
            case.name,
            golden_filename,
            actual_res.result,
        );
    }
}
test "driver-netconf copy-config" {
    const test_name = "copy-config";

    const cases = [_]struct {
        name: []const u8,
    }{
        .{
            .name = "simple",
        },
    };

    for (cases) |case| {
        const record = helper.isRecording();

        const fixture_filename = try helper.fixturePath(
            std.testing.allocator,
            "netconf",
            test_name,
            case.name,
        );
        defer std.testing.allocator.free(fixture_filename);

        const golden_filename = try helper.goldenPath(
            std.testing.allocator,
            "netconf",
            test_name,
            case.name,
        );
        defer std.testing.allocator.free(golden_filename);

        const d = try initTestDriver(record, fixture_filename);
        defer d.deinit();

        const open_res = try d.open(std.testing.allocator, .{});
        defer open_res.deinit();

        const actual_res = try d.copyConfig(std.testing.allocator, .{});
        defer actual_res.deinit();

        defer helper.closeDriver(netconf.Driver, d, std.testing.allocator);

        try std.testing.expect(!actual_res.result_failure_indicated);

        try helper.processFixutreTestStrResult(
            test_name,
            case.name,
            golden_filename,
            actual_res.result,
        );
    }
}

test "driver-netconf delete-config" {
    const test_name = "delete-config";

    const cases = [_]struct {
        name: []const u8,
    }{
        .{
            .name = "simple",
        },
    };

    for (cases) |case| {
        const record = helper.isRecording();

        const fixture_filename = try helper.fixturePath(
            std.testing.allocator,
            "netconf",
            test_name,
            case.name,
        );
        defer std.testing.allocator.free(fixture_filename);

        const golden_filename = try helper.goldenPath(
            std.testing.allocator,
            "netconf",
            test_name,
            case.name,
        );
        defer std.testing.allocator.free(golden_filename);

        const d = try initTestDriver(record, fixture_filename);
        defer d.deinit();

        const open_res = try d.open(std.testing.allocator, .{});
        defer open_res.deinit();

        const actual_res = try d.deleteConfig(
            std.testing.allocator,
            .{
                .target = .startup,
            },
        );
        defer actual_res.deinit();

        defer helper.closeDriver(netconf.Driver, d, std.testing.allocator);

        try std.testing.expect(!actual_res.result_failure_indicated);

        try helper.processFixutreTestStrResult(
            test_name,
            case.name,
            golden_filename,
            actual_res.result,
        );
    }
}

test "driver-netconf get" {
    const test_name = "get";

    const cases = [_]struct {
        name: []const u8,
    }{
        .{
            .name = "simple",
        },
    };

    for (cases) |case| {
        const record = helper.isRecording();

        const fixture_filename = try helper.fixturePath(
            std.testing.allocator,
            "netconf",
            test_name,
            case.name,
        );
        defer std.testing.allocator.free(fixture_filename);

        const golden_filename = try helper.goldenPath(
            std.testing.allocator,
            "netconf",
            test_name,
            case.name,
        );
        defer std.testing.allocator.free(golden_filename);

        const d = try initTestDriver(record, fixture_filename);
        defer d.deinit();

        const open_res = try d.open(std.testing.allocator, .{});
        defer open_res.deinit();

        const actual_res = try d.get(std.testing.allocator, .{});
        defer actual_res.deinit();

        defer helper.closeDriver(netconf.Driver, d, std.testing.allocator);

        try std.testing.expect(!actual_res.result_failure_indicated);

        try helper.processFixutreTestStrResult(
            test_name,
            case.name,
            golden_filename,
            actual_res.result,
        );
    }
}

test "driver-netconf lock" {
    const test_name = "lock";

    const cases = [_]struct {
        name: []const u8,
    }{
        .{
            .name = "simple",
        },
    };

    for (cases) |case| {
        const record = helper.isRecording();

        const fixture_filename = try helper.fixturePath(
            std.testing.allocator,
            "netconf",
            test_name,
            case.name,
        );
        defer std.testing.allocator.free(fixture_filename);

        const golden_filename = try helper.goldenPath(
            std.testing.allocator,
            "netconf",
            test_name,
            case.name,
        );
        defer std.testing.allocator.free(golden_filename);

        const d = try initTestDriver(record, fixture_filename);
        defer d.deinit();

        const open_res = try d.open(std.testing.allocator, .{});
        defer open_res.deinit();

        const actual_res = try d.lock(
            std.testing.allocator,
            .{
                .target = .candidate,
            },
        );
        defer actual_res.deinit();

        defer helper.closeDriver(netconf.Driver, d, std.testing.allocator);

        try std.testing.expect(!actual_res.result_failure_indicated);

        try helper.processFixutreTestStrResult(
            test_name,
            case.name,
            golden_filename,
            actual_res.result,
        );
    }
}

test "driver-netconf unlock" {
    const test_name = "unlock";

    const cases = [_]struct {
        name: []const u8,
    }{
        .{
            .name = "simple",
        },
    };

    for (cases) |case| {
        const record = helper.isRecording();

        const fixture_filename = try helper.fixturePath(
            std.testing.allocator,
            "netconf",
            test_name,
            case.name,
        );
        defer std.testing.allocator.free(fixture_filename);

        const golden_filename = try helper.goldenPath(
            std.testing.allocator,
            "netconf",
            test_name,
            case.name,
        );
        defer std.testing.allocator.free(golden_filename);

        const d = try initTestDriver(record, fixture_filename);
        defer d.deinit();

        const open_res = try d.open(std.testing.allocator, .{});
        defer open_res.deinit();

        const lock_res = try d.lock(
            std.testing.allocator,
            .{
                .target = .candidate,
            },
        );
        defer lock_res.deinit();

        const actual_res = try d.unlock(
            std.testing.allocator,
            .{
                .target = .candidate,
            },
        );
        defer actual_res.deinit();

        defer helper.closeDriver(netconf.Driver, d, std.testing.allocator);

        try std.testing.expect(!actual_res.result_failure_indicated);

        try helper.processFixutreTestStrResult(
            test_name,
            case.name,
            golden_filename,
            actual_res.result,
        );
    }
}

test "driver-netconf close-session" {
    const test_name = "close-session";

    const cases = [_]struct {
        name: []const u8,
    }{
        .{
            .name = "simple",
        },
    };

    for (cases) |case| {
        const record = helper.isRecording();

        const fixture_filename = try helper.fixturePath(
            std.testing.allocator,
            "netconf",
            test_name,
            case.name,
        );
        defer std.testing.allocator.free(fixture_filename);

        const golden_filename = try helper.goldenPath(
            std.testing.allocator,
            "netconf",
            test_name,
            case.name,
        );
        defer std.testing.allocator.free(golden_filename);

        const d = try initTestDriver(record, fixture_filename);
        defer d.deinit();

        const open_res = try d.open(std.testing.allocator, .{});
        defer open_res.deinit();

        const actual_res = try d.closeSession(std.testing.allocator, .{});
        defer actual_res.deinit();

        try std.testing.expect(!actual_res.result_failure_indicated);

        try helper.processFixutreTestStrResult(
            test_name,
            case.name,
            golden_filename,
            actual_res.result,
        );
    }
}

test "driver-netconf commit" {
    const test_name = "commit";

    const cases = [_]struct {
        name: []const u8,
    }{
        .{
            .name = "simple",
        },
    };

    for (cases) |case| {
        const record = helper.isRecording();

        const fixture_filename = try helper.fixturePath(
            std.testing.allocator,
            "netconf",
            test_name,
            case.name,
        );
        defer std.testing.allocator.free(fixture_filename);

        const golden_filename = try helper.goldenPath(
            std.testing.allocator,
            "netconf",
            test_name,
            case.name,
        );
        defer std.testing.allocator.free(golden_filename);

        const d = try initTestDriver(record, fixture_filename);
        defer d.deinit();

        const open_res = try d.open(std.testing.allocator, .{});
        defer open_res.deinit();

        const actual_res = try d.commit(std.testing.allocator, .{});
        defer actual_res.deinit();

        defer helper.closeDriver(netconf.Driver, d, std.testing.allocator);

        try std.testing.expect(!actual_res.result_failure_indicated);

        try helper.processFixutreTestStrResult(
            test_name,
            case.name,
            golden_filename,
            actual_res.result,
        );
    }
}

test "driver-netconf discard" {
    const test_name = "discard";

    const cases = [_]struct {
        name: []const u8,
    }{
        .{
            .name = "simple",
        },
    };

    for (cases) |case| {
        const record = helper.isRecording();

        const fixture_filename = try helper.fixturePath(
            std.testing.allocator,
            "netconf",
            test_name,
            case.name,
        );
        defer std.testing.allocator.free(fixture_filename);

        const golden_filename = try helper.goldenPath(
            std.testing.allocator,
            "netconf",
            test_name,
            case.name,
        );
        defer std.testing.allocator.free(golden_filename);

        const d = try initTestDriver(record, fixture_filename);
        defer d.deinit();

        const open_res = try d.open(std.testing.allocator, .{});
        defer open_res.deinit();

        const actual_res = try d.discard(std.testing.allocator, .{});
        defer actual_res.deinit();

        defer helper.closeDriver(netconf.Driver, d, std.testing.allocator);

        try std.testing.expect(!actual_res.result_failure_indicated);

        try helper.processFixutreTestStrResult(
            test_name,
            case.name,
            golden_filename,
            actual_res.result,
        );
    }
}

test "driver-netconf cancel-commit" {
    const test_name = "cancel-commit";

    const cases = [_]struct {
        name: []const u8,
    }{
        .{
            .name = "simple",
        },
    };

    for (cases) |case| {
        const record = helper.isRecording();

        const fixture_filename = try helper.fixturePath(
            std.testing.allocator,
            "netconf",
            test_name,
            case.name,
        );
        defer std.testing.allocator.free(fixture_filename);

        const golden_filename = try helper.goldenPath(
            std.testing.allocator,
            "netconf",
            test_name,
            case.name,
        );
        defer std.testing.allocator.free(golden_filename);

        const d = try initTestDriver(record, fixture_filename);
        defer d.deinit();

        const open_res = try d.open(std.testing.allocator, .{});
        defer open_res.deinit();

        const actual_res = try d.cancelCommit(std.testing.allocator, .{});
        defer actual_res.deinit();

        defer helper.closeDriver(netconf.Driver, d, std.testing.allocator);

        // we know this one will actaully fail (expected, nothing to cancel)
        try std.testing.expect(actual_res.result_failure_indicated);

        try helper.processFixutreTestStrResult(
            test_name,
            case.name,
            golden_filename,
            actual_res.result,
        );
    }
}

test "driver-netconf action" {
    const test_name = "action";

    const cases = [_]struct {
        name: []const u8,
        action: []const u8,
    }{
        .{
            .name = "simple",
            .action =
            \\<system xmlns="urn:dummy:actions">
            \\  <reboot>
            \\    <delay>5</delay>
            \\  </reboot>
            \\</system>
            ,
        },
    };

    for (cases) |case| {
        const record = helper.isRecording();

        const fixture_filename = try helper.fixturePath(
            std.testing.allocator,
            "netconf",
            test_name,
            case.name,
        );
        defer std.testing.allocator.free(fixture_filename);

        const golden_filename = try helper.goldenPath(
            std.testing.allocator,
            "netconf",
            test_name,
            case.name,
        );
        defer std.testing.allocator.free(golden_filename);

        const d = try initTestDriver(record, fixture_filename);
        defer d.deinit();

        const open_res = try d.open(std.testing.allocator, .{});
        defer open_res.deinit();

        const actual_res = try d.action(
            std.testing.allocator,
            .{
                .action = case.action,
            },
        );
        defer actual_res.deinit();

        defer helper.closeDriver(netconf.Driver, d, std.testing.allocator);

        try std.testing.expect(!actual_res.result_failure_indicated);

        try helper.processFixutreTestStrResult(
            test_name,
            case.name,
            golden_filename,
            actual_res.result,
        );
    }
}

test "driver-netconf edit-data" {
    const test_name = "edit-data";

    const cases = [_]struct {
        name: []const u8,
        edit_content: []const u8,
    }{
        .{
            .name = "simple",
            .edit_content =
            \\<system xmlns="urn:some:data">
            \\  <hostname>my-router</hostname>
            \\  <interfaces>
            \\    <name>eth0</name>
            \\    <enabled>true</enabled>
            \\  </interfaces>
            \\  <interfaces>
            \\    <name>eth1</name>
            \\    <enabled>false</enabled>
            \\  </interfaces>
            \\</system>
            ,
        },
    };

    for (cases) |case| {
        const record = helper.isRecording();

        const fixture_filename = try helper.fixturePath(
            std.testing.allocator,
            "netconf",
            test_name,
            case.name,
        );
        defer std.testing.allocator.free(fixture_filename);

        const golden_filename = try helper.goldenPath(
            std.testing.allocator,
            "netconf",
            test_name,
            case.name,
        );
        defer std.testing.allocator.free(golden_filename);

        const d = try initTestDriver(record, fixture_filename);
        defer d.deinit();

        const open_res = try d.open(std.testing.allocator, .{});
        defer open_res.deinit();

        const actual_res = try d.editData(
            std.testing.allocator,
            .{
                .edit_content = case.edit_content,
            },
        );
        defer actual_res.deinit();

        defer helper.closeDriver(netconf.Driver, d, std.testing.allocator);

        try std.testing.expect(!actual_res.result_failure_indicated);

        try helper.processFixutreTestStrResult(
            test_name,
            case.name,
            golden_filename,
            actual_res.result,
        );
    }
}

test "driver-netconf get-schema" {
    const test_name = "get-schema";

    const cases = [_]struct {
        name: []const u8,
        identifier: []const u8,
    }{
        .{
            .name = "simple",
            .identifier = "ietf-yang-types",
        },
    };

    for (cases) |case| {
        const record = helper.isRecording();

        const fixture_filename = try helper.fixturePath(
            std.testing.allocator,
            "netconf",
            test_name,
            case.name,
        );
        defer std.testing.allocator.free(fixture_filename);

        const golden_filename = try helper.goldenPath(
            std.testing.allocator,
            "netconf",
            test_name,
            case.name,
        );
        defer std.testing.allocator.free(golden_filename);

        const d = try initTestDriver(record, fixture_filename);
        defer d.deinit();

        const open_res = try d.open(std.testing.allocator, .{});
        defer open_res.deinit();

        const actual_res = try d.getSchema(
            std.testing.allocator,
            .{
                .identifier = case.identifier,
            },
        );
        defer actual_res.deinit();

        defer helper.closeDriver(netconf.Driver, d, std.testing.allocator);

        try std.testing.expect(!actual_res.result_failure_indicated);

        try helper.processFixutreTestStrResult(
            test_name,
            case.name,
            golden_filename,
            actual_res.result,
        );
    }
}
