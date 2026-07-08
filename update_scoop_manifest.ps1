# update_scoop_manifest.ps1 -- refresh a scoop manifest's hash after rebuilding its zip
#
# Usage: powershell -File update_scoop_manifest.ps1 -ZipPath <zip> -ManifestPath <json>
#
# Only updates architecture.64bit.hash to match the current file. Version is
# left untouched -- this project has no semver/release-tag process yet, so
# bumping "version" here would just be a guess.

param(
    [Parameter(Mandatory=$true)][string]$ZipPath,
    [Parameter(Mandatory=$true)][string]$ManifestPath
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $ZipPath)) {
    Write-Error "Not found: $ZipPath"
    exit 1
}
if (-not (Test-Path $ManifestPath)) {
    Write-Error "Not found: $ManifestPath"
    exit 1
}

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ZipPath).Hash.ToLower()

# Parse first (to validate JSON and read the old hash for the log line), but
# write back via a surgical regex replace on the raw text -- ConvertTo-Json
# reformats/reorders the whole file (extra alignment spaces, \uXXXX-escaped
# punctuation), which would turn every release into a full-file diff.
$manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
$oldHash = $manifest.architecture.'64bit'.hash

$content = Get-Content -Raw -LiteralPath $ManifestPath
$newContent = $content -replace '("hash":\s*")[0-9a-f]{64}(")', "`${1}$hash`${2}"
if ($newContent -eq $content -and $oldHash -ne $hash) {
    Write-Error "hash field not found/replaced in $ManifestPath"
    exit 1
}
[System.IO.File]::WriteAllText($ManifestPath, $newContent, (New-Object System.Text.UTF8Encoding $false))

if ($oldHash -eq $hash) {
    Write-Host "No change: $ManifestPath hash already $hash"
} else {
    Write-Host "Updated $ManifestPath"
    Write-Host "  old hash: $oldHash"
    Write-Host "  new hash: $hash"
}
