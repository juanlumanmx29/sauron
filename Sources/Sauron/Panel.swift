import AppKit
import Combine
import SwiftUI

// Ventana flotante y su comportamiento: posicion anclada a una esquina,
// arrastre, expandir/contraer, asomarse ante un evento.

enum Esquina: String {
    case arribaDerecha, arribaIzquierda, abajoDerecha, abajoIzquierda

    init(arriba: Bool, derecha: Bool) {
        switch (arriba, derecha) {
        case (true, true): self = .arribaDerecha
        case (true, false): self = .arribaIzquierda
        case (false, true): self = .abajoDerecha
        case (false, false): self = .abajoIzquierda
        }
    }

    var arriba: Bool { self == .arribaDerecha || self == .arribaIzquierda }
    var derecha: Bool { self == .arribaDerecha || self == .abajoDerecha }
}

enum Presentacion: Equatable {
    case contraida
    case asomada(String)
    case expandida
}

/// Estado de la interfaz compartido entre AppKit y SwiftUI.
final class Interfaz: ObservableObject {
    @Published var presentacion: Presentacion = .contraida
    @Published var esquina: Esquina = .arribaDerecha
    @Published var altoMaximo: CGFloat = 520

    /// Identificadores de `Tonos.catalogo`.
    @Published var tonoAtencion: String {
        didSet { UserDefaults.standard.set(tonoAtencion, forKey: "tonoAtencion") }
    }
    @Published var tonoTermino: String {
        didSet { UserDefaults.standard.set(tonoTermino, forKey: "tonoTermino") }
    }
    @Published var asomarse: Bool { didSet { UserDefaults.standard.set(asomarse, forKey: "asomarse") } }
    @Published var mostrarInactivas: Bool {
        didSet { UserDefaults.standard.set(mostrarInactivas, forKey: "mostrarInactivas") }
    }

    var alternar: () -> Void = {}
    var ir: (Sesion) -> Void = { _ in }
    var arrastrar: (_ terminado: Bool) -> Void = { _ in }
    var marcarTodo: () -> Void = {}
    var decidir: (Solicitud, _ permitir: Bool) -> Void = { _, _ in }

    init() {
        let d = UserDefaults.standard
        d.register(defaults: ["asomarse": true, "mostrarInactivas": true])
        // Versiones anteriores: un solo interruptor "sonido", y despues tonos
        // sintetizados que se reemplazaron por los de macOS. Se vuelve a los
        // predeterminados, salvo si el sonido estaba apagado.
        if d.integer(forKey: "versionTonos") < 3 {
            let todoApagado = d.object(forKey: "sonido") as? Bool == false
            for clave in ["tonoAtencion", "tonoTermino"] {
                if todoApagado || d.string(forKey: clave) == "ninguno" {
                    d.set("ninguno", forKey: clave)
                } else {
                    d.removeObject(forKey: clave)
                }
            }
            d.removeObject(forKey: "sonido")
            d.set(3, forKey: "versionTonos")
        }
        tonoAtencion = Tonos.valido(d.string(forKey: "tonoAtencion"), siNo: Tonos.porDefectoAtencion)
        tonoTermino = Tonos.valido(d.string(forKey: "tonoTermino"), siNo: Tonos.porDefectoTermino)
        asomarse = d.bool(forKey: "asomarse")
        mostrarInactivas = d.bool(forKey: "mostrarInactivas")
    }
}

