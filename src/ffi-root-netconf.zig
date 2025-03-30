const std = @import("std");

const ffi_driver = @import("ffi-driver.zig");
const ffi_operations = @import("ffi-operations.zig");
const ffi_args_to_options = @import("ffi-args-to-options-netconf.zig");

const logging = @import("logging.zig");
const ascii = @import("ascii.zig");

// for forcing inclusion in the ffi-root.zig entrypoint we use for the ffi layer
pub const noop = true;

export fn netconfPollOperation(
    d_ptr: usize,
    operation_id: u32,
    operation_done: *bool,
    operation_input_size: *u64,
    operation_result_raw_size: *u64,
    operation_result_size: *u64,
    operation_rpc_warnings_size: *u64,
    operation_rpc_errors_size: *u64,
    operation_error_size: *u64,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const ret = d.pollOperation(
        operation_id,
        false,
    ) catch |err| {
        d.log(
            logging.LogLevel.critical,
            "error during poll operation {any}",
            .{err},
        );

        return 1;
    };

    if (!ret.done) {
        operation_done.* = false;

        return 0;
    }

    operation_done.* = true;

    if (ret.err != null) {
        const err_name = @errorName(ret.err.?);

        operation_result_size.* = 0;
        operation_error_size.* = err_name.len;
    } else {
        const dret = switch (ret.result) {
            .netconf => |r| r.?,
            else => @panic("attempting to access non netconf result from netconf type"),
        };

        if (dret.input) |i| {
            operation_input_size.* = i.len;
        }

        operation_result_raw_size.* = dret.result_raw.len;
        operation_result_size.* = dret.result.len;

        if (dret.result_failure_indicated) {
            operation_rpc_warnings_size.* = dret.getWarningsLen();
            operation_rpc_errors_size.* = dret.getErrorsLen();
        }
    }

    return 0;
}

// TODO ofc, only needed for python sync (not go, not py async), so lower prio
export fn netconfWaitOperation(
    d_ptr: usize,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    _ = d;

    return 0;
}

export fn netconfFetchOperation(
    d_ptr: usize,
    operation_id: u32,
    operation_start_time: *u64,
    operation_end_time: *u64,
    operation_input: *[]u8,
    operation_result_raw: *[]u8,
    operation_result: *[]u8,
    operation_rpc_warnings: *[]u8,
    operation_rpc_errors: *[]u8,
    operation_error: *[]u8,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const ret = d.pollOperation(
        operation_id,
        true,
    ) catch |err| {
        d.log(
            logging.LogLevel.critical,
            "error during fetch operation {any}",
            .{err},
        );

        return 1;
    };

    defer {
        const dret = switch (ret.result) {
            .netconf => |r| r,
            else => @panic("attempting to access non netconf result from netconf type"),
        };
        if (dret != null) {
            dret.?.deinit();
        }
    }

    if (ret.err != null) {
        const err_name = @errorName(ret.err.?);

        @memcpy(operation_error.*.ptr, err_name);
    } else {
        const dret = switch (ret.result) {
            .netconf => |r| r.?,
            else => @panic("attempting to access non netconf result from netconf type"),
        };

        if (dret.splits_ns.items.len > 0) {
            operation_start_time.* = @intCast(dret.start_time_ns);
            operation_end_time.* = @intCast(dret.splits_ns.items[dret.splits_ns.items.len - 1]);
        } else {
            // was a noop -- like enterMode but where mode didn't change
            operation_start_time.* = @intCast(dret.start_time_ns);
            operation_end_time.* = @intCast(dret.start_time_ns);
        }

        if (dret.input) |i| {
            @memcpy(operation_input.*[0..i.len], i);
        }

        @memcpy(operation_result_raw.*, dret.result_raw);
        @memcpy(operation_result.*, dret.result);

        // to avoid a pointless allocation since we are already copying from the result into the
        // given string pointers, we'll do basically the same thing the result does in normal (zig)
        // operations in getResult/getResultRaw by iterating over the underlying array list and
        // copying from there, inserting newlines between results, into the given pointer(s)
        var cur: usize = 0;
        for (0.., dret.result_warning_messages.items) |idx, warning| {
            @memcpy(operation_rpc_warnings.*[cur .. cur + warning.len], warning);
            cur += warning.len;

            if (idx != dret.result_warning_messages.items.len - 1) {
                operation_rpc_warnings.*[cur] = ascii.control_chars.lf;
                cur += 1;
            }
        }

        cur = 0;

        for (0.., dret.result_error_messages.items) |idx, err| {
            @memcpy(operation_rpc_errors.*[cur .. cur + err.len], err);
            cur += err.len;

            if (idx != dret.result_error_messages.items.len - 1) {
                operation_rpc_errors.*[cur] = ascii.control_chars.lf;
                cur += 1;
            }
        }
    }

    return 0;
}

