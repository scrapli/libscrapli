// open/close things are aliased to "normal" operation so they are the same, but users can simply
// import all operation things from the netconf operation package when doing netconf bits.
const operation = @import("operation.zig");

// TODO omg so many enums to lower case
pub const Kind = enum {
    // not "standard" netconf operations, but operations for us!
    Open,
    Close,

    // rfc 4741 rpcs
    GetConfig,
    EditConfig,
    CopyConfig,
    DeleteConfig,
    Lock,
    Unlock,
    Get,
    CloseSession,
    KillSession,

    // rfc 6241 rpcs
    Commit,
    Discard,
    CancelCommit,
    Validate,

    // rfc 5277 rpcs
    CreateSubscription,

    // rfc 8640/8641
    EstablishSubscription,
    ModifySubscription,
    DeleteSubscription,
    ResyncSubscription,
    KillSubscription,

    // rfc 6022 rpcs
    GetSchema,

    // rfc 8525/8526 rpcs
    GetData,
    EditData,

    // rfc 7950 rps
    Action,
};

pub const RpcOptions = union(Kind) {
    Open: OpenOptions,
    Close: CloseOptions,

    GetConfig: GetConfigOptions,
    EditConfig: EditConfigOptions,
    CopyConfig: CopyConfigOptions,
    DeleteConfig: DeleteConfigOptions,
    Lock: LockUnlockOptions,
    Unlock: LockUnlockOptions,
    Get: GetOptions,
    CloseSession: CloseSessionOptions,
    KillSession: KillSessionOptions,

    Commit: CommitOptions,
    Discard: DiscardOptions,
    CancelCommit: CancelCommitOptions,
    Validate: ValidateOptions,

    CreateSubscription: CreateSubscriptionOptions,

    EstablishSubscription: EstablishSubscriptionOptions,
    ModifySubscription: ModifySubscriptionOptions,
    DeleteSubscription: DeleteSubscriptionOptions,
    ResyncSubscription: ResyncSubscriptionOptions,
    KillSubscription: KillSubscriptionOptions,

    GetSchema: GetSchemaOptions,

    GetData: GetDataOptions,
    EditData: EditDataOptions,

    Action: ActionOptions,

    pub fn getKind(self: RpcOptions) Kind {
        return @as(Kind, self);
    }
};

pub const DatastoreType = enum {
    // https://datatracker.ietf.org/doc/html/rfc8342
    Conventional,
    Running,
    Candidate,
    Startup,
    Intended,
    Dynamic,
    Operational,

    pub fn toString(self: DatastoreType) []const u8 {
        switch (self) {
            .Conventional => {
                return "conventional";
            },
            .Running => {
                return "running";
            },
            .Candidate => {
                return "candidate";
            },
            .Startup => {
                return "startup";
            },
            .Intended => {
                return "intended";
            },
            .Dynamic => {
                return "dynamic";
            },
            .Operational => {
                return "operational";
            },
        }
    }
};

pub const FilterType = enum {
    Subtree,
    Xpath,

    pub fn toString(self: FilterType) []const u8 {
        switch (self) {
            .Subtree => {
                return "subtree";
            },
            .Xpath => {
                return "xpath";
            },
        }
    }
};

/// with-defaults supported on get, get-config, copy-config operations. see rfc-6243.
pub const DefaultsType = enum {
    ReportAll,
    ReportAllTagged,
    Trim,
    Explicit,

    pub fn toString(self: DefaultsType) []const u8 {
        switch (self) {
            .ReportAll => {
                return "report-all";
            },
            .ReportAllTagged => {
                return "report-all-tagged";
            },
            .Trim => {
                return "trim";
            },
            .Explicit => {
                return "explicit";
            },
        }
    }
};

pub const SchemaFormat = enum {
    // https://datatracker.ietf.org/doc/html/rfc6022#section-2.1.3
    Xsd,
    Yang,
    Yin,
    Rng,
    Rnc,

    pub fn toString(self: SchemaFormat) []const u8 {
        switch (self) {
            .Xsd => {
                return "xsd";
            },
            .Yang => {
                return "yang";
            },
            .Yin => {
                return "yin";
            },
            .Rng => {
                return "rng";
            },
            .Rnc => {
                return "rnc";
            },
        }
    }
};

pub const OpenOptions = operation.OpenOptions;

pub const CloseOptions = operation.CloseOptions;

pub const GetConfigOptions = struct {
    cancel: ?*bool = null,
    source: DatastoreType = DatastoreType.Running,
    filter: ?[]const u8 = null,
    filter_type: FilterType = FilterType.Subtree,
    filter_namespace_prefix: ?[]const u8 = null,
    filter_namespace: ?[]const u8 = null,
    defaults_type: ?DefaultsType = null,
};

