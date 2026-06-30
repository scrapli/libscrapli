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
    last_error: []const u8 = "",
};

/// OperationOptions is a struct holding tagged unions which in turn hold available options for all
/// cli or netconf operations.
pub const OperationOptions = struct {
    id: u32,
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
