import Foundation
import CoreServices

// Convierte las lecturas del registro en sesiones con fase y detecta los dos
// eventos que importan: una sesion pasa a esperar al usuario, o termina un
// turno de trabajo.

struct Sesion: Identifiable, Equatable {
    let id: String
    let pid: Int32
    let cwd: String
    let carpeta: String
    let titulo: String
    let modo: Modo
    let fase: Fase
    let esperaPor: String?
    let desde: Date

    var nombreCarpeta: String {
        let n = (carpeta as NSString).lastPathComponent
        return n.isEmpty ? carpeta : n
    }

    var textoFase: String {
        switch fase {
        case .atencion:
            switch esperaPor {
            case "permission prompt": return "Pide permiso"
            case "input needed": return "Te hace una pregunta"
            case "dialog open": return "Diálogo abierto"
            default: return "Requiere atención"
            }
        case .termino: return "Terminó"
        case .trabajando: return "Trabajando"
        case .inactiva: return "Inactiva"
        }
    }
}

enum Evento {
    case atencion(Sesion)
    case termino(Sesion)

    var sesion: Sesion {
        switch self {
        case .atencion(let s), .termino(let s): return s
        }
    }
}

final class Vigia: ObservableObject {
    @Published private(set) var sesiones: [Sesion] = []
    var alOcurrir: ((Evento) -> Void)?

    /// Un turno mas corto no cuenta como "termino" (comandos instantaneos).
    static let turnoMinimo: TimeInterval = 2
    /// Tiempo que debe sostenerse "idle" antes de avisar: al terminar un turno
    /// con un mensaje en cola, la sesion pasa por idle un instante.
    static let confirmacion: TimeInterval = 1.5

    private struct Lectura {
        let registro: RegistroSesion
        let transcript: DatosTranscript
        let carpeta: String
    }

    private struct Previo {
        var estado: String
        var inicioTurno: Date?
    }

    private let cola = DispatchQueue(label: "sauron.lectura", qos: .utility)
    private let lector = LectorTranscript()
    private var observador: Observador?
    private var respaldo: Timer?
    /// Fin de cada proceso de Claude Code: si muere sin borrar su registro
    /// (cierre forzado), se entera al instante y sin sondear.
    private var finales: [Int32: DispatchSourceProcess] = [:]
    /// Procesos cuyo aviso de fin ya llego: no se vuelven a vigilar. Si el
    /// sistema avisara de un proceso que sigue vivo, recrear la fuente en
    /// cada lectura seria un bucle; para ese caso queda el respaldo.
    private var yaAvisaron = Set<Int32>()

    private var previos: [String: Previo] = [:]
    private var terminadas: [String: Date] = [:]    // termino y aun no se ve
    private var porConfirmar: [String: Date] = [:]  // busy -> idle por confirmar
    private var primeraPasada = true
    private var leyendo = false
    private var otraPendiente = false