export fn netconfRaw(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
    payload: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{
                    .raw = .{
                        .cancel = cancel,
                        .payload = std.mem.span(payload),
                    },
                },
            },
        },
    ) catch |err| {
        d.log(
            logging.LogLevel.critical,
            "error during queue raw {any}",
            .{err},
        );

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn netconfGetConfig(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
    source: [*c]const u8,
    filter: [*c]const u8,
    filter_type: [*c]const u8,
    filter_namespace_prefix: [*c]const u8,
    filter_namespace: [*c]const u8,
    defaults_type: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const options = ffi_args_to_options.GetConfigOptionsFromArgs(
        cancel,
        source,
        filter,
        filter_type,
        filter_namespace_prefix,
        filter_namespace,
        defaults_type,
    );

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{
                    .get_config = options,
                },
            },
        },
    ) catch |err| {
        d.log(
            logging.LogLevel.critical,
            "error during queue getConfig {any}",
            .{err},
        );

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn netconfEditConfig(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
    config: [*c]const u8,
    target: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const options = ffi_args_to_options.EditConfigOptionsFromArgs(
        cancel,
        config,
        target,
    );

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{
                    .edit_config = options,
                },
            },
        },
    ) catch |err| {
        d.log(
            logging.LogLevel.critical,
            "error during queue editConfig {any}",
            .{err},
        );

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn netconfCopyConfig(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
    target: [*c]const u8,
    source: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const options = ffi_args_to_options.CopyConfigOptionsFromArgs(
        cancel,
        source,
        target,
    );

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{
                    .copy_config = options,
                },
            },
        },
    ) catch |err| {
        d.log(
            logging.LogLevel.critical,
            "error during queue copyConfig {any}",
            .{err},
        );

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn netconfDeleteConfig(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
    target: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const options = ffi_args_to_options.DeleteConfigOptionsFromArgs(
        cancel,
        target,
    );

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{
                    .delete_config = options,
                },
            },
        },
    ) catch |err| {
        d.log(
            logging.LogLevel.critical,
            "error during queue deleteConfig {any}",
            .{err},
        );

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn netconfLock(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
    target: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const options = ffi_args_to_options.LockUnlockOptionsFromArgs(
        cancel,
        target,
    );

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{
                    .lock = options,
                },
            },
        },
    ) catch |err| {
        d.log(
            logging.LogLevel.critical,
            "error during queue lock {any}",
            .{err},
        );

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn netconfUnlock(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
    target: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const options = ffi_args_to_options.LockUnlockOptionsFromArgs(
        cancel,
        target,
    );

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{
                    .unlock = options,
                },
            },
        },
    ) catch |err| {
        d.log(
            logging.LogLevel.critical,
            "error during queue unlock {any}",
            .{err},
        );

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn netconfGet(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
    filter: [*c]const u8,
    filter_type: [*c]const u8,
    filter_namespace_prefix: [*c]const u8,
    filter_namespace: [*c]const u8,
    defaults_type: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const options = ffi_args_to_options.GetOptionsFromArgs(
        cancel,
        filter,
        filter_type,
        filter_namespace_prefix,
        filter_namespace,
        defaults_type,
    );

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{
                    .get = options,
                },
            },
        },
    ) catch |err| {
        d.log(
            logging.LogLevel.critical,
            "error during queue unlock {any}",
            .{err},
        );

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn netconfCloseSession(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{
                    .close_session = .{
                        .cancel = cancel,
                    },
                },
            },
        },
    ) catch |err| {
        d.log(
            logging.LogLevel.critical,
            "error during queue unlock {any}",
            .{err},
        );

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn netconfKillSession(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
    session_id: u64,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{
                    .kill_session = .{
                        .cancel = cancel,
                        .session_id = session_id,
                    },
                },
            },
        },
    ) catch |err| {
        d.log(
            logging.LogLevel.critical,
            "error during queue unlock {any}",
            .{err},
        );

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn netconfCommit(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{
                    .commit = .{
                        .cancel = cancel,
                    },
                },
            },
        },
    ) catch |err| {
        d.log(
            logging.LogLevel.critical,
            "error during queue commit {any}",
            .{err},
        );

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn netconfDiscard(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{
                    .discard = .{
                        .cancel = cancel,
                    },
                },
            },
        },
    ) catch |err| {
        d.log(
            logging.LogLevel.critical,
            "error during queue discard {any}",
            .{err},
        );

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn netconfCancelCommit(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{
                    .cancel_commit = .{
                        .cancel = cancel,
                    },
                },
            },
        },
    ) catch |err| {
        d.log(
            logging.LogLevel.critical,
            "error during queue cancelCommit {any}",
            .{err},
        );

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn netconfValidate(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
    source: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{ .validate = ffi_args_to_options.ValidateOptionsFromArgs(
                    cancel,
                    source,
                ) },
            },
        },
    ) catch |err| {
        d.log(
            logging.LogLevel.critical,
            "error during queue validate {any}",
            .{err},
        );

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn netconfGetSchema(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
    identifier: [*c]const u8,
    version: [*c]const u8,
    format: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{
                    .get_schema = ffi_args_to_options.GetSchemaOptionsFromArgs(
                        cancel,
                        identifier,
                        version,
                        format,
                    ),
                },
            },
        },
    ) catch |err| {
        d.log(
            logging.LogLevel.critical,
            "error during queue getSchema {any}",
            .{err},
        );

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

// TODO would be nice to order things nicer (as in the same order as the options see purego issue:
// https://github.com/ebitengine/purego/issues/309
export fn netconfGetData(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
    config_filter: bool,
    max_depth: i32, // TODO is uint so if we pass -1 can be null
    with_origin: bool,
    datastore: [*c]const u8,
    filter: [*c]const u8,
    filter_type: [*c]const u8,
    filter_namespace_prefix: [*c]const u8,
    filter_namespace: [*c]const u8,
    origin_filters: [*c]const u8,
    defaults_type: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{
                    .get_data = ffi_args_to_options.GetDataOptionsFromArgs(
                        cancel,
                        datastore,
                        filter,
                        filter_type,
                        filter_namespace_prefix,
                        filter_namespace,
                        config_filter,
                        origin_filters,
                        max_depth,
                        with_origin,
                        defaults_type,
                    ),
                },
            },
        },
    ) catch |err| {
        d.log(
            logging.LogLevel.critical,
            "error during queue getData {any}",
            .{err},
        );

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn netconfEditData(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
    datastore: [*c]const u8,
    edit_content: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{
                    .edit_data = ffi_args_to_options.EditDataOptionsFromArgs(
                        cancel,
                        datastore,
                        edit_content,
                    ),
                },
            },
        },
    ) catch |err| {
        d.log(
            logging.LogLevel.critical,
            "error during queue editData {any}",
            .{err},
        );

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn netconfAction(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
    action: [*c]const u8,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{
                    .action = .{
                        .cancel = cancel,
                        .action = std.mem.span(action),
                    },
                },
            },
        },
    ) catch |err| {
        d.log(
            logging.LogLevel.critical,
            "error during queue action {any}",
            .{err},
        );

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}
