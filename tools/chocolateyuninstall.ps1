$ErrorActionPreference = 'Stop';

$AppxPackageName = "40174MouriNaruto.NanaZip"

# Run in Windows PowerShell so the Appx module loads regardless of the host
$logFile = Join-Path $env:TEMP "nanazip-uninstall-$PID.log"
$uninstallCommand = @"
`$ErrorActionPreference = 'Stop'
try {
  Import-Module Appx -Force
  Get-AppxPackage -Name '$AppxPackageName' -AllUsers | Remove-AppxPackage -AllUsers
} catch {
  `$_ | Out-String | Set-Content -Path '$logFile'
  exit 1
}
"@
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($uninstallCommand))

$result = Start-Process powershell.exe -ArgumentList "-NoProfile", "-EncodedCommand", $encoded -Wait -PassThru -WindowStyle Hidden

if ($result.ExitCode -ne 0) {
  $details = if (Test-Path $logFile) { Get-Content $logFile -Raw } else { "exit code $($result.ExitCode)" }
  Remove-Item $logFile -ErrorAction SilentlyContinue
  throw "Failed to uninstall NanaZip package: $details"
}
