# Checks that the package can be built: placeholders replaced with dummy values, dummy msixbundle,
# nuspec is valid XML, required files exist, `choco pack` succeeds without warnings.
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$work = Join-Path ([IO.Path]::GetTempPath()) "nanazip-packcheck-$PID"
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item $work -ItemType Directory | Out-Null

try {
  foreach ($f in 'nanazip.nuspec', 'tools\VERIFICATION.txt', 'tools\LICENSE.txt', 'tools\chocolateyinstall.ps1', 'tools\chocolateyuninstall.ps1') {
    if (-not (Test-Path (Join-Path $root $f))) { throw "Missing required file: $f" }
  }

  $version = (Get-Content (Join-Path $root 'version.txt') -Raw).Trim()
  $fileName = "NanaZip_$version.0.msixbundle"
  Copy-Item (Join-Path $root 'nanazip.nuspec') $work
  Copy-Item (Join-Path $root 'tools') $work -Recurse

  $values = [ordered]@{
    '#REPLACE_VERSION#'      = $version
    '#REPLACE_RELEASE_INFO#' = "https://github.com/M2Team/NanaZip/releases/tag/$version.0"
    '#REPLACE_URL#'          = "https://github.com/M2Team/NanaZip/releases/download/$version.0/$fileName"
    '#REPLACE_CHECKSUM#'     = ('0' * 64)
    '#REPLACE_FILENAME#'     = $fileName
  }
  $utf8 = New-Object System.Text.UTF8Encoding $false
  foreach ($f in 'nanazip.nuspec', 'tools\VERIFICATION.txt', 'tools\chocolateyinstall.ps1') {
    $path = Join-Path $work $f
    $text = [IO.File]::ReadAllText($path, $utf8)
    foreach ($k in $values.Keys) { $text = $text.Replace($k, $values[$k]) }
    if ($text -match '#REPLACE_\w+#') { throw "Unknown placeholder left in $f" }
    [IO.File]::WriteAllText($path, $text, $utf8)
  }
  [xml](Get-Content (Join-Path $work 'nanazip.nuspec') -Raw) | Out-Null
  Set-Content (Join-Path $work "tools\$fileName") 'dummy'

  Push-Location $work
  try { $output = choco pack 2>&1 } finally { Pop-Location }
  $output | ForEach-Object { Write-Host $_ }
  if ($LASTEXITCODE -ne 0) { throw "choco pack failed (exit code $LASTEXITCODE)" }
  if ($output -match '^\s*WARNING') { throw 'choco pack reported warnings' }
  if (-not (Test-Path (Join-Path $work "nanazip.$version.nupkg"))) { throw 'nupkg not created' }
  Write-Host "Pack check OK for version $version"
} finally {
  Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
