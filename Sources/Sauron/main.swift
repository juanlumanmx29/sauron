import AppKit

let argumentos = CommandLine.arguments
// Primero y sin AppKit: Claude Code lo lanza en cada petición de permiso.
if argumentos.contains("--hook-permiso") {
    exit(HookPermiso.ejecutar())
}
if argumentos.contains("--volcar") {
    Volcado.ejecutar()
    exit(0)
}
if argumentos.contains("--sonidos") {
    Tonos.listar()
    exit(0)
}
if let i = argumentos.firstIndex(of: "--icono"), i + 1 < argumentos.count {
    exit(Logo.generar(en: argumentos[i + 1]) ? 0 : 1)
}
if let i = argumentos.firstIndex(of: "--capturas"), i + 1 < argumentos.count {
    _ = NSApplication.shared
    MainActor.assumeIsolated { Capturas.ejecutar(en: argumentos[i + 1]) }
    exit(0)
}

final class Delegado: NSObject, NSApplicationDelegate {
    private var controlador: Controlador?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Una sola instancia: si ya hay otra corriendo, esta se cierra.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            NSApp.terminate(nil)
            return
        }
        let c = Controlador()
        c.iniciar()
        controlador = c
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--autoprueba"), i + 1 < args.count {
            c.autoprueba(en: args[i + 1])
        }
    }
}

let app = NSApplication.shared
let delegado = Delegado()
app.delegate = delegado
app.setActivationPolicy(.accessory)
app.run()
