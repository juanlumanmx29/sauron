import AppKit
import QuartzCore
import SwiftUI

/// Recorre cuadros pre-dibujados con una animacion de Core Animation sobre
/// `contents`. Los cuadros se dibujan una vez por escala de pantalla y la
/// animacion corre en el servidor de render: la app no se despierta en cada
/// cuadro. La usan el ojo de la pildora y el destello de las filas.
struct CuadrosAnimados: NSViewRepresentable {
    let tamano: CGSize
    let paso: TimeInterval
    /// Escala de pantalla -> cuadros.
    let dibujar: (CGFloat) -> [CGImage]

    func makeNSView(context: Context) -> VistaCuadros {
        VistaCuadros(tamano: tamano, paso: paso, dibujar: dibujar)
    }

    func updateNSView(_ vista: VistaCuadros, context: Context) {}
}

final class VistaCuadros: NSView {
    static let clave = "cuadros"

    private let tamano: CGSize
    private let paso: TimeInterval
    private let dibujar: (CGFloat) -> [CGImage]
    private var escalaAnimada: CGFloat = 0
    /// Subcapa propia: AppKit puede reescribir el `contents` de la capa de la
    /// vista al redibujarla, pero no toca sus subcapas.
    let capaAnimada = CALayer()

    init(tamano: CGSize, paso: TimeInterval, dibujar: @escaping (CGFloat) -> [CGImage]) {
        self.tamano = tamano
        self.paso = paso
        self.dibujar = dibujar
        super.init(frame: NSRect(origin: .zero, size: tamano))
        wantsLayer = true
        layer?.addSublayer(capaAnimada)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override var intrinsicContentSize: NSSize { tamano }

    /// Transparente al raton: el clic y el arrastre son de la pildora.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        capaAnimada.frame = bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        animar()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        animar()
    }

    private func animar() {
        guard let escala = window?.backingScaleFactor, escala != escalaAnimada else { return }
        escalaAnimada = escala
        let imagenes = dibujar(escala)
        guard !imagenes.isEmpty else { return }
        let capa = capaAnimada
        capa.contentsGravity = .center
        capa.contentsScale = escala
        capa.contents = imagenes[0]

        let animacion = CAKeyframeAnimation(keyPath: "contents")
        animacion.values = imagenes
        animacion.calculationMode = .discrete
        animacion.duration = paso * Double(imagenes.count)
        animacion.repeatCount = .infinity
        animacion.isRemovedOnCompletion = false
        capa.add(animacion, forKey: Self.clave)
    }
}

/// Halo de la pildora: un anillo ambar con resplandor que late. Solo se anima
/// la opacidad de una capa rasterizada: el servidor de render mezcla una
/// imagen ya dibujada en vez de recalcular la sombra en cada cuadro, y la
/// app no se despierta.
struct HaloPulso: NSViewRepresentable {
    func makeNSView(context: Context) -> VistaHalo { VistaHalo() }
    func updateNSView(_ vista: VistaHalo, context: Context) {}
}

final class VistaHalo: NSView {
    static let clave = "pulso"
    let anillo = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        let ambar = NSColor(Tema.ambar).cgColor
        anillo.fillColor = nil
        anillo.strokeColor = ambar
        anillo.lineWidth = 2
        anillo.shadowColor = ambar
        anillo.shadowOffset = .zero
        anillo.shadowOpacity = 0.6
        anillo.shadowRadius = 6
        anillo.opacity = 0.35
        anillo.shouldRasterize = true
        layer?.addSublayer(anillo)

        // 1,7 s por ciclo, de 0,35 a 1 de opacidad.
        let latido = CABasicAnimation(keyPath: "opacity")
        latido.fromValue = 0.35
        latido.toValue = 1.0
        latido.duration = 0.85
        latido.autoreverses = true
        latido.repeatCount = .infinity
        latido.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        latido.isRemovedOnCompletion = false
        anillo.add(latido, forKey: Self.clave)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let escala = window?.backingScaleFactor ?? 2
        anillo.contentsScale = escala
        anillo.rasterizationScale = escala
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        anillo.frame = bounds
        let r = bounds.insetBy(dx: 1, dy: 1)
        anillo.path = CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension Destello {
    /// Cuadros del giro: los glifos del indicador de la CLI.
    static func imagenes(tamano: CGFloat, escala: CGFloat) -> [CGImage] {
        cuadros.compactMap { glifo($0, tamano: tamano, escala: escala) }
    }

    private static func glifo(_ texto: String, tamano: CGFloat, escala: CGFloat) -> CGImage? {
        let lado = tamano + 2
        let pixeles = Int(ceil(lado * escala))
        guard let ctx = CGContext(
            data: nil, width: pixeles, height: pixeles, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.scaleBy(x: escala, y: escala)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let atributos: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: tamano, weight: .bold),
            .foregroundColor: NSColor(Tema.claude),
        ]
        let glifo = NSAttributedString(string: texto, attributes: atributos)
        let medida = glifo.size()
        glifo.draw(at: NSPoint(x: (lado - medida.width) / 2, y: (lado - medida.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}
