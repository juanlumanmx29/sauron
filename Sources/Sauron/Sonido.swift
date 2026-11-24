import AVFoundation
import Foundation

/// Un sonido de aviso. Son tonos que ya trae macOS (alertas y tonos de llamada
/// de Apple, y los sonidos del sistema): Sauron no distribuye audio. Si un
/// archivo no existe en esta version del sistema, el tono no aparece.
struct Tono {
    enum Grupo: String, CaseIterable {
        case epicos = "Épicos"
        case sobrios = "Sobrios"
        case sistema = "Del sistema"
        case ninguno = ""
    }

    let id: String
    let etiqueta: String
    let grupo: Grupo
    /// nil: sin sonido.
    let ruta: String?
    /// Atenuacion para igualar el volumen: cada tono se lleva a un nivel
    /// activo de unos -24 dB RMS (medido sobre el archivo). Nunca se sube.
    let volumen: Float
    /// Corte para los tonos de llamada, que duran 10 s o mas.
    var corte: TimeInterval? = nil
    var desvanecer: TimeInterval = 0.1
}

enum Tonos {
    private static let alertas = "/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/AlertTones/"
    private static let llamadas = "/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/Ringtones/"
    private static let sistema = "/System/Library/Sounds/"

    static let catalogo: [Tono] = [
        Tono(id: "fanfarria", etiqueta: "Fanfarria", grupo: .epicos, ruta: alertas + "Classic/Fanfare.m4r", volumen: 0.62),
        Tono(id: "cuerno", etiqueta: "Cuerno", grupo: .epicos, ruta: alertas + "Classic/Horn.m4r", volumen: 0.37),
        Tono(id: "sherwood", etiqueta: "Bosque de Sherwood", grupo: .epicos,
             ruta: alertas + "Classic/Sherwood Forest.m4r", volumen: 0.28),
        // La primera frase del arpa termina en silencio a los 4,6 s.
        Tono(id: "arpa", etiqueta: "Arpa", grupo: .epicos, ruta: llamadas + "Harp.m4r", volumen: 0.59,
             corte: 4.6, desvanecer: 0.1),
        // Las campanas no paran: corte con desvanecimiento.
        Tono(id: "campanario", etiqueta: "Campanario", grupo: .epicos, ruta: llamadas + "Bell Tower.m4r",
             volumen: 0.91, corte: 4.0, desvanecer: 1.0),
        Tono(id: "campana", etiqueta: "Campana", grupo: .epicos, ruta: alertas + "Classic/Bell.m4r", volumen: 1.0),
        Tono(id: "hechizo", etiqueta: "Hechizo", grupo: .epicos, ruta: alertas + "Classic/Spell.m4r", volumen: 0.77),
        Tono(id: "suspenso", etiqueta: "Suspenso", grupo: .epicos, ruta: alertas + "Classic/Suspense.m4r", volumen: 0.71),

        Tono(id: "acorde", etiqueta: "Acorde", grupo: .sobrios, ruta: alertas + "Modern/Chord.m4r", volumen: 1.0),
        Tono(id: "nota", etiqueta: "Nota", grupo: .sobrios, ruta: alertas + "Modern/Note.m4r", volumen: 1.0),
        Tono(id: "aurora", etiqueta: "Aurora", grupo: .sobrios, ruta: alertas + "Modern/Aurora.m4r", volumen: 0.51),
        Tono(id: "bambu", etiqueta: "Bambú", grupo: .sobrios, ruta: alertas + "Modern/Bamboo.m4r", volumen: 0.91),
        Tono(id: "completado", etiqueta: "Completado", grupo: .sobrios, ruta: alertas + "Modern/Complete.m4r", volumen: 0.73),
        Tono(id: "carillon", etiqueta: "Carillón", grupo: .sobrios, ruta: alertas + "Classic/Chime.m4r", volumen: 0.97),

        Tono(id: "heroe", etiqueta: "Héroe", grupo: .sistema, ruta: sistema + "Hero.aiff", volumen: 0.73),
        Tono(id: "ping", etiqueta: "Ping", grupo: .sistema, ruta: sistema + "Ping.aiff", volumen: 1.0),
        Tono(id: "vidrio", etiqueta: "Vidrio", grupo: .sistema, ruta: sistema + "Glass.aiff", volumen: 1.0),

        Tono(id: "ninguno", etiqueta: "Sin sonido", grupo: .ninguno, ruta: nil, volumen: 0),
    ]

    static let disponibles: [Tono] = catalogo.filter { t in
        t.ruta.map { FileManager.default.fileExists(atPath: $0) } ?? true
    }

    static let porDefectoAtencion = "fanfarria"
    static let porDefectoTermino = "arpa"

    static func tono(_ id: String) -> Tono? { disponibles.first { $0.id == id } }

    /// Si un tono guardado ya no existe, se usa el predeterminado (o, si
    /// tampoco existe, el primero disponible con sonido).
    static func valido(_ id: String?, siNo predeterminado: String) -> String {
        if let id, tono(id) != nil { return id }
        if tono(predeterminado) != nil { return predeterminado }
        return disponibles.first { $0.ruta != nil }?.id ?? "ninguno"
    }

    /// `Sauron --sonidos`: el catalogo con lo que hay en este Mac.
    static func listar() {
        for t in catalogo {
            guard let ruta = t.ruta else {
                print("\(t.id): sin sonido")
                continue
            }
            let existe = FileManager.default.fileExists(atPath: ruta)
            let duracion = (try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: ruta)))?.duration
            let dur = duracion.map { String(format: "%.2f s", $0) } ?? "no se pudo abrir"
            let corte = t.corte.map { String(format: ", corte %.1f s", $0) } ?? ""
            print("\(t.id) [\(t.grupo.rawValue)] \(existe ? dur : "NO EXISTE") volumen \(t.volumen)\(corte)")
        }
    }
}

enum Sonido {
    private static var reproductores: [String: AVAudioPlayer] = [:]
    private static var actual: AVAudioPlayer?
    /// Cada reproduccion invalida los cortes programados de la anterior.
    private static var generacion = 0

    /// Abre los archivos de antemano para que el primer aviso no espere.
    static func preparar(_ ids: [String]) {
        for id in ids { _ = reproductor(id) }
    }

    /// Si llegan dos avisos juntos, el ultimo (el mas urgente) corta al otro.
    static func reproducir(_ id: String) {
        detener()
        guard let t = Tonos.tono(id), let r = reproductor(id) else { return }
        generacion += 1
        let g = generacion
        r.currentTime = 0
        r.volume = t.volumen
        r.play()
        actual = r
        guard let corte = t.corte else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, corte - t.desvanecer)) {
            guard g == generacion else { return }
            r.setVolume(0, fadeDuration: t.desvanecer)
            DispatchQueue.main.asyncAfter(deadline: .now() + t.desvanecer) {
                guard g == generacion else { return }
                r.stop()
                actual = nil
            }
        }
    }

    static func detener() {
        generacion += 1
        actual?.stop()
        actual = nil
    }

    private static func reproductor(_ id: String) -> AVAudioPlayer? {
        if let r = reproductores[id] { return r }
        guard let ruta = Tonos.tono(id)?.ruta,
              let r = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: ruta))
        else { return nil }
        r.prepareToPlay()
        reproductores[id] = r
        return r
    }
}