pub const EditConfigOptions = struct {
    cancel: ?*bool = null,
    config: []const u8,
    target: DatastoreType = DatastoreType.Running,
    // TODO: https://www.rfc-editor.org/rfc/rfc4741.html#section-7.2
    // defaults_operation: null,
    // test_option: null,
    // error_option: null,
};

pub const CopyConfigOptions = struct {
    cancel: ?*bool = null,
    target: DatastoreType = DatastoreType.Startup,
    source: DatastoreType = DatastoreType.Running,
};

pub const DeleteConfigOptions = struct {
    cancel: ?*bool = null,
    target: DatastoreType = DatastoreType.Running,
};

pub const LockUnlockOptions = struct {
    cancel: ?*bool = null,
    target: DatastoreType = DatastoreType.Running,
};

pub const GetOptions = struct {
    cancel: ?*bool = null,
    filter: ?[]const u8 = null,
    filter_type: FilterType = FilterType.Subtree,
    filter_namespace_prefix: ?[]const u8 = null,
    filter_namespace: ?[]const u8 = null,
    defaults_type: ?DefaultsType = null,
};

pub const CloseSessionOptions = struct {
    cancel: ?*bool = null,
};

pub const KillSessionOptions = struct {
    cancel: ?*bool = null,
    session_id: u64,
};

pub const CommitOptions = struct {
    cancel: ?*bool = null,
};

pub const DiscardOptions = struct {
    cancel: ?*bool = null,
};

pub const CancelCommitOptions = struct {
    cancel: ?*bool = null,
    // TODO add persist-id param -> https://datatracker.ietf.org/doc/html/rfc6241#section-8.4.4.1
};

pub const ValidateOptions = struct {
    cancel: ?*bool = null,
    source: DatastoreType = DatastoreType.Running,
};

pub const CreateSubscriptionOptions = struct {
    cancel: ?*bool = null,
    stream: ?[]const u8,
    filter: ?[]const u8,
    filter_type: FilterType,
    filter_namespace_prefix: ?[]const u8,
    filter_namespace: ?[]const u8,
    start_time: ?u64,
    stop_time: ?u64,
};

pub const EstablishSubscriptionOptions = struct {
    cancel: ?*bool = null,
    stream: []const u8,
    filter: ?[]const u8,
    filter_type: FilterType = FilterType.Subtree,
    filter_namespace_prefix: ?[]const u8 = null,
    filter_namespace: ?[]const u8 = null,
    period: ?u64,
    stop_time: ?u64,
    dscp: ?u8,
    weighting: ?u8,
    dependency: ?u32,
    encoding: ?[]const u8 = null,
};

pub const ModifySubscriptionOptions = struct {
    cancel: ?*bool = null,
    id: u64,
    stream: []const u8,
    filter: ?[]const u8,
    filter_type: FilterType,
    filter_namespace_prefix: ?[]const u8,
    filter_namespace: ?[]const u8,
    period: ?u64,
    stop_time: ?u64,
    dscp: ?u8,
    weighting: ?u8,
    dependency: ?u32,
    encoding: ?[]const u8,
};

pub const DeleteSubscriptionOptions = struct {
    cancel: ?*bool = null,
    id: u64,
};

pub const ResyncSubscriptionOptions = struct {
    cancel: ?*bool = null,
    id: u64,
};

pub const KillSubscriptionOptions = struct {
    cancel: ?*bool = null,
    id: u64,
};

pub const GetSchemaOptions = struct {
    cancel: ?*bool = null,
    identifier: []const u8,
    version: ?[]const u8 = null,
    format: SchemaFormat = SchemaFormat.Yang,
};

pub const GetDataOptions = struct {
    // https://datatracker.ietf.org/doc/rfc8526/ section 3.1.1
    cancel: ?*bool = null,
    datastore: DatastoreType = DatastoreType.Running,
    filter: ?[]const u8 = null,
    filter_type: FilterType = FilterType.Subtree,
    filter_namespace_prefix: ?[]const u8 = null,
    filter_namespace: ?[]const u8 = null,
    config_filter: bool = true,
    // TODO check if this should/could be typed or if it makes more sense to leave as a str
    origin_filters: ?[]const u8 = null,
    max_depth: ?u32 = null,
    with_origin: ?bool = null,
    defaults_type: ?DefaultsType = null,
};

pub const EditDataOptions = struct {
    cancel: ?*bool,
    datastore: DatastoreType = DatastoreType.Running,
    // TODO -- same as edit-config rpc -> defaults_operation: null,
    edit_content: []const u8,
};

pub const ActionOptions = struct {
    cancel: ?*bool,
    action: []const u8,
};

pub fn NewGetConfigOptions() GetConfigOptions {
    return GetConfigOptions{
        .cancel = null,
        .source = DatastoreType.Running,
        .filter = null,
        .filter_type = FilterType.Subtree,
        .filter_namespace_prefix = null,
        .filter_namespace = null,
        .defaults_type = null,
    };
}

