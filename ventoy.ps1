#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$temporary = $null
$previousTls = [Net.ServicePointManager]::SecurityProtocol
try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'Use ./ventoy.sh on Linux. This entry point requires Windows.'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Open PowerShell with Run as administrator, change to this repository, then run .\ventoy.ps1 again.'
    }
    foreach ($file in @('Disks.ps1', 'Install.ps1', 'Isos.ps1')) {
        . (Join-Path $PSScriptRoot "windows\$file")
    }
    [Net.ServicePointManager]::SecurityProtocol = $previousTls -bor [Net.SecurityProtocolType]::Tls12
    Write-Host "Ventoy USB Setup`n[1] Create a new Ventoy USB`n[2] Add ISO to existing Ventoy USB"
    $action = Read-Host 'Select'
    if ($action -notin @('1', '2')) { throw 'Invalid selection.' }
    $disks = @(Get-UsbDisks)
    if ($disks.Count -eq 0) { throw 'No eligible USB disks found. Connect an online, writable USB disk and retry.' }
    Write-Host "`nAvailable USB disks (external USB SSDs may also appear):"
    for ($i = 0; $i -lt $disks.Count; $i++) {
        Write-Host "[$($i + 1)]"
        Show-UsbDisk $disks[$i]
    }
    $index = 0
    if (-not [int]::TryParse((Read-Host 'Select USB by list number'), [ref]$index) -or
        $index -lt 1 -or $index -gt $disks.Count) { throw 'Invalid USB selection.' }
    $selected = Get-SelectedDisk $disks[$index - 1]
    if ($action -eq '1') {
        $temporary = Join-Path ([IO.Path]::GetTempPath()) ('ventoy-usb-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $temporary | Out-Null
        $exe = Save-VentoyPackage $temporary
        Install-Ventoy -Selected $selected -Executable $exe
        # Give Windows a bounded interval to expose the new volumes.
        for ($attempt = 0; $attempt -lt 15; $attempt++) {
            try { $null = Get-VentoyDataVolume $selected; break }
            catch { if ($attempt -eq 14) { throw }; Start-Sleep -Seconds 2 }
        }
    }
    else { $null = Get-VentoyDataVolume $selected }
    $iso = Read-IsoPath
    if ($null -ne $iso) { Copy-IsoToVentoy -Selected $selected -Path $iso.FullName }
}
catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
finally {
    [Net.ServicePointManager]::SecurityProtocol = $previousTls
    if ($temporary -and (Test-Path -LiteralPath $temporary)) {
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}
