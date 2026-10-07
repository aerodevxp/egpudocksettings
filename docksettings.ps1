<#
.SYNOPSIS
    ROG Ally X GPU Config Automation - Windows Port v1.2
.DESCRIPTION
    Discovers game config files, creates iGPU/eGPU profiles, and swaps them
    when switching between internal and external GPUs. Now with notifications!
#>

param(
    [ValidateSet('igpu','egpu')]
    [string]$Gpu,
    [switch]$DryRun,
    [switch]$Help
)

## ============================================================
## BASIC VARIABLES
## ============================================================
$RootDir   = $PSScriptRoot
$DockDir   = Join-Path $RootDir "docksettings"
$MapFile   = Join-Path $DockDir "master_map.txt"
$StateFile = Join-Path $DockDir "global_state"
$DB        = Join-Path $RootDir "docksettings_db.csv"
$LogFile   = Join-Path $DockDir "global.log"
$LockFile  = Join-Path $env:TEMP "docksettings.lock"

## Profile Directories
$IgpuProfiles = Join-Path $DockDir "profiles\igpu"
$EgpuProfiles = Join-Path $DockDir "profiles\egpu"
$BackupDir    = Join-Path $DockDir "backups"

## Steam path detection
$SteamRoot = $null
$regPaths = @(
    "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam",
    "HKLM:\SOFTWARE\Valve\Steam",
    "HKCU:\SOFTWARE\Valve\Steam"
)
foreach ($rp in $regPaths) {
    if (Test-Path $rp) {
        $prop = Get-ItemProperty $rp -ErrorAction SilentlyContinue
        if ($prop.InstallPath) { $SteamRoot = $prop.InstallPath; break }
    }
}
if (-not $SteamRoot) {
    $candidates = @("C:\Program Files (x86)\Steam", "C:\Program Files\Steam")
    foreach ($c in $candidates) { if (Test-Path $c) { $SteamRoot = $c; break } }
}
if (-not $SteamRoot) { $SteamRoot = "C:\Program Files (x86)\Steam" }

## Config Zones (Customize these!)
$ConfigZones = @(
    "$SteamRoot\steamapps\common"
    # "D:\SteamLibrary\steamapps\common"
)

$SystemConfigZones = @(
    "$env:USERPROFILE\Documents\My Games",
    "$env:APPDATA",
    "$env:LOCALAPPDATA"
)

$ConfigExtensions = @('*.ini', '*.cfg', '*.json', '*.xml', '*.sav', '*.config')
$ExclusionPatterns = @('crashreport', 'crashdump', '\steam\config', '\steam\dumps', '\steam\logs', '\steam\appcache', '\windows\', '\microsoft\', '\packages\')

## ============================================================
## NOTIFICATION HELPER
## ============================================================
function Show-Notification {
    param([string]$Title, [string]$Message)

    # Play the default Windows notification sound
    [System.Media.SystemSounds]::Asterisk.Play()

    # Try Windows 10/11 native Toast Notification
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $textNodes = $template.GetElementsByTagName("text")
        $textNodes.Item(0).AppendChild($template.CreateTextNode($Title)) | Out-Null
        $textNodes.Item(1).AppendChild($template.CreateTextNode($Message)) | Out-Null

        $toast = [Windows.UI.Notifications.ToastNotification]::new($template)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("PowerShell").Show($toast)
    } catch {
        # Fallback to older Balloon Tip if WinRT fails
        try {
            Add-Type -AssemblyName System.Windows.Forms
            $notify = New-Object System.Windows.Forms.NotifyIcon
            $notify.Icon = [System.Drawing.SystemIcons]::Information
            $notify.BalloonTipTitle = $Title
            $notify.BalloonTipText = $Message
            $notify.Visible = $true
            $notify.ShowBalloonTip(5000)
            Start-Sleep -Seconds 3
            $notify.Dispose()
        } catch {
            Write-Host "Notification: $Title - $Message"
        }
    }
}

## ============================================================
## LOGGING HELPERS
## ============================================================
function Write-DebugLog { param([string]$Message) $ts = Get-Date -Format 'dd-MM-yyyy HH:mm:ss'; $line = "$ts [DEBUG] $Message"; Write-Host $line; Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue }
function Write-InfoLog  { param([string]$Message) $ts = Get-Date -Format 'dd-MM-yyyy HH:mm:ss'; $line = "$ts [INFO] $Message";  Write-Host $line; Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue }
function Write-WarnLog  { param([string]$Message) $ts = Get-Date -Format 'dd-MM-yyyy HH:mm:ss'; $line = "$ts [WARN] $Message";  Write-Host $line; Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue }

