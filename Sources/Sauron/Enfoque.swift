import AppKit

// Lleva a la ventana y a la pestaña de una sesion, en dos pasos:
// 1. Abrir su carpeta con VS Code: si ya esta abierta, VS Code enfoca esa
//    ventana en lugar de abrir otra.
// 2. Abrir vscode://anthropic.claude-code/open?session=<id>. VS Code entrega
//    la URI a la ventana activa (la del paso 1) y la extension revela la
//    pestaña de esa sesion si ya existe.

enum Enfoque {
    static let idVSCode = "com.microsoft.VSCode"
    static let pausa: TimeInterval = 0.35

    static func ir(a s: Sesion) {
        let ws = NSWorkspace.shared
        guard let app = ws.urlForApplication(withBundleIdentifier: idVSCode) else {
            NSSound.beep()
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        let carpeta = URL(fileURLWithPath: s.carpeta, isDirectory: true)
        ws.open([carpeta], withApplicationAt: app, configuration: cfg) { _, error in
            if let error { print("No se pudo enfocar la ventana: \(error.localizedDescription)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + pausa) {
                abrirSesion(s.id, con: app)
            }
        }
    }

    private static func abrirSesion(_ id: String, con app: URL) {
        var c = URLComponents()
        c.scheme = "vscode"
        c.host = "anthropic.claude-code"
        c.path = "/open"
        c.queryItems = [URLQueryItem(name: "session", value: id)]
        guard let url = c.url else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: cfg) { _, error in
            if let error { print("No se pudo abrir la sesión: \(error.localizedDescription)") }
        }
    }
}
