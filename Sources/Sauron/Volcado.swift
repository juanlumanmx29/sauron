import Foundation

// `Sauron --volcar`: imprime en JSON lo que el widget interpreta de cada
// sesion viva, sin abrir la interfaz. Sirve para contrastar con
// ~/.claude/sessions y con lo que muestran las pestañas de VS Code.

enum Volcado {
    static func ejecutar() {
        let carpetas = Registro.carpetasAbiertas()
        let lector = LectorTranscript()
        let inicio = Date()
        var salida: [[String: Any]] = []

        for r in Registro.sesiones(soloVSCode: false).sorted(by: { $0.cwd < $1.cwd }) {
            let t = lector.datos(sesion: r.sesion, cwd: r.cwd)
            let carpeta = Registro.carpeta(para: r.cwd, en: carpetas)
            salida.append([
                "pid": r.pid,
                "sesion": r.sesion,
                "origen": r.origen,
                "seMuestra": r.origen == Registro.origenVSCode,
                "cwd": r.cwd,
                "carpetaVentana": carpeta,
                "nombreCarpeta": (carpeta as NSString).lastPathComponent,
                "titulo": (t.tituloPropio ?? r.nombrePropio ?? t.tituloIA) as Any? ?? NSNull(),
                "tituloIA": t.tituloIA ?? NSNull(),
                "tituloPropio": t.tituloPropio ?? NSNull(),
                "modo": t.modo ?? NSNull(),
                "estado": r.estado,
                "esperaPor": r.esperaPor ?? NSNull(),
                "actualizado": ISO8601DateFormatter().string(from: r.actualizado),
            ])
        }

        let resumen: [String: Any] = [
            "ventanas": carpetas,
            "sesiones": salida,
            "msLectura": Int(Date().timeIntervalSince(inicio) * 1000),
        ]
        if let datos = try? JSONSerialization.data(withJSONObject: resumen, options: [.prettyPrinted, .sortedKeys]),
           let texto = String(data: datos, encoding: .utf8) {
            print(texto)
        }
    }
}
