<#
.SYNOPSIS
  Looks for a NanaZip release newer than the one recorded in version.txt and, if found,
  opens a pull request that bumps version.txt.
.PARAMETER RecreateClosed
  Treat a closed (not merged) pull request for the release branch as not handled and open a new one.
  Set by the manual run of the workflow (env RECREATE_CLOSED=true); the daily run never recreates a pull
  request that was closed on purpose.
.PARAMETER DryRun
  Only print what would be done (no download, no git, no pull request).
.NOTES
  In GitHub Actions, GH_TOKEN (or GITHUB_TOKEN) must be set. Requires git and gh.
#>
param (
  [string]$UpstreamRepo = 'M2Team/NanaZip',
  [switch]$DryRun,
  [switch]$RecreateClosed = ($env:RECREATE_CLOSED -eq 'true')
)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$versionFile = Join-Path $root 'version.txt'

function Get-NormalizedVersion([string]$tag) {
  $v = [version]($tag.TrimStart('v'))
  return "$($v.Major).$($v.Minor).$([Math]::Max($v.Build, 0))"
}

$current = (Get-Content $versionFile -Raw).Trim()

# Filtering is done by gh/jq (same result on Windows PowerShell 5.1 and PowerShell 7). Authenticated through
# GH_TOKEN in GitHub Actions; the same call works locally with `gh auth login`.
# /releases/latest returns the newest non-draft, non-prerelease release. The releases *list* endpoint was
# observed answering "200 []" about one call in three, so it is not used. A few retries guard against other glitches.
$release = $null
for ($attempt = 1; $attempt -le 4 -and -not $release; $attempt++) {
  if ($attempt -gt 1) { Write-Warning "No usable answer from the GitHub API (attempt $($attempt - 1)/4), retrying in 10 s."; Start-Sleep -Seconds 10 }
  $releaseJson = gh api "repos/$UpstreamRepo/releases/latest"
  if ($LASTEXITCODE -ne 0) { throw "gh api failed with exit code $LASTEXITCODE" }
  $candidate = ($releaseJson -join "`n") | ConvertFrom-Json
  if ($candidate -and $candidate.tag_name -and -not $candidate.prerelease -and -not $candidate.draft) { $release = $candidate }
}
if (-not $release) { throw "No stable release found on $UpstreamRepo after 4 attempts (last answer: $($releaseJson -join ' '))." }$asset = $release.assets | Where-Object { $_.name -match '^NanaZip_.*\.msixbundle$' } | Select-Object -First 1
if (-not $asset) { throw "Asset NanaZip_*.msixbundle not found in release $($release.tag_name)" }

$latest = Get-NormalizedVersion $release.tag_name
Write-Host "Packaged version (version.txt): $current"
Write-Host "Latest stable release         : $latest ($($release.tag_name))"

if ([version]$latest -le [version]$current) {
  Write-Host 'Up to date, nothing to do.'
  return
}

$branch = "release/nanazip-$latest"

# Native commands do not honor $ErrorActionPreference: fail on any non-zero exit code.
function Invoke-Native {
  $output = & $args[0] $args[1..($args.Count - 1)]
  if ($LASTEXITCODE -ne 0) { throw "Command failed with exit code ${LASTEXITCODE}: $($args -join ' ')" }
  return $output
}

# The CI run started by the dispatch is not attached to the pull request (empty checks list), so wait for
# its end and report the result in a pull request comment. Never fatal, and bounded in time: the run status
# can lag behind its jobs on GitHub's side (a run was seen "in progress" long after its job had succeeded),
# so the jobs are looked at as well.
function Write-CiResult([string]$Branch, [string]$PullRequest) {
  try {
    $run = $null
    for ($i = 0; $i -lt 12 -and -not $run; $i++) {
      Start-Sleep -Seconds 5
      $json = (Invoke-Native gh run list --branch $Branch --event workflow_dispatch --limit 1 --json 'databaseId,url') -join "`n" | ConvertFrom-Json
      $run = foreach ($r in $json) { $r }
    }
    if (-not $run) { throw 'CI run not found' }

    $conclusion = $null
    for ($i = 0; $i -lt 60 -and -not $conclusion; $i++) {   # 5 minutes at most
      Start-Sleep -Seconds 5
      $info = (Invoke-Native gh run view $run.databaseId --json 'status,conclusion,jobs') -join "`n" | ConvertFrom-Json
      if ($info.status -eq 'completed') { $conclusion = $info.conclusion; continue }
      $jobs = @(foreach ($j in $info.jobs) { $j })
      if ($jobs.Count -gt 0 -and -not ($jobs | Where-Object { $_.status -ne 'completed' })) {
        $conclusion = if ($jobs | Where-Object { $_.conclusion -ne 'success' }) { 'failure' } else { 'success' }
      }
    }
    if (-not $conclusion) { $conclusion = 'still running after 5 minutes' }
    Invoke-Native gh pr comment $PullRequest --body "**CI: $conclusion** - $($run.url)" | Out-Null
    Write-Host "CI result posted on the pull request: $conclusion"
  } catch {
    Write-Warning "Could not report the CI result on the pull request: $_"
  }
}
if ($DryRun) {
  Write-Host "[DryRun] would create branch $branch, bump version.txt to $latest and open a pull request."
  return
}

# Every step is idempotent so that a partially failed run is repaired by the next one.
$branchExists = [bool](Invoke-Native git ls-remote --heads origin $branch)
$prsJson = ((Invoke-Native gh pr list --head $branch --state all --json 'number,state') -join "`n") | ConvertFrom-Json
$prs = @(foreach ($pr in $prsJson) { $pr })
$openPrs = @($prs | Where-Object { $_.state -eq 'OPEN' })
$merged = @($prs | Where-Object { $_.state -eq 'MERGED' })
# A closed (not merged) pull request is a refusal: it is only ignored when recreating is requested.
$ignoreClosed = $RecreateClosed -and $merged.Count -eq 0
if ($openPrs.Count -eq 0 -and $prs.Count -gt 0 -and -not $ignoreClosed) {
  Write-Host "The pull request for $branch was already handled ($($prs[0].state)), nothing to do."
  return
}
if ($openPrs.Count -gt 0) {
  Write-Host "A pull request is already open for $branch."
  # Pull requests opened with GITHUB_TOKEN do not trigger workflows: make sure the checks were started.
  $ciRuns = @(Invoke-Native gh run list --branch $branch --json workflowName --jq '.[].workflowName') -contains 'CI'
  if (-not $ciRuns) {
    Write-Host 'No CI run found for this branch, starting it.'
    Invoke-Native gh workflow run ci.yml --ref $branch | Out-Null
    Write-CiResult $branch ([string]$openPrs[0].number)
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
$prUrl = $body | gh pr create --base master --head $branch --title "Update NanaZip to $latest" --body-file -
if ($LASTEXITCODE -ne 0) { throw "gh pr create failed with exit code $LASTEXITCODE" }
Write-Host "Pull request: $prUrl"

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

Write-CiResult $branch $prUrl