    /// Todo por eventos: FSEvents sobre los registros de sesion y los locks
    /// del IDE, y el fin de cada proceso. En reposo no se lee nada. El
    /// temporizador es solo un respaldo por si se perdiera un evento.
    func iniciar() {
        observador = Observador(rutas: [Rutas.sesiones.path, Rutas.ide.path]) { [weak self] in
            self?.refrescar()
        }
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.refrescar() }
        t.tolerance = 15
        RunLoop.main.add(t, forMode: .common)
        respaldo = t
        refrescar()
    }

    private func vigilarProcesos(_ pids: Set<Int32>) {
        for (pid, fuente) in finales where !pids.contains(pid) {
            fuente.cancel()
            finales[pid] = nil
        }
        yaAvisaron.formIntersection(pids)
        for pid in pids where finales[pid] == nil && !yaAvisaron.contains(pid) {
            let fuente = DispatchSource.makeProcessSource(identifier: pid_t(pid), eventMask: .exit, queue: .main)
            fuente.setEventHandler { [weak self] in
                guard let self else { return }
                self.yaAvisaron.insert(pid)
                self.finales[pid]?.cancel()
                self.finales[pid] = nil
                self.refrescar()
            }
            fuente.resume()
            finales[pid] = fuente
        }
    }

    func refrescar() {
        if leyendo {
            otraPendiente = true
            return
        }
        leyendo = true
        cola.async { [weak self, lector] in
            let carpetas = Registro.carpetasAbiertas()
            let registros = Registro.sesiones()
            let lecturas = registros.map { r in
                Lectura(
                    registro: r,
                    transcript: lector.datos(sesion: r.sesion, cwd: r.cwd),
                    carpeta: Registro.carpeta(para: r.cwd, en: carpetas)
                )
            }
            lector.olvidar(salvo: Set(registros.map(\.sesion)))
            DispatchQueue.main.async {
                guard let self else { return }
                self.aplicar(lecturas)
                self.leyendo = false
                if self.otraPendiente {
                    self.otraPendiente = false
                    self.refrescar()
                }
            }
        }
    }

    func marcarVista(_ id: String) {
        guard terminadas.removeValue(forKey: id) != nil else { return }
        sesiones = sesiones.map { s in s.id == id ? reconstruir(s, fase: .inactiva) : s }.sorted(by: Self.orden)
    }

    func marcarTodas() {
        guard !terminadas.isEmpty else { return }
        terminadas.removeAll()
        sesiones = sesiones.map { s in s.fase == .termino ? reconstruir(s, fase: .inactiva) : s }.sorted(by: Self.orden)
    }

    // MARK: - Maquina de estados

    private func aplicar(_ lecturas: [Lectura]) {
        let ahora = Date()
        var nuevas: [Sesion] = []
        var avisosAtencion: [String] = []
        var avisosTermino: [String] = []
        var vivas = Set<String>()
        var reintentar = false

        for l in lecturas {
            let r = l.registro
            let id = r.sesion
            vivas.insert(id)
            let previo = previos[id]
            var inicio = previo?.inicioTurno

            switch r.estado {
            case "busy", "waiting":
                if previo == nil || previo?.estado == "idle" { inicio = r.actualizado }
                terminadas[id] = nil
                porConfirmar[id] = nil
                let empiezaEspera = r.estado == "waiting"
                    && (previo.map { $0.estado != "waiting" } ?? !primeraPasada)
                if empiezaEspera { avisosAtencion.append(id) }
            default:
                if let p = previo, p.estado == "busy", !primeraPasada {
                    let duracion = r.actualizado.timeIntervalSince(inicio ?? r.actualizado)
                    if duracion >= Self.turnoMinimo { porConfirmar[id] = r.actualizado }
                }
                inicio = nil
                if let t = porConfirmar[id] {
                    if ahora.timeIntervalSince(t) >= Self.confirmacion {
                        porConfirmar[id] = nil
                        terminadas[id] = t
                        avisosTermino.append(id)
                    } else {
                        reintentar = true
                    }
                }
            }
            previos[id] = Previo(estado: r.estado, inicioTurno: inicio)

            let fase: Fase
            switch r.estado {
            case "waiting": fase = .atencion
            case "busy": fase = .trabajando
            default: fase = terminadas[id] != nil ? .termino : .inactiva
            }
            let t = l.transcript
            nuevas.append(Sesion(
                id: id,
                pid: r.pid,
                cwd: r.cwd,
                carpeta: l.carpeta,
                titulo: t.tituloPropio ?? r.nombrePropio ?? t.tituloIA ?? "Nueva sesión",
                modo: Modo(texto: t.modo),
                fase: fase,
                esperaPor: r.esperaPor,
                desde: fase == .termino ? (terminadas[id] ?? r.actualizado) : r.actualizado
            ))
        }

        vigilarProcesos(Set(lecturas.map(\.registro.pid)))

        for id in previos.keys where !vivas.contains(id) {
            previos[id] = nil
            terminadas[id] = nil
            porConfirmar[id] = nil
        }
        primeraPasada = false

        nuevas.sort(by: Self.orden)
        if nuevas != sesiones { sesiones = nuevas }

        // Primero los "termino" y al final los de atencion: si coinciden, el
        // ultimo aviso (el que se asoma) es el mas urgente.
        for id in avisosTermino {
            if let s = nuevas.first(where: { $0.id == id }) { emitir(.termino(s)) }
        }
        for id in avisosAtencion {
            if let s = nuevas.first(where: { $0.id == id }) { emitir(.atencion(s)) }
        }
        if reintentar {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.confirmacion + 0.1) { [weak self] in
                self?.refrescar()
            }
        }
    }

    private func emitir(_ e: Evento) {
        let s = e.sesion
        let tipo: String
        switch e {
        case .atencion: tipo = "atencion"
        case .termino: tipo = "termino"
        }
        print(String(format: "%.3f", Date().timeIntervalSince1970), tipo, s.nombreCarpeta, "|", s.titulo, "|", s.modo.rawValue)
        fflush(stdout)
        alOcurrir?(e)
    }

    private func reconstruir(_ s: Sesion, fase: Fase) -> Sesion {
        Sesion(id: s.id, pid: s.pid, cwd: s.cwd, carpeta: s.carpeta, titulo: s.titulo,
               modo: s.modo, fase: fase, esperaPor: s.esperaPor, desde: s.desde)
    }

    static func orden(_ a: Sesion, _ b: Sesion) -> Bool {
        if a.fase != b.fase { return a.fase < b.fase }
        return a.desde > b.desde
    }
}

// MARK: - FSEvents

/// Avisa cuando cambia algo dentro de unas carpetas. Claude Code reescribe el
/// registro de una sesion en cada cambio de estado.
final class Observador {
    private var flujo: FSEventStreamRef?
    private let accion: () -> Void

    init(rutas: [String], accion: @escaping () -> Void) {
        self.accion = accion
        var contexto = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let retorno: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Observador>.fromOpaque(info).takeUnretainedValue().accion()
        }
        let banderas = FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents)
        guard let flujo = FSEventStreamCreate(
            nil, retorno, &contexto, rutas as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, banderas
        ) else { return }
        FSEventStreamSetDispatchQueue(flujo, DispatchQueue.main)
        FSEventStreamStart(flujo)
        self.flujo = flujo
    }

    deinit {
        if let flujo {
            FSEventStreamStop(flujo)
            FSEventStreamInvalidate(flujo)
            FSEventStreamRelease(flujo)
        }
    }
}
