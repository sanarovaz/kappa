#!/bin/bash
# Compila Kappa y arma Kappa.app en esta misma carpeta.
set -e
cd "$(dirname "$0")"

if ! command -v swift >/dev/null 2>&1; then
  echo "No encuentro 'swift'. Instalá las herramientas de línea de comandos con:"
  echo "    xcode-select --install"
  echo "y volvé a ejecutar este script."
  read -n 1 -s -r -p "Presioná una tecla para cerrar..."
  exit 1
fi

echo "==> Compilando (release)..."
swift build -c release

APP="Kappa.app"
echo "==> Armando $APP ..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/Kappa" "$APP/Contents/MacOS/Kappa"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/Kappa.icns "$APP/Contents/Resources/Kappa.icns"
codesign --force --deep --sign - "$APP"

echo "==> Cerrando instancias anteriores (si hay)..."
pkill -x Kappa || true
pkill -x BarraTicker || true
sleep 1

# Limpieza del nombre anterior
rm -rf "BarraTicker.app"

echo "==> Listo. Abriendo..."
open -n "$APP"
