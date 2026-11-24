import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// El Ojo, logo de Sauron. Se dibuja con Core Graphics para servir a todos
/// los tamaños: el icono de la app, el logo del README y la píldora.
enum Logo {
    /// Alto del ojo respecto de su ancho.
    static let proporcion: CGFloat = 0.46

    // MARK: - Icono de la app

    /// Icono cuadrado de `lado` px con la retícula de macOS (placa de
    /// 824/1024 centrada). Se dibuja en unidades de 1024.
    static func icono(lado: Int) -> CGImage? {
        guard let ctx = contexto(lado, lado) else { return nil }
        let escala = CGFloat(lado) / 1024
        ctx.scaleBy(x: escala, y: escala)
        let lienzo = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        // En tamaños chicos las llamas no se leen: solo el ojo, más grande.
        let detalle = lado >= 64

        let placa = CGRect(x: 100, y: 100, width: 824, height: 824)
        let forma = CGPath(roundedRect: placa, cornerWidth: 185, cornerHeight: 185, transform: nil)
        let ancho: CGFloat = detalle ? 560 : 700
        let alto = ancho * proporcion
        let ojo = CGRect(x: 512 - ancho / 2, y: 512 - alto / 2 - (detalle ? 40 : 0), width: ancho, height: alto)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.5))
        ctx.addPath(forma)
        ctx.setFillColor(color(0x0A0607))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(forma)
        ctx.clip()
        ctx.drawLinearGradient(
            gradiente([(0, 0x2E130D, 1), (0.5, 0x140A09, 1), (1, 0x060405, 1)]),
            start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: []
        )
        let centro = CGPoint(x: ojo.midX, y: ojo.midY)
        ctx.drawRadialGradient(
            gradiente([(0, 0xFF5A14, 0.5), (0.4, 0xB82A0C, 0.22), (1, 0x5A0A04, 0)]),
            startCenter: centro, startRadius: 0, endCenter: centro, endRadius: 440, options: []
        )
        if detalle, let llamas = llamas(lado: lado, ojo: ojo) {
            ctx.setBlendMode(.screen)
            if let suave = desenfocar(llamas, radio: 26 * escala) {
                ctx.draw(suave, in: lienzo)
                ctx.draw(suave, in: lienzo)
            }
            ctx.setAlpha(0.7)
            ctx.draw(llamas, in: lienzo)
            ctx.setAlpha(1)
            ctx.setBlendMode(.normal)
        }
        dibujarOjo(ctx, en: ojo, mirada: 0, detalle: detalle)
        ctx.restoreGState()

        ctx.addPath(CGPath(roundedRect: placa.insetBy(dx: 2, dy: 2), cornerWidth: 183, cornerHeight: 183, transform: nil))
        ctx.setStrokeColor(color(0xFFFFFF, 0.10))
        ctx.setLineWidth(4)
        ctx.strokePath()
        return ctx.makeImage()
    }

    /// `Sauron --icono <carpeta>`: escribe `Sauron.iconset` (para iconutil)
    /// y `logo.png` (512 px, el del README).
    static func generar(en carpeta: String) -> Bool {
        let raiz = URL(fileURLWithPath: carpeta, isDirectory: true)
        let juego = raiz.appendingPathComponent("Sauron.iconset", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: juego, withIntermediateDirectories: true)
        } catch {
            print("No se pudo crear \(juego.path): \(error.localizedDescription)")
            return false
        }
        var bien = true
        for base in [16, 32, 128, 256, 512] {
            for factor in [1, 2] {
                let nombre = "icon_\(base)x\(base)" + (factor == 2 ? "@2x" : "") + ".png"
                bien = escribir(icono(lado: base * factor), en: juego.appendingPathComponent(nombre)) && bien
            }
        }
        bien = escribir(icono(lado: 512), en: raiz.appendingPathComponent("logo.png")) && bien
        return bien
    }

    // MARK: - Ojo suelto (píldora)

    /// Solo el ojo, sin placa, en un lienzo de `tamano` puntos.
    /// `mirada` va de -1 (izquierda) a 1 (derecha).
    static func ojo(tamano: CGSize, escala: CGFloat, mirada: CGFloat) -> CGImage? {
        guard let ctx = contexto(Int(ceil(tamano.width * escala)), Int(ceil(tamano.height * escala))) else {
            return nil
        }
        ctx.scaleBy(x: escala, y: escala)
        let margen = tamano.height * 0.16
        let ancho = min(tamano.width - 2 * margen, (tamano.height - 2 * margen) / proporcion)
        let alto = ancho * proporcion
        let r = CGRect(x: (tamano.width - ancho) / 2, y: (tamano.height - alto) / 2, width: ancho, height: alto)
        dibujarOjo(ctx, en: r, mirada: mirada, detalle: false)
        return ctx.makeImage()
    }

    static let pasoMirada: TimeInterval = 0.08

    /// Cuadros de la mirada recorriendo de lado a lado.
    static func cuadrosMirada(tamano: CGSize, escala: CGFloat) -> [CGImage] {
        let n = 36
        return (0..<n).compactMap { i in
            ojo(tamano: tamano, escala: escala, mirada: 0.8 * sin(2 * .pi * CGFloat(i) / CGFloat(n)))
        }
    }

    // MARK: - Dibujo

    /// Contorno de almendra con puntas a los lados.
    private static func almendra(_ r: CGRect) -> CGPath {
        let p = CGMutablePath()
        let izquierda = CGPoint(x: r.minX, y: r.midY)
        let derecha = CGPoint(x: r.maxX, y: r.midY)
        // Una cúbica con ambos controles a altura h alcanza 0,75 h.
        let h = r.height / 2 / 0.75
        let dx = r.width * 0.2
        p.move(to: izquierda)
        p.addCurve(to: derecha,
                   control1: CGPoint(x: r.minX + dx, y: r.midY + h),
                   control2: CGPoint(x: r.maxX - dx, y: r.midY + h))
        p.addCurve(to: izquierda,
                   control1: CGPoint(x: r.maxX - dx, y: r.midY - h),
                   control2: CGPoint(x: r.minX + dx, y: r.midY - h))
        p.closeSubpath()
        return p
    }

    private static func dibujarOjo(_ ctx: CGContext, en r: CGRect, mirada: CGFloat, detalle: Bool) {
        let forma = almendra(r)
        let x = r.midX + mirada * r.width * 0.2

        // Halo de fuego alrededor
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: r.height * 0.35, color: color(0xFF5A14, 0.9))
        ctx.addPath(forma)
        ctx.setFillColor(color(0x7A1206))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(forma)
        ctx.clip()

        // Iris: degradado elíptico centrado en la pupila
        ctx.saveGState()
        ctx.translateBy(x: x, y: r.midY)
        ctx.scaleBy(x: 1, y: r.height / r.width)
        ctx.drawRadialGradient(
            gradiente([(0, 0xFFFBE6, 1), (0.16, 0xFFE68A, 1), (0.40, 0xFFB534, 1),
                       (0.66, 0xF5701C, 1), (0.88, 0xC0360F, 1), (1, 0x5A0C04, 1)]),
            startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: r.width / 2,
            options: [.drawsAfterEndLocation]
        )
        if detalle {
            var azar = Azar(estado: 7)
            ctx.setLineCap(.round)
            ctx.setLineWidth(r.width * 0.006)
            let radio = r.width / 2
            for i in 0..<120 {
                let angulo = CGFloat(i) / 120 * 2 * .pi + azar.siguiente() * 0.05
                let desde = radio * (0.10 + 0.15 * azar.siguiente())
                let hasta = radio * (0.55 + 0.45 * azar.siguiente())
                ctx.move(to: CGPoint(x: cos(angulo) * desde, y: sin(angulo) * desde))
                ctx.addLine(to: CGPoint(x: cos(angulo) * hasta, y: sin(angulo) * hasta))
                ctx.setStrokeColor(i % 2 == 0 ? color(0xFFF0B0, 0.22) : color(0x6A0E04, 0.30))
                ctx.strokePath()
            }
        }
        ctx.restoreGState()

        // Pupila: rendija vertical. Con pocos píxeles se ensancha; si no, se
        // mezcla con el iris y queda un gris verdoso.
        let pixeles = r.width * abs(ctx.userSpaceToDeviceSpaceTransform.a)
        let grosor: CGFloat = pixeles < 40 ? 0.13 : pixeles < 80 ? 0.10 : 0.07
        let alto = r.height * 0.96
        let d = r.width * grosor / 2 / 0.75
        let pupila = CGMutablePath()
        pupila.move(to: CGPoint(x: x, y: r.midY + alto / 2))
        pupila.addCurve(to: CGPoint(x: x, y: r.midY - alto / 2),
                        control1: CGPoint(x: x + d, y: r.midY + alto / 4),
                        control2: CGPoint(x: x + d, y: r.midY - alto / 4))
        pupila.addCurve(to: CGPoint(x: x, y: r.midY + alto / 2),
                        control1: CGPoint(x: x - d, y: r.midY - alto / 4),
                        control2: CGPoint(x: x - d, y: r.midY + alto / 4))
        pupila.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: r.width * 0.04, color: color(0x2A0000, 0.9))
        ctx.addPath(pupila)
        ctx.setFillColor(color(0x050000))
        ctx.fillPath()
        ctx.restoreGState()

        // Borde interior oscuro (la mitad del trazo queda fuera del recorte)
        ctx.addPath(forma)
        ctx.setStrokeColor(color(0x3A0602, detalle ? 0.6 : 0.85))
        ctx.setLineWidth(r.height * (detalle ? 0.06 : 0.10))
        ctx.strokePath()
        ctx.restoreGState()

        // Contorno fino para separarlo del fondo en tamaños chicos
        guard !detalle else { return }
        ctx.addPath(forma)
        ctx.setStrokeColor(color(0x1A0301, 0.9))
        ctx.setLineWidth(max(r.height * 0.025, 0.5))
        ctx.strokePath()
    }

    /// Corona de lenguas de fuego alrededor del ojo, inclinadas hacia
    /// arriba. Semilla fija: el dibujo es siempre el mismo.
    private static func llamas(lado: Int, ojo: CGRect) -> CGImage? {
        guard let ctx = contexto(lado, lado) else { return nil }
        ctx.scaleBy(x: CGFloat(lado) / 1024, y: CGFloat(lado) / 1024)
        var azar = Azar(estado: 0x5A0E)
        let c = CGPoint(x: ojo.midX, y: ojo.midY)
        let a = ojo.width / 2, b = ojo.height / 2
        let u = ojo.height
        // (cantidad, largo, ancho, color de la base, color de la punta, alfa)
        let capas: [(Int, CGFloat, CGFloat, UInt32, UInt32, CGFloat)] = [
            (26, 0.62, 0.42, 0xD8380E, 0x6A0A03, 0.75),
            (32, 0.44, 0.32, 0xFF7A1C, 0xC2300C, 0.85),
            (38, 0.26, 0.22, 0xFFD666, 0xFF8A24, 0.90),
        ]
        for (n, largoBase, anchoBase, colorBase, colorPunta, alfa) in capas {
            for i in 0..<n {
                let angulo = (CGFloat(i) + azar.siguiente() * 0.9) / CGFloat(n) * 2 * .pi
                let base = CGPoint(x: c.x + a * 0.9 * cos(angulo), y: c.y + b * 0.85 * sin(angulo))
                // Normal de la elipse, inclinada hacia arriba: el fuego sube.
                var dx = cos(angulo) / a, dy = sin(angulo) / b
                var m = hypot(dx, dy)
                dx /= m; dy /= m
                dy += 0.9
                m = hypot(dx, dy)
                dx /= m; dy /= m
                let s = sin(angulo)
                // Más largas arriba, cortas abajo y contenidas a los lados para
                // no tocar el borde de la placa.
                let subida = (1 + 0.7 * max(0, s)) * (1 - 0.45 * max(0, -s)) * (0.55 + 0.45 * abs(s))
                let largo = u * largoBase * (0.55 + 0.9 * azar.siguiente()) * subida
                let ancho = u * anchoBase * (0.7 + 0.6 * azar.siguiente())
                let giro = (azar.siguiente() - 0.5) * ancho * 2.2
                let nx = -dy, ny = dx
                func punto(_ t: CGFloat, _ lateral: CGFloat) -> CGPoint {
                    CGPoint(x: base.x + dx * largo * t + nx * lateral,
                            y: base.y + dy * largo * t + ny * lateral)
                }
                // Lengua en S: ancha en la base, punta fina desplazada.
                let punta = punto(1, giro)
                let p = CGMutablePath()
                p.move(to: punto(0, ancho / 2))
                p.addCurve(to: punta, control1: punto(0.45, ancho * 0.6 - giro * 0.3), control2: punto(0.8, giro * 0.9 + ancho * 0.05))
                p.addCurve(to: punto(0, -ancho / 2), control1: punto(0.8, giro * 0.9 - ancho * 0.05), control2: punto(0.45, -ancho * 0.6 - giro * 0.3))
                p.closeSubpath()
                ctx.saveGState()
                ctx.addPath(p)
                ctx.clip()
                ctx.drawLinearGradient(
                    gradiente([(0, colorBase, alfa), (0.55, colorPunta, alfa * 0.7), (1, colorPunta, 0)]),
                    start: base, end: punta, options: [.drawsBeforeStartLocation]
                )
                ctx.restoreGState()
            }
        }
        return ctx.makeImage()
    }

    // MARK: - Utilidades

    private static let espacio = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private static func contexto(_ ancho: Int, _ alto: Int) -> CGContext? {
        CGContext(data: nil, width: ancho, height: alto, bitsPerComponent: 8, bytesPerRow: 0,
                  space: espacio, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func color(_ hex: UInt32, _ alfa: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: espacio, components: [
            CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
            CGFloat(hex & 0xFF) / 255, alfa,
        ]) ?? CGColor(gray: 0, alpha: alfa)
    }

    private static func gradiente(_ paradas: [(CGFloat, UInt32, CGFloat)]) -> CGGradient {
        CGGradient(colorsSpace: espacio, colors: paradas.map { color($0.1, $0.2) } as CFArray,
                   locations: paradas.map(\.0))!
    }

    private static func desenfocar(_ imagen: CGImage, radio: CGFloat) -> CGImage? {
        let entrada = CIImage(cgImage: imagen)
        guard let filtro = CIFilter(name: "CIGaussianBlur") else { return nil }
        filtro.setValue(entrada.clampedToExtent(), forKey: kCIInputImageKey)
        filtro.setValue(radio, forKey: kCIInputRadiusKey)
        guard let salida = filtro.outputImage?.cropped(to: entrada.extent) else { return nil }
        return CIContext().createCGImage(salida, from: entrada.extent)
    }

    private static func escribir(_ imagen: CGImage?, en url: URL) -> Bool {
        guard let imagen,
              let destino = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else {
            print("No se pudo escribir \(url.path)")
            return false
        }
        CGImageDestinationAddImage(destino, imagen, nil)
        return CGImageDestinationFinalize(destino)
    }
}

/// Generador congruencial: el mismo dibujo en cada ejecución.
private struct Azar {
    var estado: UInt64

    mutating func siguiente() -> CGFloat {
        estado = estado &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(estado >> 40) / CGFloat(1 << 24)
    }
}
