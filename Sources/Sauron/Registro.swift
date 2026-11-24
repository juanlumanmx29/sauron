import Foundation

// Lectura, solo lectura, de dos fuentes que mantiene Claude Code:
//   ~/.claude/sessions/<pid>.json  estado vivo de cada proceso
//   ~/.claude/ide/<puerto>.lock    carpetas abiertas en cada ventana del IDE
// Todo el conocimiento del formato de estos archivos vive aqui. Si Claude
// Code lo cambia, se adapta en este archivo y en Transcript.swift.

enum Rutas {
    /// SAURON_CLAUDE_DIR permite apuntar a una copia de prueba de ~/.claude.
    static let claude: URL = {
        if let ruta = ProcessInfo.processInfo.environment["SAURON_CLAUDE_DIR"], !ruta.isEmpty {
            return URL(fileURLWithPath: ruta, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude", isDirectory: true)
    }()
    static let sesiones = claude.appendingPathComponent("sessions", isDirectory: true)
    static let ide = claude.appendingPathComponent("ide", isDirectory: true)
    static let proyectos = claude.appendingPathComponent("projects", isDirectory: true)
}

struct RegistroSesion {
    let pid: Int32
    let sesion: String
    let cwd: String
    let nombrePropio: String?   // solo si el usuario la nombro; el derivado no sirve
    let estado: String          // "busy", "waiting" o "idle"
    let esperaPor: String?      // "permission prompt", "input needed", "dialog open"
    let actualizado: Date
    let origen: String          // entrypoint: "claude-vscode", "cli", ...
}

enum Registro {
    static let origenVSCode = "claude-vscode"

    static func procesoVivo(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    static func leerJSON(_ url: URL) -> [String: Any]? {
        guard let datos = try? Data(contentsOf: url),
              let objeto = try? JSONSerialization.jsonObject(with: datos) as? [String: Any]
        else { return nil }
        return objeto
    }

    /// Sesiones con proceso vivo. Descarta los procesos precalentados
    /// ("spare"), que todavia no pertenecen a ninguna conversacion.
    static func sesiones(soloVSCode: Bool = true) -> [RegistroSesion] {
        let fm = FileManager.default
        guard let archivos = try? fm.contentsOfDirectory(at: Rutas.sesiones, includingPropertiesForKeys: nil)
        else { return [] }

        var porSesion: [String: RegistroSesion] = [:]
        for url in archivos where url.pathExtension == "json" {
            guard let o = leerJSON(url),
                  let pid = (o["pid"] as? NSNumber)?.int32Value,
                  let sesion = o["sessionId"] as? String, !sesion.isEmpty
            else { continue }
            if let reserva = o["spare"], !(reserva is NSNull), (reserva as? Bool) != false { continue }

            let origen = o["entrypoint"] as? String ?? ""
            if soloVSCode && origen != origenVSCode { continue }
            guard procesoVivo(pid) else { continue }

            let ms = ((o["statusUpdatedAt"] ?? o["updatedAt"]) as? NSNumber)?.doubleValue ?? 0
            let nombre = (o["nameSource"] as? String) == "derived" ? nil : o["name"] as? String
            let registro = RegistroSesion(
                pid: pid,
                sesion: sesion,
                cwd: o["cwd"] as? String ?? "",
                nombrePropio: (nombre?.isEmpty ?? true) ? nil : nombre,
                estado: o["status"] as? String ?? "idle",
                esperaPor: o["waitingFor"] as? String,
                actualizado: Date(timeIntervalSince1970: ms / 1000),
                origen: origen
            )
            // Una misma conversacion puede aparecer en dos procesos (al
            // reanudarla): manda el registro mas reciente.
            if let previo = porSesion[sesion], previo.actualizado >= registro.actualizado { continue }
            porSesion[sesion] = registro
        }
        return Array(porSesion.values)
    }

    /// Carpetas raiz de las ventanas del IDE con lock vigente.
    static func carpetasAbiertas() -> [String] {
        guard let archivos = try? FileManager.default.contentsOfDirectory(at: Rutas.ide, includingPropertiesForKeys: nil)
        else { return [] }
        var carpetas: [String] = []
        for url in archivos where url.pathExtension == "lock" {
            guard let o = leerJSON(url),
                  let pid = (o["pid"] as? NSNumber)?.int32Value,
                  procesoVivo(pid)
            else { continue }
            carpetas += (o["workspaceFolders"] as? [String]) ?? []
        }
        return carpetas
    }

    /// La carpeta de ventana que contiene el cwd (la mas especifica). Si
    /// ninguna lo contiene, el propio cwd.
    static func carpeta(para cwd: String, en carpetas: [String]) -> String {
        let limpio = cwd.count > 1 && cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        var mejor: String?
        for c in carpetas where limpio == c || limpio.hasPrefix(c + "/") {
            if c.count > (mejor?.count ?? -1) { mejor = c }
        }
        return mejor ?? limpio
    }
}
