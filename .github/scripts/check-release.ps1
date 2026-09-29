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

$branch = "release/nanazip-$latest"
if (-not $DryRun) {
  if (git ls-remote --heads origin $branch) {
    Write-Host "Branch $branch already exists, nothing to do."
    return
  }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) $asset.name
Write-Host "Downloading $($asset.browser_download_url)"
if ($DryRun) {
  Write-Host "[DryRun] would create branch $branch, bump version.txt to $latest and open a pull request."
  return
}
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmp
$sha256 = (Get-FileHash $tmp -Algorithm SHA256).Hash
Remove-Item $tmp

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git checkout -b $branch
[IO.File]::WriteAllText($versionFile, "$latest`n")
git add version.txt
git commit -m "Update NanaZip to $latest"
git push origin $branch

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
- [ ] ``.\packVersion.ps1`` (packs and, on confirmation, pushes to Chocolatey)
- [ ] ``.\tests\Test-InSandbox.ps1`` and a local ``choco upgrade nanazip -s . -f``
- [ ] Merge this PR once the package is published
"@
$body | gh pr create --base master --head $branch --title "Update NanaZip to $latest" --body-file -

# Pull requests opened with GITHUB_TOKEN do not trigger workflows: run the checks explicitly.
gh workflow run ci.yml --ref $branch
