import Darwin
import Foundation

// Aprobar permisos desde Sauron.
//
// Claude Code ejecuta el hook PermissionRequest al mismo tiempo que muestra
// su dialogo: en la extension de VS Code (2.1.331) ambos compiten con
// `Promise.race` y gana el primero que decide. Si el hook gana, Claude Code
// cancela el dialogo; si el usuario contesta antes en VS Code, la salida del
// hook se ignora, pero su proceso sigue vivo hasta el timeout.
//
// El hook es este mismo binario (`Sauron --hook-permiso`): pasa la peticion
// a Sauron por un socket Unix privado y espera la decision.
// - Si Sauron no esta, la sesion no es de VS Code o algo falla, el hook sale
//   sin decidir y queda solo el dialogo normal.
// - Sauron suelta la conexion cuando la sesion deja de esperar (se contesto
//   en VS Code), y el hook sale sin decidir.
// - Cada extremo comprueba que el otro es este mismo ejecutable.

enum CanalPermisos {
    static var carpeta: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Sauron", isDirectory: true)
    }

    static var ruta: String { carpeta.appendingPathComponent("permisos.sock").path }

    /// Una peticion trae el `tool_input` completo (un Write puede ser grande).
    static let maximoPeticion = 4 << 20

    static func ejecutable(de pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return n > 0 ? String(cString: buffer) : nil
    }

    /// Verdadero si el proceso al otro lado del socket es este mismo programa.
    static func esEsteMismoPrograma(_ fd: Int32) -> Bool {
        var pid: pid_t = 0
        var largo = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &largo) == 0, pid > 0,
              let otro = ejecutable(de: pid), let propio = ejecutable(de: getpid())
        else { return false }
        return otro == propio
    }

    static func direccion() -> sockaddr_un? {
        var dir = sockaddr_un()
        let bytes = Array(ruta.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: dir.sun_path) else { return nil }
        dir.sun_family = sa_family_t(AF_UNIX)
        dir.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &dir.sun_path) { $0.copyBytes(from: bytes) }
        return dir
    }

    static func sinSIGPIPE(_ fd: Int32) {
        var uno: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &uno, socklen_t(MemoryLayout<Int32>.size))
    }

    static func escribirTodo(_ fd: Int32, _ datos: Data) -> Bool {
        datos.withUnsafeBytes { p -> Bool in
            guard let base = p.baseAddress else { return true }
            var hecho = 0
            while hecho < p.count {
                let n = write(fd, base + hecho, p.count - hecho)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                hecho += n
            }
            return true
        }
    }
}

// MARK: - Hook

enum HookPermiso {
    static let mensajeRechazo = "El usuario rechazó este permiso desde Sauron."
    static let mensajeSeguirPlanificando =
        "El usuario prefiere seguir planificando (respondió desde Sauron). No ejecutes el plan todavía."

    /// `Sauron --hook-permiso`. Nunca falla hacia Claude Code: ante cualquier
    /// problema sale con 0 y sin escribir nada, y Claude Code sigue con su
    /// dialogo.
    static func ejecutar() -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        let entrada = FileHandle.standardInput.readDataToEndOfFile()
        // Solo la extension de VS Code: en la terminal el flujo puede ser otro.
        guard ProcessInfo.processInfo.environment["CLAUDE_CODE_ENTRYPOINT"] == "claude-vscode",
              entrada.count <= CanalPermisos.maximoPeticion,
              let json = (try? JSONSerialization.jsonObject(with: entrada)) as? [String: Any],
              json["hook_event_name"] as? String == "PermissionRequest",
              json["session_id"] is String,
              var linea = try? JSONSerialization.data(withJSONObject: json),
              var dir = CanalPermisos.direccion()
        else { return 0 }
        linea.append(0x0A)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        CanalPermisos.sinSIGPIPE(fd)
        let conectado = withUnsafePointer(to: &dir) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard conectado == 0, CanalPermisos.esEsteMismoPrograma(fd),
              CanalPermisos.escribirTodo(fd, linea)
        else { return 0 }

