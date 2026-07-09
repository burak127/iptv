# =============================================================================
#  setup.ps1  --  Generates the native/web platform folders for iptv_player
#
#  Run ONCE after installing Flutter:
#      powershell -ExecutionPolicy Bypass -File .\setup.ps1
#
#  It safely regenerates android/ + web/ WITHOUT losing the app source in lib/.
# =============================================================================
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
# 'flutter create .' operates on the CURRENT directory, so make sure we are IN
# the project folder regardless of where this script was invoked from.
Set-Location $root

# 1. Ensure Flutter is available -------------------------------------------------
$flutter = Get-Command flutter -ErrorAction SilentlyContinue
if (-not $flutter) {
    Write-Host "Flutter blev ikke fundet i PATH." -ForegroundColor Red
    Write-Host "Installer det forst: https://docs.flutter.dev/get-started/install/windows" -ForegroundColor Yellow
    exit 1
}
Write-Host "==> Flutter fundet: $($flutter.Source)" -ForegroundColor Green

# 2. Back up the app source (flutter create may overwrite main.dart / pubspec) ---
Write-Host "==> Sikkerhedskopierer app-kildekode..." -ForegroundColor Cyan
$backup = Join-Path $root "_backup_app"
if (Test-Path $backup) { Remove-Item -Recurse -Force $backup }
New-Item -ItemType Directory -Force -Path $backup | Out-Null
Copy-Item (Join-Path $root "lib") (Join-Path $backup "lib") -Recurse
Copy-Item (Join-Path $root "pubspec.yaml") (Join-Path $backup "pubspec.yaml")

# 3. Generate platform folders --------------------------------------------------
Write-Host "==> Genererer platform-mapper (android + web)..." -ForegroundColor Cyan
& flutter create . --platforms=android,web --org com.iptvplayer --project-name iptv_player

# 4. Restore our app source over the template ------------------------------------
Write-Host "==> Gendanner app-kildekode..." -ForegroundColor Cyan
Copy-Item (Join-Path $backup "lib\*") (Join-Path $root "lib") -Recurse -Force
Copy-Item (Join-Path $backup "pubspec.yaml") (Join-Path $root "pubspec.yaml") -Force
Remove-Item -Recurse -Force $backup

# 5. Apply the Android TV manifest ----------------------------------------------
Write-Host "==> Anvender Android TV manifest..." -ForegroundColor Cyan
$manifestSrc = Join-Path $root "platform_templates\AndroidManifest.xml"
$manifestDst = Join-Path $root "android\app\src\main\AndroidManifest.xml"
Copy-Item $manifestSrc $manifestDst -Force

# 6. Fetch dependencies ---------------------------------------------------------
Write-Host "==> Henter dependencies..." -ForegroundColor Cyan
& flutter pub get

Write-Host ""
Write-Host "Faerdig! Naeste skridt:" -ForegroundColor Green
Write-Host "   flutter devices          # se tilgaengelige enheder" -ForegroundColor Gray
Write-Host "   flutter run              # telefon/emulator/TV" -ForegroundColor Gray
Write-Host "   flutter run -d chrome    # webapp" -ForegroundColor Gray
