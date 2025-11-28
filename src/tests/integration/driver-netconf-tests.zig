const std = @import("std");

const scrapli = @import("scrapli");
const netconf = scrapli.netconf;
const flags = scrapli.flags;
const helper = scrapli.test_helper;

fn GetRecordTestDriver(record_path: []const u8) !*netconf.Driver {
    return netconf.Driver.init(
        std.testing.allocator,
        std.testing.io,
        "localhost",
        .{
            .port = 22830,
            .auth = .{
                .username = "netconf-admin",
                .password = "admin",
            },
            .session = .{
                .record_destination = .{
                    .f = record_path,
                },
            },
        },
    );
}

fn GetTestDriver(f: []const u8) !*netconf.Driver {
    const d = try netconf.Driver.init(
        std.testing.allocator,
        std.testing.io,
        "dummy",
        .{
            .port = 22830,
            .auth = .{
                .username = "netconf-admin",
                .password = "admin",
            },
            .session = .{
                // with read size 1 we end up donig a ZILLION regexs which is slow af,
                // by turning all the timeouts off and having the default netconf search
                // depth be low we speed up the tests quite a bit
                .read_size = 1,
                .operation_timeout_ns = std.time.ns_per_min * 1,
            },
            .transport = .{
                .test_ = .{
                    .f = f,
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

test "driver-netconf open" {
    const test_name = "driver-netconf-open";

    const cases = [_]struct {
        name: []const u8,
    }{
        .{
            .name = "simple",
        },
    };

    for (cases) |case| {
        const record = flags.parseCustomFlag("--record", false);

        const fixture_filename = try std.fmt.allocPrint(
            std.testing.allocator,
            "src/tests/integration/fixtures/netconf/{s}-{s}.txt",
            .{ test_name, case.name },
        );
        defer std.testing.allocator.free(fixture_filename);

        const golden_filename = try std.fmt.allocPrint(
            std.testing.allocator,
            "src/tests/integration/golden/netconf/{s}-{s}.txt",
            .{ test_name, case.name },
        );
        defer std.testing.allocator.free(golden_filename);

        var d: *netconf.Driver = undefined;

        if (record) {
            d = try GetRecordTestDriver(fixture_filename);
        } else {
            d = try GetTestDriver(fixture_filename);
        }
        defer d.deinit();

        const actual_res = try d.open(std.testing.allocator, .{});
        defer actual_res.deinit();

        defer {
            const close_ret = d.close(std.testing.allocator, .{}) catch unreachable;
            close_ret.deinit();
        }

        try std.testing.expect(!actual_res.result_failure_indicated);

        try helper.processFixutreTestStrResult(
            test_name,
            case.name,
            golden_filename,
            actual_res.result,
        );
    }
}

test "driver-netconf get-config" {
    const test_name = "driver-netconf-get-config";

    const cases = [_]struct {
        name: []const u8,
    }{
        .{
            .name = "simple",
        },
    };

    for (cases) |case| {
        const record = flags.parseCustomFlag("--record", false);

        const fixture_filename = try std.fmt.allocPrint(
            std.testing.allocator,
            "src/tests/integration/fixtures/netconf/{s}-{s}.txt",
            .{ test_name, case.name },
        );
        defer std.testing.allocator.free(fixture_filename);

        const golden_filename = try std.fmt.allocPrint(
            std.testing.allocator,
            "src/tests/integration/golden/netconf/{s}-{s}.txt",
            .{ test_name, case.name },
        );
        defer std.testing.allocator.free(golden_filename);

        var d: *netconf.Driver = undefined;

        if (record) {
            d = try GetRecordTestDriver(fixture_filename);
        } else {
            d = try GetTestDriver(fixture_filename);
        }
        defer d.deinit();

        const open_res = try d.open(std.testing.allocator, .{});
        defer open_res.deinit();

        const actual_res = try d.getConfig(std.testing.allocator, .{});
        defer actual_res.deinit();

        defer {
            const close_ret = d.close(std.testing.allocator, .{}) catch unreachable;
            close_ret.deinit();
        }

        try std.testing.expect(!actual_res.result_failure_indicated);

        try helper.processFixutreTestStrResult(
            test_name,
            case.name,
            golden_filename,
            actual_res.result,
        );
    }
}

// edit config

// copy config

// delete config

test "driver-netconf lock" {
    const test_name = "driver-netconf-lock";

    const cases = [_]struct {
        name: []const u8,
    }{
        .{
            .name = "simple",
        },
    };

    for (cases) |case| {
        const record = flags.parseCustomFlag("--record", false);

        const fixture_filename = try std.fmt.allocPrint(
            std.testing.allocator,
            "src/tests/integration/fixtures/netconf/{s}-{s}.txt",
            .{ test_name, case.name },
        );
        defer std.testing.allocator.free(fixture_filename);

        const golden_filename = try std.fmt.allocPrint(
            std.testing.allocator,
            "src/tests/integration/golden/netconf/{s}-{s}.txt",
            .{ test_name, case.name },
        );
        defer std.testing.allocator.free(golden_filename);

        var d: *netconf.Driver = undefined;

        if (record) {
            d = try GetRecordTestDriver(fixture_filename);
        } else {
            d = try GetTestDriver(fixture_filename);
        }
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

        defer {
            const close_ret = d.close(std.testing.allocator, .{}) catch unreachable;
            close_ret.deinit();
        }

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
    const test_name = "driver-netconf-unlock";

    const cases = [_]struct {
        name: []const u8,
    }{
        .{
            .name = "simple",
        },
    };

    for (cases) |case| {
        const record = flags.parseCustomFlag("--record", false);

        const fixture_filename = try std.fmt.allocPrint(
            std.testing.allocator,
            "src/tests/integration/fixtures/netconf/{s}-{s}.txt",
            .{ test_name, case.name },
        );
        defer std.testing.allocator.free(fixture_filename);

        const golden_filename = try std.fmt.allocPrint(
            std.testing.allocator,
            "src/tests/integration/golden/netconf/{s}-{s}.txt",
            .{ test_name, case.name },
        );
        defer std.testing.allocator.free(golden_filename);

        var d: *netconf.Driver = undefined;

        if (record) {
            d = try GetRecordTestDriver(fixture_filename);
        } else {
            d = try GetTestDriver(fixture_filename);
        }
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

        defer {
            const close_ret = d.close(std.testing.allocator, .{}) catch unreachable;
            close_ret.deinit();
        }

        try std.testing.expect(!actual_res.result_failure_indicated);

        try helper.processFixutreTestStrResult(
            test_name,
            case.name,
            golden_filename,
            actual_res.result,
        );
    }
}

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
