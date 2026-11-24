import SwiftUI

/// Raiz: la pildora queda siempre en la esquina de anclaje y el contenido
/// (aviso o lista) crece hacia el centro de la pantalla.
struct VistaRaiz: View {
    @ObservedObject var vigia: Vigia
    @ObservedObject var ui: Interfaz
    @ObservedObject var permisos: GestorPermisos

    var body: some View {
        let e = ui.esquina
        VStack(alignment: e.derecha ? .trailing : .leading, spacing: 8) {
            if !e.arriba { contenido }
            Pildora(sesiones: vigia.sesiones, ui: ui)
            if e.arriba { contenido }
        }
        .padding(12)
        .fixedSize()
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var contenido: some View {
        switch ui.presentacion {
        case .contraida:
            EmptyView()
        case .asomada(let id):
            if let s = vigia.sesiones.first(where: { $0.id == id }) {
                Aviso(sesion: s, solicitudes: permisos.de(id), sinEfecto: permisos.sinEfecto.contains(id), ui: ui)
            }
        case .expandida:
            Lista(sesiones: visibles, solicitudes: Dictionary(grouping: permisos.pendientes, by: \.sesion),
                  sinEfecto: permisos.sinEfecto, ui: ui)
        }
    }

    private var visibles: [Sesion] {
        ui.mostrarInactivas ? vigia.sesiones : vigia.sesiones.filter { $0.fase != .inactiva }
    }
}

/// Lo que se asoma unos segundos al ocurrir un evento: carpeta y sesion, y
/// el permiso que pide si lo hay.
struct Aviso: View {
    let sesion: Sesion
    var solicitudes: [Solicitud] = []
    var sinEfecto = false
    @ObservedObject var ui: Interfaz

    var body: some View {
        Tarjeta(ancho: 320) {
            VStack(alignment: .leading, spacing: 2) {
                Text(sesion.nombreCarpeta)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                FilaSesion(sesion: sesion, solicitudes: solicitudes, sinEfecto: sinEfecto,
                           alPulsar: { ui.ir(sesion) }, decidir: ui.decidir)
                    .padding(.bottom, 4)
            }
        }
    }
}

// MARK: - Pildora

struct Pildora: View {
    let sesiones: [Sesion]
    @ObservedObject var ui: Interfaz

    private var atencion: Int { sesiones.filter { $0.fase == .atencion }.count }
    private var termino: Int { sesiones.filter { $0.fase == .termino }.count }
    private var trabajando: Int { sesiones.filter { $0.fase == .trabajando }.count }

    var body: some View {
        let a = atencion
        return Contadores(total: sesiones.count, atencion: a, termino: termino, trabajando: trabajando)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(Capsule().fill(Tema.fondo.opacity(0.95)))
            .overlay(Capsule().strokeBorder(colorBorde, lineWidth: 1.5))
            .shadow(color: Color.black.opacity(0.45), radius: 4, y: 1)
            .background { if a > 0 { AnilloPulso() } }
            .contentShape(Capsule())
            .onTapGesture { ui.alternar() }
            .gesture(arrastre)
            .help("Clic: ver sesiones · Arrastrar: mover · Clic derecho: opciones")
    }

    private var arrastre: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { _ in ui.arrastrar(false) }
            .onEnded { _ in ui.arrastrar(true) }
    }

    private var colorBorde: Color {
        if atencion > 0 { return Tema.ambar.opacity(0.9) }
        if termino > 0 { return Tema.verde.opacity(0.85) }
        if trabajando > 0 { return Tema.claude.opacity(0.45) }
        return Tema.borde
    }
}

/// Halo ambar que late mientras alguna sesion espera. Es Core Animation
/// (ver HaloPulso): con un TimelineView a 30 cuadros costaba ~5 % de CPU
/// durante toda la espera. Tampoco sirve `withAnimation(.repeatForever)`:
/// arrastra a todo lo que cambie en la misma transaccion.
struct AnilloPulso: View {
    @Environment(\.esCaptura) private var esCaptura