/// Panel sin borde que nunca toma el foco: hacer clic en el widget no le
/// quita el teclado a VS Code.
final class PanelFlotante: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 50),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Acepta el primer clic aunque la app no este activa, avisa cuando el
/// puntero entra o sale (para no cerrar un aviso que se esta leyendo) y
/// cuando cambia el tamaño ideal del contenido SwiftUI.
///
/// El tamaño se obtiene de `intrinsicContentSize`: SwiftUI invalida ese valor
/// cada vez que su contenido cambia de tamaño. `onPreferenceChange` con un
/// GeometryReader no sirve aqui: dentro del panel solo se dispara una vez,
/// con el valor por defecto.
final class VistaAnfitriona: NSHostingView<VistaRaiz> {
    var alCambiarPuntero: ((Bool) -> Void)?
    var alCambiarTamano: ((CGSize) -> Void)?
    var menuContextual: (() -> NSMenu)?
    private var zona: NSTrackingArea?
    private var avisoPendiente = false

    required init(rootView: VistaRaiz) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Menu de AppKit y no `.contextMenu` de SwiftUI: en un panel que nunca
    /// toma el foco, el de SwiftUI no es fiable, y es la unica via para salir.
    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuContextual?() else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        avisarTamano()
    }

    /// Se difiere al siguiente ciclo para leer el tamaño ya recalculado y
    /// agrupar varias invalidaciones seguidas en un solo aviso.
    func avisarTamano() {
        guard !avisoPendiente else { return }
        avisoPendiente = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.avisoPendiente = false
            let t = self.intrinsicContentSize
            if t.width > 0, t.height > 0 { self.alCambiarTamano?(t) }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let zona { removeTrackingArea(zona) }
        let nueva = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(nueva)
        zona = nueva
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        alCambiarPuntero?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        alCambiarPuntero?(false)
    }
}

final class Controlador: NSObject {
    let vigia = Vigia()
    let ui = Interfaz()
    let permisos = GestorPermisos()
    private(set) var panel: PanelFlotante!
    private var suscripciones: [AnyCancellable] = []
    private var muestra: Timer?
    private var muestraSonando = false
    /// Tono cuya muestra esta programada o sonando (evita repetirla).
    private var idMuestra: String?

    /// Punto de la pantalla donde queda fija la esquina del panel. El panel
    /// crece desde ahi hacia el lado con espacio.
    private var ancla = NSPoint.zero
    private var tamano = CGSize.zero
    private var desfase: NSPoint?
    private var cierre: Timer?
    private var punteroDentro = false
    private var monitorClics: Any?

    static let margen: CGFloat = 8
    static let duracionAsomo: TimeInterval = 4
    /// Con un permiso que aprobar hace falta mas tiempo para llegar al boton.
    static let duracionPermiso: TimeInterval = 10

    func iniciar() {
        // La posicion se carga antes de crear la vista: SwiftUI informa su
        // tamaño apenas se asigna como contenido, y colocar() necesita el ancla.
        cargarPosicion()
        ui.alternar = { [weak self] in self?.alternar() }
        ui.ir = { [weak self] s in self?.ir(a: s) }
        ui.arrastrar = { [weak self] terminado in self?.arrastrar(terminado: terminado) }
        ui.marcarTodo = { [weak self] in self?.vigia.marcarTodas() }
        ui.decidir = { [weak self] s, permitir in self?.decidir(s, permitir: permitir) }

        panel = PanelFlotante()
        let anfitrion = VistaAnfitriona(rootView: VistaRaiz(vigia: vigia, ui: ui, permisos: permisos))
        anfitrion.sizingOptions = [.intrinsicContentSize]
        anfitrion.autoresizingMask = [.width, .height]
        anfitrion.alCambiarPuntero = { [weak self] dentro in self?.cambioPuntero(dentro) }
        anfitrion.alCambiarTamano = { [weak self] t in self?.redimensionar(t) }
        anfitrion.menuContextual = { [weak self] in self?.construirMenu() ?? NSMenu() }
        panel.contentView = anfitrion
        anfitrion.avisarTamano()
        panel.orderFrontRegardless()

        vigia.alOcurrir = { [weak self] e in self?.manejar(e) }
        permisos.alLlegar = { [weak self] s in self?.asomarPorPermiso(s.sesion) }
        permisos.alQuedarSinEfecto = { [weak self] sesion in self?.asomarPorPermiso(sesion) }
        permisos.iniciar()
        suscripciones.append(vigia.$sesiones.sink { [weak self] s in self?.permisos.sincronizar(s) })
        suscripciones.append(ui.$presentacion.removeDuplicates().sink { [weak self] p in self?.ajustarMonitor(p) })
        vigia.iniciar()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [ui] in
            Sonido.preparar([ui.tonoAtencion, ui.tonoTermino])
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(pantallasCambiaron),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    // MARK: - Presentacion

    private func alternar() {
        cierre?.invalidate()
        if ui.presentacion == .expandida {
            ui.presentacion = .contraida
        } else {
            ui.altoMaximo = altoDisponible()
            ui.presentacion = .expandida
            vigia.refrescar()
        }
    }

    private func contraer() {
        cierre?.invalidate()
        if ui.presentacion != .contraida { ui.presentacion = .contraida }
    }

    /// Un clic en cualquier otra app contrae el widget. El monitor global
    /// (no requiere Accesibilidad) solo existe mientras hay algo abierto:
    /// contraido no recibe un evento por cada clic del sistema.
    private func ajustarMonitor(_ p: Presentacion) {
        if p == .contraida {
            if let m = monitorClics {
                NSEvent.removeMonitor(m)
                monitorClics = nil
            }
        } else if monitorClics == nil {
            monitorClics = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.contraer()
            }
        }
    }

