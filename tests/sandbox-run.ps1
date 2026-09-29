# Runs INSIDE Windows Sandbox (started by the generated .wsb). Not meant to be run on the host.
$ErrorActionPreference = 'Continue'
$resultDir = 'C:\results'
Start-Transcript -Path "$resultDir\sandbox.log" -Force | Out-Null

$config     = Get-Content 'C:\pkg\config.json' -Raw | ConvertFrom-Json
$newVersion = $config.NewVersion
$oldVersion = $config.OldVersion

$results = [ordered]@{}
function Step($name, [scriptblock]$body) {
  Write-Host "`n=== $name ===" -ForegroundColor Cyan
  try { $ok = & $body } catch { Write-Host $_ -ForegroundColor Red; $ok = $false }
  $results[$name] = [bool]$ok
  Write-Host ("{0}: {1}" -f $name, $(if ($ok) { 'OK' } else { 'FAILED' })) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
}

# Installed NanaZip version as seen by Windows (Appx), or $null when not installed
function NanaZipVersion {
  $pkg = Get-AppxPackage -AllUsers -Name '40174MouriNaruto.NanaZip' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($pkg) { return ([version]$pkg.Version).ToString(3) }
  return $null
}
# Prints the installed version (Appx + Chocolatey) and returns whether it matches $expected ($null = not installed)
function CheckVersion($expected) {
  $actual = NanaZipVersion
  Write-Host ("  Appx version       : {0}" -f $(if ($actual) { $actual } else { '<not installed>' }))
  Write-Host ("  Chocolatey version : {0}" -f ((choco list nanazip --limit-output) -join ''))
  Write-Host ("  Expected           : {0}" -f $(if ($expected) { $expected } else { '<not installed>' }))
  return ($actual -eq $expected)
}

Step 'Install Chocolatey' {
  Set-ExecutionPolicy Bypass -Scope Process -Force
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
  Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
  $env:Path += ";$env:ALLUSERSPROFILE\chocolatey\bin"
  [bool](Get-Command choco -ErrorAction SilentlyContinue)
}

# --- Scenario 1: fresh install of the new package ---
Step "Fresh install $newVersion" {
  choco install nanazip --version $newVersion -s C:\pkg -y --no-progress
  ($LASTEXITCODE -eq 0) -and (CheckVersion $newVersion)
}
Step 'Uninstall' {
  choco uninstall nanazip -y --no-progress
  ($LASTEXITCODE -eq 0) -and (CheckVersion $null)
}

# --- Scenario 2: upgrade from the old package ---
if ($oldVersion) {
  Step "Install old version $oldVersion" {
    choco install nanazip --version $oldVersion -s C:\pkg -y --no-progress
    ($LASTEXITCODE -eq 0) -and (CheckVersion $oldVersion)
  }
  Step "Upgrade $oldVersion -> $newVersion" {
    choco upgrade nanazip -s C:\pkg -y --no-progress
    ($LASTEXITCODE -eq 0) -and (CheckVersion $newVersion)
  }
} else {
  Write-Host "`nNo old package provided: upgrade scenario skipped." -ForegroundColor Yellow
  Step "Install $newVersion" {
    choco install nanazip --version $newVersion -s C:\pkg -y --no-progress
    ($LASTEXITCODE -eq 0) -and (CheckVersion $newVersion)
  }
}

# --- Scenario 3: reinstall same version, then final uninstall ---
Step 'Reinstall with --force (same version)' {
  choco upgrade nanazip -s C:\pkg -y -f --no-progress
  ($LASTEXITCODE -eq 0) -and (CheckVersion $newVersion)
}
Step 'Final uninstall' {
  choco uninstall nanazip -y --no-progress
  ($LASTEXITCODE -eq 0) -and (CheckVersion $null)
}

Write-Host "`n================ SUMMARY ================" -ForegroundColor Cyan
$results.GetEnumerator() | ForEach-Object { Write-Host ("{0,-45} {1}" -f $_.Key, $(if ($_.Value) { 'OK' } else { 'FAILED' })) }
$results.GetEnumerator() | ForEach-Object { "{0}`t{1}" -f $_.Key, $_.Value } | Set-Content "$resultDir\summary.txt"
Stop-Transcript | Out-Null
Write-Host "`nLogs saved on the host (results folder). You can close this window / the Sandbox."
