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

    var host = try get_env_var_or_default(
        host_env_var_name,
        default_host,
    );
    defer host.deinit();

    var password = try get_env_var_or_default(
        password_env_var_name,
        default_password,
    );
    defer password.deinit();

    const d = try netconf.Driver.init(
        allocator,
        host.string,
        .{
            // uncomment and import the logger package like: `const logging = scrapli.logging;`
            // for a simple logger setup
            // .logger = logging.Logger{ .allocator = allocator, .f = logging.stdLogf, },
            .port = try get_port(),
            .auth = .{
                .username = "admin",
                .password = password.string,
            },
            .session = .{
                // uncomment to log/record to a file
                // .record_destination = .{
                //     .f = "out.txt",
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
}
