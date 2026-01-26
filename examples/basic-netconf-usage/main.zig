const std = @import("std");

const scrapli = @import("scrapli");
const netconf = scrapli.netconf;
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
            .scope = .parser,
            .level = .err,
        },
    },
};

fn getPort(
    environ_map: *std.process.Environ.Map,
) !u16 {
    if (environ_map.get(host_env_var_port)) |p| {
        return try std.fmt.parseInt(u16, p, 10);
    }

    return default_port;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    const host = init.environ_map.get(host_env_var_name) orelse default_host;
    const password = init.environ_map.get(password_env_var_name) orelse default_password;

    const d = try netconf.Driver.init(
        allocator,
        io,
        host,
        .{
            // uncomment and import the logger package like: `const logging = scrapli.logging;`
            // for a simple logger setup
            // .logger = logging.Logger{ .allocator = allocator, .f = logging.stdLogf, },
            .port = try getPort(init.environ_map),
            .auth = .{
                .username = "admin",
                .password = password,
            },
            .session = .{
                // uncomment to log/record to a file
                // .record_destination = .{
                //     .f = "out.log",
                // },
            },
            .transport = .{
                // comment out to use bin transport if desired
                .ssh2 = .{},
            },
        },
    );
    defer d.deinit();

    const open_result = try d.open(
        allocator,
        .{},
    );
    defer open_result.deinit();

    std.debug.print(
        "{s}\n{s}\n{s}\n Completed in {d}s\n",
        .{
            banner,
            open_result.result,
            banner,
            open_result.elapsedTimeSeconds(),
        },
    );

    const get_result = try d.getConfig(allocator, .{});
    defer get_result.deinit();

    std.debug.print(
        "{s}\n{s}\n{s}\n Completed in {d}s\n",
        .{
            banner,
            get_result.result,
            banner,
            get_result.elapsedTimeSeconds(),
        },
    );

    const get_config_result = try d.get(allocator, .{
        .filter = "<system><aaa><authentication></authentication></aaa></system>",
    });
    defer get_config_result.deinit();

    std.debug.print(
        "{s}\n{s}\n{s}\n Completed in {d}s\n",
        .{
            banner,
            get_config_result.result,
            banner,
            get_config_result.elapsedTimeSeconds(),
        },
    );

    const close_result = try d.close(allocator, .{});
    defer close_result.deinit();

    std.debug.print(
        "{s}\n{s}\n{s}\n Completed in {d}s\n",
        .{
            banner,
            close_result.result,
            banner,
            close_result.elapsedTimeSeconds(),
        },
    );
}
