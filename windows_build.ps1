#Requires -Version 5.1
<#
.SYNOPSIS
    Build QLC+ on Windows from PowerShell. No MSYS2 shell required.

.DESCRIPTION
    This script:
      1. Downloads and installs MSYS2 (if not already installed)
      2. Installs MinGW64 toolchain and libraries via pacman
      3. Installs Qt via aqtinstall
      4. Downloads and builds the D2XX (FTDI) SDK
      5. Configures and builds QLC+ with CMake/Ninja

    Just right-click this script and "Run with PowerShell", or run from
    a PowerShell prompt:  .\windows_build.ps1

.PARAMETER QmlUI
    Build QLC+ 5 (QML UI) instead of QLC+ 4 (Widgets).

.PARAMETER Install
    Run 'ninja install' after building.

.PARAMETER Installer
    Create an NSIS installer (.exe) after building.

.PARAMETER SkipDeps
    Skip installing MSYS2 packages (for re-runs).

.PARAMETER SkipQt
    Skip Qt installation (use existing Qt).

.PARAMETER SkipD2XX
    Skip D2XX SDK download.

.PARAMETER QtVersion
    Qt version to install (default: 6.10.2).

.PARAMETER Msys2Dir
    MSYS2 installation directory (default: C:\msys64).

.PARAMETER Jobs
    Number of parallel build jobs (default: number of CPU cores).

.EXAMPLE
    .\windows_build.ps1
    Build QLC+ 4 with default settings.

.EXAMPLE
    .\windows_build.ps1 -QmlUI -Installer
    Build QLC+ 5 and create an NSIS installer.

.EXAMPLE
    .\windows_build.ps1 -SkipDeps -SkipQt -SkipD2XX
    Rebuild without re-downloading anything.
#>

[CmdletBinding()]
param(
    [switch]$QmlUI,
    [switch]$Install,
    [switch]$Installer,
    [switch]$SkipDeps,
    [switch]$SkipQt,
    [switch]$SkipD2XX,
    [string]$QtVersion = "6.10.2",
    [string]$Msys2Dir = "C:\msys64",
    [int]$Jobs = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -------------------------------------------------------------------
# Configuration
# -------------------------------------------------------------------
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$QtInstDir   = "C:\Qt"
$QtDir       = Join-Path $QtInstDir "$QtVersion\mingw_64"
$D2xxDir     = "C:\projects\D2XXSDK"
$BuildDir    = Join-Path $ScriptDir "build"
$Msys2Bash   = Join-Path $Msys2Dir "usr\bin\bash.exe"
$Msys2Url    = "https://github.com/msys2/msys2-installer/releases/download/2024-12-08/msys2-x86_64-20241208.exe"

if ($Jobs -le 0) {
    $Jobs = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
    if ($Jobs -le 0) { $Jobs = 4 }
}

$UIVariant = if ($QmlUI) { "QLC+ 5 (QML)" } else { "QLC+ 4 (Widgets)" }

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  QLC+ Windows Build (PowerShell)" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  UI variant : $UIVariant"
Write-Host "  Qt version : $QtVersion"
Write-Host "  Qt dir     : $QtDir"
Write-Host "  MSYS2 dir  : $Msys2Dir"
Write-Host "  Build dir  : $BuildDir"
Write-Host "  Jobs       : $Jobs"
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# -------------------------------------------------------------------
# Helper: run a command inside MSYS2 MinGW64
# -------------------------------------------------------------------
function Invoke-Msys2 {
    param([string]$Command, [string]$Description = "")

    if ($Description) {
        Write-Host "    $Description" -ForegroundColor Gray
    }

    $env:MSYSTEM = "MINGW64"
    $env:CHERE_INVOKING = "1"

    # Pass through Qt path so cmake can find it
    $env:QTDIR = $QtDir -replace '\\', '/'

    & $Msys2Bash --login -c $Command
    if ($LASTEXITCODE -ne 0) {
        throw "MSYS2 command failed (exit code $LASTEXITCODE): $Command"
    }
}

# -------------------------------------------------------------------
# Step 1: Install MSYS2 if needed
# -------------------------------------------------------------------
if (-not (Test-Path $Msys2Bash)) {
    Write-Host ">>> Step 1a: Downloading MSYS2..." -ForegroundColor Yellow
    $msys2Installer = Join-Path $env:TEMP "msys2-installer.exe"

    if (-not (Test-Path $msys2Installer)) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Msys2Url -OutFile $msys2Installer -UseBasicParsing
    }

    Write-Host ">>> Step 1a: Installing MSYS2 to $Msys2Dir..." -ForegroundColor Yellow
    Write-Host "    (This may take a few minutes)" -ForegroundColor Gray
    Start-Process -FilePath $msys2Installer -ArgumentList "install", "--root", $Msys2Dir, "--confirm-command" -Wait -NoNewWindow

    # Initialize MSYS2 (first run updates)
    Write-Host ">>> Step 1a: Initializing MSYS2..." -ForegroundColor Yellow
    Invoke-Msys2 "echo 'MSYS2 initialized'" "First-run initialization"

    Write-Host "    MSYS2 installed." -ForegroundColor Green
    Write-Host ""
} else {
    Write-Host ">>> Step 1a: MSYS2 found at $Msys2Dir" -ForegroundColor Green
    Write-Host ""
}