function Get-FileHashQuick {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return (Get-FileHash -LiteralPath $Path -Algorithm MD5).Hash }
    return "FILE_NOT_FOUND"
}

function Test-Excluded {
    param([string]$Path)
    $lower = $Path.ToLower()
    foreach ($pat in $ExclusionPatterns) { if ($lower -like "*$pat*") { return $true } }
    return $false
}

## ============================================================
## PHASE 1-3: CRAWL AND REGISTER
## ============================================================
function Invoke-CrawlAndRegister {
    "" | Set-Content $LogFile
    Write-InfoLog "========== STARTING SCAN =========="
    $foundFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $scannedCount = 0; $excludedCount = 0

    Write-InfoLog "========== PHASE 1: ZONE SCAN =========="
    $allZones = @() + $ConfigZones + $SystemConfigZones

    foreach ($zone in $allZones) {
        if (-not (Test-Path -LiteralPath $zone)) { continue }
        $files = Get-ChildItem -LiteralPath $zone -Recurse -File -Include $ConfigExtensions -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            if (Test-Excluded $f.FullName) { $excludedCount++; continue }
            if ($foundFiles.Add($f.FullName)) { $scannedCount++ }
        }
    }

    Write-InfoLog "========== PHASE 2: CSV SCAN =========="
    if (Test-Path -LiteralPath $DB) {
        $entries = Get-Content -LiteralPath $DB | Where-Object { $_.Trim() -ne '' }
        foreach ($entry in $entries) {
            $entry = $entry.Trim()
            if (Test-Path -LiteralPath $entry -PathType Container) {
                $dirFiles = Get-ChildItem -LiteralPath $entry -Recurse -File -Include $ConfigExtensions -ErrorAction SilentlyContinue
                foreach ($f in $dirFiles) { if (-not (Test-Excluded $f.FullName)) { $foundFiles.Add($f.FullName) | Out-Null } }
            } elseif (Test-Path -LiteralPath $entry -PathType Leaf) {
                $foundFiles.Add($entry) | Out-Null
            }
        }
    } else { New-Item -Path $DB -ItemType File -Force | Out-Null }

    Write-InfoLog "========== PHASE 3: TOTAL FILES =========="
    Write-InfoLog "Total unique files discovered: $($foundFiles.Count)"

    Write-InfoLog "========== PHASE 4: REGISTRATION =========="
    New-Item -ItemType Directory -Path $IgpuProfiles -Force | Out-Null
    New-Item -ItemType Directory -Path $EgpuProfiles -Force | Out-Null
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    if (-not (Test-Path $MapFile)) { New-Item -Path $MapFile -ItemType File -Force | Out-Null }

    $mapLines = @(Get-Content $MapFile | Where-Object { $_.Trim() -ne '' })
    $existingPaths = @{}
    foreach ($ml in $mapLines) { $parts = $ml -split '\|', 2; if ($parts.Count -eq 2) { $existingPaths[$parts[1].Trim()] = $parts[0].Trim() } }

    $nextId = $mapLines.Count + 1
    foreach ($filePath in $foundFiles) {
        if ([string]::IsNullOrWhiteSpace($filePath)) { continue }
        if ($existingPaths.ContainsKey($filePath)) { continue }

        $id = "ID_$nextId"; $nextId++
        Add-Content -Path $MapFile -Value "$id | $filePath"

        if (Test-Path -LiteralPath $filePath) {
            $filename = Split-Path $filePath -Leaf
            Copy-Item -LiteralPath $filePath -Destination (Join-Path $BackupDir "${id}_$filename") -Force -ErrorAction SilentlyContinue

            $igpuPath = Join-Path $IgpuProfiles $id
            if (-not (Test-Path $igpuPath)) { Copy-Item -LiteralPath $filePath -Destination $igpuPath -Force -ErrorAction SilentlyContinue }

            $egpuPath = Join-Path $EgpuProfiles $id
            if (-not (Test-Path $egpuPath)) { Copy-Item -LiteralPath $filePath -Destination $egpuPath -Force -ErrorAction SilentlyContinue }
        }
    }
}

