import Foundation

// Titulo y modo de permisos de una sesion, sacados de su transcript
// ~/.claude/projects/<cwd codificado>/<sessionId>.jsonl
//
// - Titulo: ultima entrada "custom-title" (si se renombro) o "ai-title".
// - Modo: "permissionMode" de la ultima entrada "user" que lo traiga.
//
// Los transcripts pueden pesar decenas de MB. La primera lectura va desde el
// final hacia atras por bloques y se detiene al encontrar lo necesario; las
// siguientes solo leen los bytes agregados desde la ultima vez.
// No es seguro para hilos: se usa desde una sola cola.

struct DatosTranscript: Equatable {
    var tituloPropio: String?
    var tituloIA: String?
    var modo: String?

    var completo: Bool { (tituloPropio != nil || tituloIA != nil) && modo != nil }
}

final class LectorTranscript {
    private struct Entrada {
        var url: URL
        var offset: UInt64   // fin de la ultima linea completa ya procesada
        var datos: DatosTranscript
    }

    private var cache: [String: Entrada] = [:]
    private let bloque: UInt64 = 256 * 1024
    private let limiteHaciaAtras: UInt64 = 32 * 1024 * 1024

    private static let marcaIA = Data("\"ai-title\"".utf8)
    private static let marcaPropio = Data("\"custom-title\"".utf8)
    private static let marcaModo = Data("\"permissionMode\"".utf8)

    func datos(sesion: String, cwd: String) -> DatosTranscript {
        if var e = cache[sesion] {
            guard let tam = tamano(e.url) else {
                cache[sesion] = nil
                return DatosTranscript()
            }
            if tam < e.offset {
                // El archivo se reescribio: se lee de nuevo desde cero.
                cache[sesion] = nil
                return datos(sesion: sesion, cwd: cwd)
            }
            if tam > e.offset {
                leerAgregado(&e, hasta: tam)
                cache[sesion] = e
            }
            return e.datos
        }

        guard let url = ubicar(sesion: sesion, cwd: cwd), let tam = tamano(url) else {
            return DatosTranscript()
        }
        let (datos, offset) = leerHaciaAtras(url, tamano: tam)
        cache[sesion] = Entrada(url: url, offset: offset, datos: datos)
        return datos
    }

    func olvidar(salvo activas: Set<String>) {
        cache = cache.filter { activas.contains($0.key) }
    }

    // MARK: - Ubicacion

    /// Claude Code nombra la carpeta del proyecto con el cwd cambiando todo lo
    /// que no es alfanumerico ASCII por "-". Se intenta esa primero; si no
    /// existe se recorre projects/ entero.
    private func ubicar(sesion: String, cwd: String) -> URL? {
        let fm = FileManager.default
        let codificado = String(cwd.unicodeScalars.map { escalar -> Character in
            let v = escalar.value
            let alfanumerico = (48...57).contains(v) || (65...90).contains(v) || (97...122).contains(v)
            return alfanumerico ? Character(escalar) : "-"
        })
        let directa = Rutas.proyectos
            .appendingPathComponent(codificado, isDirectory: true)
            .appendingPathComponent(sesion + ".jsonl")
        if fm.fileExists(atPath: directa.path) { return directa }

        guard let carpetas = try? fm.contentsOfDirectory(at: Rutas.proyectos, includingPropertiesForKeys: nil)
        else { return nil }
        for carpeta in carpetas {
            let candidato = carpeta.appendingPathComponent(sesion + ".jsonl")
            if fm.fileExists(atPath: candidato.path) { return candidato }
        }
        return nil
    }

    private func tamano(_ url: URL) -> UInt64? {
        guard let atributos = try? FileManager.default.attributesOfItem(atPath: url.path),
              let n = atributos[.size] as? NSNumber
        else { return nil }
        return n.uint64Value
    }

    // MARK: - Lectura

    private func leerHaciaAtras(_ url: URL, tamano tam: UInt64) -> (DatosTranscript, UInt64) {
        var datos = DatosTranscript()
        guard let h = try? FileHandle(forReadingFrom: url) else { return (datos, 0) }
        defer { try? h.close() }

        var offset: UInt64 = tam
        var fin = tam
        var resto = Data()
        var primero = true
        let tope = tam > limiteHaciaAtras ? tam - limiteHaciaAtras : 0

        while fin > tope {
            let inicio = max(tope, fin > bloque ? fin - bloque : 0)
            do { try h.seek(toOffset: inicio) } catch { break }
            var trozo = h.readData(ofLength: Int(fin - inicio))
            if primero {
                // La lectura incremental retoma desde el fin de la ultima
                // linea completa; un fragmento final a medio escribir se
                // vuelve a leer la proxima vez.
                if let ultimo = trozo.lastIndex(of: 0x0A) {
                    offset = inicio + UInt64(trozo.distance(from: trozo.startIndex, to: ultimo)) + 1
                } else {
                    offset = inicio
                }
                primero = false
            }
            trozo.append(resto)
            var lineas = trozo.split(separator: 0x0A, omittingEmptySubsequences: false)
            if inicio > 0, !lineas.isEmpty {
                resto = Data(lineas.removeFirst())
            } else {
                resto = Data()
            }
            for linea in lineas.reversed() {
                aplicar(linea, a: &datos, reemplazar: false)
                if datos.completo { return (datos, offset) }
            }
            fin = inicio
        }
        return (datos, offset)
    }

    private func leerAgregado(_ e: inout Entrada, hasta tam: UInt64) {
        guard let h = try? FileHandle(forReadingFrom: e.url) else { return }
        defer { try? h.close() }
        do { try h.seek(toOffset: e.offset) } catch { return }
        let nuevo = h.readData(ofLength: Int(tam - e.offset))
        guard let ultimo = nuevo.lastIndex(of: 0x0A) else { return }
        let completas = nuevo[nuevo.startIndex...ultimo]
        for linea in completas.split(separator: 0x0A) {
            aplicar(linea, a: &e.datos, reemplazar: true)
        }
        e.offset += UInt64(completas.count)
    }

    /// Hacia atras (reemplazar = false) gana el primer valor encontrado, que
    /// es el mas reciente. Hacia adelante gana el ultimo.
    private func aplicar(_ linea: Data, a datos: inout DatosTranscript, reemplazar: Bool) {
        let ia = linea.range(of: Self.marcaIA) != nil
        let propio = linea.range(of: Self.marcaPropio) != nil
        let modo = linea.range(of: Self.marcaModo) != nil
        guard ia || propio || modo,
              let o = try? JSONSerialization.jsonObject(with: linea) as? [String: Any]
        else { return }

        switch o["type"] as? String {
        case "ai-title":
            if let t = o["aiTitle"] as? String, !t.isEmpty, reemplazar || datos.tituloIA == nil {
                datos.tituloIA = t
            }
        case "custom-title":
            if let t = o["customTitle"] as? String, !t.isEmpty, reemplazar || datos.tituloPropio == nil {
                datos.tituloPropio = t
            }
        case "user":
            if let m = o["permissionMode"] as? String, reemplazar || datos.modo == nil {
                datos.modo = m
            }
        default:
            break
        }
    }
}