        // Espera la decision. Si Sauron suelta la conexion, no hay decision.
        var respuesta = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while respuesta.count < 4096, !respuesta.contains(0x0A) {
            let n = read(fd, &buffer, buffer.count)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }
            respuesta.append(contentsOf: buffer[0..<n])
        }
        guard let fin = respuesta.firstIndex(of: 0x0A),
              let r = (try? JSONSerialization.jsonObject(with: Data(respuesta[..<fin]))) as? [String: Any]
        else { return 0 }
        var decision: [String: Any]
        switch r["decision"] as? String {
        case "allow":
            decision = ["behavior": "allow"]
            // Las herramientas que piden interaccion del usuario (aprobar un
            // plan) ignoran un "allow" del hook salvo que traiga
            // `updatedInput`; Claude Code solo lo admite para ExitPlanMode y
            // AskUserQuestion. Se devuelve la entrada tal cual: si cambiara,
            // la rechaza. En los permisos normales NO se manda: obligaria a
            // reevaluar la llamada y algunas aprobaciones pasarian a rechazo.
            if json["tool_name"] as? String == "ExitPlanMode", let entrada = json["tool_input"] as? [String: Any] {
                decision["updatedInput"] = entrada
            }
        case "deny":
            let mensaje = json["tool_name"] as? String == "ExitPlanMode" ? mensajeSeguirPlanificando : mensajeRechazo
            decision = ["behavior": "deny", "message": mensaje]
        default: return 0
        }
        let salida: [String: Any] = [
            "hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision],
        ]
        guard let datos = try? JSONSerialization.data(withJSONObject: salida) else { return 0 }
        FileHandle.standardOutput.write(datos)
        return 0
    }
}

// MARK: - Servidor (dentro de Sauron)

final class ServidorPermisos {
    /// En el hilo principal.
    var alRecibir: ((Solicitud) -> Void)?
    /// En el hilo principal: el hook se fue (timeout o turno cancelado).
    var alDesconectarse: ((String) -> Void)?

    private final class Cliente {
        let fd: Int32
        var fuente: DispatchSourceRead?
        var buffer = Data()
        var recibida = false
        init(fd: Int32) { self.fd = fd }
    }

    private let cola = DispatchQueue(label: "sauron.permisos")
    private var escucha: Int32 = -1
    private var fuente: DispatchSourceRead?
    private var clientes: [String: Cliente] = [:]   // solo desde `cola`

