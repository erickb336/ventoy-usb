function Get-LocalIso {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path.Trim().Trim('"') -ErrorAction Stop
    if ($item -isnot [System.IO.FileInfo] -or $item.Extension -ine '.iso' -or $item.Length -eq 0) {
        throw 'Select an existing, nonempty .iso file (not a folder or unfinished download).'
    }
    $item
}

function Read-IsoPath {
    Write-Host "`nISO: [1] Windows 11  [2] Local ISO  [3] Skip"
    switch (Read-Host 'Select') {
        '1' {
            $url = 'https://www.microsoft.com/software-download/windows11'
            Write-Host "Download the Windows 11 disk image (ISO) to your PC: $url"
            Write-Host 'Choose the architecture matching the target PC. Wait for the download to finish.'
            Write-Host 'Press Ctrl+J in your browser to see download progress. This terminal cannot track the browser download.'
            Write-Host 'Do not double-click the ISO or run Windows Setup on this PC. Paste the finished file path below.'
            try { Start-Process $url } catch { Write-Warning 'Could not open a browser. Open the URL above manually.' }
        }
        '2' { }
        '3' { return }
        default { throw 'Invalid ISO selection.' }
    }
    Write-Host 'Waiting for your ISO path. USB copying starts only after you enter it.'
    Get-LocalIso (Read-Host 'Full path to downloaded/local ISO (quotes optional)')
}

function Get-IsoSha256 {
    param([string]$Path, [string]$Activity)
    $stream = $null
    $hasher = [Security.Cryptography.SHA256]::Create()
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $lastUpdate = -1.0
    try {
        $stream = [IO.File]::OpenRead($Path)
        $buffer = New-Object byte[] (4MB)
        while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $null = $hasher.TransformBlock($buffer, 0, $count, $buffer, 0)
            if ($timer.Elapsed.TotalSeconds - $lastUpdate -ge 0.25) {
                $percent = [int][Math]::Min(100, 100.0 * $stream.Position / [Math]::Max(1, $stream.Length))
                Write-Progress -Id 2 -Activity $Activity -Status "$percent% read" -PercentComplete $percent
                $lastUpdate = $timer.Elapsed.TotalSeconds
            }
        }
        $null = $hasher.TransformFinalBlock($buffer, 0, 0)
        [BitConverter]::ToString($hasher.Hash).Replace('-', '')
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        $hasher.Dispose()
        Write-Progress -Id 2 -Activity $Activity -Completed
    }
}

function Copy-IsoToVentoy {
    param([Parameter(Mandatory)]$Selected, [Parameter(Mandatory)][string]$Path)
    $iso = Get-LocalIso $Path
    $volume = Get-VentoyDataVolume $Selected
    $root = "$($volume.DriveLetter):\"
    $destination = Join-Path $root $iso.Name
    if (Test-Path -LiteralPath $destination) { throw "Already exists: $destination. Rename or remove it manually before retrying." }
    if ($volume.SizeRemaining -lt $iso.Length) { throw 'Not enough free space on the selected Ventoy data partition.' }
    if ($volume.FileSystem -eq 'FAT32' -and $iso.Length -gt 4294967295) {
        throw 'This ISO exceeds the FAT32 file size limit. Use an exFAT or NTFS Ventoy data partition.'
    }
    Write-Host "Copying $($iso.FullName) to Disk $($Selected.Number), $destination"
    # Recheck the physical disk and volume immediately before opening the output.
    $current = Get-VentoyDataVolume $Selected
    if ($current.UniqueId -ne $volume.UniqueId -or $current.DriveLetter -ne $volume.DriveLetter) {
        throw 'USB volume changed. Restart and select the disk again.'
    }
    Copy-VerifiedIso -Source $iso.FullName -Destination $destination
    Write-Host 'ISO copied and SHA-256 verified. Safely eject the USB before unplugging it.'
}

function Copy-VerifiedIso {
    param([string]$Source, [string]$Destination)
    $partial = Join-Path (Split-Path -Parent $Destination) ('.ventoy-copy-' + [guid]::NewGuid().ToString('N') + '.partial')
    $inputStream = $null
    $outputStream = $null
    $ProgressPreference = 'Continue'
    try {
        Write-Host '[1/3] Copying ISO to USB...'
        $inputStream = [IO.File]::OpenRead($Source)
        $outputStream = [IO.File]::Open($partial, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $buffer = New-Object byte[] (4MB)
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $lastUpdate = -1.0
        $copied = 0L
        while (($count = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outputStream.Write($buffer, 0, $count)
            $copied += $count
            if ($timer.Elapsed.TotalSeconds - $lastUpdate -ge 0.25) {
                $elapsed = [Math]::Max(0.001, $timer.Elapsed.TotalSeconds)
                $rate = $copied / $elapsed
                $percent = [int][Math]::Min(100, 100.0 * $copied / [Math]::Max(1, $inputStream.Length))
                $remaining = [int][Math]::Min([int]::MaxValue, [Math]::Max(0, ($inputStream.Length - $copied) / $rate))
                $status = '{0}% | {1:N2} / {2:N2} GiB | {3:N1} MiB/s' -f $percent, ($copied / 1GB), ($inputStream.Length / 1GB), ($rate / 1MB)
                Write-Progress -Id 1 -Activity 'Copying ISO to USB' -Status $status -PercentComplete $percent -SecondsRemaining $remaining
                $lastUpdate = $timer.Elapsed.TotalSeconds
            }
        }
        Write-Progress -Id 1 -Activity 'Copying ISO to USB' -Status 'Flushing buffered data to USB. Please wait...' -PercentComplete 100
        $outputStream.Flush($true)
        Write-Progress -Id 1 -Activity 'Copying ISO to USB' -Completed
        $outputStream.Dispose(); $outputStream = $null
        $inputStream.Dispose(); $inputStream = $null
        Write-Host '[2/3] Reading source ISO for SHA-256 verification...'
        $sourceHash = Get-IsoSha256 -Path $Source -Activity 'Verifying source ISO (2/3)'
        Write-Host '[3/3] Reading USB copy for SHA-256 verification. Keep the USB connected...'
        $destinationHash = Get-IsoSha256 -Path $partial -Activity 'Verifying USB copy (3/3)'
        if ($sourceHash -ne $destinationHash) {
            throw 'Copied ISO checksum mismatch.'
        }
        # File.Move refuses to overwrite an existing ISO, including one created during the copy.
        [IO.File]::Move($partial, $destination)
    }
    finally {
        Write-Progress -Id 1 -Activity 'Copying ISO to USB' -Completed
        if ($null -ne $outputStream) { $outputStream.Dispose() }
        if ($null -ne $inputStream) { $inputStream.Dispose() }
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue }
    }
}
