<#
.SYNOPSIS
  Tests install / reinstall / uninstall of the packed nupkg in a disposable Windows Sandbox.
.PARAMETER Package
  Path to the .nupkg. Default: newest nanazip.*.nupkg at the repository root.
.PARAMETER OldPackage
  Path to an older .nupkg used to test the upgrade. Default: the second newest nanazip.*.nupkg at the repository root
  (none = upgrade test skipped).
.PARAMETER NoLaunch
  Only prepare the staging folder and the .wsb file, do not start the Sandbox.
.PARAMETER Wait
  Wait for the tests to finish, close the Sandbox afterwards and return $true only if every step succeeded.
.PARAMETER TimeoutMinutes
  Maximum time to wait with -Wait (default 20).
#>
param (
  [string]$Package,
  [string]$OldPackage,
  [switch]$NoLaunch,
  [switch]$Wait,
  [int]$TimeoutMinutes = 20
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

$all = Get-ChildItem $repo -Filter 'nanazip.*.nupkg' |
  Sort-Object { [version]($_.BaseName -replace '^nanazip\.') } -Descending
if (-not $Package) { $Package = $all | Select-Object -First 1 -ExpandProperty FullName }
if (-not $Package -or -not (Test-Path $Package)) { throw "No .nupkg found. Run 'choco pack' (or packVersion.ps1) first." }

if (-not $OldPackage) { $OldPackage = $all | Where-Object { $_.FullName -ne (Resolve-Path $Package).Path } | Select-Object -First 1 -ExpandProperty FullName }
function PkgVersion($path) { if ($path) { (Split-Path $path -Leaf) -replace '^nanazip\.' -replace '\.nupkg$' } }
$newVersion = PkgVersion $Package
$oldVersion = PkgVersion $OldPackage
if ($oldVersion -and [version]$oldVersion -ge [version]$newVersion) { throw "Old package ($oldVersion) must be older than the tested package ($newVersion)." }

$stale = Get-ChildItem (Join-Path $repo 'tools') -Filter '*.ps1' |
  Where-Object { $_.LastWriteTime -gt (Get-Item $Package).LastWriteTime }
if ($stale) { Write-Warning "The package is older than: $($stale.Name -join ', '). Repack before testing." }

if (-not $NoLaunch -and -not (Get-Command WindowsSandbox.exe -ErrorAction SilentlyContinue)) {
  throw @"
Windows Sandbox is not enabled. In an ADMIN PowerShell run:
  Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All
then reboot (virtualization must be enabled in the BIOS/UEFI).
"@
}

$work    = Join-Path $env:TEMP 'nanazip-sandbox'
$pkgDir  = Join-Path $work 'pkg'
$results = Join-Path $work 'results'
Remove-Item (Join-Path $work '*') -Recurse -Force -ErrorAction SilentlyContinue
New-Item $pkgDir, $results -ItemType Directory -Force | Out-Null
Copy-Item $Package $pkgDir
if ($OldPackage) { Copy-Item $OldPackage $pkgDir }
@{ NewVersion = $newVersion; OldVersion = $oldVersion; AutoClose = [bool]$Wait } | ConvertTo-Json | Set-Content (Join-Path $pkgDir 'config.json')
Copy-Item (Join-Path $PSScriptRoot 'sandbox-run.ps1') $pkgDir

$wsb = Join-Path $work 'nanazip-test.wsb'
# Paths are written into XML: escape &, <, >, quotes
$pkgDirXml   = [System.Security.SecurityElement]::Escape($pkgDir)
$resultsXml  = [System.Security.SecurityElement]::Escape($results)
@"
<Configuration>
  <Networking>Enable</Networking>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$pkgDirXml</HostFolder>
      <SandboxFolder>C:\pkg</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$resultsXml</HostFolder>
      <SandboxFolder>C:\results</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe -NoExit -ExecutionPolicy Bypass -File C:\pkg\sandbox-run.ps1</Command>
  </LogonCommand>
</Configuration>
"@ | Set-Content -Path $wsb -Encoding UTF8

Write-Host "Package : $Package ($newVersion)"
Write-Host "Old pkg : $(if ($OldPackage) { "$OldPackage ($oldVersion)" } else { '<none>, upgrade test skipped' })"
Write-Host "Config  : $wsb"
Write-Host "Results : $results (summary.txt, sandbox.log)"
if ($NoLaunch) { return }

Write-Host "Starting Windows Sandbox..."
Start-Process WindowsSandbox.exe -ArgumentList "`"$wsb`""

if (-not $Wait) { return }

# Wait for the summary written by sandbox-run.ps1, then report the result
$summaryFile = Join-Path $results 'summary.txt'
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
Write-Host "Waiting for the tests to finish (timeout: $TimeoutMinutes min)..."
while (-not (Test-Path $summaryFile) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 5 }
if (-not (Test-Path $summaryFile)) {
  Write-Warning "Timeout: no result after $TimeoutMinutes minutes. Log: $(Join-Path $results 'sandbox.log')"
  return $false
}

$steps = @(Get-Content $summaryFile | Where-Object { $_ } | ForEach-Object {
  $name, $value = $_ -split "`t"
  [pscustomobject]@{ Step = $name; Passed = ($value -eq 'True') }
})
foreach ($s in $steps) {
  Write-Host ("  {0,-45} {1}" -f $s.Step, $(if ($s.Passed) { 'OK' } else { 'FAILED' })) -ForegroundColor $(if ($s.Passed) { 'Green' } else { 'Red' })
}
Write-Host "Log: $(Join-Path $results 'sandbox.log')"
return [bool](($steps.Count -gt 0) -and -not ($steps | Where-Object { -not $_.Passed }))