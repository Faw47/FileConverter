#!/bin/bash
set -euo pipefail

# Makes one copy of File Converter the one macOS uses: for "Open With",
# Services, and the Finder menu. Other registered copies (old Xcode builds
# in DerivedData, backups in dist/) are unregistered so Finder stops
# loading their extensions.
# Usage: ./Scripts/use_build.sh [path/to/File Converter.app]
#        (default: dist/File Converter.app)

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-${PROJECT_DIR}/dist/File Converter.app}"
APP_ID="io.fileconverter.app"
EXTENSION_ID="io.fileconverter.app.findersync"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [ ! -d "${APP}" ]; then
  echo "No app at ${APP}. Build one with Scripts/package_app.sh first." >&2
  exit 1
fi
APP="$(cd "$(dirname "${APP}")" && pwd)/$(basename "${APP}")"

# Every registered bundle with one of our identifiers, whatever its folder
# is called: backups like "File Converter.app.previous.<date>" do not end in
# ".app" but still carry a Finder extension macOS may choose.
registered_paths() {
  "${LSREGISTER}" -dump 2>/dev/null \
    | awk -v app="${APP_ID}" -v ext="${EXTENSION_ID}" '
        /^path:/ { sub(/^path:[ \t]*/, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); path = $0 }
        /^identifier:/ && ($2 == app || $2 == ext) { print path }
      ' \
    | sort -u
}

echo "==> Unregistering other copies of File Converter..."
registered_paths | while IFS= read -r other; do
  case "${other}" in
    "${APP}"|"${APP}"/*) continue ;;
  esac
  echo "    ${other}"
  case "${other}" in
    *.appex) pluginkit -r "${other}" 2>/dev/null || true ;;
    *) pluginkit -r "${other}/Contents/PlugIns/FileConverterFinderExtension.appex" 2>/dev/null || true ;;
  esac
  "${LSREGISTER}" -u "${other}" 2>/dev/null || true
done

echo "==> Registering ${APP}..."
"${LSREGISTER}" -f -R "${APP}"
pluginkit -a "${APP}/Contents/PlugIns/FileConverterFinderExtension.appex"
pluginkit -e use -i "${EXTENSION_ID}"

# pluginkit updates its database asynchronously; check after it settles.
EXPECTED="${APP}/Contents/PlugIns/FileConverterFinderExtension.appex"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  ACTIVE="$(pluginkit -m -v -i "${EXTENSION_ID}" 2>/dev/null | awk -F'\t' 'NF { print $NF; exit }')"
  [ "${ACTIVE}" = "${EXPECTED}" ] && break
  sleep 1
done

echo "==> Finder extension in use:"
echo "    ${ACTIVE:-none}"
LEFT="$(registered_paths | grep -v -F "${APP}" || true)"
if [ -n "${LEFT}" ]; then
  echo "==> Still registered elsewhere (macOS may re-register a copy when it is opened):"
  echo "${LEFT}" | sed 's/^/    /'
fi
if [ "${ACTIVE}" != "${EXPECTED}" ]; then
  echo "error: Finder is not using ${EXPECTED}" >&2
  exit 1
fi
echo
echo "If the Finder menu does not appear, relaunch Finder (Option-right-click"
echo "Finder in the Dock, then Relaunch)."
