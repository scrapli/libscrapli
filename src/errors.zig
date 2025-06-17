pub const ScrapliError = error{
    // TODO really gotta do better than this... can these have context so i can return it? then
    // we can have fewer errors because this is unhinged
    UnsupportedTransport,
    OpenFailed,
    NotOpened,
    TimeoutExceeded,
    CapabilitiesError,
    Cancelled,
    WriteFailed,
    ReadFailed,
    AuthenticationFailed,
    RegexError,
    UnknownMode,
    UnsupportedOperation,
    ParsingError,
    LookupFailed,
    PtyError,
    SetNonBlockingFailed,
    BadOperationId,
    EOF,
    CallbackFailed,
};
