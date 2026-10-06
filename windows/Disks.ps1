function Assert-UsbDisk {
    param([Parameter(Mandatory)]$Disk)
    if ([string]$Disk.BusType -ne 'USB' -or $Disk.IsBoot -or $Disk.IsSystem -or
        $Disk.IsOffline -or $Disk.IsReadOnly -or $Disk.Size -le 0) {
        throw 'Disk must be an online, writable USB disk that is not a boot/system disk.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$Disk.UniqueId)) {
        throw 'Disk has no stable Windows identifier; refusing to use it.'
    }
}

function Get-UsbDisks {
    @(Get-Disk -ErrorAction Stop | Where-Object {
        [string]$_.BusType -eq 'USB' -and -not $_.IsBoot -and -not $_.IsSystem -and
        -not $_.IsOffline -and -not $_.IsReadOnly -and $_.Size -gt 0
    } | Sort-Object Number)
}

function Get-SelectedDisk {
    param([Parameter(Mandatory)]$Selected)
    $current = Get-Disk -Number $Selected.Number -ErrorAction Stop
    Assert-UsbDisk $current
    if ($current.Number -ne $Selected.Number -or $current.UniqueId -ne $Selected.UniqueId -or $current.Size -ne $Selected.Size -or
        $current.SerialNumber -ne $Selected.SerialNumber -or $current.Path -ne $Selected.Path) {
        throw 'The selected disk changed or was disconnected. Restart and select it again.'
    }
    $current
}

function Show-UsbDisk {
    param([Parameter(Mandatory)]$Disk)
    Write-Host ('Disk {0} | {1} | {2:N2} GiB | Serial: {3}' -f
        $Disk.Number, $Disk.FriendlyName, ($Disk.Size / 1GB), $Disk.SerialNumber)
    Write-Host "  ID: $($Disk.UniqueId)"
    try { $partitions = @(Get-Partition -DiskNumber $Disk.Number -ErrorAction Stop) }
    catch {
        if ($_.CategoryInfo.Category -ne 'ObjectNotFound') { throw }
        $partitions = @() # A blank/RAW USB may have no partitions.
    }
    foreach ($partition in $partitions) {
        # Linux or unformatted partitions may have no Windows volume.
        $volumes = @($partition | Get-Volume -ErrorAction SilentlyContinue)
        if ($volumes.Count -eq 0) {
            Write-Host ('  Partition {0}: {1:N2} GiB (no recognized Windows volume)' -f
                $partition.PartitionNumber, ($partition.Size / 1GB))
        }
        foreach ($volume in $volumes) {
            Write-Host ('  Partition {0}: {1}  Label: {2}  Format: {3}  {4:N2} GiB' -f
                $partition.PartitionNumber, ($partition.AccessPaths -join ', '),
                $volume.FileSystemLabel, $volume.FileSystem, ($partition.Size / 1GB))
        }
    }
}

function Get-VentoyDataVolume {
    param([Parameter(Mandatory)]$Selected)
    $disk = Get-SelectedDisk $Selected
    $partitions = @(Get-Partition -DiskNumber $disk.Number -ErrorAction Stop)
    $efiPartition = @($partitions | Where-Object { $_.PartitionNumber -eq 2 -and $_.Size -eq 32MB })
    $dataPartition = @($partitions | Where-Object { $_.PartitionNumber -eq 1 })
    if ($efiPartition.Count -ne 1 -or $dataPartition.Count -ne 1) { throw 'Expected Ventoy partition layout not found.' }
    $efi = @($efiPartition[0] |
        Get-Volume -ErrorAction Stop | Where-Object {
            $_.FileSystemLabel -eq 'VTOYEFI' -and $_.FileSystem -eq 'FAT'
        })
    $data = @($dataPartition[0] |
        Get-Volume -ErrorAction Stop | Where-Object { $_.FileSystem -in @('exFAT', 'NTFS', 'FAT32') })
    if ($efi.Count -ne 1 -or $data.Count -ne 1) {
        throw 'Expected Ventoy layout (data partition 1 and 32 MiB FAT VTOYEFI partition 2) not found on this disk.'
    }
    if (-not $data[0].DriveLetter) {
        throw 'Ventoy data partition has no drive letter. Assign one in Disk Management, then retry option 2.'
    }
    $data[0]
}
