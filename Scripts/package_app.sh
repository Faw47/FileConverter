#!/bin/bash
set -euo pipefail

# Unified Developer ID build — single File Converter.app (no App Store split).
# Usage: ./Scripts/package_app.sh [Debug|Release]

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-Release}"
DIST_DIR="${PROJECT_DIR}/dist"
APP_NAME="File Converter"
DERIVED="/tmp/FileConverterPackageBuild"

echo "==> Building File Converter (${CONFIG}) via Xcode (scheme: FileConverter)..."
xcodebuild -project "${PROJECT_DIR}/FileConverter.xcodeproj" \
  -scheme FileConverter \
  -configuration "${CONFIG}" \
  -derivedDataPath "${DERIVED}" \
  CODE_SIGNING_ALLOWED=YES build

SRC_APP="${DERIVED}/Build/Products/${CONFIG}/${APP_NAME}.app"
if [ ! -d "${SRC_APP}" ]; then
  echo "Build output not found at ${SRC_APP}" >&2
  exit 1
fi

echo "==> Copying to dist/..."
rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"
ditto "${SRC_APP}" "${DIST_DIR}/${APP_NAME}.app"

APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
APPEX_BUNDLE="${APP_BUNDLE}/Contents/PlugIns/FileConverterFinderExtension.appex"

echo "==> Verifying signature..."
codesign --verify --deep --strict "${APP_BUNDLE}"

echo "==> Registering with macOS LaunchServices & PluginKit..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R -trusted "${APP_BUNDLE}" 2>/dev/null || true
if [ -d "${APPEX_BUNDLE}" ]; then
  pluginkit -a "${APPEX_BUNDLE}" 2>/dev/null || true
  pluginkit -e use -i io.fileconverter.app.findersync 2>/dev/null || true
fi

echo "==> Successfully created macOS Application Bundle at:"
echo "    ${APP_BUNDLE}"
