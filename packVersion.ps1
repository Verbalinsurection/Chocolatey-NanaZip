param (
  [Alias('f')]
    [switch]$force = $false,
  [Alias('d')]
    [switch]$debug = $false,
  [Alias('np')]
    [switch]$noPrompt = $false,
  [Alias('v')]
    [string]$fversion = [string]::Empty,
  [Alias('ss')]
    [switch]$skipSandbox = $false
)
if ($Debug) { $DebugPreference = 'Continue' }

function getNormVerion {
  param (
    [string]$version
  )
  $version = $version.TrimStart('v')
  if ($version.length -lt 3) {
    $nver = [Version]::new([int]$version, 0, 0, 0)
  } else {
    $nver = [Version] $version
    if($nver.Minor -eq -1) {$nver = [Version]::new($nver.Major, 0, 0, 0)}
    if($nver.Build -eq -1) {$nver = [Version]::new($nver.Major, $nver.Minor, 0, 0)}
    if($nver.Revision -eq -1) {$nver = [Version]::new($nver.Major, $nver.Minor, $nver.Build, 0)}
  }
  return "$($nver.Major).$($nver.Minor).$($nver.Build)"
}

function ReplaceInFile {
  param (
    [string]$FilePath,
    [string[]]$SrcText,
    [string[]]$TargetText
  )

  $utf8 = New-Object System.Text.UTF8Encoding $false
  $fullPath = Join-Path $PSScriptRoot $FilePath
  $RawData = [System.IO.File]::ReadAllText($fullPath, $utf8)
  for ($index = 0; $index -lt $SrcText.count; $index++) {
    $RawData = $RawData.Replace($SrcText[$index], $TargetText[$index])
  }
  [System.IO.File]::WriteAllText($fullPath, $RawData, $utf8)
}

function GetGithubInfos {
  param (
    [string]$repo
  )

  # The releases *list* endpoint sometimes answers "200 []" (observed about one call in three), so it is not
  # used: /releases/latest gives the newest stable release, /releases/tags/<tag> a given one. A few retries
  # guard against other glitches.
  $headers = @{}
  if ($env:GITHUB_TOKEN) { $headers.Authorization = "Bearer $env:GITHUB_TOKEN" }
  $urls = if ($fversion -eq [string]::Empty) {
    @("https://api.github.com/repos/$repo/releases/latest")
  } else {
    $tag = $fversion.TrimStart('v')
    @("https://api.github.com/repos/$repo/releases/tags/$tag", "https://api.github.com/repos/$repo/releases/tags/v$tag")
  }

  $release = $null
  foreach ($url in $urls) {
    Write-Debug "Get Github infos: $url"
    for ($attempt = 1; $attempt -le 4 -and -not $release; $attempt++) {
      if ($attempt -gt 1) { Write-Debug "  retry $attempt"; Start-Sleep -Seconds 5 }
      try {
        $candidate = Invoke-RestMethod -Uri $url -Headers $headers
        if ($candidate.tag_name -and -not $candidate.draft -and ($fversion -ne [string]::Empty -or -not $candidate.prerelease)) { $release = $candidate }
      } catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { break }
        Write-Debug "  GitHub API error: $_"
      }
    }
    if ($release) { break }
  }
  if (-not $release) { throw "Release not found on $repo" }
  $asset = $release.assets | Where-Object { $_.name -match '^NanaZip_.*\.msixbundle$' } | Select-Object -First 1
  if (-not $asset) { throw "Asset NanaZip_*.msixbundle not found in release $($release.tag_name)" }
  Write-Debug "  Find asset x86_64: $($asset.name)"

  return @{
    Version    = getNormVerion $release.tag_name
    ReleaseUrl = $release.html_url
    URL64      = $asset.browser_download_url
    FileName   = $asset.name
  }
}

function DownloadAsset {
  param ($release)

  Remove-Item -Path (Join-Path $PSScriptRoot 'tools\*.msixbundle') -ErrorAction SilentlyContinue
  $target = Join-Path $PSScriptRoot "tools\$($release.FileName)"
  Invoke-WebRequest -Uri $release.URL64 -OutFile $target
  $hash = (Get-FileHash $target).Hash
  Write-Debug "  FileHash x86_64: $hash"
  return $hash
}

function GetActual {
  param (
    [string]$packageId
  )

  Write-Debug "Get Chocolatey infos: $packageId"
  $chocoVersion = choco search $packageId --by-id-only --exact --limit-output
  if(!$chocoVersion) {
    Write-Warning "Unable to find package on Chocolatey"
    return '0.0.0'
  }
  Write-Debug " Find Chocolatey infos: $chocoVersion"
  return $chocoVersion.split('|')[1]
}

