const std = @import("std");
const ffi_driver = @import("ffi-driver.zig");

// for forcing inclusion in the ffi.zig entrypoint we use for the ffi layer
pub export fn noop() void {}

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

// this is unsafe/will leak, and should only be used in testing
export fn setDriverOptionSessionRecorderPath(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    var f = std.fs.cwd().createFile(
        std.mem.span(value),
        .{},
    ) catch {
        return 1;
    };

    d.real_driver.session.options.recorder = f.writer();

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
        .bin => {
            d.real_driver.options.transport.bin.bin = d.real_driver.options.transport.bin.allocator.dupe(
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
        .bin => {
            d.real_driver.options.transport.bin.extra_open_args = d.real_driver.options.transport.bin.allocator.dupe(
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
        .bin => {
            d.real_driver.options.transport.bin.override_open_args = d.real_driver.options.transport.bin.allocator.dupe(
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
        .bin => {
            d.real_driver.options.transport.bin.ssh_config_path = d.real_driver.options.transport.bin.allocator.dupe(
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
        .bin => {
            d.real_driver.options.transport.bin.known_hosts_path = d.real_driver.options.transport.bin.allocator.dupe(
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
        .bin => {
            d.real_driver.options.transport.bin.enable_strict_key = true;
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
        .bin => {
            d.real_driver.options.transport.bin.term_height = value;
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
        .bin => {
            d.real_driver.options.transport.bin.term_width = value;
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
        .ssh2 => {
            d.real_driver.options.transport.ssh2.libssh2_trace = true;
        },
        else => {
            return 1;
        },
    }

    return 0;
}

//
// test transport options
//

export fn setDriverOptionTestTransportF(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver.session.transport.implementation) {
        .test_ => {
            d.real_driver.options.transport.test_.f = d.real_driver.options.transport.test_.allocator.dupe(
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
