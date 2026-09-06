#!/bin/bash
set -euo pipefail

# Local artifact builder — creates a locally signed app bundle without
# publishing, notarizing, or enabling the Finder extension.
# Usage: ./Scripts/package_app.sh [Debug|Release]

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-Release}"
DIST_DIR="${PROJECT_DIR}/dist"
APP_NAME="File Converter"
BUILD_DIR="$(mktemp -d "/tmp/FileConverterPackageBuild.XXXXXX")"
ARCHIVE_PATH="${BUILD_DIR}/FileConverter.xcarchive"

cleanup_build() {
  if [ -d "${BUILD_DIR}" ] && [[ "${BUILD_DIR}" == "/tmp/FileConverterPackageBuild."* ]]; then
    rm -R "${BUILD_DIR}"
  fi
}
trap cleanup_build EXIT

echo "==> Archiving File Converter (${CONFIG}) via Xcode (scheme: FileConverter)..."
xcodebuild -project "${PROJECT_DIR}/FileConverter.xcodeproj" \
  -scheme FileConverter \
  -configuration "${CONFIG}" \
  -archivePath "${ARCHIVE_PATH}" \
  CODE_SIGNING_ALLOWED=NO archive

SRC_APP="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app"
SRC_DSYM="${ARCHIVE_PATH}/dSYMs/${APP_NAME}.app.dSYM"
if [ ! -d "${SRC_APP}" ]; then
  echo "Build output not found at ${SRC_APP}" >&2
  exit 1
fi
if [ ! -d "${SRC_DSYM}" ]; then
  echo "Debug symbols not found at ${SRC_DSYM}" >&2
  exit 1
fi

echo "==> Copying to dist/ using an atomic staging directory..."
mkdir -p "${DIST_DIR}"
STAGING_DIR="$(mktemp -d "${DIST_DIR}/.staging.XXXXXX")"
cleanup_staging() {
  if [ -d "${STAGING_DIR}" ] && [[ "${STAGING_DIR}" == "${DIST_DIR}/.staging."* ]]; then
    rm -R "${STAGING_DIR}"
  fi
}
trap 'cleanup_staging; cleanup_build' EXIT
ditto "${SRC_APP}" "${STAGING_DIR}/${APP_NAME}.app"
ditto "${SRC_DSYM}" "${STAGING_DIR}/${APP_NAME}.app.dSYM"

VERSION_TAG="$(date +%Y%m%d-%H%M%S)"
if [ -d "${DIST_DIR}/${APP_NAME}.app" ]; then
  mv "${DIST_DIR}/${APP_NAME}.app" "${DIST_DIR}/${APP_NAME}.app.previous.${VERSION_TAG}"
fi
if [ -d "${DIST_DIR}/${APP_NAME}.app.dSYM" ]; then
  mv "${DIST_DIR}/${APP_NAME}.app.dSYM" "${DIST_DIR}/${APP_NAME}.app.dSYM.previous.${VERSION_TAG}"
fi
mv "${STAGING_DIR}/${APP_NAME}.app" "${DIST_DIR}/${APP_NAME}.app"
mv "${STAGING_DIR}/${APP_NAME}.app.dSYM" "${DIST_DIR}/${APP_NAME}.app.dSYM"

APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
APPEX_BUNDLE="${APP_BUNDLE}/Contents/PlugIns/FileConverterFinderExtension.appex"
LOCAL_FINDER_ENTITLEMENTS="${PROJECT_DIR}/Scripts/FileConverterFinderLocal.entitlements"
SIGNING_IDENTITY="${FILE_CONVERTER_LOCAL_SIGNING_IDENTITY:-}"
if [ -z "${SIGNING_IDENTITY}" ]; then
  # Prefer the user's Apple Development identity so Finder can reuse an
  # existing sandbox container ACL. Fall back to ad-hoc signing on machines
  # without a local certificate; callers can always set the identity above.
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development:/{print $2; exit}' || true)"
  if [ -z "${SIGNING_IDENTITY}" ]; then
    SIGNING_IDENTITY="-"
  fi
