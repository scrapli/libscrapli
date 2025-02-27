const std = @import("std");

const driver = @import("../../driver-netconf.zig");
const operation = @import("../../operation-netconf.zig");
const ascii = @import("../../ascii.zig");
const test_transport = @import("../../transport-test.zig");
const flags = @import("../../flags.zig");
const file = @import("../../file.zig");
const helper = @import("../../test-helper.zig");

fn GetRecordTestDriver(recorder: std.fs.File.Writer) !*driver.Driver {
    var opts = driver.NewOptions();

    opts.session.recorder = recorder;

    opts.auth.username = "admin";
    opts.auth.password = "admin";
    opts.port = 22830;

    return driver.NewDriver(
        std.testing.allocator,
        "localhost",
        opts,
    );
}

fn GetTestDriver(f: []const u8) !*driver.Driver {
    var opts = driver.NewOptions();

    // with read size 1 we end up donig a ZILLION regexs which is slow af,
    // by turning all the timeouts off and having the default netconf search
    // depth be low we speed up the tests quite a bit
    opts.session.read_size = 1;
    opts.session.read_delay_backoff_factor = 0;
    opts.session.read_delay_min_ns = 0;
    opts.session.read_delay_max_ns = 0;
    opts.session.operation_timeout_ns = std.time.ns_per_min * 1;

    // the default initial search depth of 256 will be too deep and consume some of the
    // server hello. this is just an issue due to how the test transport reads the file
    opts.session.operation_max_search_depth = 32;

    opts.auth.username = "admin";
    opts.auth.password = "admin";
    opts.transport = test_transport.NewOptions();
    opts.transport.Test.f = f;

    return driver.NewDriver(
        std.testing.allocator,
        "dummy",
        opts,
    );
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

        var f: std.fs.File = undefined;

        defer {
            if (record) {
                f.close();

                var content = file.readFromPath(std.testing.allocator, fixture_filename) catch unreachable;
                defer std.testing.allocator.free(content);

                const new_size = ascii.stripAsciiAndAnsiControlCharsInPlace(content, 0);
                file.writeToPath(std.testing.allocator, fixture_filename, content[0..new_size]) catch unreachable;
            }
        }

        var d: *driver.Driver = undefined;

        if (record) {
            f = try std.fs.cwd().createFile(
                fixture_filename,
                .{},
            );

            d = try GetRecordTestDriver(f.writer());
        } else {
            d = try GetTestDriver(fixture_filename);
        }

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

        try std.testing.expect(!actual_res.result_failure_indicated);

        try helper.processFixutreTestStrResult(
            test_name,
            case.name,
            golden_filename,
            actual,
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

        var f: std.fs.File = undefined;

        defer {
            if (record) {
                f.close();

                var content = file.readFromPath(std.testing.allocator, fixture_filename) catch unreachable;
                defer std.testing.allocator.free(content);

                const new_size = ascii.stripAsciiAndAnsiControlCharsInPlace(content, 0);
                file.writeToPath(std.testing.allocator, fixture_filename, content[0..new_size]) catch unreachable;
            }
        }

        var d: *driver.Driver = undefined;

        if (record) {
            f = try std.fs.cwd().createFile(
                fixture_filename,
                .{},
            );

            d = try GetRecordTestDriver(f.writer());
        } else {
            d = try GetTestDriver(fixture_filename);
        }

        try d.init();
        defer d.deinit();

        const open_res = try d.open(std.testing.allocator, operation.NewOpenOptions());
        defer open_res.deinit();

        const actual_res = try d.getConfig(std.testing.allocator, operation.NewGetConfigOptions());
        defer actual_res.deinit();

        defer {
            const close_ret = d.close(std.testing.allocator, operation.NewCloseOptions()) catch unreachable;
            close_ret.deinit();
        }

        const actual = try actual_res.getResult(std.testing.allocator);
        defer std.testing.allocator.free(actual);

        try std.testing.expect(!actual_res.result_failure_indicated);

        try helper.processFixutreTestStrResult(
            test_name,
            case.name,
            golden_filename,
            actual,
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

        var f: std.fs.File = undefined;

        defer {
            if (record) {
                f.close();

                var content = file.readFromPath(std.testing.allocator, fixture_filename) catch unreachable;
                defer std.testing.allocator.free(content);

                const new_size = ascii.stripAsciiAndAnsiControlCharsInPlace(content, 0);
                file.writeToPath(std.testing.allocator, fixture_filename, content[0..new_size]) catch unreachable;
            }
        }

        var d: *driver.Driver = undefined;

        if (record) {
            f = try std.fs.cwd().createFile(
                fixture_filename,
                .{},
            );

            d = try GetRecordTestDriver(f.writer());
        } else {
            d = try GetTestDriver(fixture_filename);
        }

        try d.init();
        defer d.deinit();

        const open_res = try d.open(std.testing.allocator, operation.NewOpenOptions());
        defer open_res.deinit();

        var lock_unlock_options = operation.NewLockUnlockOptions();
        lock_unlock_options.target = operation.DatastoreType.Candidate;

        const actual_res = try d.lock(std.testing.allocator, lock_unlock_options);
        defer actual_res.deinit();

        defer {
            const close_ret = d.close(std.testing.allocator, operation.NewCloseOptions()) catch unreachable;
            close_ret.deinit();
        }

        const actual = try actual_res.getResult(std.testing.allocator);
        defer std.testing.allocator.free(actual);

        try std.testing.expect(!actual_res.result_failure_indicated);

        try helper.processFixutreTestStrResult(
            test_name,
            case.name,
            golden_filename,
            actual,
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

        var f: std.fs.File = undefined;

        defer {
            if (record) {
                f.close();

                var content = file.readFromPath(std.testing.allocator, fixture_filename) catch unreachable;
                defer std.testing.allocator.free(content);

                const new_size = ascii.stripAsciiAndAnsiControlCharsInPlace(content, 0);
                file.writeToPath(std.testing.allocator, fixture_filename, content[0..new_size]) catch unreachable;
            }
        }

        var d: *driver.Driver = undefined;

        if (record) {
            f = try std.fs.cwd().createFile(
                fixture_filename,
                .{},
            );

            d = try GetRecordTestDriver(f.writer());
        } else {
            d = try GetTestDriver(fixture_filename);
        }

        try d.init();
        defer d.deinit();

        const open_res = try d.open(std.testing.allocator, operation.NewOpenOptions());
        defer open_res.deinit();

        var lock_unlock_options = operation.NewLockUnlockOptions();
        lock_unlock_options.target = operation.DatastoreType.Candidate;

        const lock_res = try d.lock(std.testing.allocator, lock_unlock_options);
        defer lock_res.deinit();

        const actual_res = try d.unlock(std.testing.allocator, lock_unlock_options);
        defer actual_res.deinit();

        defer {
            const close_ret = d.close(std.testing.allocator, operation.NewCloseOptions()) catch unreachable;
            close_ret.deinit();
        }

        const actual = try actual_res.getResult(std.testing.allocator);
        defer std.testing.allocator.free(actual);

        try std.testing.expect(!actual_res.result_failure_indicated);

        try helper.processFixutreTestStrResult(
            test_name,
            case.name,
            golden_filename,
            actual,
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
