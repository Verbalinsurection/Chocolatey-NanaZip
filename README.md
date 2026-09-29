# NanaZip - Chocolatey package

Chocolatey package for NanaZip **The 7-Zip derivative intended for the modern Windows experience**
See here for NanaZip: <https://github.com/M2Team/NanaZip>

## Chocolatey package

This is the repository for packaging NanaZip to Chocolatey (<https://community.chocolatey.org/>)

## Other packages

My Chocolatey package: <https://community.chocolatey.org/profiles/verbalinsurection>

## Usage

`packVersion.ps1` builds (and optionally pushes) the package for the latest stable NanaZip release.
It downloads the `NanaZip_*.msixbundle` asset, computes its SHA256, fills the `#REPLACE_*#` placeholders
in `nanazip.nuspec`, `tools/VERIFICATION.txt` and `tools/chocolateyinstall.ps1`, runs `choco pack`,
then restores the templates.

```powershell
.\packVersion.ps1            # latest stable release, prompts before packing and pushing
.\packVersion.ps1 -f         # pack even if the version is already on Chocolatey
.\packVersion.ps1 -np        # no prompts
.\packVersion.ps1 -v 7.0.1843.0   # a specific release tag
.\packVersion.ps1 -d         # debug output
```

Set `GITHUB_TOKEN` to avoid the anonymous GitHub API rate limit.

### Testing in Windows Sandbox

`tests\Test-InSandbox.ps1` tests the packed package in a disposable Windows Sandbox (feature to enable once:
`Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All`, admin, then reboot).
It is the only script to run by hand; `tests\sandbox-run.ps1` runs inside the Sandbox and needs no arguments.

```powershell
.\packVersion.ps1                 # 1. pack the new version (creates nanazip.<version>.nupkg)
.\tests\Test-InSandbox.ps1        # 2. test it
```

The script picks the packages itself from the `nanazip.*.nupkg` files at the repository root: the newest one is
tested, the one just before it is used as the "old" package for the upgrade test. Options (all optional):

```powershell
.\tests\Test-InSandbox.ps1 -Package .\nanazip.7.0.1843.nupkg      # package to test
.\tests\Test-InSandbox.ps1 -OldPackage .\nanazip.6.5.1800.nupkg   # older package for the upgrade test
.\tests\Test-InSandbox.ps1 -NoLaunch                              # prepare only, do not start the Sandbox
```

Steps run in the Sandbox: fresh install, uninstall, install of the old version, upgrade, forced reinstall, final
uninstall. After each step the installed NanaZip version (Appx and Chocolatey) is checked. Results are shown in the
Sandbox window and saved on the host in `%TEMP%\nanazip-sandbox\results` (`summary.txt`, `sandbox.log`).
Without an old package, the upgrade test is skipped.

To test a locally packed package on your own machine: `choco upgrade nanazip -s . -f` (`--force` reinstalls the same version).

## Automation (GitHub Actions)

- `ci.yml` (pull requests, `master`, manual): lints the PowerShell scripts and checks that the package can be
  packed (`.github/scripts/ci-pack-check.ps1`, placeholders replaced by dummy values).
- `new-release.yml` (daily, manual): compares the latest stable NanaZip release with `version.txt`. If it is newer,
  it opens a pull request `Update NanaZip to <version>` (branch `release/nanazip-<version>`) that bumps `version.txt`
  and gives the release link and the SHA256 of the asset.

Publishing stays manual: check out the pull request branch, run `.\packVersion.ps1`, test the package
(`.\tests\Test-InSandbox.ps1`, `choco upgrade nanazip -s . -f`), let the script push it to Chocolatey, then merge the PR.

Repository setting required: *Settings > Actions > General > Workflow permissions > Allow GitHub Actions to create
and approve pull requests*.