    func iniciar() -> Bool {
        let carpeta = CanalPermisos.carpeta
        try? FileManager.default.createDirectory(
            at: carpeta, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(carpeta.path, 0o700)
        guard var dir = CanalPermisos.direccion() else { return false }
        unlink(CanalPermisos.ruta)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        // El socket nace 0600: solo este usuario puede conectarse.
        let mascara = umask(0o077)
        let enlazado = withUnsafePointer(to: &dir) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(mascara)
        guard enlazado == 0, chmod(CanalPermisos.ruta, 0o600) == 0, listen(fd, 16) == 0 else {
            close(fd)
            return false
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        escucha = fd
        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: cola)
        s.setEventHandler { [weak self] in self?.aceptar() }
        s.resume()
        fuente = s
        return true
    }

    func responder(_ id: String, permitir: Bool) {
        cola.async {
            guard let c = self.clientes[id] else { return }
            let linea = permitir ? "{\"decision\":\"allow\"}\n" : "{\"decision\":\"deny\"}\n"
            _ = CanalPermisos.escribirTodo(c.fd, Data(linea.utf8))
            self.cerrar(id, avisar: false)
        }
    }

    /// Cierra sin decidir: el hook sale y Claude Code sigue con su dialogo.
    func soltar(_ id: String) {
        cola.async { self.cerrar(id, avisar: false) }
    }

    private func aceptar() {
        while true {
            let c = accept(escucha, nil, nil)
            if c < 0 { return }
            CanalPermisos.sinSIGPIPE(c)
            guard CanalPermisos.esEsteMismoPrograma(c) else {
                close(c)
                continue
            }
            _ = fcntl(c, F_SETFL, fcntl(c, F_GETFL) | O_NONBLOCK)
            let id = UUID().uuidString
            let cliente = Cliente(fd: c)
            let s = DispatchSource.makeReadSource(fileDescriptor: c, queue: cola)
            s.setEventHandler { [weak self] in self?.leer(id) }
            s.setCancelHandler { close(c) }
            cliente.fuente = s
            clientes[id] = cliente
            s.resume()
        }
    }

    private func leer(_ id: String) {
        guard let c = clientes[id] else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(c.fd, &buffer, buffer.count)
            if n > 0 {
                if c.recibida { continue }
                c.buffer.append(contentsOf: buffer[0..<n])
                if c.buffer.count > CanalPermisos.maximoPeticion {
                    cerrar(id, avisar: false)
                    return
                }
                guard let fin = c.buffer.firstIndex(of: 0x0A) else { continue }
                c.recibida = true
                let linea = Data(c.buffer[c.buffer.startIndex..<fin])
                c.buffer = Data()
                guard let s = Solicitud(id: id, json: linea) else {
                    cerrar(id, avisar: false)
                    return
                }
                DispatchQueue.main.async { [weak self] in self?.alRecibir?(s) }
                continue
            }
            if n == 0 {
                cerrar(id, avisar: true)
                return
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            cerrar(id, avisar: true)
            return
        }
    }

    /// Solo desde `cola`.
    private func cerrar(_ id: String, avisar: Bool) {
        guard let c = clientes.removeValue(forKey: id) else { return }
        c.fuente?.cancel()
        if avisar, c.recibida {
            DispatchQueue.main.async { [weak self] in self?.alDesconectarse?(id) }
        }
    }
}

// MARK: - Solicitud

/// Una peticion de permiso pendiente, ya traducida a algo legible.
struct Solicitud: Identifiable, Equatable {
    /// Que se puede contestar desde Sauron.
    enum Tipo: String {
        /// Permitir o rechazar.
        case permiso
        /// Aprobar el plan o seguir planificando.
        case plan
        /// Pide respuestas que Sauron no puede escribir: solo aviso.
        case pregunta
    }

    let id: String
    let tipo: Tipo
    let sesion: String
    let herramienta: String
    /// Que pide, en palabras: "Ejecutar comando", "Editar archivo"...
    let accion: String
    /// Sobre que: el comando, la ruta, la URL.
    let objeto: String
    /// Todo lo anterior con mas contexto, para el tooltip.
    let detalle: String
    let icono: String
    let llegada: Date

    init?(id: String, json: Data) {
        guard let d = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let sesion = d["session_id"] as? String,
              let herramienta = d["tool_name"] as? String
        else { return nil }
        self.init(id: id, sesion: sesion, herramienta: herramienta,
                  entrada: d["tool_input"] as? [String: Any] ?? [:], cwd: d["cwd"] as? String)
    }

    init(id: String, sesion: String, herramienta: String, entrada: [String: Any], cwd: String?,
         llegada: Date = Date()) {
        self.id = id
        self.sesion = sesion
        self.herramienta = herramienta
        self.llegada = llegada
        switch herramienta {
        case "ExitPlanMode": tipo = .plan
        case "AskUserQuestion": tipo = .pregunta
        default: tipo = .permiso
        }
        let d = Self.describir(herramienta, entrada, cwd)
        accion = d.accion
        objeto = String(d.objeto.prefix(800))
        detalle = String(d.detalle.prefix(4000))
        icono = d.icono
    }

