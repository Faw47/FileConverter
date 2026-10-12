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

echo "==> Unregistering other copies of File Converter..."
"${LSREGISTER}" -dump 2>/dev/null \
  | awk -v id="${APP_ID}" '
      /^path:/ { sub(/^path:[ \t]*/, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); path = $0 }
      /^identifier:/ && $2 == id && path ~ /\.app$/ { print path }
    ' \
  | sort -u \
  | while IFS= read -r other; do
      if [ "${other}" != "${APP}" ]; then
        echo "    ${other}"
        "${LSREGISTER}" -u "${other}" 2>/dev/null || true
        pluginkit -r "${other}/Contents/PlugIns/FileConverterFinderExtension.appex" 2>/dev/null || true
      fi
    done

echo "==> Registering ${APP}..."
"${LSREGISTER}" -f -R "${APP}"
pluginkit -a "${APP}/Contents/PlugIns/FileConverterFinderExtension.appex"
pluginkit -e use -i "${EXTENSION_ID}"

echo "==> Finder extension now in use:"
pluginkit -m -v -i "${EXTENSION_ID}" || true

echo
echo "If the Finder menu does not appear, relaunch Finder (Option-right-click"
echo "Finder in the Dock, then Relaunch)."
