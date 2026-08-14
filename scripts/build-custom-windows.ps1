[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputIso,

    [Parameter(Mandatory = $true)]
    [string]$UbuntuPackage,

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 99)]
    [int]$ImageIndex,

    [Parameter(Mandatory = $false)]
    [string]$OutputRoot = (Join-Path $PSScriptRoot 'output')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $false)][string[]]$Arguments = @()
    )

    Write-Host "> $FilePath $($Arguments -join ' ')"
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath failed with exit code $LASTEXITCODE"
    }
}

function Enable-OptionalOfflineFeature {
    param(
        [Parameter(Mandatory = $true)][string]$ImagePath,
        [Parameter(Mandatory = $true)][string]$FeatureName
    )

    $arguments = @(
        "/Image:$ImagePath",
        "/Enable-Feature",
        '/FeatureName:$FeatureName',
        "/All",
        "/LimitAccess"
    )
    Write-Host ("> dism.exe " + ($arguments -join " "))
    $output = & dism.exe @arguments 2>&1
    $exitCode = $LASTEXITCODE
    $output | ForEach-Object { Write-Host $_ }
    if ($exitCode -eq 0) { return $true }
    $hexCode = "{0:X8}" -f ([uint32]$exitCode)
    if ($hexCode -eq "800F080C") {
        Write-Warning "Feature $FeatureName is not present in the source image; continuing without it."
        return $false
    }
    throw "dism.exe failed enabling $FeatureName with exit code $exitCode"
}
function Set-OfflineRegistryDword {
    param(
        [Parameter(Mandatory = $true)][string]$HiveName,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$Value
    )

    Invoke-Native 'reg.exe' @('add', "HKLM\$HiveName\$Key", '/v', $Name, '/t', 'REG_DWORD', '/d', "$Value", '/f')
}

function Load-OfflineHive {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Path
    )

    Invoke-Native 'reg.exe' @('load', "HKLM\$Name", $Path)
}

function Unload-OfflineHive {
    param([Parameter(Mandatory = $true)][string]$Name)
    Invoke-Native 'reg.exe' @('unload', "HKLM\$Name")
}

function Find-Oscdimg {
    $roots = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits'),
        (Join-Path ${env:ProgramFiles} 'Windows Kits')
    ) | Where-Object { $_ -and (Test-Path $_) }

    foreach ($root in $roots) {
        $candidate = Get-ChildItem -Path $root -Filter 'oscdimg.exe' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($candidate) { return $candidate.FullName }
    }

    throw 'oscdimg.exe was not found. The Windows ADK deployment tools are required to rebuild the ISO.'
}

function Write-FirstLogonScript {
    param([Parameter(Mandatory = $true)][string]$Path)

    @'
$ErrorActionPreference = 'Continue'
$log = 'C:\Windows\Setup\Scripts\tiny11-custom-first-logon.log'
Start-Transcript -Path $log -Force | Out-Null
try {
    $touchpad = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PrecisionTouchPad'
    New-Item -Path $touchpad -Force | Out-Null
    $touchpadValues = @{
        TapEnabled = 1
        TwoFingerTapEnabled = 1
        ThreeFingerTapEnabled = 1
        FourFingerTapEnabled = 1
        ThreeFingerSlideEnabled = 1
        FourFingerSlideEnabled = 1
        RightClickZoneEnabled = 1
        DisableTouchpadWhileTyping = 0
    }
    foreach ($entry in $touchpadValues.GetEnumerator()) {
        New-ItemProperty -Path $touchpad -Name $entry.Key -Value $entry.Value -PropertyType DWord -Force | Out-Null
    }

    $ubuntuWsl = 'C:\Windows\Setup\Files\Ubuntu.wsl'
    if (Test-Path $ubuntuWsl) {
        try {
            & wsl.exe --install --from-file $ubuntuWsl --no-launch
            if ($LASTEXITCODE -ne 0) { throw "wsl.exe failed with exit code $LASTEXITCODE" }
            Write-Host 'Ubuntu WSL package installed for the first Windows user.'
        } catch {
            Write-Warning "Ubuntu WSL package installation did not complete: $($_.Exception.Message)"
        }
    }

    try {
        wsl.exe --set-default-version 2
    } catch {
        Write-Warning "WSL default version could not be set yet: $($_.Exception.Message)"
    }

    Write-Host 'Automatic Windows Update is disabled by the offline policy. Microsoft Store, Defender, and activation services were not disabled.'
} finally {
    Stop-Transcript | Out-Null
}
'@ | Set-Content -Path $Path -Encoding UTF8
}

