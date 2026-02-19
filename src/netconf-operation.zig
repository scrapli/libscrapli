/// A const used for matching rpc-error tags.
pub const default_rpc_error_tag = "rpc-error>";

/// Version is an enum of the netconf versions.
pub const Version = enum {
    version_1_0,
    version_1_1,
};

/// Kind is an enum holding all the libscrapli operation kinds.
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

/// RpcOptions is a union of possible rpcs and their options.
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

    /// Returns the "kind" from the tagged union.
    pub fn getKind(self: RpcOptions) Kind {
        return @as(Kind, self);
    }
};

/// DatastoreType is an enum representing possible datastore targets/destinations for rpcs.
pub const DatastoreType = enum {
    // https://datatracker.ietf.org/doc/html/rfc8342
    conventional,
    running,
    candidate,
    startup,
    intended,
    dynamic,
    operational,
};

/// FilterType is an enum representing possible filter types for rpcs.
pub const FilterType = enum {
    subtree,
    xpath,
};

/// DefaultsType is an enum representing possible defaults types for rcp operations.
/// with-defaults supported on get, get-config, copy-config operations. see rfc-6243.
pub const DefaultsType = enum {
    report_all,
    report_all_tagged,
    trim,
    explicit,

    /// Returns the value of the enum as a string, cant use tagName because of hyphens.
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

/// SchemaFormat is an enum representing possible schema formats.
pub const SchemaFormat = enum {
    // https://datatracker.ietf.org/doc/html/rfc6022#section-2.1.3
    xsd,
    yang,
    yin,
    rng,
    rnc,
};

/// DefaultOperation is an enum representing defaul operation settings to pass to rpcs.
/// for example with edit-config, see rfc4741
pub const DefaultOperation = enum {
    merge,
    replace,
    none,
};

/// TestOption is an enum representing test options to pass to rpcs.
/// also see rfc4741
pub const TestOption = enum {
    test_then_set,
    set,

    /// Returns the value of the enum as a string, cant use tagName because of hyphens.
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

/// ErrorOption is an enum representing error options to pass to rpcs.
/// and... also see rfc4741
pub const ErrorOption = enum {
    stop_on_error,
    continue_on_error,
    rollback_on_error,

    /// Returns the value of the enum as a string, cant use tagName because of hyphens.
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

/// OpenOptions holds options for the open operation.
pub const OpenOptions = struct {
    cancel: ?*bool = null,
};

/// CloseOptions holds options for the close operation.
pub const CloseOptions = struct {
    cancel: ?*bool = null,
    // force does *not* send a close-session rpc, just stops the process thread and closes the
    // session and returns an empty result.
    force: bool = false,
};

/// RawRpcOptions holds options for a "raw" rpc -- basically a generic rpc that users can use to
/// send any not natively supported rpc.
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

/// GetConfigOptions holds options for the get-config rpc.
pub const GetConfigOptions = struct {
    cancel: ?*bool = null,
    source: DatastoreType = DatastoreType.running,
    filter: ?[]const u8 = null,
    filter_type: FilterType = FilterType.subtree,
    filter_namespace_prefix: ?[]const u8 = null,
    filter_namespace: ?[]const u8 = null,
    defaults_type: ?DefaultsType = null,
};

/// EditConfigOptions holds options for the edit-config rpc.
pub const EditConfigOptions = struct {
    cancel: ?*bool = null,
    config: []const u8,
    target: DatastoreType = DatastoreType.running,
    default_operation: ?DefaultOperation = null,
    test_option: ?TestOption = null,
    error_option: ?ErrorOption = null,
};

/// CopyConfigOptions holds options for the copy-config rpc.
pub const CopyConfigOptions = struct {
    cancel: ?*bool = null,
    target: DatastoreType = DatastoreType.startup,
    source: DatastoreType = DatastoreType.running,
};

/// DeleteConfigOptions holds options for the delete-config rpc.
pub const DeleteConfigOptions = struct {
    cancel: ?*bool = null,
    target: DatastoreType = DatastoreType.running,
};

/// LockUnlockOptions holds options for the lock or unlock rpc.
pub const LockUnlockOptions = struct {
    cancel: ?*bool = null,
    target: DatastoreType = DatastoreType.running,
};

/// GetOptions holds options for the get-options rpc.
pub const GetOptions = struct {
    cancel: ?*bool = null,
    filter: ?[]const u8 = null,
    filter_type: FilterType = FilterType.subtree,
    filter_namespace_prefix: ?[]const u8 = null,
    filter_namespace: ?[]const u8 = null,
    defaults_type: ?DefaultsType = null,
};

/// CloseSessionOptions holds options for the close-session rpc.
pub const CloseSessionOptions = struct {
    cancel: ?*bool = null,
};

/// KillSessionOptions holds options for the kill-session rpc.
pub const KillSessionOptions = struct {
    cancel: ?*bool = null,
    session_id: u64,
};

/// CommitOptions holds options for the commit rpc.
pub const CommitOptions = struct {
    cancel: ?*bool = null,
};

/// DiscardOptions holds options for the discard rpc.
pub const DiscardOptions = struct {
    cancel: ?*bool = null,
};

/// CancelCommitOptions holds options for the cancel-commit rpc.
pub const CancelCommitOptions = struct {
    cancel: ?*bool = null,
    persist_id: ?[]const u8 = null,
};

/// ValidateOptions holds options for the validate rpc.
pub const ValidateOptions = struct {
    cancel: ?*bool = null,
    source: DatastoreType = DatastoreType.running,
};

/// GetSchemaOptions holds options for the get-schema rpc.
pub const GetSchemaOptions = struct {
    cancel: ?*bool = null,
    identifier: []const u8,
    version: ?[]const u8 = null,
    format: SchemaFormat = SchemaFormat.yang,
};

/// GetDataOptions holds options for the get-data rpc.
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

/// EditDataOptions holds options for the edit-data rpc.
pub const EditDataOptions = struct {
    cancel: ?*bool = null,
    datastore: DatastoreType = DatastoreType.running,
    edit_content: []const u8,
    default_operation: ?DefaultOperation = null,
};

/// ActionOptions holds options for the action rpc.
pub const ActionOptions = struct {
    cancel: ?*bool = null,
    action: []const u8,
};
