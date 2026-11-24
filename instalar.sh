#!/bin/bash
# Instala Sauron en ~/Applications y lo deja arrancando al iniciar sesión
# mediante un LaunchAgent del usuario. También agrega el hook
# PermissionRequest a la configuración global de Claude Code, para aprobar
# permisos desde Sauron. Todo es reversible.
#
#   ./instalar.sh                 compila, instala, agrega el hook y arranca
#   ./instalar.sh --desinstalar   detiene y borra la app, el LaunchAgent y el hook
set -euo pipefail
cd "$(dirname "$0")"

ETIQUETA="local.sauron"
APP_DESTINO="$HOME/Applications/Sauron.app"
AGENTE="$HOME/Library/LaunchAgents/$ETIQUETA.plist"
DOMINIO="gui/$(id -u)"
CONFIG="$HOME/.claude/settings.json"
BINARIO="$APP_DESTINO/Contents/MacOS/Sauron"

detener() {
    launchctl bootout "$DOMINIO/$ETIQUETA" 2>/dev/null || true
    # Espera a que launchd termine de soltar el servicio antes de volver a
    # registrarlo; si no, bootstrap falla con "Input/output error".
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        launchctl print "$DOMINIO/$ETIQUETA" >/dev/null 2>&1 || break
        sleep 0.3
    done
    pkill -x Sauron 2>/dev/null || true
}

# Pone o quita el hook en la configuración global de Claude Code. Solo toca
# la entrada de Sauron; el resto del archivo queda igual. La primera vez
# guarda una copia junto al original (settings.json.antes-de-sauron).
hook() {
    local accion="$1"
    if [ "$accion" = "poner" ] && [ -f "$CONFIG" ] && [ ! -f "$CONFIG.antes-de-sauron" ]; then
        cp -p "$CONFIG" "$CONFIG.antes-de-sauron"
    fi
    /usr/bin/python3 - "$CONFIG" "$accion" "$BINARIO" <<'PY'
import json, os, sys, tempfile

ruta, accion, binario = sys.argv[1:4]
if not os.path.exists(ruta):
    if accion == "quitar":
        sys.exit(0)
    datos = {}
else:
    with open(ruta, encoding="utf-8") as f:
        datos = json.load(f)

def es_de_sauron(grupo):
    return any(h.get("command", "").endswith("Sauron.app/Contents/MacOS/Sauron")
               and "--hook-permiso" in h.get("args", []) for h in grupo.get("hooks", []))

hooks = datos.get("hooks", {})
lista = [g for g in hooks.get("PermissionRequest", []) if not es_de_sauron(g)]
if accion == "poner":
    # Forma exec (args): sin shell de por medio. Si el hook falla, Claude
    # Code lo ignora (onFailure por defecto) y sigue con su diálogo.
    lista.append({"matcher": "*", "hooks": [
        {"type": "command", "command": binario, "args": ["--hook-permiso"], "timeout": 3600}]})
if lista:
    hooks["PermissionRequest"] = lista
else:
    hooks.pop("PermissionRequest", None)
if hooks:
    datos["hooks"] = hooks
else:
    datos.pop("hooks", None)

carpeta = os.path.dirname(ruta)
os.makedirs(carpeta, exist_ok=True)
fd, temporal = tempfile.mkstemp(dir=carpeta, prefix=".settings.", suffix=".tmp")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write(json.dumps(datos, indent=2, ensure_ascii=False) + "\n")
if os.path.exists(ruta):
    os.chmod(temporal, os.stat(ruta).st_mode & 0o777)
os.replace(temporal, ruta)
PY
}

if [ "${1:-}" = "--desinstalar" ]; then
    detener
    hook quitar
    rm -f "$AGENTE"
    rm -rf "$APP_DESTINO" "$HOME/Library/Application Support/Sauron"
    echo "Sauron desinstalado (app, LaunchAgent y hook)."
    exit 0
fi

./construir.sh
detener

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$APP_DESTINO"
cp -R build.noindex/Sauron.app "$APP_DESTINO"

cat > "$AGENTE" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$ETIQUETA</string>
	<key>ProgramArguments</key>
	<array>
		<string>$BINARIO</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
</dict>
</plist>
PLIST
plutil -lint "$AGENTE" >/dev/null

# Registra la app en LaunchServices para que el lanzador tome su icono.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP_DESTINO" || true

hook poner

launchctl bootstrap "$DOMINIO" "$AGENTE"
echo "Sauron instalado en $APP_DESTINO y en marcha."
echo "Hook de permisos agregado a $CONFIG."
echo "Arranca solo al iniciar sesión. Para quitarlo: ./instalar.sh --desinstalar"
