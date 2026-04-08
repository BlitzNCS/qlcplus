#!/bin/bash
#
# QLC+ Windows Build Script (MSYS2 MinGW64)
#
# This script automates the full Windows build process:
#   1. Installs MSYS2 packages (compiler, libraries)
#   2. Installs Qt via aqtinstall
#   3. Downloads and builds the D2XX (FTDI) SDK
#   4. Configures and builds QLC+
#   5. Optionally creates an NSIS installer
#
# Usage (run from an MSYS2 MinGW64 shell):
#   ./build_windows.sh          # Build QLC+ 4 (Qt Widgets UI)
#   ./build_windows.sh --qmlui  # Build QLC+ 5 (QML UI)
#   ./build_windows.sh --help   # Show all options
#

set -e

# -------------------------------------------------------------------
# Defaults
# -------------------------------------------------------------------
BUILD_TYPE="Release"
QT_VERSION="6.10.2"
QT_INSTALL_DIR="/c/Qt"
D2XX_DIR="/c/projects/D2XXSDK"
BUILD_DIR="build"
QMLUI=OFF
INSTALL=false
INSTALLER=false
SKIP_DEPS=false
SKIP_QT=false
SKIP_D2XX=false
PARALLEL=$(nproc 2>/dev/null || echo 4)

# -------------------------------------------------------------------
# Parse arguments
# -------------------------------------------------------------------
print_help() {
    cat <<'HELPTEXT'
QLC+ Windows Build Script

Usage: ./build_windows.sh [OPTIONS]

Options:
  --qmlui             Build QLC+ 5 (QML UI) instead of QLC+ 4
  --qt-version VER    Qt version to install (default: 6.10.2)
  --qt-dir DIR        Qt installation directory (default: /c/Qt)
  --build-dir DIR     Build output directory (default: build)
  --build-type TYPE   CMake build type: Release|Debug|RelWithDebInfo (default: Release)
  --install           Run 'ninja install' after building
  --installer         Create NSIS installer after building
  --skip-deps         Skip installing MSYS2 packages
  --skip-qt           Skip Qt installation (use existing Qt)
  --skip-d2xx         Skip D2XX SDK download
  --jobs N            Parallel build jobs (default: nproc)
  --help              Show this help message
HELPTEXT
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --qmlui)        QMLUI=ON; shift ;;
        --qt-version)   QT_VERSION="$2"; shift 2 ;;
        --qt-dir)       QT_INSTALL_DIR="$2"; shift 2 ;;
        --build-dir)    BUILD_DIR="$2"; shift 2 ;;
        --build-type)   BUILD_TYPE="$2"; shift 2 ;;
        --install)      INSTALL=true; shift ;;
        --installer)    INSTALLER=true; shift ;;
        --skip-deps)    SKIP_DEPS=true; shift ;;
        --skip-qt)      SKIP_QT=true; shift ;;
        --skip-d2xx)    SKIP_D2XX=true; shift ;;
        --jobs)         PARALLEL="$2"; shift 2 ;;
        --help)         print_help; exit 0 ;;
        *)              echo "Unknown option: $1"; print_help; exit 1 ;;
    esac
done

QTDIR="${QT_INSTALL_DIR}/${QT_VERSION}/mingw_64"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "============================================"
echo "QLC+ Windows Build"
echo "============================================"
echo "  UI variant : $([ "$QMLUI" = "ON" ] && echo "QLC+ 5 (QML)" || echo "QLC+ 4 (Widgets)")"
echo "  Build type : ${BUILD_TYPE}"
echo "  Qt version : ${QT_VERSION}"
echo "  Qt dir     : ${QTDIR}"
echo "  Build dir  : ${BUILD_DIR}"
echo "  Jobs       : ${PARALLEL}"
echo "============================================"
echo

# -------------------------------------------------------------------
# Verify we're in an MSYS2 MinGW64 environment
# -------------------------------------------------------------------
if [[ -z "$MSYSTEM" ]]; then
    echo "WARNING: MSYSTEM is not set. This script is designed to run in an MSYS2 MinGW64 shell."
    echo "         Install MSYS2 from https://www.msys2.org/ and open 'MSYS2 MinGW 64-bit'."
    echo
    read -rp "Continue anyway? [y/N] " answer
    [[ "$answer" =~ ^[Yy] ]] || exit 1
elif [[ "$MSYSTEM" != "MINGW64" ]]; then
    echo "WARNING: Current MSYSTEM is '$MSYSTEM', expected 'MINGW64'."
    echo "         Open 'MSYS2 MinGW 64-bit' for a 64-bit build."
    echo
    read -rp "Continue anyway? [y/N] " answer
    [[ "$answer" =~ ^[Yy] ]] || exit 1
fi

# -------------------------------------------------------------------
# Step 1: Install MSYS2 packages
# -------------------------------------------------------------------
if [[ "$SKIP_DEPS" != "true" ]]; then
    echo ">>> Step 1: Installing MSYS2 packages..."
    pacman -S --needed --noconfirm \
        wget \
        unzip \
        mingw-w64-x86_64-gcc \
        mingw-w64-x86_64-gcc-libs \
        mingw-w64-x86_64-cmake \
        mingw-w64-x86_64-ninja \
        mingw-w64-x86_64-libmad \
        mingw-w64-x86_64-libsndfile \
        mingw-w64-x86_64-flac \
        mingw-w64-x86_64-fftw \
        mingw-w64-x86_64-libusb \
        mingw-w64-x86_64-python-pip \
        mingw-w64-x86_64-python-psutil \
        mingw-w64-x86_64-nsis
    echo "    Done."
    echo
else
    echo ">>> Step 1: Skipping MSYS2 packages (--skip-deps)."
    echo
