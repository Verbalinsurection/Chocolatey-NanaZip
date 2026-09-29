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

To test a locally packed package: `choco upgrade nanazip -s . -f` (`--force` reinstalls the same version).
