param(
    [string]$OldVer = "00023",
    [string]$NewVer = "00024"
)

$ErrorActionPreference = "Stop"
$Repo = (Resolve-Path "$PSScriptRoot\..").Path
Set-Location $Repo

$PlatformZip = "zsilencer-windows-x64.zip"

Write-Host "=== Building NEW version ($NewVer) ===" -ForegroundColor Cyan
cmake -B build-new -S . `
    -A x64 `
    -DZSILENCER_VERSION="$NewVer" `
    -DZSILENCER_LOBBY_HOST=127.0.0.1 `
    -DZSILENCER_LOBBY_PORT=15170
cmake --build build-new --config Release -j

New-Item -ItemType Directory -Force -Path test-update-host | Out-Null
if (Test-Path "test-update-host/$PlatformZip") { Remove-Item "test-update-host/$PlatformZip" }
Compress-Archive -Path "build-new/Release/zsilencer.exe","build-new/Release/*.dll","data" `
    -DestinationPath "test-update-host/$PlatformZip"

$sha = (Get-FileHash "test-update-host/$PlatformZip" -Algorithm SHA256).Hash.ToLower()
Write-Host "NEW zip sha256=$sha"

Write-Host "=== Building OLD version ($OldVer) ===" -ForegroundColor Cyan
cmake -B build-old -S . `
    -A x64 `
    -DZSILENCER_VERSION="$OldVer" `
    -DZSILENCER_LOBBY_HOST=127.0.0.1 `
    -DZSILENCER_LOBBY_PORT=15170
cmake --build build-old --config Release -j

$manifest = @"
{
  "version":        "$NewVer",
  "macos_url":      "http://127.0.0.1:8000/$PlatformZip",
  "macos_sha256":   "$sha",
  "windows_url":    "http://127.0.0.1:8000/$PlatformZip",
  "windows_sha256": "$sha"
}
"@
Set-Content -Path update.json -Value $manifest

Write-Host "=== Starting HTTP server on :8000 ==="
$http = Start-Process -PassThru python -ArgumentList "-m","http.server","8000" -WorkingDirectory "$Repo/test-update-host"

Push-Location server
go build
Pop-Location

Write-Host "=== Starting lobby on :15170 ==="
$lobby = Start-Process -PassThru .\server\zsilencer-lobby.exe `
    -ArgumentList "-addr",":15170","-version","$NewVer","-update-manifest","$Repo\update.json"

Start-Sleep -Seconds 1
Write-Host "=== Launching OLD client — expect update modal ===" -ForegroundColor Cyan
try {
    & .\build-old\Release\zsilencer.exe
} finally {
    Stop-Process -Id $http.Id -ErrorAction SilentlyContinue
    Stop-Process -Id $lobby.Id -ErrorAction SilentlyContinue
}
