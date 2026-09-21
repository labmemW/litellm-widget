# Rebuild config.ini from possibly-corrupted single-line content (script file, not inline!)
$dir = Join-Path $env:USERPROFILE '.litellm-widget'
$f = Join-Path $dir 'config.ini'

$raw = [System.IO.File]::ReadAllText($f)
# extract values by regex from whatever shape the file is in
$key = if ($raw -match 'api_key=([A-Za-z0-9_\-]+)') { $matches[1] } else { $null }
$base = if ($raw -match 'base_url=(http://[^\s]+)') { $matches[1] } else { $null }
$model = if ($raw -match 'probe_model=([A-Za-z0-9_\-.]+)') { ($matches[1] -replace 'opacity.*$','') } else { 'Qwen3.8-Flash' }
if (-not $key) { throw 'api_key not recoverable from config.ini' }
if (-not $base) { throw 'base_url not recoverable from config.ini' }
if ($model -notmatch '^[A-Za-z0-9_\-.]+$') { $model = 'Qwen3.8-Flash' }

$lines = @(
  "base_url=$base",
  "api_key=$key",
  "refresh_seconds=60",
  "warn_pct=80",
  "crit_pct=95",
  "probe_model=$model",
  "opacity=0.85"
)
[System.IO.File]::WriteAllLines($f, $lines, [System.Text.Encoding]::ASCII)
Write-Output ("config rebuilt: base={0} key_len={1} model={2}" -f $base, $key.Length, $model)

# verify parse
$check = @{}
Get-Content $f | ForEach-Object { if ($_ -match '^\s*([a-z_]+)\s*=\s*(.*)$') { $check[$matches[1]] = $matches[2].Trim() } }
Write-Output ("verify: {0} keys, base_ok={1}, key_ok={2}, line_count={3}" -f $check.Count, ($check.base_url -like 'http://*'), ($check.api_key.Length -eq 25), (Get-Content $f).Count)

# scrub the leaked debug file
$ls = Join-Path $dir 'last-state.txt'
if (Test-Path $ls) { Remove-Item $ls -Force; Write-Output 'last-state.txt removed (contained leaked key)' }
