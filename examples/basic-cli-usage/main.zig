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

    const d = try cli.Driver.init(
        allocator,
        io,
        host,
        .{
            .definition = .{
                .string = definition,
            },
            // uncomment and import the logger package like: `const logging = scrapli.logging;`
            // for a simple logger setup
            // .logger = logging.Logger{
            //     .allocator = allocator,
            //     .f = logging.stdLogf,
            // },
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
