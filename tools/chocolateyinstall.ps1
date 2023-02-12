$ErrorActionPreference = 'Stop';

$toolsDir       = "$(Split-Path -parent $MyInvocation.MyCommand.Definition)"
$fileName       = "$toolsDir\#REPLACE_FILENAME#"
$version        = "#REPLACE_VERSION#"
$PreRelease     = "False"

$WindowsVersion=[Environment]::OSVersion.Version
if ($WindowsVersion.Major -ne "10") {
  throw "This package requires Windows 10."
}

$IsCorrectBuild=[Environment]::OSVersion.Version.Build
if ($IsCorrectBuild -lt "19041") {
  throw "This package requires at least Windows 10 version 2004/OS build 19041.x."
}

$AppxPackageName = "40174MouriNaruto.NanaZip"

if ($PreRelease -match "True") {
  $AppxPackageName += "Preview"
}

if ((Get-AppxPackage -name $AppxPackageName).Version -Match $version) {
  if($env:ChocolateyForce) {
    # you can't install the same version of an appx package, you need to remove it first
    Write-Host Removing already installed version first.
    Get-AppxPackage -Name $AppxPackageName | Remove-AppxPackage
  } else {
    Write-Host The $version version of NanaZip is already installed. If you want to reinstall use --force
    return
  }
}

Add-AppxPackage -Path $fileName
