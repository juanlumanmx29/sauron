import SwiftUI

// Paleta tomada del tema oscuro de la CLI de Claude Code. La extensión de
// VS Code aplica la misma lógica: auto y bypass comparten el rojo de error.

enum Tema {
    static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(red: r / 255, green: g / 255, blue: b / 255)
    }

    static let claude = rgb(215, 119, 87)
    static let violeta = rgb(175, 135, 255)
    static let verdeAzulado = rgb(72, 150, 140)
    static let rojo = rgb(255, 107, 128)
    static let ambar = rgb(255, 193, 7)
    static let verde = rgb(78, 186, 101)
    static let gris = rgb(136, 136, 136)

    static let fondo = Color(white: 0.105)
    static let borde = Color.white.opacity(0.09)
}

enum Modo: String {
    case normal = "default"
    case aceptaEdiciones = "acceptEdits"
    case plan
    case auto
    case sinPermisos = "bypassPermissions"
    case desconocido

    init(texto: String?) {
        self = texto.flatMap { Modo(rawValue: $0) } ?? .desconocido
    }

    var color: Color {
        switch self {
        case .normal: return Tema.claude
        case .aceptaEdiciones: return Tema.violeta
        case .plan: return Tema.verdeAzulado
        case .auto, .sinPermisos: return Tema.rojo
        case .desconocido: return Tema.gris
        }
    }

    var etiqueta: String {
        switch self {
        case .normal: return "default"
        case .aceptaEdiciones: return "acepta ediciones"
        case .plan: return "plan"
        case .auto: return "auto"
        case .sinPermisos: return "sin permisos"
        case .desconocido: return ""
        }
    }
}

enum Fase: Int, Comparable {
    case atencion = 0
    case termino = 1
    case trabajando = 2
    /// Turno terminado, pero con comandos o subagentes en segundo plano.
    case segundoPlano = 3
    case inactiva = 4

    static func < (a: Fase, b: Fase) -> Bool { a.rawValue < b.rawValue }

    var color: Color {
        switch self {
        case .atencion: return Tema.ambar
        case .termino: return Tema.verde
        case .trabajando, .segundoPlano: return Tema.claude
        case .inactiva: return Tema.gris
        }
    }
}
