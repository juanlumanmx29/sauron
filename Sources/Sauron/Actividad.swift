import Darwin
import Foundation

// Trabajo que sigue cuando una sesion ya termino su turno: comandos en
// segundo plano (Bash con run_in_background, Monitor) y subagentes. El
// registro de la sesion solo dice "idle"; aqui se miran los procesos hijos y
// los archivos de los subagentes.

enum Procesos {
    /// Hijos del proceso de una sesion que son comandos del Bash de Claude
    /// Code, que los lanza con `zsh -c source …/shell-snapshots/…`. Con la
    /// sesion en reposo, son comandos en segundo plano. Los servidores MCP
    /// tambien son hijos, pero no llevan esa marca.
    static func enSegundoPlano(de pid: Int32) -> [Int32] {
        hijos(de: pid).filter { argumentos(de: $0)?.contains("/shell-snapshots/") == true }
    }

    static func hijos(de pid: Int32) -> [Int32] {
        let maximo = 256
        var buffer = [pid_t](repeating: 0, count: maximo)
        let bytes = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), &buffer,
                                  Int32(maximo * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        return buffer.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    /// Linea de comandos de un proceso (KERN_PROCARGS2: argc, la ruta y los
    /// argumentos separados por ceros). Bastan los primeros KB: la marca va
    /// en el primer argumento.
    static func argumentos(de pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var tamano = 16 * 1024
        var datos = [UInt8](repeating: 0, count: tamano)
        guard sysctl(&mib, 3, &datos, &tamano, nil, 0) == 0, tamano > 4 else { return nil }
        return String(decoding: datos[4..<tamano].map { $0 == 0 ? 0x20 : $0 }, as: UTF8.self)
    }
}

/// Subagentes en curso de una sesion: los `subagents/agent-*.meta.json` que
/// Claude Code deja junto al transcript. Al terminar les agrega
/// `"finished": true`.
final class ContadorSubagentes {
    /// Metas ya terminados: no cambian mas y no se vuelven a leer.
    private var terminados = Set<String>()
    /// Un subagente cortado (la sesion se cerro a mitad) queda sin
    /// "finished" para siempre: solo cuenta si su transcript se movio hace
    /// menos de esto y despues de que arranco el proceso de la sesion.
    static let vigencia: TimeInterval = 2 * 3600

    func activos(en carpeta: URL, desde inicio: Date?) -> Int {
        let fm = FileManager.default
        guard let archivos = try? fm.contentsOfDirectory(at: carpeta, includingPropertiesForKeys: nil) else {
            return 0
        }
        let ahora = Date()
        var cuenta = 0
        for url in archivos where url.lastPathComponent.hasSuffix(".meta.json") {
            let ruta = url.path
            if terminados.contains(ruta) { continue }
            guard let meta = Registro.leerJSON(url) else { continue }
            if meta["finished"] as? Bool == true {
                terminados.insert(ruta)
                continue
            }
            let transcript = String(ruta.dropLast(".meta.json".count)) + ".jsonl"
            let fecha = (try? fm.attributesOfItem(atPath: transcript)[.modificationDate] as? Date)
                ?? (try? fm.attributesOfItem(atPath: ruta)[.modificationDate] as? Date)
            guard let fecha, ahora.timeIntervalSince(fecha) < Self.vigencia else { continue }
            if let inicio, fecha < inicio { continue }
            cuenta += 1
        }
        return cuenta
    }
}
