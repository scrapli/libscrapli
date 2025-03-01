const std = @import("std");
const ffi_driver = @import("ffi-driver.zig");
const driver = @import("driver.zig");
const transport = @import("transport.zig");
const bin = @import("transport-bin.zig");
const telnet = @import("transport-telnet.zig");
const ssh2 = @import("transport-ssh2.zig");
const logger = @import("logger.zig");

pub fn NewDriverOptionsFromAlloc(
    definition_variant: [*c]const u8,
    log: logger.Logger,
    port: u16,
    transport_kind: [*c]const u8,
) driver.Options {
    var opts = driver.NewOptions();

    opts.variant_name = std.mem.span(definition_variant);

    opts.logger = log;
    opts.port = port;

    // transport kind will always be passed by the higher level lang as a valid string matching
    // one of the transport kinds; but before comparison cast to zig style from c style to make
    // life easy
    const _transport_kind = std.mem.span(transport_kind);

    if (std.mem.eql(u8, @tagName(transport.Kind.Bin), _transport_kind)) {
        opts.transport = bin.NewOptions();
    } else if (std.mem.eql(u8, @tagName(transport.Kind.Telnet), _transport_kind)) {
        opts.transport = telnet.NewOptions();
    } else if (std.mem.eql(u8, @tagName(transport.Kind.SSH2), _transport_kind)) {
        opts.transport = ssh2.NewOptions();
    }

    return opts;
}

//
// session options
//

export fn setDriverOptionSessionReadSize(
    d_ptr: usize,
    value: u64,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.real_driver.session.options.read_size = value;

    return 0;
}

export fn setDriverOptionSessionReadDelayMinNs(
    d_ptr: usize,
    value: u64,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.real_driver.session.options.read_delay_min_ns = value;

    return 0;
}

export fn setDriverOptionSessionReadDelayMaxNs(
    d_ptr: usize,
    value: u64,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.real_driver.session.options.read_delay_max_ns = value;

    return 0;
}

export fn setDriverOptionSessionReadDelayBackoffFactor(
    d_ptr: usize,
    value: u8,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.real_driver.session.options.read_delay_backoff_factor = value;

    return 0;
}

export fn setDriverOptionSessionReturnChar(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.real_driver.session.options.return_char = std.mem.span(value);

    return 0;
}

export fn setDriverOptionSessionOperationTimeoutNs(
    d_ptr: usize,
    value: u64,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.real_driver.session.options.operation_timeout_ns = value;

    return 0;
}

export fn setDriverOptionSessionOperationMaxSearchDepth(
    d_ptr: usize,
    value: u64,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.real_driver.session.options.operation_max_search_depth = value;

    return 0;
}

//
// auth options
//

export fn setDriverOptionAuthUsername(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.real_driver.session.auth_options.username = std.mem.span(value);

    return 0;
}

export fn setDriverOptionAuthPassword(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.real_driver.session.auth_options.password = std.mem.span(value);

    return 0;
}

export fn setDriverOptionAuthPrivateKeyPath(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.real_driver.session.auth_options.private_key_path = std.mem.span(value);

    return 0;
}

export fn setDriverOptionAuthPrivateKeyPassphrase(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.real_driver.session.auth_options.private_key_passphrase = std.mem.span(value);

    return 0;
}

export fn setDriverOptionAuthInSessionAuthBypass(
    d_ptr: usize,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.real_driver.session.auth_options.in_session_auth_bypass = true;

    return 0;
}

export fn setDriverOptionAuthUsernamePattern(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.real_driver.session.auth_options.username_pattern = std.mem.span(value);

    return 0;
}

export fn setDriverOptionAuthPasswordPattern(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.real_driver.session.auth_options.password_pattern = std.mem.span(value);

    return 0;
}

export fn setDriverOptionAuthPassphrasePattern(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.real_driver.session.auth_options.passphrase_pattern = std.mem.span(value);

    return 0;
}

//
// bin transport options
//

export fn setDriverOptionBinTransportBin(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver.session.transport.implementation) {
        .Bin => {
            d.real_driver.session.transport.implementation.Bin.options.bin = std.mem.span(value);
        },
        else => {
            return 1;
        },
    }

    return 0;
}

export fn setDriverOptionBinTransportExtraOpenArgs(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver.session.transport.implementation) {
        .Bin => {
            d.real_driver.session.transport.implementation.Bin.options.extra_open_args = std.mem.span(value);
        },
        else => {
            return 1;
        },
    }

    return 0;
}

export fn setDriverOptionBinTransportOverrideOpenArgs(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver.session.transport.implementation) {
        .Bin => {
            d.real_driver.session.transport.implementation.Bin.options.override_open_args = std.mem.span(value);
        },
        else => {
            return 1;
        },
    }

    return 0;
}

export fn setDriverOptionBinTransportSSHConfigPath(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver.session.transport.implementation) {
        .Bin => {
            d.real_driver.session.transport.implementation.Bin.options.ssh_config_path = std.mem.span(value);
        },
        else => {
            return 1;
        },
    }

    return 0;
}

export fn setDriverOptionBinTransportKnownHostsPath(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver.session.transport.implementation) {
        .Bin => {
            d.real_driver.session.transport.implementation.Bin.options.known_hosts_path = std.mem.span(value);
        },
        else => {
            return 1;
        },
    }

    return 0;
}

export fn setDriverOptionBinTransportEnableStrictKey(
    d_ptr: usize,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver.session.transport.implementation) {
        .Bin => {
            d.real_driver.session.transport.implementation.Bin.options.enable_strict_key = true;
        },
        else => {
            return 1;
        },
    }

    return 0;
}

export fn setDriverOptionBinTransportTermHeight(
    d_ptr: usize,
    value: u16,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver.session.transport.implementation) {
        .Bin => {
            d.real_driver.session.transport.implementation.Bin.options.term_height = value;
        },
        else => {
            return 1;
        },
    }

    return 0;
}

export fn setDriverOptionBinTransportTermWidth(
    d_ptr: usize,
    value: u16,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver.session.transport.implementation) {
        .Bin => {
            d.real_driver.session.transport.implementation.Bin.options.term_width = value;
        },
        else => {
            return 1;
        },
    }

    return 0;
}

//
// ssh2 transport options
//

export fn setDriverOptionSSH2TransportSSH2Trace(
    d_ptr: usize,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver.session.transport.implementation) {
        .SSH2 => {
            d.real_driver.session.transport.implementation.SSH2.options.libssh2_trace = true;
        },
        else => {
            return 1;
        },
    }

    return 0;
}
