function Get-VentoyRelease {
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/ventoy/Ventoy/releases/latest' `
        -Headers @{ 'User-Agent' = 'ventoy-usb'; Accept = 'application/vnd.github+json' } -TimeoutSec 60
    if ($release.tag_name -notmatch '^v\d+\.\d+\.\d+$') { throw 'Unexpected Ventoy release version.' }
    $name = 'ventoy-{0}-windows.zip' -f $release.tag_name.Substring(1)
    $assets = @($release.assets | Where-Object { $_.name -ceq $name })
    if ($assets.Count -ne 1) { throw 'Official release does not contain exactly one Windows ZIP.' }
    $expected = "https://github.com/ventoy/Ventoy/releases/download/$($release.tag_name)/$name"
    if ($assets[0].browser_download_url -cne $expected) { throw 'Unexpected Ventoy download URL.' }
    $digest = $assets[0].PSObject.Properties['digest']
    if (-not $digest -or $digest.Value -notmatch '^sha256:[0-9a-fA-F]{64}$') {
        throw 'Official release has no SHA-256 asset digest; cannot verify the download.'
    }
    [pscustomobject]@{ Version = $release.tag_name; Url = $expected; Sha256 = $digest.Value.Substring(7) }
}

function Expand-VentoyPackage {
    param([string]$Archive, [string]$Destination, [string]$Sha256)
    if ((Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash -ine $Sha256) {
        throw 'Ventoy ZIP SHA-256 mismatch. Installation cancelled.'
    }
    Expand-Archive -LiteralPath $Archive -DestinationPath $Destination -ErrorAction Stop
    $executables = @(Get-ChildItem -LiteralPath $Destination -Filter Ventoy2Disk.exe -File -Recurse)
    if ($executables.Count -ne 1) { throw 'Ventoy2Disk.exe missing or ambiguous in Windows package.' }
    $executables[0].FullName
}

function Save-VentoyPackage {
    param([string]$Directory)
    $ProgressPreference = 'Continue'
    Write-Host 'Checking the latest official Ventoy release...'
    $release = Get-VentoyRelease
    Write-Host "Downloading official Ventoy $($release.Version)..."
    $archive = Join-Path $Directory 'ventoy.zip'
    try {
        Write-Progress -Id 3 -Activity 'Downloading Ventoy' -Status 'Receiving official Windows ZIP...' -PercentComplete -1
        Invoke-WebRequest -UseBasicParsing -Uri $release.Url -OutFile $archive -TimeoutSec 300
    }
    finally { Write-Progress -Id 3 -Activity 'Downloading Ventoy' -Completed }
    Write-Host 'Download finished. Verifying SHA-256 and extracting Ventoy...'
    Expand-VentoyPackage -Archive $archive -Destination (Join-Path $Directory 'extracted') -Sha256 $release.Sha256
}

function Assert-VentoyResult {
    param([string]$Directory, [int]$ExitCode)
    $done = Join-Path $Directory 'cli_done.txt'
    if ($ExitCode -ne 0 -or -not (Test-Path -LiteralPath $done) -or
        (Get-Content -LiteralPath $done -Raw).Trim() -cne '0') {
        $log = Join-Path $Directory 'cli_log.txt'
        if (Test-Path -LiteralPath $log) {
            Write-Host ((Get-Content -LiteralPath $log -Tail 40) -join [Environment]::NewLine)
        }
        throw 'Ventoy did not report a successful installation. See the log above; do not assume the USB is ready.'
    }
}

function Install-Ventoy {
    param([Parameter(Mandatory)]$Selected, [Parameter(Mandatory)][string]$Executable)
    $disk = Get-SelectedDisk $Selected
    Show-UsbDisk $disk
    Write-Host 'WARNING: ALL partitions and data on this physical disk WILL BE COMPLETELY ERASED.' -ForegroundColor Yellow
    if ((Read-Host 'Type YES to erase this disk') -cne 'YES') { throw 'Installation cancelled; no disk was modified.' }
    # Re-read after confirmation: a stale disk number must never be trusted.
    $disk = Get-SelectedDisk $Selected
    $directory = Split-Path -Parent $Executable
    foreach ($name in @('cli_done.txt', 'cli_log.txt', 'cli_percent.txt')) {
        $path = Join-Path $directory $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    Write-Host 'Installing Ventoy (GPT, Secure Boot support enabled). Do not unplug the USB.'
    $process = $null
    $ProgressPreference = 'Continue'
    try {
        $process = Start-Process -FilePath $Executable -WorkingDirectory $directory -WindowStyle Hidden `
            -ArgumentList @('VTOYCLI', '/I', "/PhyDrive:$($disk.Number)", '/GPT') -PassThru
        while (-not $process.WaitForExit(250)) {
            $percent = 0
            $progressPath = Join-Path $directory 'cli_percent.txt'
            # The installer may be replacing this file while we read it.
            $value = Get-Content -LiteralPath $progressPath -Raw -ErrorAction SilentlyContinue
            if ([int]::TryParse([string]$value, [ref]$percent) -and $percent -ge 0 -and $percent -le 100) {
                Write-Progress -Id 4 -Activity 'Installing Ventoy' -Status "$percent% - keep USB connected" -PercentComplete $percent
            }
            else {
                Write-Progress -Id 4 -Activity 'Installing Ventoy' -Status 'Waiting for installer progress - keep USB connected' -PercentComplete -1
            }
        }
        Assert-VentoyResult -Directory $directory -ExitCode $process.ExitCode
    }
    finally {
        Write-Progress -Id 4 -Activity 'Installing Ventoy' -Completed
        # Do not kill a disk writer or remove its working files on Ctrl+C.
        if ($null -ne $process) {
            $process.WaitForExit()
            $process.Dispose()
        }
    }
    Write-Host 'Ventoy installed successfully.'
}
