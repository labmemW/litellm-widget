# Restart the widget: kill the old instance (command-line match, exclude own PID),
# then relaunch via the silent VBS starter. ASCII only.
$me = $PID
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | ForEach-Object {
  if ($_.ProcessId -ne $me -and $_.CommandLine -like '*litellm-widget.ps1*') {
    Write-Output ("killing pid " + $_.ProcessId)
    Stop-Process -Id $_.ProcessId -Force
  }
}
Start-Sleep 1
Start-Process wscript.exe -ArgumentList "$env:USERPROFILE\.litellm-widget\start-widget.vbs"
Write-Output 'RESTARTED'