    var body: some View {
        if esCaptura {
            // ImageRenderer no dibuja vistas de AppKit: el halo en su punto alto.
            Capsule()
                .strokeBorder(Tema.ambar, lineWidth: 2)
                .shadow(color: Tema.ambar.opacity(0.65), radius: 8)
        } else {
            HaloPulso()
        }
    }
}

struct Contadores: View {
    let total: Int
    let atencion: Int
    let termino: Int
    let trabajando: Int

    var body: some View {
        HStack(spacing: 8) {
            Ojo(vigilando: trabajando > 0)
            if trabajando > 0 {
                Text(verbatim: "\(trabajando)").foregroundStyle(Tema.claude)
            }
            if atencion > 0 {
                HStack(spacing: 4) {
                    Circle().fill(Tema.ambar).frame(width: 7, height: 7)
                    Text(verbatim: "\(atencion)").foregroundStyle(Tema.ambar)
                }
            }
            if termino > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy))
                    Text(verbatim: "\(termino)")
                }
                .foregroundStyle(Tema.verde)
            }
            if atencion + termino + trabajando == 0 {
                Text(verbatim: total == 0 ? "–" : "\(total)").foregroundStyle(Color.secondary)
            }
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
    }
}

/// El Ojo de la pildora (ver Logo). Mientras alguna sesion trabaja, la
/// mirada recorre de lado a lado.
struct Ojo: View {
    let vigilando: Bool
    @Environment(\.esCaptura) private var esCaptura
    @Environment(\.displayScale) private var escala

    static let tamano = CGSize(width: 26, height: 16)

    var body: some View {
        Group {
            if vigilando && !esCaptura {
                CuadrosAnimados(tamano: Self.tamano, paso: Logo.pasoMirada) { escala in
                    Logo.cuadrosMirada(tamano: Self.tamano, escala: escala)
                }
            } else if let imagen = Logo.ojo(tamano: Self.tamano, escala: escala, mirada: vigilando ? 0.5 : 0) {
                // En las capturas, un cuadro fijo con la mirada de lado.
                Image(decorative: imagen, scale: escala)
            }
        }
        .frame(width: Self.tamano.width, height: Self.tamano.height)
    }
}

/// El destello de Claude. Mientras hay trabajo recorre los mismos cuadros
/// que el indicador de la CLI. La animacion es de Core Animation (ver
/// CuadrosAnimados): con un TimelineView costaba ~3 % de CPU de forma
/// sostenida, que es casi todo el dia si alguna sesion trabaja.
struct Destello: View {
    let girando: Bool
    var tamano: CGFloat = 15
    @Environment(\.esCaptura) private var esCaptura

    static let cuadros = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]
    static let paso: TimeInterval = 0.12

    var body: some View {
        Group {
            if girando && !esCaptura {
                // ImageRenderer no dibuja vistas de AppKit: en las capturas
                // va un cuadro fijo del giro.
                CuadrosAnimados(tamano: CGSize(width: tamano + 2, height: tamano + 2), paso: Self.paso) { escala in
                    Self.imagenes(tamano: tamano, escala: escala)
                }
            } else {
                Text(girando ? "✶" : "✻")
                    .font(.system(size: tamano, weight: .bold))
                    .foregroundStyle(Tema.claude)
            }
        }
        .frame(width: tamano + 2, height: tamano + 2)
    }
}

private struct ClaveCaptura: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Verdadero al renderizar con `--capturas`.
    var esCaptura: Bool {
        get { self[ClaveCaptura.self] }
        set { self[ClaveCaptura.self] = newValue }
    }
}

// MARK: - Lista

struct Tarjeta<Contenido: View>: View {
    let ancho: CGFloat
    let contenido: Contenido

    init(ancho: CGFloat, @ViewBuilder contenido: () -> Contenido) {
        self.ancho = ancho
        self.contenido = contenido()
    }

    var body: some View {
        contenido
            .frame(width: ancho, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Tema.fondo.opacity(0.97)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Tema.borde))
            .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
    }
}

struct Lista: View {
    let sesiones: [Sesion]
    var solicitudes: [String: [Solicitud]] = [:]
    var sinEfecto = Set<String>()
    @ObservedObject var ui: Interfaz

    private struct Grupo: Identifiable {
        let id: String
        let nombre: String
        let sesiones: [Sesion]
    }

