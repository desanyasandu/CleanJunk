# Builds dist\CleanJunk-v<version>.zip and a matching .sha256 file, ready to upload to GitHub Releases.
$root = $PSScriptRoot
$ver  = ([regex]::Match((Get-Content "$root\CleanJunk.ps1" -Raw), "\`$Version\s*=\s*'([^']+)'")).Groups[1].Value
if (-not $ver) { throw 'Could not read $Version from CleanJunk.ps1' }

$dist  = Join-Path $root 'dist'
$stage = Join-Path $dist "stage\CleanJunk-v$ver"
$zip   = Join-Path $dist "CleanJunk-v$ver.zip"
Remove-Item $dist -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory $stage -Force | Out-Null

$files = 'CleanJunk.ps1','CleanJunk.bat','CleanJunk-Text.bat','README.md','LICENSE','CHANGELOG.md'
foreach ($f in $files) { Copy-Item "$root\$f" $stage }
Copy-Item "$root\docs" $stage -Recurse -ErrorAction SilentlyContinue

Compress-Archive -Path "$dist\stage\CleanJunk-v$ver" -DestinationPath $zip
Remove-Item "$dist\stage" -Recurse -Force

$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
"$hash  CleanJunk-v$ver.zip" | Set-Content "$zip.sha256" -Encoding ascii
"Built: $zip"
"SHA256: $hash"
