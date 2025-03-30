// open/close things are aliased to "normal" operation so they are the same, but users can simply
// import all operation things from the netconf operation package when doing netconf bits.
const operation = @import("cli-operation.zig");

pub const Kind = enum {
    // not "standard" netconf operations, but operations for us!
    open,
    close,
    raw_rpc,

    // rfc 4741 rpcs
    get_config,
    edit_config,
    copy_config,
    delete_config,
    lock,
    unlock,
    get,
    close_session,
    kill_session,

    // rfc 6241 rpcs
    commit,
    discard,
    cancel_commit,
    validate,

    // rfc 6022 rpcs
    get_schema,

    // rfc 8525/8526 rpcs
    get_data,
    edit_data,

    // rfc 7950 rps
    action,
};

pub const RpcOptions = union(Kind) {
    open: OpenOptions,
    close: CloseOptions,
    raw_rpc: RawRpcOptions,

    get_config: GetConfigOptions,
    edit_config: EditConfigOptions,
    copy_config: CopyConfigOptions,
    delete_config: DeleteConfigOptions,
    lock: LockUnlockOptions,
    unlock: LockUnlockOptions,
    get: GetOptions,
    close_session: CloseSessionOptions,
    kill_session: KillSessionOptions,

    commit: CommitOptions,
    discard: DiscardOptions,
    cancel_commit: CancelCommitOptions,
    validate: ValidateOptions,

    get_schema: GetSchemaOptions,

    get_data: GetDataOptions,
    edit_data: EditDataOptions,

    action: ActionOptions,

    pub fn getKind(self: RpcOptions) Kind {
        return @as(Kind, self);
    }
};

pub const DatastoreType = enum {
    // https://datatracker.ietf.org/doc/html/rfc8342
    conventional,
    running,
    candidate,
    startup,
    intended,
    dynamic,
    operational,

    pub fn toString(self: DatastoreType) []const u8 {
        switch (self) {
            .conventional => {
                return "conventional";
            },
            .running => {
                return "running";
            },
            .candidate => {
                return "candidate";
            },
            .startup => {
                return "startup";
            },
            .intended => {
                return "intended";
            },
            .dynamic => {
                return "dynamic";
            },
            .operational => {
                return "operational";
            },
        }
    }
};

pub const FilterType = enum {
    subtree,
    xpath,

    pub fn toString(self: FilterType) []const u8 {
        switch (self) {
            .subtree => {
                return "subtree";
            },
            .xpath => {
                return "xpath";
            },
        }
    }
};

/// with-defaults supported on get, get-config, copy-config operations. see rfc-6243.
pub const DefaultsType = enum {
    report_all,
    report_all_tagged,
    trim,
    explicit,

    pub fn toString(self: DefaultsType) []const u8 {
        switch (self) {
            .report_all => {
                return "report-all";
            },
            .report_all_tagged => {
                return "report-all-tagged";
            },
            .trim => {
                return "trim";
            },
            .explicit => {
                return "explicit";
            },
        }
    }
};

pub const SchemaFormat = enum {
    // https://datatracker.ietf.org/doc/html/rfc6022#section-2.1.3
    xsd,
    yang,
    yin,
    rng,
    rnc,

    pub fn toString(self: SchemaFormat) []const u8 {
        switch (self) {
            .xsd => {
                return "xsd";
            },
            .yang => {
                return "yang";
            },
            .yin => {
                return "yin";
            },
            .rng => {
                return "rng";
            },
            .rnc => {
                return "rnc";
            },
        }
    }
};

pub const OpenOptions = operation.OpenOptions;

pub const CloseOptions = operation.CloseOptions;

pub const RawRpcOptions = struct {
    cancel: ?*bool = null,
    payload: []const u8,
    // TODO should support user providing a fully formed rpc *or* just the "inside" of the rpc tag
    //   in the former they need to give us the message id, in the latter we wrap what they gave
};

pub const GetConfigOptions = struct {
    cancel: ?*bool = null,
    source: DatastoreType = DatastoreType.running,
    filter: ?[]const u8 = null,
    filter_type: FilterType = FilterType.subtree,
    filter_namespace_prefix: ?[]const u8 = null,
    filter_namespace: ?[]const u8 = null,
    defaults_type: ?DefaultsType = null,
};

pub const EditConfigOptions = struct {
    cancel: ?*bool = null,
    config: []const u8,
    target: DatastoreType = DatastoreType.running,
    // TODO: https://www.rfc-editor.org/rfc/rfc4741.html#section-7.2
    // defaults_operation: null,
    // test_option: null,
    // error_option: null,
};

pub const CopyConfigOptions = struct {
    cancel: ?*bool = null,
    target: DatastoreType = DatastoreType.startup,
    source: DatastoreType = DatastoreType.running,
};

pub const DeleteConfigOptions = struct {
    cancel: ?*bool = null,
    target: DatastoreType = DatastoreType.running,
};

pub const LockUnlockOptions = struct {
    cancel: ?*bool = null,
    target: DatastoreType = DatastoreType.running,
};

pub const GetOptions = struct {
    cancel: ?*bool = null,
    filter: ?[]const u8 = null,
    filter_type: FilterType = FilterType.subtree,
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
    source: DatastoreType = DatastoreType.running,
};

pub const GetSchemaOptions = struct {
    cancel: ?*bool = null,
    identifier: []const u8,
    version: ?[]const u8 = null,
    format: SchemaFormat = SchemaFormat.yang,
};

pub const GetDataOptions = struct {
    // https://datatracker.ietf.org/doc/rfc8526/ section 3.1.1
    cancel: ?*bool = null,
    datastore: DatastoreType = DatastoreType.running,
    filter: ?[]const u8 = null,
    filter_type: FilterType = FilterType.subtree,
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
    cancel: ?*bool = null,
    datastore: DatastoreType = DatastoreType.running,
    // TODO -- same as edit-config rpc -> defaults_operation: null,
    edit_content: []const u8,
};

pub const ActionOptions = struct {
    cancel: ?*bool = null,
    action: []const u8,
};