$resolvedInputIso = (Resolve-Path $InputIso).Path
$resolvedUbuntuPackage = (Resolve-Path $UbuntuPackage).Path
$root = (New-Item -ItemType Directory -Path $OutputRoot -Force).FullName
$work = Join-Path $root 'work'
$source = Join-Path $work 'iso-source'
$mount = Join-Path $work 'wim-mount'
$reports = Join-Path $root 'reports'
New-Item -ItemType Directory -Path $work, $source, $mount, $reports -Force | Out-Null

$mountedIso = $null
$imageMounted = $false
$softwareLoaded = $false
$defaultLoaded = $false

try {
    Write-Host "Mounting source ISO: $resolvedInputIso"
    $mountedIso = Mount-DiskImage -ImagePath $resolvedInputIso -PassThru
    Start-Sleep -Seconds 2
    $volume = $mountedIso | Get-Volume | Where-Object DriveLetter | Select-Object -First 1
    if (-not $volume) { throw 'The source ISO did not expose a drive letter.' }
    $isoDrive = "$($volume.DriveLetter):\"
    & robocopy.exe $isoDrive $source /E /R:2 /W:1 /COPY:DAT /DCOPY:DAT /NFL /NDL /NJH /NJS
    if ($LASTEXITCODE -gt 7) { throw "Copying ISO contents failed with exit code $LASTEXITCODE" }
    Dismount-DiskImage -ImagePath $resolvedInputIso
    $mountedIso = $null

    $wim = Join-Path $source 'sources\install.wim'
    $esd = Join-Path $source 'sources\install.esd'
    $selectedIndex = $ImageIndex
    if (-not (Test-Path $wim)) {
        if (-not (Test-Path $esd)) { throw 'Neither sources\install.wim nor sources\install.esd exists in the source ISO.' }
        Write-Host "Converting selected ESD index $ImageIndex to a compressed WIM."
        Invoke-Native 'dism.exe' @('/Export-Image', "/SourceImageFile:$esd", "/SourceIndex:$ImageIndex", "/DestinationImageFile:$wim", '/Compress:max', '/CheckIntegrity')
        Remove-Item $esd -Force
        $selectedIndex = 1
    }

    $ubuntuSize = (Get-Item $resolvedUbuntuPackage).Length
    if ($ubuntuSize -lt 50MB) { throw "Ubuntu package is unexpectedly small: $ubuntuSize bytes" }
    Write-Host "Ubuntu package size: $ubuntuSize bytes"
    @{ ubuntuPackageBytes = $ubuntuSize; sourceIso = $resolvedInputIso; imageIndex = $ImageIndex } |
        ConvertTo-Json | Set-Content (Join-Path $reports 'build-inputs.json') -Encoding UTF8

    Write-Host "Mounting Windows image index $selectedIndex"
    Invoke-Native 'dism.exe' @('/Mount-Image', "/ImageFile:$wim", "/Index:$selectedIndex", "/MountDir:$mount")
    $imageMounted = $true

    Write-Host 'Enabling WSL2 components when the source image contains them.'
    $wslFeaturesAvailable = $true
    if (-not (Enable-OptionalOfflineFeature -ImagePath $mount -FeatureName 'Microsoft-Windows-Subsystem-Linux')) { $wslFeaturesAvailable = $false }
    if (-not (Enable-OptionalOfflineFeature -ImagePath $mount -FeatureName 'VirtualMachinePlatform')) { $wslFeaturesAvailable = $false }
    if (-not $wslFeaturesAvailable) {
        Write-Warning 'The source image does not contain all WSL2 feature payloads; the staged Ubuntu package will require a Windows image with WSL enabled.'
    }

    $setupFiles = Join-Path $mount 'Windows\Setup\Files'
    $setupScripts = Join-Path $mount 'Windows\Setup\Scripts'
    New-Item -ItemType Directory -Path $setupFiles, $setupScripts -Force | Out-Null
    Copy-Item $resolvedUbuntuPackage (Join-Path $setupFiles 'Ubuntu.wsl') -Force
    Write-FirstLogonScript (Join-Path $setupScripts 'Tiny11CustomFirstLogon.ps1')

    $manifest = [ordered]@{
        product = 'Tiny11 custom offline foundation'
        wsl = "WSL2 feature enable attempted; missing feature payloads are left disabled"
        automaticWindowsUpdate = 'disabled by policy; Microsoft Store, Defender, and activation services left enabled'
        touchpad = 'Precision Touchpad gesture defaults enabled; hardware driver support still required'
        office = 'not included in this feasibility build'
        visualTheme = 'deferred until the build pipeline is proven'
    }
    ($manifest | ConvertTo-Json -Depth 4) | Set-Content (Join-Path $setupFiles 'customization-manifest.json') -Encoding UTF8

    Write-Host 'Applying offline Windows Update policy without disabling Microsoft services.'
    $softwareHivePath = Join-Path $mount 'Windows\System32\Config\SOFTWARE'
    Load-OfflineHive 'TINY_SOFTWARE' $softwareHivePath
    $softwareLoaded = $true
    Set-OfflineRegistryDword 'TINY_SOFTWARE' 'Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate' 1
    Set-OfflineRegistryDword 'TINY_SOFTWARE' 'Policies\Microsoft\Windows\WindowsUpdate\AU' 'AUOptions' 1
    Set-OfflineRegistryDword 'TINY_SOFTWARE' 'Policies\Microsoft\Windows\WindowsUpdate' 'DisableOSUpgrade' 1
    Unload-OfflineHive 'TINY_SOFTWARE'
    $softwareLoaded = $false

    Write-Host 'Applying Precision Touchpad defaults to the Default user profile.'
    $defaultHivePath = Join-Path $mount 'Users\Default\NTUSER.DAT'
    if (Test-Path $defaultHivePath) {
        Load-OfflineHive 'TINY_DEFAULT' $defaultHivePath
        $defaultLoaded = $true
        $tpKey = 'HKLM\TINY_DEFAULT\Software\Microsoft\Windows\CurrentVersion\PrecisionTouchPad'
        Invoke-Native 'reg.exe' @('add', $tpKey, '/v', 'TapEnabled', '/t', 'REG_DWORD', '/d', '1', '/f')
        Invoke-Native 'reg.exe' @('add', $tpKey, '/v', 'TwoFingerTapEnabled', '/t', 'REG_DWORD', '/d', '1', '/f')
        Invoke-Native 'reg.exe' @('add', $tpKey, '/v', 'ThreeFingerSlideEnabled', '/t', 'REG_DWORD', '/d', '1', '/f')
        Invoke-Native 'reg.exe' @('add', $tpKey, '/v', 'FourFingerSlideEnabled', '/t', 'REG_DWORD', '/d', '1', '/f')
        Unload-OfflineHive 'TINY_DEFAULT'
        $defaultLoaded = $false
    }

    Write-Host 'Capturing installed package inventory.'
    try {
        Get-AppxProvisionedPackage -Path $mount |
            Select-Object DisplayName, Version, Architecture, PackageName |
            ConvertTo-Json -Depth 4 |
            Set-Content (Join-Path $reports 'provisioned-apps.json') -Encoding UTF8
    } catch {
        Write-Warning "App inventory was not available: $($_.Exception.Message)"
    }

    Write-Host 'Cleaning component store without ResetBase, so servicing remains recoverable.'
    Invoke-Native 'dism.exe' @("/Image:$mount", '/Cleanup-Image', '/StartComponentCleanup')
    Invoke-Native 'dism.exe' @('/Unmount-Image', "/MountDir:$mount", '/Commit')
    $imageMounted = $false

    $optimized = Join-Path $work 'install.optimized.wim'
    Write-Host 'Re-exporting the customized image with maximum WIM compression.'
    Invoke-Native 'dism.exe' @('/Export-Image', "/SourceImageFile:$wim", "/SourceIndex:$selectedIndex", "/DestinationImageFile:$optimized", '/Compress:max', '/CheckIntegrity')
    Move-Item $wim "$wim.original" -Force
    Move-Item $optimized $wim -Force
    Remove-Item "$wim.original" -Force

    $oscdimg = Find-Oscdimg
    $outputIso = Join-Path $root 'Tiny11-custom-offline.iso'
    $biosBoot = Join-Path $source 'boot\etfsboot.com'
    $efiBoot = Join-Path $source 'efi\microsoft\boot\efisys.bin'
    if (-not (Test-Path $biosBoot) -or -not (Test-Path $efiBoot)) { throw 'Boot files required for BIOS/UEFI ISO creation are missing.' }
    Write-Host "Creating ISO with $oscdimg"
    Invoke-Native $oscdimg @('-m', '-o', '-u2', '-udfver102', "-bootdata:2#p0,e,b$biosBoot#pEF,e,b$efiBoot", $source, $outputIso)

    $size = (Get-Item $outputIso).Length
    @{ outputIso = $outputIso; outputBytes = $size; oscdimg = $oscdimg } |
        ConvertTo-Json | Set-Content (Join-Path $reports 'build-result.json') -Encoding UTF8
    Write-Host "Built ISO: $outputIso ($size bytes)"
}
finally {
    if ($defaultLoaded) { reg.exe unload HKLM\TINY_DEFAULT | Out-Null }
    if ($softwareLoaded) { reg.exe unload HKLM\TINY_SOFTWARE | Out-Null }
    if ($imageMounted) { dism.exe /Unmount-Image "/MountDir:$mount" /Discard | Out-Null }
    if ($mountedIso) { Dismount-DiskImage -ImagePath $resolvedInputIso -ErrorAction SilentlyContinue }
}
