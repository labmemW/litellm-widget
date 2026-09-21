# Install autostart: silent VBS launcher + HKCU Run entry (ASCII only)
$dir = Join-Path $env:USERPROFILE '.litellm-widget'

if (-not (Test-Path (Join-Path $dir 'litellm-widget.ps1'))) {
  throw "litellm-widget.ps1 not found in $dir - copy files first"
}

# 1) VBS launcher (CRLF, ASCII) - starts powershell hidden, no console flash
$vbs = @(
  'Set sh = CreateObject("WScript.Shell")',
  ('sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File """ & sh.ExpandEnvironmentStrings("%USERPROFILE%") & "\.litellm-widget\litellm-widget.ps1""", 0, False')
) -join "`r`n"
[System.IO.File]::WriteAllText((Join-Path $dir 'start-widget.vbs'), $vbs, [System.Text.Encoding]::ASCII)
Write-Output ('VBS written: ' + (Join-Path $dir 'start-widget.vbs'))

# 2) HKCU Run entry (ExpandString so %USERPROFILE% resolves at logon)
$runPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
New-ItemProperty -Path $runPath -Name 'LiteLLMWidget' -Value 'wscript.exe "%USERPROFILE%\.litellm-widget\start-widget.vbs"' -PropertyType ExpandString -Force | Out-Null
$check = (Get-ItemProperty -Path $runPath -Name 'LiteLLMWidget').LiteLLMWidget
Write-Output ('Run entry: ' + $check)

# 3) start it now
Start-Process wscript.exe -ArgumentList ('"' + (Join-Path $dir 'start-widget.vbs') + '"')
Write-Output 'widget launched'
