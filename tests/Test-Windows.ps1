#Requires -Version 5.1
# No Pester dependency. All disk, network and process operations are simulated.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
foreach ($file in @('Disks.ps1', 'Install.ps1', 'Isos.ps1')) { . (Join-Path $root "windows\$file") }
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('ventoy-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$script:passed = 0
function Test-Case([string]$Name, [scriptblock]$Body) {
    & $Body
    $script:passed++
    Write-Host "PASS $Name"
}
function Assert-True($Condition) { if (-not $Condition) { throw 'Assertion failed.' } }
function Assert-Throws([scriptblock]$Body, [string]$Pattern) {
    $caught = $null
    try { & $Body } catch { $caught = $_ }
    if ($null -eq $caught -or $caught.ToString() -notlike "*$Pattern*") {
        throw "Expected failure containing '$Pattern'; got '$caught'."
    }
}
function New-Disk([int]$Number = 7) {
    [pscustomobject]@{ Number=$Number; FriendlyName='Test USB'; BusType='USB'; IsBoot=$false;
        IsSystem=$false; IsOffline=$false; IsReadOnly=$false; Size=32GB;
        UniqueId="usb-$Number"; SerialNumber="serial-$Number"; Path="device-$Number" }
}
# These shadows make it impossible for these tests to invoke the actual installer.
function Start-Process {
    param($FilePath, $WorkingDirectory, $WindowStyle, $ArgumentList, [switch]$PassThru)
    $script:launches++
    $script:arguments = $ArgumentList
    Set-Content -LiteralPath (Join-Path $WorkingDirectory 'cli_done.txt') -Value '0'
    $p = [pscustomobject]@{ ExitCode = 0 }
    $p | Add-Member ScriptMethod WaitForExit { param($Milliseconds); if ($null -ne $Milliseconds) { return $true } }
    $p | Add-Member ScriptMethod Dispose { }
    $p
}
function Get-Disk {
    param($Number, $ErrorAction)
    if ($PSBoundParameters.ContainsKey('Number')) {
        $script:reads++
        if ($script:swap -and $script:reads -gt 1) { return (New-Disk 8) }
        return $script:disk
    }
    $script:allDisks
}
function Get-Partition { param($DiskNumber, $ErrorAction); $script:partitions }
function Get-Volume {
    param([Parameter(ValueFromPipeline)]$Partition)
    process { if ($Partition.PartitionNumber -eq 2) { $script:efi } else { $script:data } }
}
function Read-Host { param($Prompt); $script:answer }
function Invoke-RestMethod { param($Uri, $Headers, $TimeoutSec); $script:release }
function Invoke-WebRequest { throw 'Network is disabled in unit tests.' }
$script:disk = New-Disk
$script:reads = 0
$script:swap = $false
$script:launches = 0
$script:partitions = @(
    [pscustomobject]@{ PartitionNumber=1; Size=31GB; AccessPaths=@('Z:\') },
    [pscustomobject]@{ PartitionNumber=2; Size=32MB; AccessPaths=@() }
)
$script:efi = [pscustomobject]@{ FileSystemLabel='VTOYEFI'; FileSystem='FAT' }
$script:data = [pscustomobject]@{ FileSystemLabel='Ventoy'; FileSystem='exFAT'; DriveLetter='Z'; UniqueId='volume-1'; SizeRemaining=20GB }
try {
    Test-Case 'PowerShell syntax for every script' {
        foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -Filter *.ps1) {
            $tokens=$null; $errors=$null
            $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            Assert-True ($errors.Count -eq 0)
        }
    }
    Test-Case 'USB enumeration excludes internal, boot/system, offline and read-only disks' {
        $script:allDisks = @((New-Disk))
        foreach ($property in @('IsBoot','IsSystem','IsOffline','IsReadOnly')) {
            $bad=New-Disk; $bad.$property=$true; $script:allDisks += $bad
            Assert-Throws { Assert-UsbDisk $bad } 'online, writable USB'
        }
        $bad=New-Disk; $bad.BusType='NVMe'; $script:allDisks += $bad
        Assert-Throws { Assert-UsbDisk $bad } 'online, writable USB'
        Assert-True (@(Get-UsbDisks).Count -eq 1)
        $script:allDisks=@(); Assert-True (@(Get-UsbDisks).Count -eq 0)
    }
    Test-Case 'missing identity and replaced disk fail closed' {
        $bad=New-Disk; $bad.UniqueId=''; Assert-Throws { Assert-UsbDisk $bad } 'identifier'
        $bad=New-Disk; $bad.UniqueId='replacement'; Assert-Throws { Get-SelectedDisk $bad } 'changed'
    }
    Test-Case 'only uppercase YES authorizes install' {
        foreach ($script:answer in @('', 'yes', 'NO')) {
            Assert-Throws { Install-Ventoy $script:disk (Join-Path $scratch 'fake.exe') } 'cancelled'
        }
        Assert-True ($script:launches -eq 0)
    }
    Test-Case 'disk replacement during confirmation prevents launching installer' {
        $script:answer='YES'; $script:swap=$true; $script:reads=0
        Assert-Throws { Install-Ventoy $script:disk (Join-Path $scratch 'fake.exe') } 'changed'
        Assert-True ($script:launches -eq 0)
        $script:swap=$false
    }
    Test-Case 'CLI uses physical disk, GPT and retains USB/Secure Boot checks' {
        Install-Ventoy $script:disk (Join-Path $scratch 'fake.exe')
        Assert-True (($script:arguments -join ' ') -ceq 'VTOYCLI /I /PhyDrive:7 /GPT')
        Assert-True ($script:launches -eq 1)
    }
    Test-Case 'installer requires success marker and successful process exit' {
        Assert-VentoyResult $scratch 0
        Assert-Throws { Assert-VentoyResult $scratch 1 } 'did not report'
        foreach ($value in @('1', '', 'garbage')) {
            Set-Content (Join-Path $scratch 'cli_done.txt') $value
            Assert-Throws { Assert-VentoyResult $scratch 0 } 'did not report'
        }
        Remove-Item (Join-Path $scratch 'cli_done.txt')
        Assert-Throws { Assert-VentoyResult $scratch 0 } 'did not report'
    }
    Test-Case 'data volume belongs to selected disk and requires Ventoy layout' {
        Assert-True ((Get-VentoyDataVolume $script:disk).DriveLetter -eq 'Z')
        $script:efi.FileSystemLabel='OTHER'
        Assert-Throws { Get-VentoyDataVolume $script:disk } 'layout'
        $script:efi.FileSystemLabel='VTOYEFI'; $script:data.DriveLetter=''
        Assert-Throws { Get-VentoyDataVolume $script:disk } 'no drive letter'
        $script:data.DriveLetter='Z'
        $savedPartitions=$script:partitions; $script:partitions=@()
        Assert-Throws { Get-VentoyDataVolume $script:disk } 'layout'
        $script:partitions=$savedPartitions
    }
    $isoPath = Join-Path $scratch 'test [1] file.ISO'
    Set-Content -LiteralPath $isoPath -Value 'ISO test fixture, not a bootable image.'
    Test-Case 'ISO paths handle spaces, brackets and quotes; invalid paths rejected' {
        Assert-True ((Get-LocalIso ('"' + $isoPath + '"')).FullName -eq $isoPath)
        Assert-Throws { Get-LocalIso $scratch } 'nonempty'
        $empty=Join-Path $scratch 'empty.iso'; [IO.File]::WriteAllBytes($empty, [byte[]]@())
        Assert-Throws { Get-LocalIso $empty } 'nonempty'
        $text=Join-Path $scratch 'file.txt'; Set-Content $text 'data'
        Assert-Throws { Get-LocalIso $text } 'nonempty'
        Assert-Throws { Get-LocalIso (Join-Path $scratch 'missing.iso') } 'does not exist'
    }
    Test-Case 'ISO copy checks free space before any writes' {
        $script:data.DriveLetter=$env:SystemDrive.TrimEnd(':')
        $script:data.SizeRemaining=0
        Assert-Throws { Copy-IsoToVentoy $script:disk $isoPath } 'Not enough'
        $script:data.SizeRemaining=20GB
        $script:data.DriveLetter='Z'
    }
    Test-Case 'large ISO rejected for FAT32 before copying' {
        function Get-LocalIso { [pscustomobject]@{ Name='ventoy-test-large.iso'; FullName='fixture'; Length=5GB } }
        $script:data.DriveLetter=$env:SystemDrive.TrimEnd(':'); $script:data.FileSystem='FAT32'
        Assert-Throws { Copy-IsoToVentoy $script:disk 'fixture.iso' } 'FAT32'
        $script:data.DriveLetter='Z'; $script:data.FileSystem='exFAT'
    }
    Test-Case 'copy verifies bytes, refuses overwrite and cleans partial output' {
        $dest=Join-Path $scratch 'copied.iso'
        Copy-VerifiedIso $isoPath $dest
        Assert-True ((Get-FileHash -LiteralPath $dest).Hash -eq (Get-FileHash -LiteralPath $isoPath).Hash)
        Assert-Throws { Copy-VerifiedIso $isoPath $dest } 'already exists'
        Assert-True (@(Get-ChildItem $scratch -Filter '*.partial' -Force).Count -eq 0)
    }
    Test-Case 'progress copy and streaming SHA-256 handle multiple buffers and a short last chunk' {
        $large = Join-Path $scratch 'multi-buffer.iso'
        $bytes = New-Object byte[] (9MB + 137)
        (New-Object Random(42)).NextBytes($bytes)
        [IO.File]::WriteAllBytes($large, $bytes)
        $dest = Join-Path $scratch 'multi-buffer-copy.iso'
        Copy-VerifiedIso $large $dest
        Assert-True ((Get-FileHash -LiteralPath $large).Hash -eq (Get-FileHash -LiteralPath $dest).Hash)
        Assert-True ((Get-IsoSha256 $large 'Test hash') -eq (Get-FileHash -LiteralPath $large).Hash)
    }
    Test-Case 'release resolver checks official URL, Windows asset and digest' {
        $script:release = [pscustomobject]@{ tag_name='v1.2.3'; assets=@([pscustomobject]@{
            name='ventoy-1.2.3-windows.zip'; digest=('sha256:' + ('a' * 64));
            browser_download_url='https://github.com/ventoy/Ventoy/releases/download/v1.2.3/ventoy-1.2.3-windows.zip'
        }) }
        Assert-True ((Get-VentoyRelease).Version -eq 'v1.2.3')
        $script:release.assets[0].digest=$null
        Assert-Throws { Get-VentoyRelease } 'SHA-256'
        $script:release.assets[0].digest=('sha256:' + ('a' * 64))
        $script:release.assets[0].browser_download_url='https://example.com/untrusted.zip'
        Assert-Throws { Get-VentoyRelease } 'download URL'
        $script:release.assets=@(); Assert-Throws { Get-VentoyRelease } 'Windows ZIP'
    }
    Test-Case 'archive extraction verifies digest and executable presence' {
        $fixture=Join-Path $scratch 'fixture'; New-Item -ItemType Directory $fixture | Out-Null
        Set-Content (Join-Path $fixture 'Ventoy2Disk.exe') 'FAKE - NEVER EXECUTE'
        $zip=Join-Path $scratch 'test.zip'; Compress-Archive -Path "$fixture\*" -DestinationPath $zip
        $hash=(Get-FileHash $zip).Hash
        $exe=Expand-VentoyPackage $zip (Join-Path $scratch 'expanded') $hash
        Assert-True (Test-Path -LiteralPath $exe)
        Assert-Throws { Expand-VentoyPackage $zip (Join-Path $scratch 'bad') ('0'*64) } 'mismatch'
        Set-Content (Join-Path $scratch 'invalid.zip') 'Not a ZIP'
        $badZip=Join-Path $scratch 'invalid.zip'
        Assert-Throws { Expand-VentoyPackage $badZip (Join-Path $scratch 'invalid') (Get-FileHash $badZip).Hash } ''
        $noExe=Join-Path $scratch 'no-exe.zip'
        Compress-Archive -LiteralPath $isoPath -DestinationPath $noExe
        Assert-Throws { Expand-VentoyPackage $noExe (Join-Path $scratch 'no-exe') (Get-FileHash $noExe).Hash } 'missing'
    }
    Test-Case 'download failures propagate without launching the installer' {
        function Get-VentoyRelease { [pscustomobject]@{ Version='v1.2.3'; Url='fixture'; Sha256=('a'*64) } }
        $before=$script:launches
        Assert-Throws { Save-VentoyPackage $scratch } 'Network is disabled'
        Assert-True ($script:launches -eq $before)
    }
    Write-Host "All $script:passed safe tests passed. No disk was modified and no executable was launched."
}
finally { Remove-Item -LiteralPath $scratch -Recurse -Force }