fi

# -------------------------------------------------------------------
# Step 2: Install Qt via aqtinstall
# -------------------------------------------------------------------
if [[ "$SKIP_QT" != "true" ]]; then
    if [[ -d "$QTDIR" ]]; then
        echo ">>> Step 2: Qt already exists at ${QTDIR}, skipping installation."
        echo "            (Use --qt-dir to point elsewhere, or delete this directory to reinstall.)"
    else
        echo ">>> Step 2: Installing Qt ${QT_VERSION} via aqtinstall..."
        pip install aqtinstall 2>/dev/null || pip install --break-system-packages aqtinstall
        aqt install-qt windows desktop "${QT_VERSION}" win64_mingw \
            --outputdir "${QT_INSTALL_DIR}" \
            -m qt3d qtimageformats qtmultimedia qtserialport qtwebsockets
        echo "    Qt installed to ${QTDIR}"
    fi
    echo
else
    echo ">>> Step 2: Skipping Qt installation (--skip-qt)."
    echo
fi

if [[ ! -d "$QTDIR" ]]; then
    echo "ERROR: Qt directory not found at ${QTDIR}"
    echo "       Install Qt manually or run without --skip-qt."
    exit 1
fi

# -------------------------------------------------------------------
# Step 3: Download and build D2XX SDK (FTDI USB drivers)
# -------------------------------------------------------------------
if [[ "$SKIP_D2XX" != "true" ]]; then
    if [[ -f "${D2XX_DIR}/amd64/libftd2xx.a" ]]; then
        echo ">>> Step 3: D2XX SDK already built, skipping."
    else
        echo ">>> Step 3: Downloading D2XX SDK..."
        mkdir -p "${D2XX_DIR}"
        wget -q "https://qlcplus.org/misc/CDM-v2.12.36.20-WHQL-Certified.zip" -O "${D2XX_DIR}/cdm.zip"
        cd "${D2XX_DIR}"
        unzip -o cdm.zip
        cd amd64
        gendef.exe - ftd2xx64.dll > ftd2xx.def
        dlltool -k --input-def ftd2xx.def --dllname ftd2xx64.dll --output-lib libftd2xx.a
        cd "${SCRIPT_DIR}"
        echo "    D2XX SDK built at ${D2XX_DIR}/amd64/libftd2xx.a"
    fi
    echo
else
    echo ">>> Step 3: Skipping D2XX SDK (--skip-d2xx)."
    echo
fi

# -------------------------------------------------------------------
# Step 4: Configure with CMake
# -------------------------------------------------------------------
echo ">>> Step 4: Configuring with CMake..."

CMAKE_ARGS=(
    -S .
    -B "${BUILD_DIR}"
    -G Ninja
    -DCMAKE_BUILD_TYPE="${BUILD_TYPE}"
    -DCMAKE_PREFIX_PATH="${QTDIR}/lib/cmake"
)

if [[ "$QMLUI" == "ON" ]]; then
    CMAKE_ARGS+=(-Dqmlui=ON)
fi

cmake "${CMAKE_ARGS[@]}"
echo "    Configuration complete."
echo

# -------------------------------------------------------------------
# Step 5: Build
# -------------------------------------------------------------------
echo ">>> Step 5: Building QLC+ (${PARALLEL} jobs)..."
cmake --build "${BUILD_DIR}" --parallel "${PARALLEL}"
echo "    Build complete."
echo

# -------------------------------------------------------------------
# Step 6: Install (optional)
# -------------------------------------------------------------------
if [[ "$INSTALL" == "true" || "$INSTALLER" == "true" ]]; then
    echo ">>> Step 6: Installing..."
    cmake --build "${BUILD_DIR}" --target install
    echo "    Install complete."
    echo
fi

# -------------------------------------------------------------------
# Step 7: Create installer (optional)
# -------------------------------------------------------------------
if [[ "$INSTALLER" == "true" ]]; then
    echo ">>> Step 7: Creating NSIS installer..."
    INSTALL_DIR="C:/qlcplus"

    if [[ "$QMLUI" == "ON" ]]; then
        EXE_NAME="qlcplus-qml.exe"
        DEPLOY_ARGS="--qmldir ${SCRIPT_DIR}/qmlui/qml ${EXE_NAME} qlcplusengine.dll plugins/dmxusb.dll"
        NSIS_SCRIPT="qlcplus5Qt6.nsi"
    else
        EXE_NAME="qlcplus.exe"
        DEPLOY_ARGS="${EXE_NAME} qlcplusengine.dll qlcplusui.dll qlcpluswebaccess.dll plugins/dmxusb.dll"
        NSIS_SCRIPT="qlcplus4Qt6.nsi"
    fi

    # Deploy Qt dependencies
    cd "${INSTALL_DIR}"
    "${QTDIR}/bin/windeployqt" ${DEPLOY_ARGS}

    # Build NSIS installer
    makensis -X'SetCompressor /FINAL lzma' "${NSIS_SCRIPT}"
    echo "    Installer created."
    cd "${SCRIPT_DIR}"
    echo
fi

# -------------------------------------------------------------------
# Done
# -------------------------------------------------------------------
echo "============================================"
echo "Build finished successfully!"
echo "============================================"
if [[ "$INSTALL" == "true" || "$INSTALLER" == "true" ]]; then
    echo "Installed to: C:/qlcplus"
else
    echo "Build output: ${BUILD_DIR}/"
    echo
    echo "Next steps:"
    echo "  - Run 'cmake --build ${BUILD_DIR} --target install' to install"
    echo "  - Or re-run with --install to install"
    echo "  - Or re-run with --installer to create an NSIS installer"
fi
echo
