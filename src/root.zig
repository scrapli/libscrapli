// zlinter-disable require_doc_comment
pub const ascii = @import("ascii.zig");
pub const auth = @import("auth.zig");
pub const bytes = @import("bytes.zig");
pub const bytes_check = @import("bytes-check.zig");
pub const cancellation = @import("cancellation.zig");
pub const cli = @import("cli.zig");
pub const cli_mode = @import("cli-mode.zig");
pub const cli_operation = @import("cli-operation.zig");
pub const cli_platform = @import("cli-platform.zig");
pub const cli_result = @import("cli-result.zig");
pub const errors = @import("errors.zig");
pub const ffi_driver = @import("ffi-driver.zig");
pub const ffi_root = @import("ffi-root.zig");
pub const ffi_root_cli = @import("ffi-root-cli.zig");
pub const ffi_root_netconf = @import("ffi-root-netconf.zig");
pub const file = @import("file.zig");
pub const logging = @import("logging.zig");
pub const netconf = @import("netconf.zig");
pub const netconf_operation = @import("netconf-operation.zig");
pub const netconf_result = @import("netconf-result.zig");
pub const once = @import("once.zig");
pub const queue = @import("queue.zig");
pub const re = @import("re.zig");
pub const session = @import("session.zig");
pub const strings = @import("strings.zig");
pub const test_helper = @import("test-helper.zig");
pub const transport = @import("transport.zig");
pub const transport_bin = @import("transport-bin.zig");
pub const transport_socket = @import("transport-socket.zig");
pub const transport_ssh2 = @import("transport-ssh2.zig");
pub const transport_telnet = @import("transport-telnet.zig");
pub const transport_waiter = @import("transport-waiter.zig");

test {
    _ = ascii;
    _ = auth;
    _ = bytes;
    _ = bytes_check;
    _ = cli;
    _ = cli_mode;
    _ = cli_platform;
    _ = cli_result;
    _ = errors;
    _ = ffi_driver;
    _ = ffi_root;
    _ = ffi_root_cli;
    _ = ffi_root_netconf;
    _ = netconf;
    _ = netconf_result;
    _ = once;
    _ = queue;
    _ = re;
    _ = session;
    _ = transport;
    _ = transport_bin;
    _ = transport_socket;
    _ = transport_ssh2;
    _ = transport_telnet;
    _ = transport_waiter;

    _ = @import("ffi-root.zig");
    _ = @import("ffi-root-cli.zig");
    _ = @import("ffi-root-netconf.zig");

    comptime {
        _ = @import("tests/integration/driver-tests.zig");
        _ = @import("tests/integration/driver-netconf-tests.zig");
    }

    comptime {
        _ = @import("tests/functional/driver-tests.zig");
        _ = @import("tests/functional/driver-netconf-tests.zig");
    }
}
