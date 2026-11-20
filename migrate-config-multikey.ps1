# One-shot config migration for the multi-key widget: api_key=... -> api_keys=...
# Backs up config.ini first. Never prints the key value. ASCII only.
$cfg = "$env:USERPROFILE\.litellm-widget\config.ini"
if (-not (Test-Path $cfg)) { Write-Output "ERROR: config.ini not found"; exit 1 }
Copy-Item $cfg "$cfg.bak-multikey" -Force
$lines = Get-Content $cfg
$out = New-Object System.Collections.Generic.List[string]
$migrated = $false
foreach ($l in $lines) {
  if ($l -match '^api_keys=') { $out.Add($l); $migrated = $true; continue }
  if ($l -match '^api_key=(.+)$') { $out.Add('api_keys=' + $Matches[1].Trim()); $migrated = $true; continue }
  $out.Add($l)
}
if (-not $migrated) { Write-Output 'ERROR: no api_key/api_keys line found'; exit 1 }
[System.IO.File]::WriteAllLines($cfg, $out)   # UTF-8 no BOM, same as the widget itself
Write-Output "MIGRATED backup=$cfg.bak-multikey"
