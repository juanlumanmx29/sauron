import AppKit
import SwiftUI

// `Sauron --capturas <carpeta>`: renderiza las vistas a PNG sin abrir ventanas
// ni necesitar permiso de grabación de pantalla. Usa sesiones de ejemplo que
// cubren todas las fases y todos los modos.

enum Capturas {
    @MainActor
    static func ejecutar(en carpeta: String) {
        let destino = URL(fileURLWithPath: carpeta, isDirectory: true)
        try? FileManager.default.createDirectory(at: destino, withIntermediateDirectories: true)
        let ui = Interfaz()
        // ImageRenderer no dibuja el contenido de un ScrollView: sin tope de alto.
        ui.altoMaximo = 4000
        let ahora = Date()

        func s(_ id: String, _ carpeta: String, _ titulo: String, _ modo: Modo, _ fase: Fase,
               _ espera: String? = nil, hace: TimeInterval) -> Sesion {
            Sesion(id: id, pid: 0, cwd: "/ejemplo/" + carpeta, carpeta: "/ejemplo/" + carpeta,
                   titulo: titulo, modo: modo, fase: fase, esperaPor: espera,
                   desde: ahora.addingTimeInterval(-hace))
        }
        let ejemplo = [
            s("1", "api", "Migrar autenticación a OAuth", .normal, .atencion, "permission prompt", hace: 20),
            s("2", "panel-web", "Rediseñar la página de configuración", .plan, .atencion, "input needed", hace: 95),
            s("3", "datos", "Limpiar duplicados del padrón de clientes", .auto, .termino, hace: 130),
            s("4", "api", "Corregir las pruebas de integración del módulo de pagos con un título largo", .aceptaEdiciones, .trabajando, hace: 300),
            s("5", "scripts", "Automatizar el respaldo nocturno", .sinPermisos, .trabajando, hace: 40),
            s("6", "docs", "Actualizar la guía de instalación", .auto, .inactiva, hace: 3700),
            s("7", "docs", "Nueva sesión", .desconocido, .inactiva, hace: 7200),
        ]

        guardar(Pildora(sesiones: ejemplo, ui: ui), "pildora-todo", destino)
        guardar(Pildora(sesiones: ejemplo.filter { $0.fase == .termino || $0.fase == .inactiva }, ui: ui),
                "pildora-termino", destino)
        guardar(Pildora(sesiones: ejemplo.filter { $0.fase == .inactiva }, ui: ui), "pildora-inactiva", destino)
        guardar(Pildora(sesiones: [], ui: ui), "pildora-vacia", destino)
        let permiso = Solicitud(
            id: "p1", sesion: "1", herramienta: "Bash",
            entrada: ["command": "npm run build --prefix web && npm test -- --runInBand",
                      "description": "Compilar la interfaz y correr las pruebas"],
            cwd: "/ejemplo/api")
        let edicion = Solicitud(
            id: "p2", sesion: "2", herramienta: "Edit",
            entrada: ["file_path": "/ejemplo/panel-web/src/config/Pagina.tsx",
                      "old_string": "const titulo = 'Ajustes'", "new_string": "const titulo = 'Configuración'"],
            cwd: "/ejemplo/panel-web")
        guardar(Aviso(sesion: ejemplo[0], ui: ui), "aviso-atencion", destino)
        guardar(Aviso(sesion: ejemplo[0], solicitudes: [permiso], ui: ui), "aviso-permiso", destino)
        let plan = Solicitud(
            id: "p3", sesion: "2", herramienta: "ExitPlanMode",
            entrada: ["plan": "# Rediseñar la página de configuración\n\n## Contexto\n\nLa página mezcla ajustes de cuenta y de equipo, y los usuarios no encuentran la facturación.\n\n## Pasos\n\n1. Separar en pestañas.\n2. Mover facturación arriba.",
                      "planFilePath": "/ejemplo/planes/configuracion.md"],
            cwd: "/ejemplo/panel-web")
        let pregunta = Solicitud(
            id: "p4", sesion: "2", herramienta: "AskUserQuestion",
            entrada: ["questions": [["question": "¿Qué base de datos usamos para las pruebas?", "header": "Base",
                                     "multiSelect": false,
                                     "options": [["label": "SQLite", "description": "Rápida, en memoria"],
                                                 ["label": "Postgres en Docker", "description": "Igual a producción"]]]]],
            cwd: "/ejemplo/panel-web")
        guardar(Aviso(sesion: ejemplo[1], solicitudes: [plan], ui: ui), "aviso-plan", destino)
        guardar(Aviso(sesion: ejemplo[1], solicitudes: [pregunta], ui: ui), "aviso-pregunta", destino)
        guardar(Aviso(sesion: ejemplo[0], sinEfecto: true, ui: ui), "aviso-sin-efecto", destino)
        guardar(Lista(sesiones: ejemplo, solicitudes: ["1": [permiso], "2": [edicion]], ui: ui),
                "lista-permisos", destino)
        guardar(Aviso(sesion: ejemplo[2], ui: ui), "aviso-termino", destino)
        guardar(Lista(sesiones: ejemplo, ui: ui), "lista", destino)
        guardar(Lista(sesiones: [], ui: ui), "lista-vacia", destino)
        guardarMenuSonidos(destino)
    }

    @MainActor
    private static func guardar<V: View>(_ vista: V, _ nombre: String, _ destino: URL) {
        let marco = vista
            .padding(16)
            .background(Color(white: 0.22))
            .environment(\.colorScheme, .dark)
            .environment(\.esCaptura, true)
        let r = ImageRenderer(content: marco)
        r.scale = 2
        guard let imagen = r.nsImage,
              let tiff = imagen.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            print("No se pudo renderizar \(nombre)")
            return
        }
        let url = destino.appendingPathComponent(nombre + ".png")
        try? png.write(to: url)
        print("\(url.path)  \(Int(imagen.size.width))x\(Int(imagen.size.height))")
    }

    /// Filas del submenu de sonidos sobre un fondo como el de un menu oscuro:
    /// un titulo de grupo, una fila elegida y otra resaltada.
    @MainActor
    private static func guardarMenuSonidos(_ destino: URL) {
        let elegida = VistaTonoMenu(id: "a", etiqueta: "Fanfarria", marcado: true)
        let resaltada = VistaTonoMenu(id: "b", etiqueta: "Cuerno", marcado: false)
        resaltada.resaltadoForzado = true
        let filas: [NSView] = [
            VistaTituloMenu("Épicos"), elegida, resaltada,
            VistaTonoMenu(id: "c", etiqueta: "Bosque de Sherwood", marcado: false),
            VistaTituloMenu("Sobrios"),
            VistaTonoMenu(id: "d", etiqueta: "Acorde", marcado: false),
        ]
        let alto = filas.reduce(CGFloat(10)) { $0 + $1.frame.height }
        let fondo = FondoMenu(frame: NSRect(x: 0, y: 0, width: VistaTonoMenu.ancho, height: alto))
        fondo.appearance = NSAppearance(named: .darkAqua)
        var y = alto - 5
        for f in filas {
            y -= f.frame.height
            f.frame.origin = NSPoint(x: 0, y: y)
            fondo.addSubview(f)
        }
        guard let rep = fondo.bitmapImageRepForCachingDisplay(in: fondo.bounds) else { return }
        fondo.cacheDisplay(in: fondo.bounds, to: rep)
        let url = destino.appendingPathComponent("menu-sonidos.png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

private final class FondoMenu: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.16, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}
