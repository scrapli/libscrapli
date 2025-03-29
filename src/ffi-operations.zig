const result = @import("cli-result.zig");
const result_netconf = @import("netconf-result.zig");

const operation = @import("cli-operation.zig");
const operation_netconf = @import("netconf-operation.zig");

pub const Result = union(enum) {
    cli: ?*result.Result,
    netconf: ?*result_netconf.Result,
};

pub const OperationResult = struct {
    done: bool,
    result: Result,
    err: ?anyerror,
};

pub const OperationOptions = struct {
    id: u32,
    operation: union(enum) {
        cli: union(enum) {
            open: operation.OpenOptions,
            enter_mode: operation.EnterModeOptions,
            get_prompt: operation.GetPromptOptions,
            send_input: operation.SendInputOptions,
            send_prompted_input: operation.SendPromptedInputOptions,
        },
        netconf: union(enum) {
            open: operation.OpenOptions,
            raw: operation_netconf.RawOptions,
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