    private static func describir(_ h: String, _ e: [String: Any], _ cwd: String?)
        -> (accion: String, objeto: String, detalle: String, icono: String) {
        func texto(_ k: String) -> String? {
            guard let s = e[k] as? String, !s.isEmpty else { return nil }
            return s
        }
        func ruta(_ k: String) -> String? {
            guard let r = texto(k) else { return nil }
            if let cwd, r.hasPrefix(cwd + "/") { return String(r.dropFirst(cwd.count + 1)) }
            return (r as NSString).abbreviatingWithTildeInPath
        }
        func lineas(_ s: String, _ n: Int) -> String {
            let todas = s.split(separator: "\n", omittingEmptySubsequences: false)
            let parte = todas.prefix(n).joined(separator: "\n")
            return todas.count > n ? parte + "\n…" : parte
        }
        func json() -> String {
            guard let datos = try? JSONSerialization.data(withJSONObject: e, options: [.sortedKeys]),
                  let s = String(data: datos, encoding: .utf8)
            else { return "" }
            return s
        }
        func juntar(_ partes: String?...) -> String { partes.compactMap { $0 }.joined(separator: "\n\n") }

        switch h {
        case "Bash":
            let comando = texto("command") ?? json()
            return ("Ejecutar comando", comando, juntar(texto("description"), comando), "terminal")
        case "Write":
            let r = ruta("file_path") ?? "?"
            return ("Escribir archivo", r, juntar(r, texto("content").map { lineas($0, 30) }), "doc.badge.plus")
        case "Edit", "MultiEdit":
            let r = ruta("file_path") ?? "?"
            var cambio: String?
            if let viejo = texto("old_string"), let nuevo = texto("new_string") {
                cambio = "− " + lineas(viejo, 12) + "\n+ " + lineas(nuevo, 12)
            }
            return ("Editar archivo", r, juntar(r, cambio), "pencil")
        case "NotebookEdit":
            let r = ruta("notebook_path") ?? "?"
            return ("Editar notebook", r, juntar(r, texto("new_source").map { lineas($0, 20) }), "pencil")
        case "Read":
            let r = ruta("file_path") ?? "?"
            return ("Leer archivo", r, r, "doc.text")
        case "Glob", "Grep":
            let patron = texto("pattern") ?? "?"
            let donde = ruta("path").map { "\(patron)  en  \($0)" } ?? patron
            return ("Buscar en archivos", donde, donde, "magnifyingglass")
        case "WebFetch":
            let url = texto("url") ?? "?"
            return ("Abrir página web", url, juntar(url, texto("prompt")), "globe")
        case "WebSearch":
            let q = texto("query") ?? "?"
            return ("Buscar en la web", q, q, "globe")
        case "ExitPlanMode":
            // Titulo (primer encabezado) y las primeras lineas con texto.
            let plan = texto("plan") ?? ""
            let todas = plan.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            let titulo = todas.first { $0.hasPrefix("#") }.map { $0.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) }
            let cuerpo = todas.filter { !$0.isEmpty && !$0.hasPrefix("#") }.prefix(3).joined(separator: "\n")
            let resumen = [titulo, cuerpo.isEmpty ? nil : cuerpo].compactMap { $0 }.joined(separator: "\n")
            return ("Aprobar plan", resumen.isEmpty ? "Plan sin texto" : resumen, lineas(plan, 60), "list.bullet.clipboard")
        case "AskUserQuestion":
            let preguntas = (e["questions"] as? [[String: Any]]) ?? []
            // Cada pregunta con sus opciones en una linea: "SQLite · Postgres".
            let textos = preguntas.compactMap { p -> String? in
                guard let q = p["question"] as? String else { return nil }
                let opciones = ((p["options"] as? [[String: Any]]) ?? []).compactMap { $0["label"] as? String }
                return opciones.isEmpty ? q : q + "\n" + opciones.joined(separator: " · ")
            }
            let detalle = preguntas.map { p -> String in
                let opciones = ((p["options"] as? [[String: Any]]) ?? []).map { o -> String in
                    let etiqueta = o["label"] as? String ?? "?"
                    return (o["description"] as? String).map { "• \(etiqueta): \($0)" } ?? "• \(etiqueta)"
                }
                return ([p["question"] as? String ?? "?"] + opciones).joined(separator: "\n")
            }.joined(separator: "\n\n")
            return ("Pregunta", textos.isEmpty ? "Pregunta" : textos.joined(separator: "\n"),
                    detalle.isEmpty ? json() : detalle, "questionmark.bubble")
        case "Task", "Agent":
            let d = texto("description") ?? "Subagente"
            return ("Lanzar subagente", d, juntar(d, texto("prompt").map { lineas($0, 20) }), "person.2")
        default:
            if h.hasPrefix("mcp__") {
                let partes = h.components(separatedBy: "__")
                let servidor = partes.count > 1 ? partes[1] : "MCP"
                let herramienta = partes.count > 2 ? partes[2...].joined(separator: "__") : h
                return ("MCP · \(servidor)", herramienta + "  " + json(), juntar(h, json()), "puzzlepiece")
            }
            return (h, json(), juntar(h, json()), "questionmark.circle")
        }
    }
}

