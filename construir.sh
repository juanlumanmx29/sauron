#!/bin/bash
# Compila Sauron en modo release y lo empaqueta como build.noindex/Sauron.app,
# firmado ad hoc. Solo requiere las Command Line Tools (sin Xcode).
set -euo pipefail
cd "$(dirname "$0")"

# La carpeta termina en .noindex para que Spotlight no la indexe: si no, la
# copia de compilación aparece como un segundo Sauron en el lanzador de apps.

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Sauron"

APP="build.noindex/Sauron.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Sauron"
cp Recursos/Info.plist "$APP/Contents/Info.plist"

# Icono: lo dibuja el propio binario (Logo.swift) y iconutil lo empaqueta.
rm -rf build.noindex/icono
"$BIN" --icono build.noindex/icono
iconutil -c icns build.noindex/icono/Sauron.iconset -o "$APP/Contents/Resources/Sauron.icns"
codesign --force --sign - "$APP" >/dev/null

echo "Listo: $(pwd)/$APP"
