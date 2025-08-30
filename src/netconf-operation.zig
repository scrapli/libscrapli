pub const default_rpc_error_tag = "rpc-error>";

pub const Version = enum {
    version_1_0,
    version_1_1,
};

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

    // rfc 7950 rpcs
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

// for example with edit-config, see rfc4741
pub const DefaultOperation = enum {
    merge,
    replace,
    none,

    pub fn toString(self: DefaultOperation) []const u8 {
        switch (self) {
            .merge => {
                return "merge";
            },
            .replace => {
                return "replace";
            },
            .none => {
                return "none";
            },
        }
    }
};

// also see rfc4741
pub const TestOption = enum {
    test_then_set,
    set,

    pub fn toString(self: TestOption) []const u8 {
        switch (self) {
            .test_then_set => {
                return "test-then-set";
            },
            .set => {
                return "set";
            },
        }
    }
};

// and... also see rfc4741
pub const ErrorOption = enum {
    stop_on_error,
    continue_on_error,
    rollback_on_error,

    pub fn toString(self: ErrorOption) []const u8 {
        switch (self) {
            .stop_on_error => {
                return "stop-on-error";
            },
            .continue_on_error => {
                return "continue-on-error";
            },
            .rollback_on_error => {
                return "rollback-on-error";
            },
        }
    }
};

pub const OpenOptions = struct {
    cancel: ?*bool = null,
};

pub const CloseOptions = struct {
    cancel: ?*bool = null,
    // force does *not* send a close-session rpc, just stops the process thread and closes the
    // session and returns an empty result.
    force: bool = false,
};

pub const RawRpcOptions = struct {
    cancel: ?*bool = null,
    // the inner payload, we wrap this with the outer rpc tag w/ appropriate message id
    payload: []const u8,
    // prefix the base namespace with this prefix if set -- useful when/if a device expects the
    // non-prefixed namespace to be something device specific, see next field as well.
    base_namespace_prefix: ?[]const u8 = null,
    // list of prefix:namespace pairs being prefix/namespace, for things like nxos that
    // wants to be annoying: https://github.com/scrapli/scrapligo/issues/67
    extra_namespaces: ?[]const [2][]const u8 = null,
    // a string delimited by "::" for prefix::namespace, and __libscrapli__ for additional
    // namespaces... done in order to make passing in multiple namespaces via the ffi
    // easier without having allocations/arraylists
    _extra_namespaces_ffi: ?[]const u8 = null,
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
    default_operation: ?DefaultOperation = null,
    test_option: ?TestOption = null,
    error_option: ?ErrorOption = null,
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
    persist_id: ?[]const u8 = null,
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
    config_filter: ?bool = null,
    origin_filters: ?[]const u8 = null,
    max_depth: ?u32 = null,
    with_origin: ?bool = null,
    defaults_type: ?DefaultsType = null,
};

pub const EditDataOptions = struct {
    cancel: ?*bool = null,
    datastore: DatastoreType = DatastoreType.running,
    edit_content: []const u8,
    default_operation: ?DefaultOperation = null,
};

pub const ActionOptions = struct {
    cancel: ?*bool = null,
    action: []const u8,
};
