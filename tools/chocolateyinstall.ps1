$ErrorActionPreference = 'Stop';

$toolsDir       = "$(Split-Path -parent $MyInvocation.MyCommand.Definition)"
$fileName       = "$toolsDir\#REPLACE_FILENAME#"
$version        = "#REPLACE_VERSION#"
$AppxPackageName = "40174MouriNaruto.NanaZip"

$WindowsVersion=[Environment]::OSVersion.Version
if ($WindowsVersion.Major -ne "10") {
  throw "This package requires Windows 10."
}

$IsCorrectBuild=[Environment]::OSVersion.Version.Build
if ($IsCorrectBuild -lt "19041") {
  throw "This package requires at least Windows 10 version 2004/OS build 19041.x."
}

# Same version already installed: Add-AppxPackage would fail, skip unless --force
$installed = Get-AppxPackage -Name $AppxPackageName -ErrorAction SilentlyContinue | Select-Object -First 1
if ($installed) {
  $installedVersion = ([version]$installed.Version).ToString(3)
  if ($installedVersion -eq $version -and -not $env:ChocolateyForce) {
    Write-Host "The $version version of NanaZip is already installed. If you want to reinstall use --force"
    return
  }
}

# Add-AppxPackage -ForceApplicationShutdown only closes the apps of the package. The shell extension
# (context menu) is loaded by other processes, typically a dllhost.exe COM surrogate or explorer.exe, which then
# keep the package in use (error 0x80073D02). Stop the dllhost.exe / NanaZip processes that have a module of the
# installed package loaded: Windows restarts the surrogate on demand. explorer.exe is never stopped.
if ($installed) {
  $installFolder = $installed.InstallLocation
  Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
    $process = $_
    try {
      $usesPackage = ($process.Path -like "$installFolder\*") -or
        ($process.Modules | Where-Object { $_.FileName -like "$installFolder\*" })
      if ($usesPackage -and ($process.Name -eq 'dllhost' -or $process.Name -like 'NanaZip*' -or $process.Name -eq '7zG')) {
        Write-Host "Stopping $($process.Name) (PID $($process.Id)) which uses the installed NanaZip package..."
        Stop-Process -Id $process.Id -Force -ErrorAction Stop
      }
    } catch {
      Write-Verbose "Skipping $($process.Name) (PID $($process.Id)): $_"
    }
  }
  # let Windows release the files
  Start-Sleep -Seconds 2
}
Write-Host "Deploying $fileName (this can take a minute or two)..."

# Run in Windows PowerShell so the Appx module loads regardless of the host
$logFile = Join-Path $env:TEMP "nanazip-install-$PID.log"
$installCommand = @"
`$ErrorActionPreference = 'Stop'
try {
  Import-Module Appx -Force
  Add-AppxPackage -Path '$($fileName.Replace("'", "''"))' -ForceUpdateFromAnyVersion -ForceApplicationShutdown
} catch {
  `$_ | Out-String | Set-Content -Path '$logFile'
  exit 1
}
"@
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($installCommand))

$result = Start-Process powershell.exe -ArgumentList "-NoProfile", "-EncodedCommand", $encoded -Wait -PassThru -WindowStyle Hidden

if ($result.ExitCode -ne 0) {
  $details = if (Test-Path $logFile) { Get-Content $logFile -Raw } else { "exit code $($result.ExitCode)" }
  Remove-Item $logFile -ErrorAction SilentlyContinue
  throw "Failed to install NanaZip package: $details"
}