    /// Asoma la tarjeta de una sesion con algo que contestar: una peticion
    /// nueva, o una aprobacion que VS Code no tomo.
    private func asomarPorPermiso(_ sesion: String) {
        guard ui.asomarse, desfase == nil else { return }
        switch ui.presentacion {
        case .expandida:
            return
        case .asomada(let id) where id == sesion:
            programarCierre(Self.duracionPermiso)
        default:
            guard vigia.sesiones.contains(where: { $0.id == sesion }) else { return }
            ui.presentacion = .asomada(sesion)
            programarCierre(Self.duracionPermiso)
        }
    }

    private func decidir(_ s: Solicitud, permitir: Bool) {
        permisos.decidir(s, permitir: permitir)
        if case .asomada(let id) = ui.presentacion, id == s.sesion, permisos.de(id).isEmpty {
            contraer()
        }
    }

    private func ir(a s: Sesion) {
        vigia.marcarVista(s.id)
        contraer()
        Enfoque.ir(a: s)
    }

    private func manejar(_ e: Evento) {
        switch e {
        case .atencion: Sonido.reproducir(ui.tonoAtencion)
        case .termino: Sonido.reproducir(ui.tonoTermino)
        }
        guard ui.asomarse, ui.presentacion != .expandida, desfase == nil else { return }
        ui.presentacion = .asomada(e.sesion.id)
        programarCierre(permisos.de(e.sesion.id).isEmpty ? Self.duracionAsomo : Self.duracionPermiso)
    }

    private func programarCierre(_ segundos: TimeInterval) {
        cierre?.invalidate()
        cierre = Timer.scheduledTimer(withTimeInterval: segundos, repeats: false) { [weak self] _ in
            guard let self else { return }
            guard case .asomada = self.ui.presentacion else { return }
            if self.punteroDentro {
                self.programarCierre(1.5)
            } else {
                self.ui.presentacion = .contraida
            }
        }
    }

    private func cambioPuntero(_ dentro: Bool) {
        punteroDentro = dentro
        if !dentro, case .asomada = ui.presentacion { programarCierre(1.5) }
    }

    // MARK: - Menu

