const result = @import("result.zig");
const result_netconf = @import("result-netconf.zig");

const operation = @import("operation.zig");
const operation_netconf = @import("operation-netconf.zig");

pub const Result = union(enum) {
    driver: ?*result.Result,
    netconf: ?*result_netconf.Result,
};

pub const OperationResult = struct {
    done: bool,
    result: Result,
    err: ?anyerror,
};

pub const OpenOperation = struct {
    id: u32,
    options: operation.OpenOptions,
};

pub const EnterModeOperation = struct {
    id: u32,
    requested_mode: []const u8,
    options: operation.EnterModeOptions,
};

pub const GetPromptOperation = struct {
    id: u32,
    options: operation.GetPromptOptions,
};

pub const SendInputOperation = struct {
    id: u32,
    input: []const u8,
    options: operation.SendInputOptions,
};

pub const SendPromptedInputOperation = struct {
    id: u32,
    input: []const u8,
    prompt: ?[]const u8,
    prompt_pattern: ?[]const u8,
    response: []const u8,
    options: operation.SendPromptedInputOptions,
};

pub const DriverOperationOptions = union(enum) {
    open: OpenOperation,
    enter_mode: EnterModeOperation,
    get_prompt: GetPromptOperation,
    send_input: SendInputOperation,
    send_prompted_input: SendPromptedInputOperation,
};

pub const NetconfGetConfigOperationOptions = struct {
    id: u32,
    options: operation_netconf.GetConfigOptions,
};

pub const NetconfEditConfigOperationOptions = struct {
    id: u32,
    options: operation_netconf.EditConfigOptions,
};

pub const NetconfCopyConfigOperationOptions = struct {
    id: u32,
    options: operation_netconf.CopyConfigOptions,
};

pub const NetconfDeleteConfigOperationOptions = struct {
    id: u32,
    options: operation_netconf.DeleteConfigOptions,
};

pub const NetconfLockOperationOptions = struct {
    id: u32,
    options: operation_netconf.LockUnlockOptions,
};

pub const NetconfUnlockOperationOptions = struct {
    id: u32,
    options: operation_netconf.LockUnlockOptions,
};

pub const NetconfGetOperationOptions = struct {
    id: u32,
    options: operation_netconf.GetOptions,
};

pub const NetconfCloseSessionOperationOptions = struct {
    id: u32,
    options: operation_netconf.CloseSessionOptions,
};

pub const NetconfKillSessionOperationOptions = struct {
    id: u32,
    options: operation_netconf.KillSessionOptions,
};

pub const NetconfOperationOptions = union(enum) {
    open: OpenOperation,
    get_config: NetconfGetConfigOperationOptions,
    edit_config: NetconfEditConfigOperationOptions,
    copy_config: NetconfCopyConfigOperationOptions,
    delete_config: NetconfDeleteConfigOperationOptions,
    lock: NetconfLockOperationOptions,
    unlock: NetconfLockOperationOptions,
    get: NetconfGetOperationOptions,
    close_session: NetconfCloseSessionOperationOptions,
    kill_session: NetconfKillSessionOperationOptions,
};

pub const OperationOptions = union(enum) {
    driver: DriverOperationOptions,
    netconf: NetconfOperationOptions,
};
