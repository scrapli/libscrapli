const std = @import("std");
const ffi_driver = @import("ffi-driver.zig");

// for forcing inclusion in the ffi.zig entrypoint we use for the ffi layer
pub const noop = true;

//
// session options
//

export fn setDriverOptionSessionReadSize(
    d_ptr: usize,
    value: u64,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            rd.session.options.read_size = value;
        },
        .netconf => |rd| {
            rd.session.options.read_size = value;
        },
    }

    return 0;
}

export fn setDriverOptionSessionReadDelayMinNs(
    d_ptr: usize,
    value: u64,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            rd.session.options.read_delay_min_ns = value;
        },
        .netconf => |rd| {
            rd.session.options.read_delay_min_ns = value;
        },
    }

    return 0;
}

export fn setDriverOptionSessionReadDelayMaxNs(
    d_ptr: usize,
    value: u64,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            rd.session.options.read_delay_max_ns = value;
        },
        .netconf => |rd| {
            rd.session.options.read_delay_max_ns = value;
        },
    }

    return 0;
}

export fn setDriverOptionSessionReadDelayBackoffFactor(
    d_ptr: usize,
    value: u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            rd.session.options.read_delay_backoff_factor = value;
        },
        .netconf => |rd| {
            rd.session.options.read_delay_backoff_factor = value;
        },
    }

    return 0;
}

export fn setDriverOptionSessionReturnChar(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            rd.session.options.return_char = rd.session.options.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
        .netconf => |rd| {
            rd.session.options.return_char = rd.session.options.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
    }

    return 0;
}

export fn setDriverOptionSessionOperationTimeoutNs(
    d_ptr: usize,
    value: u64,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            rd.session.options.operation_timeout_ns = value;
        },
        .netconf => |rd| {
            rd.session.options.operation_timeout_ns = value;
        },
    }

    return 0;
}

export fn setDriverOptionSessionOperationMaxSearchDepth(
    d_ptr: usize,
    value: u64,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            rd.session.options.operation_max_search_depth = value;
        },
        .netconf => |rd| {
            rd.session.options.operation_max_search_depth = value;
        },
    }

    return 0;
}

export fn setDriverOptionSessionRecorderPath(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            rd.session.options.record_destination = .{
                .f = rd.session.options.allocator.dupe(
                    u8,
                    std.mem.span(value),
                ) catch {
                    return 1;
                },
            };

            const out_f = std.fs.cwd().createFile(
                rd.session.options.record_destination.?.f,
                .{},
            ) catch {
                return 1;
            };

            var recorder = out_f.writer();
            recorder.context = out_f;

            rd.session.recorder = recorder;
        },
        .netconf => |rd| {
            rd.session.options.record_destination = .{
                .f = rd.session.options.allocator.dupe(
                    u8,
                    std.mem.span(value),
                ) catch {
                    return 1;
                },
            };

            const out_f = std.fs.cwd().createFile(
                rd.session.options.record_destination.?.f,
                .{},
            ) catch {
                return 1;
            };

            var recorder = out_f.writer();
            recorder.context = out_f;

            rd.session.recorder = recorder;
        },
    }

    return 0;
}

//
// auth options
//

export fn setDriverOptionAuthUsername(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            rd.options.auth.username = rd.options.auth.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
        .netconf => |rd| {
            rd.options.auth.username = rd.options.auth.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
    }

    return 0;
}

export fn setDriverOptionAuthPassword(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            rd.options.auth.password = rd.options.auth.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
        .netconf => |rd| {
            rd.options.auth.password = rd.options.auth.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
    }

    return 0;
}

export fn setDriverOptionAuthPrivateKeyPath(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            rd.options.auth.private_key_path = rd.options.auth.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
        .netconf => |rd| {
            rd.options.auth.private_key_path = rd.options.auth.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
    }

    return 0;
}

export fn setDriverOptionAuthPrivateKeyPassphrase(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            rd.options.auth.private_key_passphrase = rd.options.auth.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
        .netconf => |rd| {
            rd.options.auth.private_key_passphrase = rd.options.auth.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
    }

    return 0;
}

export fn setDriverOptionAuthInSessionAuthBypass(
    d_ptr: usize,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            rd.session.auth_options.in_session_auth_bypass = true;
        },
        .netconf => |rd| {
            rd.session.auth_options.in_session_auth_bypass = true;
        },
    }

    return 0;
}

