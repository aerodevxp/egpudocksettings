Stop-ScheduledTask -TaskName GPU_Watcher
Unregister-ScheduledTask -TaskName GPU_Watcher -Confirm:$false
Remove-Item -Recurse -Force C:\docksettings
Remove-Item "$env:USERPROFILE\Desktop\Switch to iGPU.lnk" -Force
Remove-Item "$env:USERPROFILE\Desktop\Switch to eGPU.lnk" -Force