    func construirMenu() -> NSMenu {
        let menu = NSMenu()
        func item(_ titulo: String, _ accion: Selector, activo: Bool? = nil) {
            let i = NSMenuItem(title: titulo, action: accion, keyEquivalent: "")
            i.target = self
            if let activo { i.state = activo ? .on : .off }
            menu.addItem(i)
        }
        menu.addItem(submenuTono("Sonido al pedir atención", actual: ui.tonoAtencion, atencion: true))
        menu.addItem(submenuTono("Sonido al terminar", actual: ui.tonoTermino, atencion: false))
        menu.addItem(.separator())
        item("Asomarse cuando hay un aviso", #selector(alternarAsomo), activo: ui.asomarse)
        item("Mostrar sesiones inactivas", #selector(alternarInactivas), activo: ui.mostrarInactivas)
        menu.addItem(.separator())
        item("Marcar todo como visto", #selector(marcarTodo))
        menu.addItem(.separator())
        item("Salir de Sauron", #selector(salir))
        return menu
    }

    /// Submenu con los tonos. Detenerse sobre uno lo hace sonar; un clic lo
    /// elige y el menu sigue abierto (filas con vista propia, ver
    /// MenuTonos.swift), para probar varios seguidos.
    private func submenuTono(_ titulo: String, actual: String, atencion: Bool) -> NSMenuItem {
        let raiz = NSMenuItem(title: titulo, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.delegate = self
        // Los items con vista no tienen accion: sin esto el menu los
        // deshabilitaria y no se resaltarian.
        sub.autoenablesItems = false
        for grupo in Tono.Grupo.allCases {
            let tonos = Tonos.disponibles.filter { $0.grupo == grupo }
            guard !tonos.isEmpty else { continue }
            if !sub.items.isEmpty { sub.addItem(.separator()) }
            if grupo != .ninguno {
                let cabecera = NSMenuItem()
                cabecera.view = VistaTituloMenu(grupo.rawValue)
                cabecera.isEnabled = false
                sub.addItem(cabecera)
            }
            for t in tonos {
                let i = NSMenuItem()
                i.representedObject = t.id
                i.isEnabled = true
                let vista = VistaTonoMenu(id: t.id, etiqueta: t.etiqueta, marcado: t.id == actual)
                vista.alElegir = { [weak self, weak sub] id in self?.elegirTono(id, atencion: atencion, en: sub) }
                vista.alResaltar = { [weak self] id in self?.programarMuestra(id) }
                i.view = vista
                sub.addItem(i)
            }
        }
        raiz.submenu = sub
        return raiz
    }

    private func elegirTono(_ id: String, atencion: Bool, en menu: NSMenu?) {
        guard Tonos.tono(id) != nil else { return }
        if atencion { ui.tonoAtencion = id } else { ui.tonoTermino = id }
        for v in menu?.items.compactMap({ $0.view as? VistaTonoMenu }) ?? [] {
            v.marcado = v.id == id
        }
        // Suena entero; no es una muestra que haya que cortar al moverse.
        muestra?.invalidate()
        muestra = nil
        muestraSonando = false
        idMuestra = id
        Sonido.reproducir(id)
    }

    /// Programa la muestra de un tono tras una breve espera (para que no
    /// suenen todos al recorrer el menu). El temporizador va en modo comun:
    /// con el menu abierto el bucle corre en modo de seguimiento.
    fileprivate func programarMuestra(_ id: String) {
        guard id != idMuestra else { return }
        cancelarMuestra()
        idMuestra = id
        let t = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.muestraSonando = true
            Sonido.reproducir(id)
        }
        RunLoop.main.add(t, forMode: .common)
        muestra = t
    }

    /// Corta solo una muestra: un tono recien elegido sigue sonando.
    fileprivate func cancelarMuestra() {
        muestra?.invalidate()
        muestra = nil
        idMuestra = nil
        if muestraSonando {
            muestraSonando = false
            Sonido.detener()
        }
    }
    @objc private func alternarAsomo() { ui.asomarse.toggle() }
    @objc private func alternarInactivas() { ui.mostrarInactivas.toggle() }
    @objc private func marcarTodo() { vigia.marcarTodas() }
    @objc private func salir() { NSApp.terminate(nil) }

    // MARK: - Geometria

    private func redimensionar(_ t: CGSize) {
        guard t.width > 1, t.height > 1 else { return }
        let nuevo = CGSize(width: ceil(t.width), height: ceil(t.height))
        // SwiftUI invalida el tamaño en cada cuadro de una animacion aunque
        // no cambie; mover la ventana sin necesidad cuesta CPU.
        guard nuevo != tamano else { return }
        tamano = nuevo
        colocar()
    }

    private func colocar() {
        guard tamano.width > 1 else { return }
        let e = ui.esquina
        let origen = NSPoint(
            x: e.derecha ? ancla.x - tamano.width : ancla.x,
            y: e.arriba ? ancla.y - tamano.height : ancla.y
        )
        panel.setFrame(NSRect(origin: origen, size: tamano), display: true)
    }

    private func arrastrar(terminado: Bool) {
        if terminado {
            desfase = nil
            reanclar()
            return
        }
        let raton = NSEvent.mouseLocation
        if desfase == nil {
            contraer()
            desfase = NSPoint(x: raton.x - ancla.x, y: raton.y - ancla.y)
        }
        guard let d = desfase else { return }
        ancla = NSPoint(x: raton.x - d.x, y: raton.y - d.y)
        colocar()
    }

    /// Tras mover el panel: lo mete dentro de la pantalla y elige la esquina
    /// segun el cuadrante en que quedo, para que al expandirse crezca hacia
    /// el centro.
    private func reanclar() {
        guard let pantalla = panel.screen ?? NSScreen.main else { return }
        let v = pantalla.visibleFrame
        var f = panel.frame
        f.origin.x = min(max(f.minX, v.minX), v.maxX - f.width)
        f.origin.y = min(max(f.minY, v.minY), v.maxY - f.height)
        let derecha = f.midX > v.midX
        let arriba = f.midY > v.midY
        ui.esquina = Esquina(arriba: arriba, derecha: derecha)
        ancla = NSPoint(x: derecha ? f.maxX : f.minX, y: arriba ? f.maxY : f.minY)
        colocar()
        guardarPosicion()
    }

    private func altoDisponible() -> CGFloat {
        guard let pantalla = panel.screen ?? NSScreen.main else { return 520 }
        let v = pantalla.visibleFrame
        let libre = ui.esquina.arriba ? ancla.y - v.minY : v.maxY - ancla.y
        return max(200, min(560, libre - 80))
    }

    @objc private func pantallasCambiaron() {
        reanclar()
    }

    private func cargarPosicion() {
        let d = UserDefaults.standard
        if let texto = d.string(forKey: "esquina"), let e = Esquina(rawValue: texto),
           d.object(forKey: "anclaX") != nil {
            let p = NSPoint(x: d.double(forKey: "anclaX"), y: d.double(forKey: "anclaY"))
            if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -2, dy: -2).contains(p) }) {
                ui.esquina = e
                ancla = p
                return
            }
        }
        let v = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        ui.esquina = .arribaDerecha
        ancla = NSPoint(x: v.maxX - Self.margen, y: v.maxY - Self.margen)
    }

    private func guardarPosicion() {
        let d = UserDefaults.standard
        d.set(ui.esquina.rawValue, forKey: "esquina")
        d.set(Double(ancla.x), forKey: "anclaX")
        d.set(Double(ancla.y), forKey: "anclaY")
    }
}

// MARK: - Vista previa de sonidos

extension Controlador: NSMenuDelegate {
    /// Al detenerse sobre un tono suena una muestra (las filas tambien lo
    /// detectan al redibujarse; `programarMuestra` no la repite).
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard let id = item?.representedObject as? String, Tonos.tono(id) != nil else {
            cancelarMuestra()
            return
        }
        programarMuestra(id)
    }

    func menuDidClose(_ menu: NSMenu) {
        cancelarMuestra()
    }
}
