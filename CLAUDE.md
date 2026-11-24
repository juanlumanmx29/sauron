# Sauron

Widget flotante (AppKit + SwiftUI) que avisa cuando una sesión de Claude Code
en VS Code requiere atención o terminó, y lleva a su pestaña con un clic.
Ver `README.md` para el uso.

> **Repositorio público** (reemplazó a una versión anterior en Node). Nada de
> lo que se escriba aquí puede contener rutas personales, nombres de usuario
> ni datos de sesiones reales (tampoco en los ejemplos de `Capturas.swift`).

## Arquitectura

```
Sources/Sauron/
  main.swift           arranque, instancia única, modos --volcar / --capturas / --autoprueba / --icono / --sonidos
  Registro.swift       lee ~/.claude/sessions (estado por proceso) y ~/.claude/ide (carpetas por ventana)
  Transcript.swift     título y modo desde el .jsonl: lectura hacia atrás y luego incremental
  Estado.swift         Vigia: máquina de estados, eventos; FSEvents + fin de proceso, respaldo de 60 s
  Actividad.swift      trabajo en segundo plano: comandos (procesos hijos) y subagentes (meta.json)
  Panel.swift          NSPanel flotante, Controlador (ancla, arrastre, asomarse, menú)
  Vistas.swift         SwiftUI: píldora, lista, fila, aviso
  Logo.swift           el Ojo: icono de la app, logo del README y ojo de la píldora (Core Graphics)
  CuadrosAnimados.swift  animación por cuadros con Core Animation (ojo de la píldora, destello de las filas)
  Tema.swift           paleta (tema oscuro de la CLI), Modo, Fase
  Enfoque.swift        abrir carpeta en VS Code y luego vscode://anthropic.claude-code/open?session=
  Permisos.swift       hook PermissionRequest (--hook-permiso), socket privado, Solicitud y GestorPermisos
  Sonido.swift         catálogo de tonos de macOS (ToneLibrary y /System/Library/Sounds), AVAudioPlayer
  MenuTonos.swift      filas propias del submenú de sonidos (no cierran el menú al elegir)
  Volcado.swift, Capturas.swift, Autoprueba.swift
```

## Reglas duras

1. **Solo Command Line Tools, sin Xcode.** Las macros de SwiftUI no compilan
   (su plugin viene con Xcode): nada de `@State`, `@Entry`, `@Observable` ni
   `#Preview`. En su lugar: `private let x = State(initialValue:)` con
   `x.wrappedValue` (tiene `nonmutating set`), `EnvironmentKey` escrita a mano
   y `ObservableObject` + `@Published`.
2. **Solo lectura sobre `~/.claude`, con una excepción autorizada:**
   `instalar.sh` agrega (y `--desinstalar` quita) el hook `PermissionRequest`
   en `~/.claude/settings.json`, tocando solo esa entrada. El hook nunca
   bloquea a Claude Code: ante cualquier fallo sale con 0 y sin salida. Nada
   más se escribe en `~/.claude`. Las pruebas usan `SAURON_CLAUDE_DIR`
   apuntando a una copia falsa.
3. **El conocimiento del formato de Claude Code vive en `Registro.swift` y
   `Transcript.swift`.** Si cambia, se adapta ahí. Campos ausentes degradan a
   valores de respaldo, nunca rompen.
4. **Idioma.** Identificadores y comentarios en español sin acentos; acentos
   solo en los textos que ve el usuario.

## Trampas ya encontradas