# -------------------------------------------------------------------
# Step 2: Install MSYS2 packages
# -------------------------------------------------------------------
if (-not $SkipDeps) {
    Write-Host ">>> Step 2: Installing MSYS2 MinGW64 packages..." -ForegroundColor Yellow
    $packages = @(
        "wget", "unzip",
        "mingw-w64-x86_64-gcc",
        "mingw-w64-x86_64-gcc-libs",
        "mingw-w64-x86_64-cmake",
        "mingw-w64-x86_64-ninja",
        "mingw-w64-x86_64-libmad",
        "mingw-w64-x86_64-libsndfile",
        "mingw-w64-x86_64-flac",
        "mingw-w64-x86_64-fftw",
        "mingw-w64-x86_64-libusb",
        "mingw-w64-x86_64-python-pip",
        "mingw-w64-x86_64-python-psutil",
        "mingw-w64-x86_64-nsis"
    ) -join " "
    Invoke-Msys2 "pacman -S --needed --noconfirm $packages" "Installing packages..."
    Write-Host "    Done." -ForegroundColor Green
    Write-Host ""
} else {
    Write-Host ">>> Step 2: Skipping MSYS2 packages (-SkipDeps)" -ForegroundColor DarkGray
    Write-Host ""
}

# -------------------------------------------------------------------
# Step 3: Install Qt via aqtinstall
# -------------------------------------------------------------------
if (-not $SkipQt) {
    if (Test-Path $QtDir) {
        Write-Host ">>> Step 3: Qt already exists at $QtDir, skipping." -ForegroundColor Green
        Write-Host ""
    } else {
        Write-Host ">>> Step 3: Installing Qt $QtVersion via aqtinstall..." -ForegroundColor Yellow
        Write-Host "    (This downloads ~1 GB and may take several minutes)" -ForegroundColor Gray
        $qtInstDirUnix = $QtInstDir -replace '\\', '/'
        Invoke-Msys2 "pip install aqtinstall 2>/dev/null || pip install --break-system-packages aqtinstall && aqt install-qt windows desktop $QtVersion win64_mingw --outputdir '$qtInstDirUnix' -m qt3d qtimageformats qtmultimedia qtserialport qtwebsockets"
        Write-Host "    Qt installed to $QtDir" -ForegroundColor Green
        Write-Host ""
    }
} else {
    Write-Host ">>> Step 3: Skipping Qt installation (-SkipQt)" -ForegroundColor DarkGray
    Write-Host ""
}

if (-not (Test-Path $QtDir)) {
    Write-Host "ERROR: Qt directory not found at $QtDir" -ForegroundColor Red
    Write-Host "       Run without -SkipQt, or install Qt manually." -ForegroundColor Red
    exit 1
}

