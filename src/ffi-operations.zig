const operation = @import("cli-operation.zig");
const operation_netconf = @import("netconf-operation.zig");
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
    operation: union(enum) {
        cli: union(enum) {
            open: operation.OpenOptions,
            close: operation.CloseOptions,
            enter_mode: operation.EnterModeOptions,
            get_prompt: operation.GetPromptOptions,
            send_input: operation.SendInputOptions,
            send_prompted_input: operation.SendPromptedInputOptions,
            read_any: operation.ReadAnyOptions,
        },
        netconf: union(enum) {
            open: operation_netconf.OpenOptions,
            close: operation_netconf.CloseOptions,
            raw_rpc: operation_netconf.RawRpcOptions,
            get_config: operation_netconf.GetConfigOptions,
            edit_config: operation_netconf.EditConfigOptions,
            copy_config: operation_netconf.CopyConfigOptions,
            delete_config: operation_netconf.DeleteConfigOptions,
            lock: operation_netconf.LockUnlockOptions,
            unlock: operation_netconf.LockUnlockOptions,
            get: operation_netconf.GetOptions,
            close_session: operation_netconf.CloseSessionOptions,
            kill_session: operation_netconf.KillSessionOptions,
            commit: operation_netconf.CommitOptions,
            discard: operation_netconf.DiscardOptions,
            cancel_commit: operation_netconf.CancelCommitOptions,
            validate: operation_netconf.ValidateOptions,
            get_schema: operation_netconf.GetSchemaOptions,
            get_data: operation_netconf.GetDataOptions,
            edit_data: operation_netconf.EditDataOptions,
            action: operation_netconf.ActionOptions,
        },
    },
};