- **`@State` es una macro en este SDK.** Ver regla 1.
- **"idle" no siempre es "terminó".** Con comandos en segundo plano (Bash
  `run_in_background`, Monitor) o subagentes, el registro dice `idle` y la
  sesión sigue trabajando. Comandos: hijos del proceso de la sesión cuya línea
  lleva `/shell-snapshots/` (así los lanza el Bash de Claude Code; los
  servidores MCP también son hijos, pero sin esa marca). Con la sesión
  trabajando, ese hijo es el comando en curso: solo se cuentan en reposo.
  Subagentes: `<sesión>/subagents/agent-*.meta.json` sin `finished` (se
  agrega `true` al terminar). Uno cortado al cerrar la sesión queda sin
  `finished`: solo cuenta si su transcript es posterior al `startedAt` del
  proceso y de menos de 2 h. Los terminados se recuerdan y no se releen.
- **El fin del trabajo de fondo no cambia el registro de la sesión**: los
  comandos se vigilan con una fuente de fin de proceso y los subagentes con
  FSEvents sobre `projects/` (latencia 1 s, filtrado a `*.meta.json` de
  `subagents/`; los transcripts, que cambian sin parar, se descartan). Al
  terminar, Claude Code suele retomar enseguida: "Terminó" espera 3 s.
- **En las simulaciones, `zsh -c "…; sleep N"` pierde la marca**: zsh se
  reemplaza por el último comando. Claude Code siempre agrega comandos
  después (`eval`, `pwd`), así que en la realidad el `zsh` queda.
- **Hook y diálogo compiten** (`Promise.race` en la ruta del host SDK de la
  extensión, 2.1.331): si el hook decide primero, Claude Code cancela el
  diálogo de VS Code; si se contesta en VS Code, la salida del hook se ignora
  **pero su proceso no se mata** (sigue hasta el timeout de 3600 s). Por eso
  `GestorPermisos` suelta la conexión cuando la sesión deja de esperar, con
  2,5 s de margen: el hook y el cambio de estado del registro llegan en
  cualquier orden.
- **Aprobar un plan exige `updatedInput`.** Para herramientas con
  `requiresUserInteraction` (como `ExitPlanMode`), Claude Code descarta un
  `allow` del hook (`qho` en `Wxn`) y sigue esperando el diálogo, salvo que
  traiga `updatedInput` y la herramienta esté en `u2i` (`ExitPlanMode`,
  `AskUserQuestion`). El hook devuelve la entrada sin cambios: si cambiara, la
  rechaza. En los permisos normales **no** se manda `updatedInput`: forzaría a
  reevaluar la llamada (`Ek`) y algunas aprobaciones pasarían a rechazo.
- **`AskUserQuestion` solo se avisa**: necesita las respuestas elegidas, que
  Sauron no escribe. El servidor suelta el hook al instante y la tarjeta
  ofrece "Responder en VS Code".
- **Red de seguridad**: si 3 s después de aprobar desde Sauron la sesión sigue
  esperando y no llegó otra petición, se marca "sin efecto" y se vuelve a
  asomar con el aviso. Antes, un `allow` ignorado hacía desaparecer la tarjeta
  mientras VS Code seguía esperando.
- **El hook solo actúa con `CLAUDE_CODE_ENTRYPOINT=claude-vscode`.** En la
  terminal el flujo de permisos es otro y no se probó.
- **`bind` con umask 077 deja el socket en 0700**, no 0600: se fija con
  `chmod`. La carpeta 0700 ya impide entrar a otros usuarios.
- **La primera ejecución tras firmar tarda ~1 s** (macOS verifica la firma);
  después el hook arranca en 5-10 ms.
- **`settings.json` se reescribe con `indent=2` y `ensure_ascii=False`**: así
  queda idéntico byte a byte salvo la entrada del hook (comprobado).
- **Sin sondeo.** El temporizador de 2 s se cambió por FSEvents sobre
  `sessions/` e `ide/` más una fuente de fin de proceso por sesión. Cada aviso
  de fin se atiende una sola vez (`yaAvisaron`): si el sistema avisara de un
  proceso vivo, recrear la fuente en cada lectura sería un bucle. Queda un
  respaldo de 60 s.
- **El monitor global de clics solo existe con algo abierto**: contraído no
  recibe un evento por cada clic del sistema.