    /// Agrupa por carpeta de ventana conservando el orden por urgencia: el
    /// grupo con la sesion mas urgente va primero.
    private var grupos: [Grupo] {
        var orden: [String] = []
        var porCarpeta: [String: [Sesion]] = [:]
        for s in sesiones {
            if porCarpeta[s.carpeta] == nil { orden.append(s.carpeta) }
            porCarpeta[s.carpeta, default: []].append(s)
        }
        return orden.compactMap { carpeta in
            guard let lista = porCarpeta[carpeta], let primera = lista.first else { return nil }
            return Grupo(id: carpeta, nombre: primera.nombreCarpeta, sesiones: lista)
        }
    }

    var body: some View {
        let g = grupos
        let pendientes = sesiones.reduce(0) { $0 + (solicitudes[$1.id]?.count ?? 0) }
        let altoEstimado = CGFloat(sesiones.count) * 46 + CGFloat(g.count) * 26 + CGFloat(pendientes) * 100 + 16
        Tarjeta(ancho: 340) {
            VStack(alignment: .leading, spacing: 0) {
                cabecera
                Divider().opacity(0.4)
                if sesiones.isEmpty {
                    Text(ui.mostrarInactivas ? "No hay sesiones de Claude Code abiertas en VS Code."
                                             : "Ninguna sesión requiere atención ni está trabajando.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .padding(14)
                } else if altoEstimado > ui.altoMaximo {
                    ScrollView { cuerpo(g) }.frame(height: ui.altoMaximo)
                } else {
                    cuerpo(g)
                }
            }
        }
    }

    private var cabecera: some View {
        let terminadas = sesiones.contains { $0.fase == .termino }
        return HStack(spacing: 6) {
            Text("Claude Code").font(.system(size: 11.5, weight: .bold))
            Text("· \(sesiones.count) \(sesiones.count == 1 ? "sesión" : "sesiones")")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            if terminadas {
                Button("Marcar vistas") { ui.marcarTodo() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Tema.verde)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func cuerpo(_ grupos: [Grupo]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(grupos) { grupo in
                HStack(spacing: 5) {
                    Image(systemName: "folder.fill").font(.system(size: 9))
                    Text(grupo.nombre).font(.system(size: 10.5, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 2)
                .help(grupo.id)

                ForEach(grupo.sesiones) { s in
                    FilaSesion(sesion: s, solicitudes: solicitudes[s.id] ?? [], sinEfecto: sinEfecto.contains(s.id),
                               alPulsar: { ui.ir(s) }, decidir: ui.decidir)
                }
            }
        }
        .padding(.bottom, 6)
    }
}

struct FilaSesion: View {
    let sesion: Sesion
    var solicitudes: [Solicitud] = []
    /// Se aprobo desde Sauron pero la sesion sigue esperando.
    var sinEfecto = false
    let alPulsar: () -> Void
    var decidir: (Solicitud, Bool) -> Void = { _, _ in }
    // `@State` es una macro en este SDK y su plugin solo viene con Xcode. Con
    // Command Line Tools se usa la estructura `State` directamente; su
    // `wrappedValue` tiene `nonmutating set`.
    private let encima = State(initialValue: false)

    var body: some View {
        let s = sesion
        // El clic de la fila lleva a VS Code; el bloque del permiso queda
        // fuera de esa zona para que sus botones no compitan con ella.
        VStack(alignment: .leading, spacing: 6) {
            fila(s)
                .contentShape(Rectangle())
                .onTapGesture(perform: alPulsar)
                .help("\(s.carpeta)\n\(s.titulo)")
            ForEach(solicitudes) { sol in
                BloquePermiso(solicitud: sol, amplio: encima.wrappedValue, abrir: alPulsar) { permitir in
                    decidir(sol, permitir)
                }
            }
            if sinEfecto && solicitudes.isEmpty {
                AvisoSinEfecto(abrir: alPulsar)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(encima.wrappedValue ? 0.07 : 0))
        )
        .padding(.horizontal, 4)
        .onHover { encima.wrappedValue = $0 }
    }

    /// El registro de la sesion no distingue un plan de una pregunta; la
    /// peticion pendiente si.
    private func textoEstado(_ s: Sesion) -> String {
        guard s.fase == .atencion, let tipo = solicitudes.first?.tipo else { return s.textoFase }
        switch tipo {
        case .plan: return "Plan para aprobar"
        case .pregunta: return "Te hace una pregunta"
        case .permiso: return "Pide permiso"
        }
    }

    private func fila(_ s: Sesion) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(s.modo.color)
                .frame(width: 3, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(s.titulo)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(s.fase == .inactiva ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    IconoFase(fase: s.fase)
                    Text(textoEstado(s)).foregroundStyle(s.fase.color)
                    if s.modo != .desconocido {
                        Text(s.modo.etiqueta)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(s.modo.color)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(s.modo.color.opacity(0.16)))
                    }
                    Spacer(minLength: 4)
                    Relativo(desde: s.desde).foregroundStyle(.tertiary)
                }
                .font(.system(size: 10.5, weight: .medium))
            }
        }
    }
}

/// Lo que pide un permiso y los botones para contestarlo. El texto completo
/// (descripcion, contenido, cambios) queda en el tooltip; al pasar el
/// puntero por la fila se muestran mas lineas.
struct BloquePermiso: View {
    let solicitud: Solicitud
    let amplio: Bool
    /// Llevar a la sesion en VS Code (para lo que no se contesta aqui).
    let abrir: () -> Void
    let decidir: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: solicitud.icono).font(.system(size: 9.5, weight: .semibold))
                Text(solicitud.accion).font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(Tema.ambar)
            Text(verbatim: solicitud.objeto)
                .font(solicitud.tipo == .permiso ? .system(size: 10.5, design: .monospaced) : .system(size: 11))
                .foregroundStyle(Color.primary.opacity(0.92))
                .lineLimit(amplio ? 10 : 2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.35)))
                .help(solicitud.detalle)
            HStack(spacing: 8) {
                Spacer()
                switch solicitud.tipo {
                case .permiso:
                    boton("Rechazar", color: Tema.rojo, relleno: false) { decidir(false) }
                    boton("Permitir", color: Tema.verde, relleno: true) { decidir(true) }
                case .plan:
                    boton("Seguir planificando", color: Tema.rojo, relleno: false) { decidir(false) }
                    boton("Aprobar plan", color: Tema.verde, relleno: true) { decidir(true) }
                case .pregunta:
                    boton("Responder en VS Code", color: Tema.ambar, relleno: true, accion: abrir)
                }
            }
        }
        .padding(.leading, 13)
    }

    private func boton(_ titulo: String, color: Color, relleno: Bool, accion: @escaping () -> Void) -> some View {
        Button(action: accion) {
            Text(titulo)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(relleno ? Color.black.opacity(0.85) : color)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Capsule().fill(relleno ? color : color.opacity(0.14)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct IconoFase: View {
    let fase: Fase

    var body: some View {
        switch fase {
        case .atencion:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Tema.ambar)
        case .termino:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Tema.verde)
        case .trabajando:
            Destello(girando: true, tamano: 10)
        case .inactiva:
            Image(systemName: "moon.fill").foregroundStyle(Tema.gris)
        }
    }
}

struct Relativo: View {
    let desde: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { contexto in
            Text(Self.texto(contexto.date.timeIntervalSince(desde)))
        }
    }

    static func texto(_ s: TimeInterval) -> String {
        if s < 60 { return "hace un momento" }
        if s < 3600 { return "hace \(Int(s / 60)) min" }
        if s < 86400 { return "hace \(Int(s / 3600)) h" }
        return "hace \(Int(s / 86400)) d"
    }
}

/// Se aprobo desde Sauron, pero la sesion sigue esperando: Claude Code no
/// tomo la respuesta (por ejemplo, una herramienta que solo acepta la del
/// dialogo de VS Code).
struct AvisoSinEfecto: View {
    let abrir: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tema.ambar)
            Text("VS Code no tomó la respuesta de Sauron. Contesta allí.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: abrir) {
                Text("Abrir").foregroundStyle(Tema.ambar)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 10.5, weight: .medium))
        .padding(.leading, 13)
    }
}
