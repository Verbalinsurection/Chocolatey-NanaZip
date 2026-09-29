<#
.SYNOPSIS
  Looks for a NanaZip release newer than the one recorded in version.txt and, if found,
  opens a pull request that bumps version.txt.
.PARAMETER DryRun
  Only print what would be done (no download, no git, no pull request).
.NOTES
  In GitHub Actions, GH_TOKEN (or GITHUB_TOKEN) must be set. Requires git and gh.
#>
param (
  [string]$UpstreamRepo = 'M2Team/NanaZip',
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$versionFile = Join-Path $root 'version.txt'

function Get-NormalizedVersion([string]$tag) {
  $v = [version]($tag.TrimStart('v'))
  return "$($v.Major).$($v.Minor).$([Math]::Max($v.Build, 0))"
}

$current = (Get-Content $versionFile -Raw).Trim()

$headers = @{}
$token = if ($env:GH_TOKEN) { $env:GH_TOKEN } else { $env:GITHUB_TOKEN }
if ($token) { $headers.Authorization = "Bearer $token" }
$releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$UpstreamRepo/releases?per_page=20" -Headers $headers
$release = $releases | Where-Object { -not $_.prerelease -and -not $_.draft } | Select-Object -First 1
if (-not $release) { throw "No stable release found on $UpstreamRepo" }
$asset = $release.assets | Where-Object { $_.name -match '^NanaZip_.*\.msixbundle$' } | Select-Object -First 1
if (-not $asset) { throw "Asset NanaZip_*.msixbundle not found in release $($release.tag_name)" }

$latest = Get-NormalizedVersion $release.tag_name
Write-Host "Packaged version (version.txt): $current"
Write-Host "Latest stable release         : $latest ($($release.tag_name))"

if ([version]$latest -le [version]$current) {
  Write-Host 'Up to date, nothing to do.'
  return
}

$branch = "release/nanazip-$latest-t3"

# Native commands do not honor $ErrorActionPreference: fail on any non-zero exit code.
function Invoke-Native {
  $output = & $args[0] $args[1..($args.Count - 1)]
  if ($LASTEXITCODE -ne 0) { throw "Command failed with exit code ${LASTEXITCODE}: $($args -join ' ')" }
  return $output
}

if ($DryRun) {
  Write-Host "[DryRun] would create branch $branch, bump version.txt to $latest and open a pull request."
  return
}

# Every step is idempotent so that a partially failed run is repaired by the next one.
$branchExists = [bool](Invoke-Native git ls-remote --heads origin $branch)
$prsJson = ((Invoke-Native gh pr list --head $branch --state all --json 'number,state') -join "`n") | ConvertFrom-Json
$prs = @(foreach ($pr in $prsJson) { $pr })
if ($prs.Count -gt 0) {
  # Closed or merged: already handled (the branch may have been deleted), never start anything.
  if (-not ($prs | Where-Object { $_.state -eq 'OPEN' })) {
    Write-Host "The pull request for $branch was already handled ($($prs[0].state)), nothing to do."
    return
  }
  Write-Host "A pull request is already open for $branch."
  # Pull requests opened with GITHUB_TOKEN do not trigger workflows: make sure the checks were started.
  $ciRuns = @(Invoke-Native gh run list --branch $branch --json workflowName --jq '.[].workflowName') -contains 'CI'
  if (-not $ciRuns) {
    Write-Host 'No CI run found for this branch, starting it.'
    Invoke-Native gh workflow run ci.yml --ref $branch | Out-Null
  }
  return
}
$tmp = Join-Path ([IO.Path]::GetTempPath()) $asset.name
Write-Host "Downloading $($asset.browser_download_url)"
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmp
$sha256 = (Get-FileHash $tmp -Algorithm SHA256).Hash
Remove-Item $tmp

if ($branchExists) {
  Write-Host "Branch $branch already exists without pull request, creating the pull request."
} else {
  Invoke-Native git config user.name 'github-actions[bot]' | Out-Null
  Invoke-Native git config user.email '41898282+github-actions[bot]@users.noreply.github.com' | Out-Null
  Invoke-Native git checkout -b $branch | Out-Null
  [IO.File]::WriteAllText($versionFile, "$latest`n")
  Invoke-Native git add version.txt | Out-Null
  Invoke-Native git commit -m "Update NanaZip to $latest" | Out-Null
  Invoke-Native git push origin $branch | Out-Null
}

$body = @"
New stable NanaZip release detected: **$($release.tag_name)** (was ``$current``).

| | |
|---|---|
| Release | $($release.html_url) |
| Asset | ``$($asset.name)`` |
| SHA256 | ``$sha256`` |

## Checklist
- [ ] Checks of this PR are green
- [ ] ``git fetch && git checkout $branch``
- [ ] ``.\packVersion.ps1`` (packs, tests the package in Windows Sandbox, then asks before pushing to Chocolatey)
- [ ] A local ``choco upgrade nanazip -s . -f``
- [ ] Merge this PR once the package is published
"@
$body | gh pr create --base master --head $branch --title "Update NanaZip to $latest" --body-file -
if ($LASTEXITCODE -ne 0) { throw "gh pr create failed with exit code $LASTEXITCODE" }

# Pull requests opened with GITHUB_TOKEN do not trigger workflows: run the checks explicitly.
Invoke-Native gh workflow run ci.yml --ref $branch | Out-Null

# A pull request opened by the bot also starts a pull_request run that waits for a manual approval
# ("action_required"). The run dispatched above does the same checks, so remove the pending one
# (it can appear a few seconds after the pull request is created).
try {
  for ($i = 0; $i -lt 6; $i++) {
    Start-Sleep -Seconds 5
    $runs = (Invoke-Native gh run list --branch $branch --event pull_request --json 'databaseId,conclusion') -join "`n" | ConvertFrom-Json
    $pending = @($runs | Where-Object { $_.conclusion -eq 'action_required' })
    foreach ($run in $pending) {
      Write-Host "Removing run $($run.databaseId) waiting for approval."
      Invoke-Native gh run delete $run.databaseId | Out-Null
    }
    if ($pending.Count -gt 0) { break }
  }
} catch {
  Write-Warning "Could not remove the run waiting for approval: $_"
}