// MARK: - Gestor

/// Peticiones pendientes, publicadas para la interfaz.
final class GestorPermisos: ObservableObject {
    @Published private(set) var pendientes: [Solicitud] = []
    /// Sesiones que siguen esperando aunque se aprobo desde Sauron: Claude
    /// Code no tomo la respuesta y hay que contestar en VS Code.
    @Published private(set) var sinEfecto = Set<String>()
    /// Llega una peticion nueva (para asomar la tarjeta).
    var alLlegar: ((Solicitud) -> Void)?
    /// Una aprobacion quedo sin efecto (para volver a asomar la tarjeta).
    var alQuedarSinEfecto: ((String) -> Void)?
    private(set) var activo = false
    private var aprobadas: [String: Date] = [:]
    /// Margen para ver si una aprobacion tuvo efecto: la sesion deberia dejar
    /// de esperar en milisegundos.
    static let comprobacion: TimeInterval = 3

    private let servidor = ServidorPermisos()
    private var sesiones: [Sesion] = []

    /// El hook y el cambio de estado del registro llegan casi a la vez, en
    /// cualquier orden: antes de soltar una peticion porque su sesion "no
    /// espera", se le da este margen.
    static let gracia: TimeInterval = 2.5

    func iniciar() {
        servidor.alRecibir = { [weak self] s in
            guard let self else { return }
            // Una pregunta no se puede contestar desde aqui: se suelta el hook
            // al instante (Claude Code sigue con su dialogo) y queda el aviso.
            if s.tipo == .pregunta { self.servidor.soltar(s.id) }
            self.sinEfecto.remove(s.sesion)
            self.pendientes.append(s)
            self.alLlegar?(s)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.gracia + 0.1) { [weak self] in
                self?.revisar()
            }
        }
        servidor.alDesconectarse = { [weak self] id in
            self?.pendientes.removeAll { $0.id == id }
        }
        activo = servidor.iniciar()
    }

    func de(_ sesion: String) -> [Solicitud] {
        pendientes.filter { $0.sesion == sesion }
    }

    func decidir(_ s: Solicitud, permitir: Bool) {
        guard s.tipo != .pregunta else { return }
        servidor.responder(s.id, permitir: permitir)
        pendientes.removeAll { $0.id == s.id }
        guard permitir else { return }
        aprobadas[s.sesion] = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.comprobacion + 0.2) { [weak self] in
            self?.revisar()
        }
    }

    func sincronizar(_ sesiones: [Sesion]) {
        self.sesiones = sesiones
        revisar()
    }

    /// Suelta las peticiones que ya no estan en juego: la sesion dejo de
    /// esperar un permiso (se contesto en VS Code) o no es una sesion de VS
    /// Code conocida.
    private func revisar() {
        let ahora = Date()
        // Cualquier espera: un plan o una pregunta no siempre figuran como
        // "permission prompt".
        let esperando = Set(sesiones.filter { $0.fase == .atencion }.map(\.id))
        let viejas = pendientes.filter {
            ahora.timeIntervalSince($0.llegada) >= Self.gracia && !esperando.contains($0.sesion)
        }
        if !viejas.isEmpty {
            for s in viejas { servidor.soltar(s.id) }
            let ids = Set(viejas.map(\.id))
            pendientes.removeAll { ids.contains($0.id) }
        }

        // Red de seguridad: si tras aprobar la sesion sigue esperando y no
        // llego otra peticion, Claude Code no tomo la respuesta.
        for (sesion, cuando) in aprobadas where ahora.timeIntervalSince(cuando) >= Self.comprobacion {
            aprobadas[sesion] = nil
            if esperando.contains(sesion), de(sesion).isEmpty, !sinEfecto.contains(sesion) {
                sinEfecto.insert(sesion)
                alQuedarSinEfecto?(sesion)
            }
        }
        let resueltas = sinEfecto.subtracting(esperando)
        if !resueltas.isEmpty { sinEfecto.subtract(resueltas) }
    }
}