# -------------------------------------------------------------------
# Step 4: Download and build D2XX SDK
# -------------------------------------------------------------------
if (-not $SkipD2XX) {
    $d2xxLib = Join-Path $D2xxDir "amd64\libftd2xx.a"
    if (Test-Path $d2xxLib) {
        Write-Host ">>> Step 4: D2XX SDK already built, skipping." -ForegroundColor Green
        Write-Host ""
    } else {
        Write-Host ">>> Step 4: Downloading D2XX SDK (FTDI USB drivers)..." -ForegroundColor Yellow
        $d2xxDirUnix = $D2xxDir -replace '\\', '/'
        Invoke-Msys2 @"
mkdir -p '$d2xxDirUnix' && \
wget -q 'https://qlcplus.org/misc/CDM-v2.12.36.20-WHQL-Certified.zip' -O '$d2xxDirUnix/cdm.zip' && \
cd '$d2xxDirUnix' && \
unzip -o cdm.zip && \
cd amd64 && \
gendef.exe - ftd2xx64.dll > ftd2xx.def && \
dlltool -k --input-def ftd2xx.def --dllname ftd2xx64.dll --output-lib libftd2xx.a
"@
        Write-Host "    D2XX SDK built." -ForegroundColor Green
        Write-Host ""
    }
} else {
    Write-Host ">>> Step 4: Skipping D2XX SDK (-SkipD2XX)" -ForegroundColor DarkGray
    Write-Host ""
}

# -------------------------------------------------------------------
# Step 5: Configure with CMake
# -------------------------------------------------------------------
Write-Host ">>> Step 5: Configuring with CMake..." -ForegroundColor Yellow

$srcDirUnix = $ScriptDir -replace '\\', '/'
$buildDirUnix = $BuildDir -replace '\\', '/'
$qtDirUnix = $QtDir -replace '\\', '/'

$cmakeCmd = "cd '$srcDirUnix' && cmake -S . -B '$buildDirUnix' -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH='$qtDirUnix/lib/cmake'"
if ($QmlUI) {
    $cmakeCmd += " -Dqmlui=ON"
}

Invoke-Msys2 $cmakeCmd "Running cmake configure..."
Write-Host "    Configuration complete." -ForegroundColor Green
Write-Host ""

# -------------------------------------------------------------------
# Step 6: Build
# -------------------------------------------------------------------
Write-Host ">>> Step 6: Building QLC+ ($Jobs jobs)..." -ForegroundColor Yellow
Invoke-Msys2 "cmake --build '$buildDirUnix' --parallel $Jobs" "Compiling..."
Write-Host "    Build complete." -ForegroundColor Green
Write-Host ""

# -------------------------------------------------------------------
# Step 7: Install (optional)
# -------------------------------------------------------------------
if ($Install -or $Installer) {
    Write-Host ">>> Step 7: Installing..." -ForegroundColor Yellow
    Invoke-Msys2 "cmake --build '$buildDirUnix' --target install"
    Write-Host "    Install complete." -ForegroundColor Green
    Write-Host ""
}

# -------------------------------------------------------------------
# Step 8: Create NSIS installer (optional)
# -------------------------------------------------------------------
if ($Installer) {
    Write-Host ">>> Step 8: Creating NSIS installer..." -ForegroundColor Yellow

    if ($QmlUI) {
        $deployArgs = "--qmldir '$srcDirUnix/qmlui/qml' qlcplus-qml.exe qlcplusengine.dll plugins/dmxusb.dll"
        $nsisScript = "qlcplus5Qt6.nsi"
    } else {
        $deployArgs = "qlcplus.exe qlcplusengine.dll qlcplusui.dll qlcpluswebaccess.dll plugins/dmxusb.dll"
        $nsisScript = "qlcplus4Qt6.nsi"
    }

    Invoke-Msys2 "cd /c/qlcplus && '$qtDirUnix/bin/windeployqt' $deployArgs && makensis -X'SetCompressor /FINAL lzma' $nsisScript"
    Write-Host "    Installer created." -ForegroundColor Green
    Write-Host ""
}

# -------------------------------------------------------------------
# Done
# -------------------------------------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Build finished successfully!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green

if ($Install -or $Installer) {
    Write-Host "  Installed to: C:\qlcplus"
} else {
    Write-Host "  Build output: $BuildDir"
    Write-Host ""
    Write-Host "  To install, re-run with -Install"
    Write-Host "  To create an installer, re-run with -Installer"
}
Write-Host ""
