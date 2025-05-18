const std = @import("std");

const scrapli = @import("scrapli");

const cli = scrapli.cli;
const strings = scrapli.strings;

const banner = "********************";

const definition =
    \\---
    \\# https://regex101.com/r/U5mgK9/1
    \\prompt_pattern: '^--.*--\s*\n[abcd]:\S+#\s*$'
    \\default_mode: 'exec'
    \\modes:
    \\  - name: 'exec'
    \\    # https://regex101.com/r/PGLSJJ/1
    \\    prompt_pattern: '^--{(\s\[[\w\s]+\]){0,5}[\+\*\s]{1,}running\s}--\[.+?\]--\s*\n[abcd]:\S+#\s*$'
    \\    accessible_modes:
    \\      - name: 'configuration'
    \\        instructions:
    \\          - send_input:
    \\              input: 'enter candidate private'
    \\  - name: 'configuration'
    \\    # https://regex101.com/r/JsaUZy/1
    \\    prompt_pattern: '^--{(\s\[[\w\s]+\]){0,5}[\+\*\!\s]{1,}candidate[\-\w\s]+}--\[.+?\]--\s*\n[abcd]:\S+#\s*$'
    \\    accessible_modes:
    \\      - name: 'exec'
    \\        instructions:
    \\          - send_input:
    \\              input: 'discard now'
    \\failure_indicators:
    \\  - 'Error:'
    \\on_open_instructions:
    \\  - enter_mode:
    \\      requested_mode: 'exec'
    \\  - send_input:
    \\      input: 'environment cli-engine type basic'
    \\  - send_input:
    \\      input: 'environment complete-on-space false'
    \\on_close_instructions:
    \\  - enter_mode:
    \\      requested_mode: 'exec'
    \\  - write:
    \\      input: 'quit'
;

const host_env_var_name = "SCRAPLI_HOST";
const host_env_var_port = "SCRAPLI_PORT";
const password_env_var_name = "SCRAPLI_PASSWORD";

const default_host = "localhost"; // assuming the local clab setup (make run-clab)
const default_port: u16 = 21022; // nokia srlinux (ssh)
const default_password = "NokiaSrl1!";

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

fn getPort() !u16 {
    const port_as_str_or_null = std.process.getEnvVarOwned(
        allocator,
        host_env_var_port,
    ) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };

    if (port_as_str_or_null == null) {
        return default_port;
    }

    defer allocator.free(port_as_str_or_null.?);

    return try std.fmt.parseInt(u16, port_as_str_or_null.?, 10);
}

fn getEnvVarOrDefault(
    env_var_name: []const u8,
    default_value: []const u8,
) !strings.MaybeHeapString {
    const set_value = std.process.getEnvVarOwned(
        allocator,
        env_var_name,
    ) catch |err| switch (err) {
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

    var host = try getEnvVarOrDefault(
        host_env_var_name,
        default_host,
    );
    defer host.deinit();

    var password = try getEnvVarOrDefault(
        password_env_var_name,
        default_password,
    );
    defer password.deinit();

    const d = try cli.Driver.init(
        allocator,
        host.string,
        .{
            .definition = .{
                .string = definition,
            },
            // uncomment and import the logger package like: `const logging = scrapli.logging;`
            // for a simple logger setup
            // .logger = logging.Logger{ .allocator = allocator, .f = logging.stdLogf, },
            .port = try getPort(),
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
            open_result.results.items[0],
            banner,
            open_result.elapsedTimeSeconds(),
        },
    );

    const send_input_result = try d.sendInput(
        allocator,
        .{
            .input = "info interface *",
        },
    );
    defer send_input_result.deinit();

    std.debug.print(
        "{s}\n{s}\n{s}\n Completed in {d}s\n",
        .{
            banner,
            send_input_result.results.items[0],
            banner,
            send_input_result.elapsedTimeSeconds(),
        },
    );

    const close_result = try d.close(allocator, .{});
    defer close_result.deinit();
}