fi

echo "==> Verifying bundle metadata..."
plutil -lint "${APP_BUNDLE}/Contents/Info.plist"
if [ -d "${APPEX_BUNDLE}" ]; then
  APPEX_INFO="${APPEX_BUNDLE}/Contents/Info.plist"
  plutil -lint "${APPEX_INFO}"

  if ! /usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionAttributes' "${APPEX_INFO}" >/dev/null; then
    echo "Finder extension metadata is missing NSExtensionAttributes: ${APPEX_INFO}" >&2
    exit 1
  fi

  APPEX_EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${APPEX_INFO}")"
  APPEX_EXECUTABLE="${APPEX_BUNDLE}/Contents/MacOS/${APPEX_EXECUTABLE_NAME}"
  PRINCIPAL_CLASS="$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPrincipalClass' "${APPEX_INFO}")"

  if [ ! -x "${APPEX_EXECUTABLE}" ]; then
    echo "Finder extension executable not found: ${APPEX_EXECUTABLE}" >&2
    exit 1
  fi

  # Finder resolves this value through the Objective-C runtime. A custom
  # @objc name can make a module-qualified plist value unresolvable even when
  # the Swift type itself still has the expected module-qualified name.
  if [[ "${PRINCIPAL_CLASS}" != *.* ]]; then
    echo "Finder extension principal class must be module-qualified: ${PRINCIPAL_CLASS}" >&2
    exit 1
  fi
  OBJC_PRINCIPAL_CLASS="_OBJC_CLASS_\$_${PRINCIPAL_CLASS}"
  if ! nm -nm "${APPEX_EXECUTABLE}" | xcrun swift-demangle | awk -v expected="${OBJC_PRINCIPAL_CLASS}" '$NF == expected { found = 1 } END { exit(found ? 0 : 1) }'; then
    echo "Finder extension Objective-C class does not match its declared principal class: ${PRINCIPAL_CLASS}" >&2
    exit 1
  fi
fi

if [[ "${FILE_CONVERTER_SKIP_LOCAL_SIGNING:-0}" == "1" ]]; then
  echo "==> Skipping local code signing (FILE_CONVERTER_SKIP_LOCAL_SIGNING=1)." >&2
else
  if [ ! -d "${APPEX_BUNDLE}" ]; then
    echo "Finder extension bundle not found: ${APPEX_BUNDLE}" >&2
    exit 1
  fi
  if [ ! -f "${LOCAL_FINDER_ENTITLEMENTS}" ]; then
    echo "Local Finder entitlements not found: ${LOCAL_FINDER_ENTITLEMENTS}" >&2
    exit 1
  fi

  # A local artifact has no provisioning profile on this machine. Ad-hoc
  # signing still gives Finder a sealed, entitlement-bearing extension while
  # the configured home-relative IPC path avoids App Group/keychain access.
  echo "==> Signing the Finder extension and sealing the app (${SIGNING_IDENTITY})..."
  # Re-sign the nested executable and its containing .appex together. The
  # deep pass is required here: signing the container alone can leave the
  # archive-build signature (and its unresolved build-setting placeholders)
  # on the executable, which makes macOS ignore the local entitlements and
  # prevents PlugInKit from registering the extension.
  codesign --force --deep --sign "${SIGNING_IDENTITY}" \
    --entitlements "${LOCAL_FINDER_ENTITLEMENTS}" \
    "${APPEX_BUNDLE}"
  codesign --force --sign "${SIGNING_IDENTITY}" "${APP_BUNDLE}"
  codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"
fi

echo "==> Created macOS application bundle at:"
echo "    ${APP_BUNDLE}"
echo "    ${DIST_DIR}/${APP_NAME}.app.dSYM"
