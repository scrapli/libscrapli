const std = @import("std");

const scrapli = @import("scrapli");

const driver = scrapli.driver_netconf;
const ssh2 = scrapli.transport_ssh2;
const operation = scrapli.operation_netconf;
const strings = scrapli.strings;

const banner = "********************";

const host_env_var_name = "SCRAPLI_HOST";
const host_env_var_port = "SCRAPLI_PORT";
const password_env_var_name = "SCRAPLI_PASSWORD";

const default_host = "localhost"; // assuming the local clab setup (make run-clab)
const default_port: u16 = 22830; // arista ceos (netconf)
const default_password = "admin";

pub const std_options = std.Options{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{
            .scope = .yaml,
            .level = .err,
        },
        .{
            .scope = .tokenizer,
            .level = .err,
        },
        .{
            .scope = .parse,
            .level = .err,
        },
    },
};

var gpa_allocator = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa_allocator.allocator();

fn get_port() !u16 {
    const port_as_str_or_null = std.process.getEnvVarOwned(allocator, host_env_var_port) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };

    if (port_as_str_or_null == null) {
        return default_port;
    }

    defer allocator.free(port_as_str_or_null.?);

    return try std.fmt.parseInt(u16, port_as_str_or_null.?, 10);
}

fn get_env_var_or_default(
    env_var_name: []const u8,
    default_value: []const u8,
) !strings.MaybeHeapString {
    const set_value = std.process.getEnvVarOwned(allocator, env_var_name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => default_value,
        else => return err,
    };

    if (std.mem.eql(u8, set_value, default_value)) {
        return strings.MaybeHeapString{
            .allocator = null,
            .string = set_value,
        };
    }

    return strings.MaybeHeapString{
        .allocator = allocator,
        .string = set_value,
    };
}

pub fn main() !void {
    defer {
        // mostly i've used this for testing but its kinda nice to double check!
        std.log.info("leak check results >> {any}\n", .{gpa_allocator.deinit()});
    }

    var host = try get_env_var_or_default(host_env_var_name, default_host);
    defer host.deinit();

    var password = try get_env_var_or_default(password_env_var_name, default_password);
    defer password.deinit();
    var opts = driver.NewOptions();

    opts.auth.username = "admin";
    opts.auth.password = password.string;
    opts.port = try get_port();

    // ssh2; if commented out you'll default to using bin transport (/bin/ssh wrapper)
    opts.transport = ssh2.NewOptions();

    // for logging to stdout, or comment/remove for no logging and add the following import/alias:
    // const logger = scrapli.logger;
    // opts.logger = logger.Logger{ .allocator = allocator, .f = logger.stdLogf };

    // for logging to a file
    // const f = try std.fs.cwd().createFile(
    //     "out.txt",
    //     .{},
    // );
    // defer f.close();
    // opts.session.recorder = f.writer();

    const d = try driver.NewDriver(
        allocator,
        host.string,
        opts,
    );

    try d.init();
    defer d.deinit();

    const open_result = try d.open(
        allocator,
        operation.NewOpenOptions(),
    );
    defer open_result.deinit();

    std.debug.print(
        "{s}\n{s}\n{s}\n Completed in {d}s\n",
        .{
            banner,
            open_result.results.items[0],
            banner,
            open_result.elapsedTimeSeconds(),
        },
    );

    const get_result = try d.getConfig(allocator, operation.NewGetConfigOptions());
    defer get_result.deinit();

    std.debug.print(
        "{s}\n{s}\n{s}\n Completed in {d}s\n",
        .{
            banner,
            get_result.results.items[0],
            banner,
            get_result.elapsedTimeSeconds(),
        },
    );

    var get_options = operation.NewGetOptions();
    get_options.filter = "<system><aaa><authentication></authentication></aaa></system>";

    const get_config_result = try d.get(allocator, get_options);
    defer get_config_result.deinit();

    std.debug.print(
        "{s}\n{s}\n{s}\n Completed in {d}s\n",
        .{
            banner,
            get_config_result.results.items[0],
            banner,
            get_config_result.elapsedTimeSeconds(),
        },
    );

    const close_result = try d.close(allocator, operation.NewCloseOptions());
    defer close_result.deinit();
}