- **El halo solo anima la opacidad de una capa rasterizada**: animar el radio
  de la sombra obliga al servidor de render a recalcularla en cada cuadro.
- **`onPreferenceChange` + `GeometryReader` no sirve para dimensionar el
  panel**: dentro del `NSPanel` se dispara una sola vez, con el valor por
  defecto. El tamaño sale de `intrinsicContentSize` (`sizingOptions =
  [.intrinsicContentSize]`) y `VistaAnfitriona.invalidateIntrinsicContentSize`
  avisa al controlador.
- **La posición se carga antes de asignar la vista.** SwiftUI informa su
  tamaño apenas se asigna como `contentView`; sin ancla, el panel acaba en
  (0,0).
- **`withAnimation(.repeatForever)` contamina la transacción**: animaba
  también los contadores, que parpadeaban o no se dibujaban.
- **El halo de atención con `TimelineView` a 30 cuadros costaba ~5 % de CPU**
  durante toda la espera de un permiso (pueden ser horas). Ahora es Core
  Animation (`HaloPulso` en `CuadrosAnimados.swift`): ~0,2 % con una sesión
  esperando y otra trabajando.
- **Las vistas de AppKit dentro de la píldora son transparentes al ratón**
  (`hitTest` devuelve `nil`): el clic y el arrastre son de SwiftUI.
- **Un `TimelineView` para el destello costaba ~3 % de CPU** sostenido. Las
  animaciones son una `CAKeyframeAnimation` sobre `contents` en una subcapa
  (`CuadrosAnimados`): corre en el servidor de render y la app queda en ~0 %.
  Va en subcapa porque AppKit puede reescribir el `contents` de la capa de la
  vista.
- **La capa de presentación no expone los cuadros** de una animación sobre
  `contents`; la autoprueba solo puede comprobar que esté instalada y en curso.
- **El menú contextual es de AppKit** (`rightMouseDown` en
  `VistaAnfitriona`). El `.contextMenu` de SwiftUI no es fiable en un panel
  que nunca toma el foco, y es la única vía para salir.
- **El panel no puede ser key** (`canBecomeKey = false`): si lo fuera, un
  clic le quitaría el teclado a VS Code. Por eso `acceptsFirstMouse = true`.
- **El `pid` de los locks de `~/.claude/ide` es el proceso principal de VS
  Code**, compartido por todas las ventanas. La sesión se asocia a su ventana
  por carpeta (prefijo más largo del `cwd`), no por pid.
- **Los registros `spare`** son procesos precalentados sin conversación: se
  descartan.
- **"Terminó" se confirma tras 1,5 s en `idle`**: al terminar un turno con un
  mensaje en cola, la sesión pasa por `idle` un instante. Turnos de menos de
  2 s no avisan.
- **`ImageRenderer` no dibuja vistas de AppKit**: en `--capturas` el ojo y el
  destello se sustituyen por un cuadro fijo (`EnvironmentValues.esCaptura`).
- **El icono no se versiona**: `construir.sh` lo dibuja con `--icono` y lo
  empaqueta con `iconutil`. `docs/logo.png` sí está en el repositorio (lo usa
  el README); si cambia el dibujo, se copia a mano desde
  `build.noindex/icono/logo.png`.
- **La salida va a `build.noindex/`**: Spotlight no indexa carpetas con ese
  sufijo. Con `build/`, la copia de compilación aparecía como un segundo
  Sauron en el lanzador de apps.
- **El lanzador guarda el icono en caché**: si la app se registró antes de
  tener icono, sigue mostrando el genérico. `instalar.sh` vuelve a registrar
  la app con `lsregister -f`; subir `CFBundleVersion` también lo renueva.
- **Los sonidos son tonos de macOS, no propios.** Se probó sintetizarlos
  (cuerno, tambores, campanas, arpa) y sonaban a videojuego barato. Los de
  `ToneLibrary.framework` son de un framework privado: la ruta puede cambiar
  entre versiones, y los que falten no se muestran (`--sonidos` lo lista).
  No se copian al repositorio.
