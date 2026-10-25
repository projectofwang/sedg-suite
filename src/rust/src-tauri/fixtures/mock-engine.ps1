# Deterministic stand-in for the engine's -Protocol jsonl mode.
# Pure ASCII: the engine family is read on code pages that mangle anything else.
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$out = New-Object System.IO.StreamWriter([Console]::OpenStandardOutput(), $utf8)
$out.AutoFlush = $true
$err = New-Object System.IO.StreamWriter([Console]::OpenStandardError(), $utf8)
$err.AutoFlush = $true

$null = [Console]::In.ReadLine()

$out.WriteLine('{"type":"hello","protocolVersion":1,"pid":4242,"engineVersion":"mock-1.0"}')
for ($i = 0; $i -lt 2000; $i++) {
    $err.WriteLine('diag line ' + $i + ' ' + ('x' * 40))
}
$out.WriteLine('{"type":"event","seq":1,"tsUtc":"2026-01-01T00:00:00Z","phase":"status","message":"working"}')
$out.WriteLine('{"type":"progress","seq":2,"tsUtc":"2026-01-01T00:00:01Z","phase":"status","bytesTransferred":10,"bytesTotal":100}')
$out.WriteLine('{"type":"result","ok":true,"code":"None","message":"status ok","currentState":"installed","restoredState":"unchanged","nextStep":"none","data":{"observedUtc":"2026-01-01T00:00:00Z","phases":[]}}')
$out.Flush()
$err.Flush()