pub fn NewEditConfigOptions() EditConfigOptions {
    return EditConfigOptions{
        .cancel = null,
        .config = "",
        .target = DatastoreType.Running,
    };
}

pub fn NewCopyConfigOptions() CopyConfigOptions {
    return CopyConfigOptions{
        .cancel = null,
        .source = DatastoreType.Running,
        .target = DatastoreType.Startup,
    };
}

pub fn NewDeleteConfigOptions() DeleteConfigOptions {
    return DeleteConfigOptions{
        .cancel = null,
        .target = DatastoreType.Running,
    };
}

pub fn NewGetOptions() GetOptions {
    return GetOptions{
        .cancel = null,
        .filter = null,
        .filter_type = FilterType.Subtree,
        .filter_namespace_prefix = null,
        .filter_namespace = null,
        .defaults_type = null,
    };
}

pub fn NewLockUnlockOptions() LockUnlockOptions {
    return LockUnlockOptions{
        .cancel = null,
        .target = DatastoreType.Running,
    };
}

pub fn NewCloseSessionOptions() CloseSessionOptions {
    return CloseSessionOptions{
        .cancel = null,
    };
}

pub fn NewKillSessionOptions() KillSessionOptions {
    return KillSessionOptions{
        .cancel = null,
        .session_id = 0,
    };
}

pub fn NewCommitOptions() CommitOptions {
    return CommitOptions{
        .cancel = null,
    };
}

pub fn NewDiscardOptions() DiscardOptions {
    return DiscardOptions{
        .cancel = null,
    };
}

pub fn NewCancelCommitOptions() CancelCommitOptions {
    return CancelCommitOptions{
        .cancel = null,
    };
}

pub fn NewValidateOptions() ValidateOptions {
    return ValidateOptions{
        .cancel = null,
        .source = DatastoreType.Running,
    };
}

pub fn NewCreateSubscriptionOptions() CreateSubscriptionOptions {
    return CreateSubscriptionOptions{
        .cancel = null,
        .stream = null,
        .filter = null,
        .filter_type = FilterType.Subtree,
        .filter_namespace_prefix = null,
        .filter_namespace = null,
        .start_time = null,
        .stop_time = null,
    };
}

pub fn NewEstablishSubscriptionOptions() EstablishSubscriptionOptions {
    return EstablishSubscriptionOptions{
        .cancel = null,
        .stream = "",
        .filter = null,
        .filter_type = FilterType.Subtree,
        .filter_namespace_prefix = null,
        .filter_namespace = null,
        .period = null,
        .stop_time = null,
        .dscp = null,
        .weighting = null,
        .dependency = null,
        .encoding = null,
    };
}

pub fn NewModifySubscriptionOptions() ModifySubscriptionOptions {
    return ModifySubscriptionOptions{
        .cancel = null,
        .id = 0,
        .stream = "",
        .filter = null,
        .filter_type = FilterType.Subtree,
        .filter_namespace_prefix = null,
        .filter_namespace = null,
        .period = null,
        .stop_time = null,
        .dscp = null,
        .weighting = null,
        .dependency = null,
        .encoding = null,
    };
}

pub fn NewDeleteSubscriptionOptions() DeleteSubscriptionOptions {
    return DeleteSubscriptionOptions{
        .cancel = null,
        .id = 0,
    };
}

pub fn NewResyncSubscriptionOptions() ResyncSubscriptionOptions {
    return ResyncSubscriptionOptions{
        .cancel = null,
        .id = 0,
    };
}

pub fn NewKillSubscriptionOptions() KillSubscriptionOptions {
    return KillSubscriptionOptions{
        .cancel = null,
        .id = 0,
    };
}

pub fn NewGetSchemaOptions() GetSchemaOptions {
    return GetSchemaOptions{
        .cancel = null,
        .identifier = "",
        .version = null,
        .format = SchemaFormat.Yang,
    };
}

pub fn NewGetDataOptions() GetDataOptions {
    return GetDataOptions{
        .cancel = null,
        .datastore = DatastoreType.Running,
        .filter = null,
        .filter_type = FilterType.Subtree,
        .filter_namespace_prefix = null,
        .filter_namespace = null,
        .config_filter = true,
        .origin_filters = null,
        .max_depth = null,
        .with_origin = null,
        .defaults_type = null,
    };
}

pub fn NewEditDataOptions() EditDataOptions {
    return EditDataOptions{
        .cancel = null,
        .datastore = DatastoreType.Running,
        // TODO everything that has required args like this should be params of the New funcs
        //   just getting things in place for now though :)
        .edit_content = "",
    };
}

pub fn NewActionOptions() ActionOptions {
    return ActionOptions{
        .cancel = null,
        .action = "",
    };
}