## ============================================================
## STEAM SHADER CACHE SWAP
## ============================================================
function Swap-SteamShaderCache {
    param([string]$GpuTag)
    $ShaderCache = Join-Path $SteamRoot "steamapps\shadercache"
    $TargetCache = "$ShaderCache.$GpuTag"

    if (-not (Test-Path $TargetCache)) { New-Item -ItemType Directory -Path $TargetCache -Force | Out-Null }

    if (Test-Path $ShaderCache) {
        $item = Get-Item $ShaderCache -Force
        if ($item.LinkType -eq 'SymbolicLink' -or $item.LinkType -eq 'Junction') {
            Remove-Item $ShaderCache -Force -ErrorAction SilentlyContinue
        } elseif ($item.PSIsContainer) {
            $currentTag = if ($GpuTag -eq 'egpu') { 'igpu' } else { 'egpu' }
            $oppositeCache = "$ShaderCache.$currentTag"
            if (-not (Test-Path $oppositeCache)) { New-Item -ItemType Directory -Path $oppositeCache -Force | Out-Null }
            Get-ChildItem $ShaderCache -ErrorAction SilentlyContinue | ForEach-Object { Move-Item $_.FullName $oppositeCache -Force -ErrorAction SilentlyContinue }
            Remove-Item $ShaderCache -Force -Recurse -ErrorAction SilentlyContinue
        }
    }
    cmd /c mklink /J "$ShaderCache" "$TargetCache" 2>$null
}

## ============================================================
## PERFORM SWAP
## ============================================================
function Invoke-PerformSwap {
    param([string]$TargetState)
    $currentState = if (Test-Path $StateFile) { (Get-Content $StateFile -Raw).Trim() } else { 'unknown' }

    if ($TargetState -eq $currentState -and $currentState -ne 'unknown') {
        Write-Host "Already in $TargetState mode — nothing to do."
        return
    }

    $saveToDir = ""; $loadFromDir = ""
    if ($TargetState -eq 'egpu') {
        $loadFromDir = $EgpuProfiles
        if ($currentState -eq 'igpu') { $saveToDir = $IgpuProfiles }
    } else {
        $loadFromDir = $IgpuProfiles
        if ($currentState -eq 'egpu') { $saveToDir = $EgpuProfiles }
    }

    if (Test-Path $MapFile) {
        foreach ($line in Get-Content $MapFile) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $parts = $line -split '\|', 2
            $id = $parts[0].Trim(); $filepath = $parts[1].Trim()

            # First run backup to both
            if ($currentState -eq 'unknown' -and (Test-Path -LiteralPath $filepath)) {
                Copy-Item -LiteralPath $filepath -Destination (Join-Path $IgpuProfiles $id) -Force -ErrorAction SilentlyContinue
                Copy-Item -LiteralPath $filepath -Destination (Join-Path $EgpuProfiles $id) -Force -ErrorAction SilentlyContinue
            }

            # Normal backup
            if ($saveToDir -ne '' -and (Test-Path -LiteralPath $filepath) -and -not $DryRun) {
                Copy-Item -LiteralPath $filepath -Destination (Join-Path $saveToDir $id) -Force -ErrorAction SilentlyContinue
            }

            # Apply target profile
            $profilePath = Join-Path $loadFromDir $id
            if (Test-Path -LiteralPath $profilePath -and -not $DryRun) {
                $targetDir = Split-Path $filepath -Parent
                if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
                Copy-Item -LiteralPath $profilePath -Destination $filepath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if (-not $DryRun) {
        Swap-SteamShaderCache $TargetState
        Set-Content -Path $StateFile -Value $TargetState
        Write-InfoLog "State updated: Now in $TargetState mode"
    }

    # Send Notification
    $gpuLabel = if ($TargetState -eq 'egpu') { "eGPU" } else { "iGPU" }
    if ($DryRun) {
        Show-Notification -Title "GPU Swap Dry Run" -Message "Tested switch to $gpuLabel mode. No files changed."
    } else {
        Show-Notification -Title "GPU Swap Complete" -Message "Successfully switched to $gpuLabel mode."
    }
}

## ============================================================
## HELP & MAIN
## ============================================================
function Show-Help {
    Write-Host "ROG Ally X GPU Config Automation v1.2"
    Write-Host "Usage: .\docksettings.ps1 -Gpu <igpu|egpu> [-DryRun]"
}

if ($Help) { Show-Help; exit 0 }

# Lock logic
if (Test-Path $LockFile) {
    $lockPid = (Get-Content $LockFile -Raw).Trim()
    if (Get-Process -Id $lockPid -ErrorAction SilentlyContinue) { Write-Host "[ERROR] Another instance running."; exit 1 }
    Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
}
$PID | Out-File $LockFile -Encoding ascii

if (-not (Test-Path $StateFile)) { "unknown" | Set-Content $StateFile }

Invoke-CrawlAndRegister
if ($Gpu) { Invoke-PerformSwap $Gpu } else { Show-Help }
