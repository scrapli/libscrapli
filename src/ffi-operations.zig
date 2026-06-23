const std = @import("std");

const netconf_operation = @import("netconf-operation.zig");
const operation = @import("cli-operation.zig");
const result = @import("cli-result.zig");
const result_netconf = @import("netconf-result.zig");

/// Result is a tagged union of cli and netconf result types.
pub const Result = union(enum) {
    cli: ?*result.Result,
    netconf: ?*result_netconf.Result,
};

/// OperationResult is a simple struct holding information about the result of an operation.
pub const OperationResult = struct {
    done: bool,
    result: Result,
    err: ?anyerror,
};

/// OperationOptions is a struct holding tagged unions which in turn hold available options for all
/// cli or netconf operations.
pub const OperationOptions = struct {
    id: u32,
    ffi_owned: bool = false,
    operation: union(enum) {
        cli: union(enum) {
            open: operation.OpenOptions,
            close: operation.CloseOptions,
            enter_mode: operation.EnterModeOptions,
            get_prompt: operation.GetPromptOptions,
            send_input: operation.SendInputOptions,
            send_inputs: operation.SendInputsOptions,
            send_prompted_input: operation.SendPromptedInputOptions,
            read_any: operation.ReadAnyOptions,
        },
        netconf: union(enum) {
            open: netconf_operation.OpenOptions,
            close: netconf_operation.CloseOptions,
            raw_rpc: netconf_operation.RawRpcOptions,
            get_config: netconf_operation.GetConfigOptions,
            edit_config: netconf_operation.EditConfigOptions,
            copy_config: netconf_operation.CopyConfigOptions,
            delete_config: netconf_operation.DeleteConfigOptions,
            lock: netconf_operation.LockUnlockOptions,
            unlock: netconf_operation.LockUnlockOptions,
            get: netconf_operation.GetOptions,
            close_session: netconf_operation.CloseSessionOptions,
            kill_session: netconf_operation.KillSessionOptions,
            commit: netconf_operation.CommitOptions,
            discard: netconf_operation.DiscardOptions,
            cancel_commit: netconf_operation.CancelCommitOptions,
            validate: netconf_operation.ValidateOptions,
            get_schema: netconf_operation.GetSchemaOptions,
            get_data: netconf_operation.GetDataOptions,
            edit_data: netconf_operation.EditDataOptions,
            action: netconf_operation.ActionOptions,
        },
    },
};

pub fn deinitFfiOwnedOperationOptions(
    allocator: std.mem.Allocator,
    options: OperationOptions,
) void {
    if (!options.ffi_owned) {
        return;
    }

    switch (options.operation) {
        .cli => |cli_op| switch (cli_op) {
            .enter_mode => |o| allocator.free(o.requested_mode),
            .send_input => |o| {
                allocator.free(o.input);
                allocator.free(o.requested_mode);
            },
            .send_inputs => |o| {
                if (o._ffi_inputs) |ffi_inputs| {
                    allocator.free(ffi_inputs);
                }
                allocator.free(o.requested_mode);
            },
            .send_prompted_input => |o| {
                allocator.free(o.input);
                if (o.prompt_exact) |prompt_exact| {
                    allocator.free(prompt_exact);
                }
                if (o.prompt_pattern) |prompt_pattern| {
                    allocator.free(prompt_pattern);
                }
                allocator.free(o.response);
                allocator.free(o.requested_mode);
                if (o.abort_input) |abort_input| {
                    allocator.free(abort_input);
                }
            },
            else => {},
        },
        .netconf => |netconf_op| switch (netconf_op) {
            .raw_rpc => |o| {
                allocator.free(o.payload);
                if (o.base_namespace_prefix) |base_namespace_prefix| {
                    allocator.free(base_namespace_prefix);
                }
                if (o._extra_namespaces_ffi) |extra_namespaces| {
                    allocator.free(extra_namespaces);
                }
            },
            .get_config => |o| {
                if (o.filter) |filter| {
                    allocator.free(filter);
                }
                if (o.filter_namespace_prefix) |filter_namespace_prefix| {
                    allocator.free(filter_namespace_prefix);
                }
                if (o.filter_namespace) |filter_namespace| {
                    allocator.free(filter_namespace);
                }
            },
            .edit_config => |o| allocator.free(o.config),
            .get => |o| {
                if (o.filter) |filter| {
                    allocator.free(filter);
                }
                if (o.filter_namespace_prefix) |filter_namespace_prefix| {
                    allocator.free(filter_namespace_prefix);
                }
                if (o.filter_namespace) |filter_namespace| {
                    allocator.free(filter_namespace);
                }
            },
            .cancel_commit => |o| {
                if (o.persist_id) |persist_id| {
                    allocator.free(persist_id);
                }
            },
            .get_schema => |o| {
                allocator.free(o.identifier);
                if (o.version) |version| {
                    allocator.free(version);
                }
            },
            .get_data => |o| {
                if (o.filter) |filter| {
                    allocator.free(filter);
                }
                if (o.filter_namespace_prefix) |filter_namespace_prefix| {
                    allocator.free(filter_namespace_prefix);
                }
                if (o.filter_namespace) |filter_namespace| {
                    allocator.free(filter_namespace);
                }
                if (o.origin_filters) |origin_filters| {
                    allocator.free(origin_filters);
                }
            },
            .edit_data => |o| allocator.free(o.edit_content),
            .action => |o| allocator.free(o.action),
            else => {},
        },
    }
}

/// CliOperationSizes holds operation sizes for an operation, returned from ffi driver to the ffi
/// layer. Doesn't contain error size as that would be processed in a different branch before this
/// would ever be used.
pub const CliOperationSizes = struct {
    operation_count: usize,
    operation_input_size: usize,
    operation_result_raw_size: usize,
    operation_result_size: usize,
    operation_failure_indicator_size: usize,
};
