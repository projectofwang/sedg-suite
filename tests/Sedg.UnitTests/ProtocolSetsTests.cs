using Sedg.Protocol;
using Sedg.UnitTests;

/// <summary>The closed action and error vocabularies; each member list is exact.</summary>
public static class ProtocolSetsTests
{
    private static readonly string[] ExpectedActions =
    {
        "Status",
        "Install",
        "Update",
        "Pause",
        "Resume",
        "Restart",
        "Uninstall",
        "Purge",
        "SetUpstream",
        "SetDns",
        "RestoreEngine",
        "SetLanguage",
        "TestCdnOptimization",
    };

    private static readonly string[] ExpectedErrorCodes =
    {
        "None",
        "EngineSpawn",
        "Protocol",
        "Timeout",
        "BrokerDenied",
        "BrokerNonce",
        "BrokerSchema",
        "MutexBusy",
        "VersionMismatch",
        "UnsupportedOs",
        "Offline",
        "ManifestUnapproved",
        "HashMismatch",
        "InsufficientDisk",
        "UacDenied",
        "Network",
        "SourceUnreachable",
        "NoNetwork",
        "EngineGeneric",
        "Validation",
        "Preflight",
        "Cancelled",
        "NotInstalled",
        "Config",
    };

    [Test]
    public static void ProtocolActionMembersAreClosed()
        => Assert.Equal(ExpectedActions, Enum.GetNames<ProtocolAction>());

    [Test]
    public static void ErrorCodeMembersAreClosed()
        => Assert.Equal(ExpectedErrorCodes, Enum.GetNames<ErrorCode>());
}