- **Elegir un tono no cierra el menú** porque sus filas son items con vista
  (`MenuTonos.swift`): AppKit no cierra el menú ni envía acción al hacer clic
  en ellos; la vista maneja `mouseUp`. Esos items no dibujan nada por sí
  mismos (marca, resaltado, texto) y no tienen acción, así que el submenú
  lleva `autoenablesItems = false` o quedarían deshabilitados. La muestra se
  programa desde `menu(_:willHighlight:)` y, de respaldo, al redibujarse la
  fila resaltada; `programarMuestra` no la repite.
- **Volúmenes igualados** midiendo el RMS de los tramos activos de cada
  archivo y atenuando hasta ~-24 dB (nunca se sube). Los tonos de llamada se
  cortan: el arpa en el silencio que deja su primera frase (4,6 s), el
  campanario a los 4 s con 1 s de desvanecimiento. *Minuet* se descartó: dura
  7 s sin una pausa clara donde cortar.
- **En tamaños chicos la pupila se ensancha** (`Logo.dibujarOjo`): con pocos
  píxeles una rendija fina se mezcla con el iris y queda gris verdosa.
- **`layer.render(in:)` (la captura de `--autoprueba`) dibuja dos marcas en
  los extremos del borde de la píldora** que no aparecen con `ImageRenderer`
  (`--capturas`) y que siguen aunque se oculte el halo. Es un artefacto de esa
  vía de captura, no del dibujo.
- **`CGWindowListCopyWindowInfo` informa coordenadas que no coinciden con el
  `frame` de AppKit** en este equipo. Para verificar la posición, usar
  `--autoprueba`, que imprime el marco desde dentro.
- `swift build` con Command Line Tools avisa de rutas de búsqueda de `ld`
  inexistentes (XCTest). Es inocuo.

## Verificación

No basta con que compile. Antes de dar algo por terminado:

```bash
./construir.sh
F=build.noindex/Sauron.app/Contents/MacOS/Sauron

# Datos reales: títulos iguales a las pestañas, modo y carpeta correctos
$F --volcar

# Vistas con todas las fases y modos (revisar los PNG)
$F --capturas /ruta/temporal/capturas

# Ventana real: marcos dentro de la pantalla, ojo animado si alguna sesión trabaja
$F --autoprueba /ruta/temporal/autoprueba

# Icono: revisar build.noindex/icono/logo.png y los tamaños chicos del iconset

# Sonidos: que todos los tonos del catálogo existan en este Mac
$F --sonidos

# CPU en reposo ~0 % (medir unos 15 s con `ps -o time= -p <pid>`)
```

Para el puente de permisos, `pruebas/permisos.py` (detener antes el Sauron
instalado: comparten el socket). Cubre permitir, rechazar, aprobar un plan
(con `updatedInput` idéntico), seguir planificando, pregunta como aviso, red
de seguridad, Sauron apagado, sesión que no espera, hook muerto, sesión de
terminal, servidor impostor y permisos del socket.

Para la máquina de estados, simular transiciones escribiendo registros falsos
en una carpeta apuntada por `SAURON_CLAUDE_DIR` (con `sessions/`, `ide/` y
`projects/`) y leer los eventos que Sauron imprime por la salida estándar.
Casos mínimos: turno terminado, permiso pedido, turno corto sin aviso, mensaje
en cola sin aviso, sesión de CLI y `spare` ignoradas, sesión cerrada, y
trabajo de fondo: comando en segundo plano (el aviso llega cuando termina),
comando tras el que Claude retoma (sin aviso intermedio) y subagente (aviso
al escribir `finished`). Para el comando, la "sesión" falsa debe ser un
proceso propio que lance `zsh -c "source …/shell-snapshots/… ; sleep N; true"`.