function BackupFiles {
  param (
    [string[]]$FilesToBackup
  )

  Write-Debug "Backup $($FilesToBackup.Count) files"
  $backupDir = Join-Path $PSScriptRoot 'bck'
  if (Test-Path $backupDir) { throw "Directory 'bck' already exists (previous run interrupted?). Restore files from it and remove it." }
  New-Item -Path $backupDir -ItemType Directory | Out-Null

  $backups = [ordered]@{}
  foreach ($file in $FilesToBackup) {
    $backupFile = Join-Path $backupDir ($file.Replace('/', '_'))
    Write-Debug " Copy-Item $file -Destination $backupFile"
    Copy-Item (Join-Path $PSScriptRoot $file) -Destination $backupFile
    $backups[$file] = $backupFile
  }
  return $backups
}

function RestoreFiles {
  param (
    $Backups
  )

  Write-Debug "Restore $($Backups.Count) files"
  foreach ($file in $Backups.Keys) {
    Write-Debug " Copy-Item $($Backups[$file]) -Destination $file -Force"
    Copy-Item $Backups[$file] -Destination (Join-Path $PSScriptRoot $file) -Force
  }
  Remove-Item (Join-Path $PSScriptRoot 'bck') -Recurse
}

###############################################################################
##              Start                                                        ##
###############################################################################
Write-Host "--------------------------------------------------"
Write-Host "Packaging NanaZip"
Write-Host "--------------------------------------------------"

$packageId          = 'nanazip'
$githubRepo         = 'M2Team/NanaZip'
$filesToUpdate      = 'nanazip.nuspec', 'tools/VERIFICATION.txt', 'tools/chocolateyinstall.ps1'

## Get package and web version ##
$latestRelease = GetGithubInfos $githubRepo
$actualVersion = GetActual $packageId
Write-Host "Chocolatey version  : $actualVersion"
Write-Host "Github repo version : $($latestRelease.Version)"

## Check if packaging is needed ##
if([version]$latestRelease.Version -le [version]$actualVersion -And !$force) {
  Write-Warning "No new version available"
  exit
}
Write-Warning "Update available !"

## Download asset and compute checksum ##
$latestRelease.SHA64 = DownloadAsset $latestRelease

## Display release informations ##
Write-Host "--------------------------------------------------"
Write-Host "Url64 : $($latestRelease.URL64)"
Write-Host "Sha64 : $($latestRelease.SHA64)"
Write-Host "--------------------------------------------------"

if(!$noPrompt) {
  $confirmation = Read-Host "Start packing [Y/n]?"
  $confirmation = ('y',$confirmation)[[bool]$confirmation]
  if($confirmation -eq 'n') {exit}
}

## Backup files
$backups = BackupFiles $filesToUpdate

try {
  ## Replace informations in files ##
  foreach ($file in $filesToUpdate) {
    Write-Debug "Update $file"
    ReplaceInFile -FilePath $file `
                  -SrcText '#REPLACE_VERSION#', '#REPLACE_RELEASE_INFO#', '#REPLACE_URL#', '#REPLACE_CHECKSUM#', '#REPLACE_FILENAME#' `
                  -TargetText $latestRelease.Version, $latestRelease.ReleaseUrl, $latestRelease.URL64, $latestRelease.SHA64, $latestRelease.FileName
  }

  ## Pack choco package ##
  if(!$noPrompt) {
    Read-Host -Prompt "Files updated, press any key to continue"
  }
  Write-Debug "Starting 'choco pack'"
  Push-Location $PSScriptRoot
  try { choco pack } finally { Pop-Location }
  if ($LASTEXITCODE -ne 0) { throw "choco pack failed (exit code $LASTEXITCODE)" }
} finally {
  ## Restore files
  RestoreFiles $backups
}

## Test the package in Windows Sandbox before any push ##
$packFileName = Join-Path $PSScriptRoot ($packageId + '.' + $latestRelease.Version + '.nupkg')
if ($skipSandbox) {
  Write-Warning "Sandbox test skipped (-skipSandbox): the package is pushed untested."
} else {
  if (-not (Get-Command WindowsSandbox.exe -ErrorAction SilentlyContinue)) {
    throw "Windows Sandbox is not available (see README to enable it). Use -skipSandbox to bypass the test."
  }
  Write-Host "Testing the package in Windows Sandbox (a few minutes)..."
  $sandboxOk = @(& (Join-Path $PSScriptRoot 'tests\Test-InSandbox.ps1') -Package $packFileName -Wait)[-1]
  if ($sandboxOk -ne $true) {
    Write-Error "Sandbox tests FAILED, package NOT pushed. Package: $packFileName"
    exit 1
  }
  Write-Host "Sandbox tests passed." -ForegroundColor Green
}

## Keep version.txt in sync with the packaged version ##
$versionFile = Join-Path $PSScriptRoot 'version.txt'
if (-not (Test-Path $versionFile) -or (Get-Content $versionFile -Raw).Trim() -ne $latestRelease.Version) {
  [System.IO.File]::WriteAllText($versionFile, "$($latestRelease.Version)`n")
  Write-Warning "version.txt updated to $($latestRelease.Version), don't forget to commit it."
}

## Push choco package (always asks, even with -noPrompt) ##
$confirmation = Read-Host "Push package [Y/n]?"
$confirmation = ('y',$confirmation)[[bool]$confirmation]
if($confirmation -eq 'n') {exit}
choco push $packFileName