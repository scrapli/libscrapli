const std = @import("std");
const ffi_driver = @import("ffi-driver.zig");
const driver = @import("driver.zig");
const transport = @import("transport.zig");
const logger = @import("logger.zig");

pub fn NewDriverOptionsFromAlloc(
    definition_variant: [*c]const u8,
    log: logger.Logger,
    port: u16,
    transport_kind: [*c]const u8,
) driver.OptionsInputs {
    var opts = driver.OptionsInputs{};

    opts.variant_name = std.mem.span(definition_variant);

    opts.logger = log;
    opts.port = port;

    // transport kind will always be passed by the higher level lang as a valid string matching
    // one of the transport kinds; but before comparison cast to zig style from c style to make
    // life easy
    const _transport_kind = std.mem.span(transport_kind);

    if (std.mem.eql(u8, @tagName(transport.Kind.Bin), _transport_kind)) {
        opts.transport = .{ .Bin = .{} };
    } else if (std.mem.eql(u8, @tagName(transport.Kind.Telnet), _transport_kind)) {
        opts.transport = .{ .Telnet = .{} };
    } else if (std.mem.eql(u8, @tagName(transport.Kind.SSH2), _transport_kind)) {
        opts.transport = .{ .SSH2 = .{} };
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

    d.real_driver.session.options.return_char = d.real_driver.session.options.allocator.dupe(
        u8,
        std.mem.span(value),
    ) catch {
        return 1;
    };

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

    d.real_driver.options.auth.username = d.real_driver.options.auth.allocator.dupe(
        u8,
        std.mem.span(value),
    ) catch {
        return 1;
    };

    return 0;
}

export fn setDriverOptionAuthPassword(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    // TODO
    d.real_driver.options.auth.password = d.real_driver.options.auth.allocator.dupe(
        u8,
        std.mem.span(value),
    ) catch {
        return 1;
    };

    return 0;
}

export fn setDriverOptionAuthPrivateKeyPath(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.real_driver.options.auth.private_key_path = d.real_driver.options.auth.allocator.dupe(
        u8,
        std.mem.span(value),
    ) catch {
        return 1;
    };

    return 0;
}

export fn setDriverOptionAuthPrivateKeyPassphrase(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.real_driver.options.auth.private_key_passphrase = d.real_driver.options.auth.allocator.dupe(
        u8,
        std.mem.span(value),
    ) catch {
        return 1;
    };

    return 0;
}

export fn setDriverOptionAuthInSessionAuthBypass(
    d_ptr: usize,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.real_driver.session.auth_options.in_session_auth_bypass = true;

    return 0;
}

export fn setDriverOptionAuthLookupKeyValue(
    d_ptr: usize,
    key: [*c]const u8,
    value: [*c]const u8,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.real_driver.options.auth.extendLookupMap(
        std.mem.span(key),
        std.mem.span(value),
    ) catch {
        return 1;
    };

    return 0;
}

export fn setDriverOptionAuthUsernamePattern(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.real_driver.session.auth_options.username_pattern = d.real_driver.options.auth.allocator.dupe(
        u8,
        std.mem.span(value),
    ) catch {
        return 1;
    };

    return 0;
}

export fn setDriverOptionAuthPasswordPattern(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.real_driver.session.auth_options.password_pattern = d.real_driver.options.auth.allocator.dupe(
        u8,
        std.mem.span(value),
    ) catch {
        return 1;
    };

    return 0;
}

export fn setDriverOptionAuthPassphrasePattern(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.real_driver.session.auth_options.passphrase_pattern = d.real_driver.options.auth.allocator.dupe(
        u8,
        std.mem.span(value),
    ) catch {
        return 1;
    };

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
            d.real_driver.options.transport.Bin.bin = d.real_driver.options.transport.Bin.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
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
            d.real_driver.options.transport.Bin.extra_open_args = d.real_driver.options.transport.Bin.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
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
            d.real_driver.options.transport.Bin.override_open_args = d.real_driver.options.transport.Bin.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
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
            d.real_driver.options.transport.Bin.ssh_config_path = d.real_driver.options.transport.Bin.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
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
            d.real_driver.options.transport.Bin.known_hosts_path = d.real_driver.options.transport.Bin.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
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
            d.real_driver.options.transport.Bin.enable_strict_key = true;
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
            d.real_driver.options.transport.Bin.term_height = value;
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
            d.real_driver.options.transport.Bin.term_width = value;
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
            d.real_driver.options.transport.SSH2.libssh2_trace = true;
        },
        else => {
            return 1;
        },
    }

    return 0;
}
