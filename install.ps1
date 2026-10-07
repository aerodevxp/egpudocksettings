<#
.SYNOPSIS
    Self-installer for docksettings GPU config automation
#>

#Requires -RunAsAdministrator

$InstallDir    = "C:\docksettings"
$TaskName      = "GPU_Watcher"

function Write-Step  { param([string]$m) Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Ok    { param([string]$m) Write-Host "[+] $m" -ForegroundColor Green }

Write-Step "Checking prerequisites..."
$sourceScript = Join-Path $PSScriptRoot "docksettings.ps1"
if (-not (Test-Path $sourceScript)) { Write-Host "[-] docksettings.ps1 not found!" -ForegroundColor Red; exit 1 }

Write-Step "Creating install directory: $InstallDir"
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

Write-Step "Installing docksettings.ps1..."
Copy-Item -LiteralPath $sourceScript -Destination "$InstallDir\docksettings.ps1" -Force

Write-Step "Generating gpu_watcher.ps1..."
$watcherScript = @'
$ScriptPath    = "C:\docksettings\docksettings.ps1"
$DetectionMode = "auto"
$PollInterval  = 5
$LogFile       = "$env:TEMP\gpu_watcher.log"

function Get-ActiveGpus {
    return Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -and $_.Name -notmatch "Microsoft Basic Render Driver" -and $_.Name -notmatch "Microsoft Remote Display Adapter"
    }
}

function Test-EgpuPresent {
    $gpus = Get-ActiveGpus
    if ($DetectionMode -eq "auto") { return $gpus.Count -gt 1 }
    return $false
}

function Write-Log { param([string]$Msg); $ts = Get-Date -Format "dd-MM-yyyy HH:mm:ss"; Add-Content -Path $LogFile -Value "$ts $Msg" }

$lastState = ""
Start-Sleep -Seconds 10

while ($true) {
    try {
        $hasEgpu = Test-EgpuPresent
        if ($hasEgpu -and $lastState -ne "egpu") {
            Write-Log "eGPU detected — triggering swap"
            Start-Process powershell.exe -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`" -Gpu egpu" -Wait
            $lastState = "egpu"
        } elseif (-not $hasEgpu -and $lastState -ne "igpu" -and $lastState -ne "") {
            Write-Log "eGPU disconnected — triggering swap"
            Start-Process powershell.exe -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`" -Gpu igpu" -Wait
            $lastState = "igpu"
        } elseif ($lastState -eq "") {
            $lastState = if ($hasEgpu) { "egpu" } else { "igpu" }
        }
    } catch { Write-Log "Error: $_" }
    Start-Sleep -Seconds $PollInterval
}
'@
$watcherScript | Out-File -FilePath "$InstallDir\gpu_watcher.ps1" -Encoding utf8 -Force

Write-Step "Creating desktop shortcuts..."
$desktop = [Environment]::GetFolderPath("Desktop")
$shell = New-Object -ComObject WScript.Shell
$shortcuts = @{ "Switch to iGPU.lnk" = "igpu"; "Switch to eGPU.lnk" = "egpu" }
foreach ($sc in $shortcuts.GetEnumerator()) {
    $lnk = $shell.CreateShortcut(Join-Path $desktop $sc.Key)
    $lnk.TargetPath = "powershell.exe"
    $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$InstallDir\docksettings.ps1`" -Gpu $($sc.Value)"
    $lnk.WorkingDirectory = $InstallDir
    $lnk.Save()
}

Write-Step "Registering scheduled task: $TaskName"
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$InstallDir\gpu_watcher.ps1`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)

# Run as the current user so GUI notifications work!
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Write-Ok "Task registered: $TaskName"

Write-Step "Starting watcher..."
Start-ScheduledTask -TaskName $TaskName
Write-Ok "Watcher started"

Write-Host "Installation complete!" -ForegroundColor Green
