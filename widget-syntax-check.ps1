# ASCII-purity + syntax + compile check for the widget (ASCII-only checker)
$target = 'C:\Users\z\.litellm-widget\litellm-widget.ps1'
$lines = Get-Content $target

$bad = @()
for ($i = 0; $i -lt $lines.Count; $i++) {
  if ($lines[$i].ToCharArray() | Where-Object { [int]$_ -gt 127 }) {
    $bad += ("  line {0}: {1}" -f ($i+1), $lines[$i].Substring(0, [Math]::Min(60, $lines[$i].Length)))
  }
}
if ($bad.Count -gt 0) { Write-Output 'NON-ASCII lines found:'; $bad; exit 1 }
Write-Output ('whole file is pure ASCII (' + $lines.Count + ' lines)')

$start = -1; $end = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
  if ($lines[$i] -eq "`$source = @'") { $start = $i + 1; continue }
  if ($start -ge 0 -and $lines[$i] -eq "'@") { $end = $i; break }
}
if ($start -lt 0 -or $end -lt 0) { Write-Output ("ERROR: here-string not located"); exit 1 }
$cs = ($lines[$start..($end - 1)] -join "`n")

$tokens = $null; $errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors -and $errors.Count -gt 0) {
  $errors | ForEach-Object { Write-Output ("SYNTAX ERROR line {0}: {1}" -f $_.Extent.StartLineNumber, $_.Message) }
  exit 1
}
Write-Output 'ps1 syntax OK'

try {
  Add-Type -TypeDefinition $cs -ReferencedAssemblies @(
    'System.dll','System.Core.dll','System.Drawing.dll','System.Windows.Forms.dll','System.Net.Http.dll') -OutputAssembly "$env:TEMP\litellm-widget-check.dll"
  Write-Output 'C# compile OK'
} catch {
  Write-Output ('C# COMPILE FAILED: ' + $_.Exception.Message)
  if ($_.Exception.InnerException) { Write-Output ('inner: ' + $_.Exception.InnerException.Message) }
  exit 1
}
