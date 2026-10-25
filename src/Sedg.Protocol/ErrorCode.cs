namespace Sedg.Protocol;

/// <summary>Closed error vocabulary; every member maps to a localized title.</summary>
public enum ErrorCode
{
    None = 0,
    EngineSpawn,
    Protocol,
    Timeout,
    BrokerDenied,
    BrokerNonce,
    BrokerSchema,
    MutexBusy,
    VersionMismatch,
    UnsupportedOs,
    Offline,
    ManifestUnapproved,
    HashMismatch,
    InsufficientDisk,
    UacDenied,
    Network,
    SourceUnreachable,
    NoNetwork,
    EngineGeneric,
    Validation,
    Preflight,
    Cancelled,
    NotInstalled,
    Config,
}
