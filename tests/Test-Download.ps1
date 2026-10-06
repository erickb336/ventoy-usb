#Requires -Version 5.1
# Opt-in network smoke test: downloads/extracts only; never launches Ventoy.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'windows\Install.ps1')
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('ventoy-download-test-' + [guid]::NewGuid().ToString('N'))
$previousTls = [Net.ServicePointManager]::SecurityProtocol
try {
    [Net.ServicePointManager]::SecurityProtocol = $previousTls -bor [Net.SecurityProtocolType]::Tls12
    New-Item -ItemType Directory -Path $temporary | Out-Null
    $exe = Save-VentoyPackage $temporary
    Write-Host "PASS: official release resolved, downloaded, hash verified and extracted: $exe"
}
finally {
    [Net.ServicePointManager]::SecurityProtocol = $previousTls
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}