export fn setDriverOptionAuthLookupKeyValue(
    d_ptr: usize,
    key: [*c]const u8,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            rd.options.auth.extendLookupMap(
                std.mem.span(key),
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
        .netconf => |rd| {
            rd.options.auth.extendLookupMap(
                std.mem.span(key),
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
    }

    return 0;
}

export fn setDriverOptionAuthUsernamePattern(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            rd.options.auth.username_pattern = rd.options.auth.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
        .netconf => |rd| {
            rd.options.auth.username_pattern = rd.options.auth.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
    }

    return 0;
}

export fn setDriverOptionAuthPasswordPattern(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            rd.options.auth.password_pattern = rd.options.auth.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
        .netconf => |rd| {
            rd.options.auth.password_pattern = rd.options.auth.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
    }

    return 0;
}

export fn setDriverOptionAuthPassphrasePattern(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            rd.options.auth.passphrase_pattern = rd.options.auth.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
        .netconf => |rd| {
            rd.options.auth.passphrase_pattern = rd.options.auth.allocator.dupe(
                u8,
                std.mem.span(value),
            ) catch {
                return 1;
            };
        },
    }

    return 0;
}

//
// bin transport options
//

export fn setDriverOptionBinTransportBin(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            switch (rd.session.transport.implementation) {
                .bin => |i| {
                    i.options.bin = rd.options.transport.bin.allocator.dupe(
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
        },
        .netconf => |rd| {
            switch (rd.session.transport.implementation) {
                .bin => |i| {
                    i.options.bin = rd.options.transport.bin.allocator.dupe(
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
        },
    }

    return 0;
}

export fn setDriverOptionBinTransportExtraOpenArgs(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            switch (rd.session.transport.implementation) {
                .bin => |i| {
                    i.options.extra_open_args = rd.options.transport.bin.allocator.dupe(
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
        },
        .netconf => |rd| {
            switch (rd.session.transport.implementation) {
                .bin => |i| {
                    i.options.extra_open_args = rd.options.transport.bin.allocator.dupe(
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
        },
    }

    return 0;
}

export fn setDriverOptionBinTransportOverrideOpenArgs(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            switch (rd.session.transport.implementation) {
                .bin => |i| {
                    i.options.override_open_args = rd.options.transport.bin.allocator.dupe(
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
        },
        .netconf => |rd| {
            switch (rd.session.transport.implementation) {
                .bin => |i| {
                    i.options.override_open_args = rd.options.transport.bin.allocator.dupe(
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
        },
    }

    return 0;
}

export fn setDriverOptionBinTransportSSHConfigPath(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            switch (rd.session.transport.implementation) {
                .bin => |i| {
                    i.options.ssh_config_path = rd.options.transport.bin.allocator.dupe(
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
        },
        .netconf => |rd| {
            switch (rd.session.transport.implementation) {
                .bin => |i| {
                    i.options.ssh_config_path = rd.options.transport.bin.allocator.dupe(
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
        },
    }

    return 0;
}

export fn setDriverOptionBinTransportKnownHostsPath(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            switch (rd.session.transport.implementation) {
                .bin => |i| {
                    i.options.known_hosts_path = rd.options.transport.bin.allocator.dupe(
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
        },
        .netconf => |rd| {
            switch (rd.session.transport.implementation) {
                .bin => |i| {
                    i.options.known_hosts_path = rd.options.transport.bin.allocator.dupe(
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
        },
    }

    return 0;
}

export fn setDriverOptionBinTransportEnableStrictKey(
    d_ptr: usize,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            switch (rd.session.transport.implementation) {
                .bin => |i| {
                    i.options.enable_strict_key = true;
                },
                else => {
                    return 1;
                },
            }
        },
        .netconf => |rd| {
            switch (rd.session.transport.implementation) {
                .bin => |i| {
                    i.options.enable_strict_key = true;
                },
                else => {
                    return 1;
                },
            }
        },
    }

    return 0;
}

export fn setDriverOptionBinTransportTermHeight(
    d_ptr: usize,
    value: u16,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            switch (rd.session.transport.implementation) {
                .bin => |i| {
                    i.options.term_height = value;
                },
                else => {
                    return 1;
                },
            }
        },
        .netconf => |rd| {
            switch (rd.session.transport.implementation) {
                .bin => |i| {
                    i.options.term_height = value;
                },
                else => {
                    return 1;
                },
            }
        },
    }

    return 0;
}

export fn setDriverOptionBinTransportTermWidth(
    d_ptr: usize,
    value: u16,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            switch (rd.session.transport.implementation) {
                .bin => |i| {
                    i.options.term_width = value;
                },
                else => {
                    return 1;
                },
            }
        },
        .netconf => |rd| {
            switch (rd.session.transport.implementation) {
                .bin => |i| {
                    i.options.term_width = value;
                },
                else => {
                    return 1;
                },
            }
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
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            switch (rd.session.transport.implementation) {
                .ssh2 => |i| {
                    i.options.libssh2_trace = true;
                },
                else => {
                    return 1;
                },
            }
        },
        .netconf => |rd| {
            switch (rd.session.transport.implementation) {
                .ssh2 => |i| {
                    i.options.libssh2_trace = true;
                },
                else => {
                    return 1;
                },
            }
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
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => |rd| {
            switch (rd.session.transport.implementation) {
                .test_ => |i| {
                    i.options.f = rd.options.transport.test_.allocator.dupe(
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
        },
        .netconf => |rd| {
            switch (rd.session.transport.implementation) {
                .test_ => |i| {
                    i.options.f = rd.options.transport.test_.allocator.dupe(
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
        },
    }

    return 0;
}
