import AppKit

// `Sauron --autoprueba <carpeta>`: arranca el widget normal, recorre sus tres
// presentaciones, guarda cada una como PNG renderizando las capas de la
// propia ventana (no requiere permiso de grabación de pantalla), comprueba
// que el destello avanza y sale. Sirve para verificar la ventana real sin
// mirar la pantalla.

extension Controlador {
    func autoprueba(en carpeta: String) {
        let destino = URL(fileURLWithPath: carpeta, isDirectory: true)
        try? FileManager.default.createDirectory(at: destino, withIntermediateDirectories: true)
        var pasos: [(TimeInterval, () -> Void)] = []

        pasos.append((1.5, { [self] in
            informar("contraida")
            guardarVentana("ventana-contraida", destino)
            ui.presentacion = .expandida
        }))
        pasos.append((0.8, { [self] in
            informar("expandida")
            guardarVentana("ventana-expandida", destino)
            if let s = vigia.sesiones.first { ui.presentacion = .asomada(s.id) }
        }))
        pasos.append((0.8, { [self] in
            informar("asomada")
            guardarVentana("ventana-asomada", destino)
            ui.presentacion = .contraida
        }))
        pasos.append((0.8, { [self] in
            informar("contraida otra vez")
            comprobarAnimaciones()
            imprimirMenu(construirMenu(), sangria: "  ")
            print("canal de permisos: \(permisos.activo ? "escuchando" : "INACTIVO")")
            if let s = permisos.pendientes.first {
                print("permiso pendiente: \(s.herramienta) · \(s.accion) · \(s.objeto)")
                ui.presentacion = .asomada(s.sesion)
            } else {
                print("permisos pendientes: 0")
            }
        }))
        // Si un hook de prueba dejo una peticion, se fotografia la tarjeta y se
        // contesta (permitir, o rechazar con SAURON_PRUEBA_RECHAZAR).
        pasos.append((0.8, { [self] in
            guard let s = permisos.pendientes.first else { return }
            informar("permiso")
            guardarVentana("ventana-permiso", destino)
            let rechazar = ProcessInfo.processInfo.environment["SAURON_PRUEBA_RECHAZAR"] != nil
            ui.decidir(s, !rechazar)
            print("respondido: \(rechazar ? "rechazar" : "permitir"); pendientes ahora: \(permisos.pendientes.count)")
        }))
        pasos.append((0.5, { NSApp.terminate(nil) }))

        var demora: TimeInterval = 0
        for (espera, paso) in pasos {
            demora += espera
            DispatchQueue.main.asyncAfter(deadline: .now() + demora, execute: paso)
        }
    }

    private func informar(_ etapa: String) {
        let v = (panel.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let f = panel.frame
        let dentro = v.contains(f)
        print("[\(etapa)] marco=\(f) pantalla visible=\(v) dentro=\(dentro) sesiones=\(vigia.sesiones.count)")
    }

    private func guardarVentana(_ nombre: String, _ destino: URL) {
        guard let vista = panel.contentView, let capa = vista.layer else {
            print("  sin capa para renderizar")
            return
        }
        let escala = panel.backingScaleFactor
        let ancho = Int(vista.bounds.width * escala), alto = Int(vista.bounds.height * escala)
        guard let ctx = CGContext(
            data: nil, width: ancho, height: alto, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        // Fondo gris para ver los bordes de lo transparente.
        ctx.setFillColor(CGColor(gray: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ancho, height: alto))
        if vista.isFlipped || capa.isGeometryFlipped {
            ctx.translateBy(x: 0, y: CGFloat(alto))
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.scaleBy(x: escala, y: escala)
        capa.render(in: ctx)
        guard let imagen = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: imagen)
        let url = destino.appendingPathComponent(nombre + ".png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("  \(url.path)")
    }

    /// El menu contextual tal como se construiria al hacer clic derecho.
    private func imprimirMenu(_ menu: NSMenu, sangria: String) {
        if sangria == "  " { print("menú contextual:") }
        for i in menu.items {
            if i.isSeparatorItem { print(sangria + "—"); continue }
            if let t = i.view as? VistaTituloMenu {
                print("\(sangria)  \(t.titulo)  [título]")
                continue
            }
            if let v = i.view as? VistaTonoMenu {
                let elegible = i.isEnabled && v.alElegir != nil && menu.autoenablesItems == false
                print("\(sangria)\(v.marcado ? "✓ " : "  ")\(v.etiqueta)  [vista\(elegible ? ", elegible sin cerrar" : ", NO ELEGIBLE")]")
                continue
            }
            let marca = i.state == .on ? "✓ " : "  "
            let accion = i.action.map { NSStringFromSelector($0) } ?? (i.submenu != nil ? "submenú" : "sin acción")
            print("\(sangria)\(marca)\(i.title)  [\(accion)]")
            if let sub = i.submenu { imprimirMenu(sub, sangria: sangria + "    ") }
        }
    }

    private func comprobarAnimaciones() {
        var animadas: [VistaCuadros] = []
        var halos: [VistaHalo] = []
        func recorrer(_ v: NSView) {
            if let d = v as? VistaCuadros { animadas.append(d) }
            if let h = v as? VistaHalo { halos.append(h) }
            v.subviews.forEach(recorrer)
        }
        if let raiz = panel.contentView { recorrer(raiz) }
        let esperando = vigia.sesiones.filter { $0.fase == .atencion }.count
        print("halos en la ventana: \(halos.count) (sesiones esperando: \(esperando))")
        for h in halos {
            let instalada = h.anillo.animation(forKey: VistaHalo.clave) != nil
            print("  halo \(instalada ? "animado" : "sin animación"), marco \(NSStringFromRect(h.frame))")
        }
        let trabajando = vigia.sesiones.filter { $0.fase == .trabajando }.count
        print("animaciones en la ventana: \(animadas.count) (sesiones trabajando: \(trabajando))")
        // Los cuadros de una animacion sobre `contents` los calcula el
        // servidor de render: la capa de presentacion no los expone. Se
        // comprueba que la animacion este instalada y avanzando en el tiempo.
        for d in animadas {
            guard let anim = d.capaAnimada.animation(forKey: VistaCuadros.clave) else {
                print("  sin animación")
                continue
            }
            let transcurrido = d.capaAnimada.convertTime(CACurrentMediaTime(), from: nil) - anim.beginTime
            print(String(format: "  animación instalada, %.1f s en curso, velocidad %.0f, marco %@",
                         transcurrido, d.capaAnimada.speed, NSStringFromRect(d.frame)))
        }
    }
}
