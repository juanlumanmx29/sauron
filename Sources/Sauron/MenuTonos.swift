import AppKit

// Filas del submenu de sonidos. Son vistas propias porque un item de menu con
// vista no cierra el menu al hacer clic: se pueden escuchar y elegir varios
// tonos seguidos. Un item con vista no dibuja nada por si mismo (ni titulo,
// ni marca, ni resaltado): todo eso va aqui.

final class VistaTonoMenu: NSView {
    let id: String
    let etiqueta: String
    var marcado: Bool { didSet { needsDisplay = true } }
    /// Clic: elegir este tono.
    var alElegir: ((String) -> Void)?
    /// El puntero llego a la fila: programar la muestra.
    var alResaltar: ((String) -> Void)?
    /// Solo para `--capturas`: fuera de un menu no hay resaltado real.
    var resaltadoForzado: Bool?
    private var estabaResaltado = false

    static let ancho: CGFloat = 210
    static let alto: CGFloat = 22
    /// Donde empieza el texto; a la izquierda va la marca.
    static let sangria: CGFloat = 26

    init(id: String, etiqueta: String, marcado: Bool) {
        self.id = id
        self.etiqueta = etiqueta
        self.marcado = marcado
        super.init(frame: NSRect(x: 0, y: 0, width: Self.ancho, height: Self.alto))
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(etiqueta)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    /// El menu vuelve a dibujar la vista cada vez que cambia el resaltado del
    /// item: aqui se detecta la llegada del puntero. Es un respaldo de
    /// `menu(_:willHighlight:)`, y la muestra se programa una sola vez.
    override func draw(_ dirtyRect: NSRect) {
        let resaltado = resaltadoForzado ?? (enclosingMenuItem?.isHighlighted ?? false)
        if resaltado, !estabaResaltado, resaltadoForzado == nil {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.alResaltar?(self.id)
            }
        }
        estabaResaltado = resaltado

        if resaltado {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 5, yRadius: 5).fill()
        }
        let atributos: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: resaltado ? NSColor.selectedMenuItemTextColor : NSColor.labelColor,
        ]
        let texto = NSAttributedString(string: etiqueta, attributes: atributos)
        let y = (bounds.height - texto.size().height) / 2
        if marcado {
            NSAttributedString(string: "✓", attributes: atributos).draw(at: NSPoint(x: 11, y: y))
        }
        texto.draw(at: NSPoint(x: Self.sangria, y: y))
    }

    override func mouseUp(with event: NSEvent) {
        alElegir?(id)
    }
}

/// Titulo de grupo ("Épicos", "Sobrios"...), alineado con los textos.
final class VistaTituloMenu: NSView {
    let titulo: String

    init(_ titulo: String) {
        self.titulo = titulo
        super.init(frame: NSRect(x: 0, y: 0, width: VistaTonoMenu.ancho, height: 20))
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(titulo)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func draw(_ dirtyRect: NSRect) {
        let atributos: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let t = NSAttributedString(string: titulo, attributes: atributos)
        t.draw(at: NSPoint(x: VistaTonoMenu.sangria, y: (bounds.height - t.size().height) / 2))
    }
}
