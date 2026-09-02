#!/bin/bash
set -euo pipefail

# Directory locations
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/.build"
DIST_DIR="${PROJECT_DIR}/dist"
APP_NAME="File Converter"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
EXT_NAME="FileConverterFinderSync"
APPEX_BUNDLE="${APP_BUNDLE}/Contents/PlugIns/${EXT_NAME}.appex"

echo "==> Building File Converter in Release mode..."
swift build -c release --package-path "${PROJECT_DIR}"

BIN_PATH=$(swift build -c release --package-path "${PROJECT_DIR}" --show-bin-path)

echo "==> Cleaning old distribution folder..."
rm -rf "${DIST_DIR}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
mkdir -p "${APP_BUNDLE}/Contents/PlugIns"
mkdir -p "${APPEX_BUNDLE}/Contents/MacOS"
mkdir -p "${APPEX_BUNDLE}/Contents/Resources"

echo "==> Copying Host App binaries and Info.plist..."
cp "${BIN_PATH}/FileConverterApp" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "${PROJECT_DIR}/Sources/FileConverterApp/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
if [ -f "${PROJECT_DIR}/Sources/FileConverterApp/Resources/AppIcon.icns" ]; then
    cp "${PROJECT_DIR}/Sources/FileConverterApp/Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi
echo -n "APPL????" > "${APP_BUNDLE}/Contents/PkgInfo"

# Update CFBundleExecutable in Info.plist to match binary name
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable ${APP_NAME}" "${APP_BUNDLE}/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string ${APP_NAME}" "${APP_BUNDLE}/Contents/Info.plist"

echo "==> Packaging Finder Sync Extension (.appex)..."
if [ -f "${BIN_PATH}/${EXT_NAME}" ]; then
    cp "${BIN_PATH}/${EXT_NAME}" "${APPEX_BUNDLE}/Contents/MacOS/${EXT_NAME}"
elif [ -f "${BIN_PATH}/lib${EXT_NAME}.dylib" ]; then
    cp "${BIN_PATH}/lib${EXT_NAME}.dylib" "${APPEX_BUNDLE}/Contents/MacOS/${EXT_NAME}"
fi

cp "${PROJECT_DIR}/Sources/FileConverterFinderSync/Info.plist" "${APPEX_BUNDLE}/Contents/Info.plist"
echo -n "XPC!????" > "${APPEX_BUNDLE}/Contents/PkgInfo"

/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable ${EXT_NAME}" "${APPEX_BUNDLE}/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string ${EXT_NAME}" "${APPEX_BUNDLE}/Contents/Info.plist"

echo "==> Signing bundles with entitlements (ad-hoc development signature)..."
codesign --force --sign - \
    --entitlements "${PROJECT_DIR}/Sources/FileConverterFinderSync/FileConverterFinderSync.entitlements" \
    "${APPEX_BUNDLE}"

codesign --force --sign - \
    --entitlements "${PROJECT_DIR}/Sources/FileConverterApp/FileConverterApp.entitlements" \
    "${APP_BUNDLE}"

echo "==> Verifying signature..."
codesign --verify --deep --strict "${APP_BUNDLE}"

echo "==> Registering with macOS LaunchServices & PluginKit..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R -trusted "${APP_BUNDLE}" 2>/dev/null || true
pluginkit -a "${APPEX_BUNDLE}" 2>/dev/null || true
pluginkit -e use -i io.fileconverter.app.findersync 2>/dev/null || true

echo "==> Successfully created macOS Application Bundle at:"
echo "    ${APP_BUNDLE}"
