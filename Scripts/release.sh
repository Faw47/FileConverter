#!/bin/bash
set -euo pipefail

# Builds a signed, notarized File Converter DMG that opens on any Mac
# without Gatekeeper warnings.
#
# Usage:
#   ./Scripts/release.sh --check     report what is missing, build nothing
#   ./Scripts/release.sh [VERSION]   build dist/File Converter VERSION.dmg
#
# Needs, once per Mac:
#   1. A "Developer ID Application" certificate in the login keychain
#      (Xcode › Settings › Accounts › Manage Certificates › + ).
#   2. A notarytool keychain profile:
#        xcrun notarytool store-credentials "FileConverterNotary" \
#          --apple-id YOU@EXAMPLE.COM --team-id TEAMID --password APP-SPECIFIC-PASSWORD
#
# Environment (optional):
#   DEVELOPER_ID_APPLICATION  signing identity name; found automatically if unset
#   NOTARY_PROFILE            notarytool profile name (default FileConverterNotary)
#   FILE_CONVERTER_DIST_DIR   build somewhere other than dist/
#   FILE_CONVERTER_RELEASE_DRY_RUN=1
#                             sign ad hoc and skip notarization, to test the
#                             build, signing, and DMG steps without the account

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="File Converter"
DIST_DIR="${FILE_CONVERTER_DIST_DIR:-${PROJECT_DIR}/dist}"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
APPEX_BUNDLE="${APP_BUNDLE}/Contents/PlugIns/FileConverterFinderExtension.appex"
APP_ENTITLEMENTS="${PROJECT_DIR}/Scripts/FileConverterAppLocal.entitlements"
FINDER_ENTITLEMENTS="${PROJECT_DIR}/Scripts/FileConverterFinderLocal.entitlements"
NOTARY_PROFILE="${NOTARY_PROFILE:-FileConverterNotary}"

CHECK_ONLY=0
VERSION=""
for arg in "$@"; do
  case "${arg}" in
    --check) CHECK_ONLY=1 ;;
    -h|--help) sed -n '4,26p' "$0"; exit 0 ;;
    -*) echo "Unknown option ${arg}. Usage: $0 [--check] [VERSION]" >&2; exit 64 ;;
    *) VERSION="${arg}" ;;
  esac
done

DRY_RUN="${FILE_CONVERTER_RELEASE_DRY_RUN:-0}"
IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
TIMESTAMP="--timestamp"
if [ "${DRY_RUN}" = "1" ]; then
  IDENTITY="-"
  TIMESTAMP="--timestamp=none"
fi
if [ -z "${IDENTITY}" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application:/{print $2; exit}' || true)"
fi

missing=0
report() { echo "  ✗ $1" >&2; missing=1; }
echo "==> Checking release prerequisites..."
if [ -n "${IDENTITY}" ]; then
  echo "  ✓ Signing identity: ${IDENTITY}"
else
  report "No \"Developer ID Application\" certificate in the keychain (Apple Development certificates can't be notarized)."
fi
if [ "${DRY_RUN}" = "1" ]; then
  echo "  • Dry run: ad-hoc signature, no notarization"
elif xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
  echo "  ✓ Notary profile: ${NOTARY_PROFILE}"
else
  report "No usable notarytool profile named \"${NOTARY_PROFILE}\" (see the header of this script)."
fi
for tool in xcodebuild hdiutil codesign xcrun spctl; do
  command -v "${tool}" >/dev/null 2>&1 || report "${tool} not found."
done
for file in "${APP_ENTITLEMENTS}" "${FINDER_ENTITLEMENTS}"; do
  [ -f "${file}" ] || report "Missing ${file}."
done

if [ "${CHECK_ONLY}" -eq 1 ]; then
  [ "${missing}" -eq 0 ] && echo "==> Ready to release." || echo "==> Not ready; see above." >&2
  exit "${missing}"
fi
if [ "${missing}" -ne 0 ]; then
  echo "==> Can't release until the items above are fixed." >&2
  exit 1
fi

echo "==> Building the app (Release)..."
FILE_CONVERTER_SKIP_LOCAL_SIGNING=1 "${PROJECT_DIR}/Scripts/package_app.sh" --no-backup Release

if [ -z "${VERSION}" ]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_BUNDLE}/Contents/Info.plist")"
fi

# Inside out: the extension's executable, the extension, then the app.
# Hardened runtime and a secure timestamp are what notarization requires.
sign() {
  codesign --force --options runtime "${TIMESTAMP}" --sign "${IDENTITY}" --entitlements "$1" "$2"
}
echo "==> Signing with ${IDENTITY}..."
APPEX_EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${APPEX_BUNDLE}/Contents/Info.plist")"
sign "${FINDER_ENTITLEMENTS}" "${APPEX_BUNDLE}/Contents/MacOS/${APPEX_EXECUTABLE_NAME}"
sign "${FINDER_ENTITLEMENTS}" "${APPEX_BUNDLE}"
sign "${APP_ENTITLEMENTS}" "${APP_BUNDLE}"
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"

DMG="${DIST_DIR}/${APP_NAME} ${VERSION}.dmg"
STAGE="$(mktemp -d "/tmp/FileConverterRelease.XXXXXX")"
trap 'rm -R "${STAGE}"' EXIT
echo "==> Making ${DMG}..."
ditto "${APP_BUNDLE}" "${STAGE}/${APP_NAME}.app"
ln -s /Applications "${STAGE}/Applications"
rm -f "${DMG}"
hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGE}" -fs HFS+ -format UDZO -ov "${DMG}" >/dev/null
codesign --force "${TIMESTAMP}" --sign "${IDENTITY}" "${DMG}"

if [ "${DRY_RUN}" = "1" ]; then
  hdiutil verify "${DMG}" >/dev/null
  echo "==> Dry run done (not notarized): ${DMG}"
  exit 0
fi

echo "==> Notarizing (this usually takes a few minutes)..."
xcrun notarytool submit "${DMG}" --keychain-profile "${NOTARY_PROFILE}" --wait
xcrun stapler staple "${DMG}"
xcrun stapler validate "${DMG}"
spctl --assess --type open --context context:primary-signature --verbose=2 "${DMG}"

echo "==> Released: ${DMG}"
